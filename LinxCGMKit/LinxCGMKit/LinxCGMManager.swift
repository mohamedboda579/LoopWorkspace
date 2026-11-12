import Foundation
import HealthKit
import LoopKit
import os.log
#if canImport(UIKit)
    import UIKit
#endif

public protocol LinxStateObserver: AnyObject {
    func linxStateDidUpdate(_ state: LinxCGMManagerState)
    func linxStatusDidUpdate(_ status: String)
    /// List of Linx sensors detected in range changed (for picker).
    func linxNearbyDevicesDidUpdate(_ devices: [LinxNearbyDevice])
    func linxSensorSessionDidUpdate(startDate: Date?, endDate: Date?)
}

public extension LinxStateObserver {
    // Backward-compatible default: optional for observers that don't care.
    func linxNearbyDevicesDidUpdate(_: [LinxNearbyDevice]) {}
    func linxSensorSessionDidUpdate(startDate _: Date?, endDate _: Date?) {}
}

/// A Linx sensor detected in range for the picker list.
public struct LinxNearbyDevice: Identifiable, Equatable {
    /// Advertised full name (e.g. "LinX-2222296PN2") — also used as the identifier.
    public let name: String
    /// Last measured signal strength (dBm).
    public let rssi: Int
    public var id: String { name }
    public init(name: String, rssi: Int) {
        self.name = name
        self.rssi = rssi
    }
}

public class LinxCGMManager: CGMManager {
    private let log = OSLog(subsystem: "com.linxcgmkit", category: "LinxCGMManager")

    // MARK: - State

    private var lockedState: LinxCGMManagerState
    private let stateLock = NSLock()

    public var state: LinxCGMManagerState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lockedState
    }

    private func mutateState(_ changes: (inout LinxCGMManagerState) -> Void) {
        stateLock.lock()
        var newValue = lockedState
        changes(&newValue)
        let changed = newValue != lockedState
        lockedState = newValue
        stateLock.unlock()

        if changed {
            delegateQueue?.async {
                self.cgmManagerDelegate?.cgmManagerDidUpdateState(self)
                self.cgmManagerDelegate?.cgmManager(self, didUpdate: self.cgmManagerStatus)
            }
            stateObservers.forEach { $0.linxStateDidUpdate(newValue) }
        }
    }

    /// Observers are held weakly so a closed settings screen does not stay
    /// alive (and keep receiving updates) for the lifetime of the manager.
    private final class WeakObserver {
        weak var value: LinxStateObserver?
        init(_ value: LinxStateObserver) { self.value = value }
    }

    private let observersLock = NSLock()
    private var weakStateObservers: [WeakObserver] = []

    private var stateObservers: [LinxStateObserver] {
        observersLock.lock()
        defer { observersLock.unlock() }
        weakStateObservers.removeAll { $0.value == nil }
        return weakStateObservers.compactMap(\.value)
    }

    public func addStateObserver(_ observer: LinxStateObserver) {
        observersLock.lock()
        defer { observersLock.unlock() }
        guard !weakStateObservers.contains(where: { $0.value === observer }) else { return }
        weakStateObservers.append(WeakObserver(observer))
    }

    public func removeStateObserver(_ observer: LinxStateObserver) {
        observersLock.lock()
        defer { observersLock.unlock() }
        weakStateObservers.removeAll { $0.value == nil || $0.value === observer }
    }

    // MARK: - Scanner

    private let scanner = LinxScanner()
    private var lastStatus: String = "Starting..."
    public var latestReading: LinxGlucoseReading?
    public private(set) var sensorSessionStartDate: Date?
    public private(set) var sensorSessionEndDate: Date?

    /// Linx sensors detected in range (name → last RSSI + time).
    /// Populated by the scanner; listed by the picker UI.
    private var nearbyDevicesByName: [String: (rssi: Int, seen: Date)] = [:]

    /// Currently known in-range Linx sensors, sorted by decreasing signal strength.
    /// We keep devices seen within the last 30 seconds.
    public var nearbyDevices: [LinxNearbyDevice] {
        let cutoff = Date().addingTimeInterval(-30)
        return nearbyDevicesByName
            .filter { $0.value.seen >= cutoff }
            .map { LinxNearbyDevice(name: $0.key, rssi: $0.value.rssi) }
            .sorted { $0.rssi > $1.rssi }
    }

    /// DiaExpert reports every minute, but AID dosing runs on a five-minute cycle.
    /// Keep all minute values for HUD and smoothing, while passing only one sample
    /// per five-minute window to Loop. The 10-second tolerance below absorbs BLE
    /// delivery jitter around the nominal boundary.
    public static let loopCycleInterval: TimeInterval = 5 * 60

    /// Time of the last sample actually passed to Loop.
    private var lastSampleSentAt: Date?

    /// Value (mg/dL) of the last sample actually passed to Loop.
    /// We compute trend ourselves from this + the current value
    /// (mg/dL per minute), because the sensor packet does not provide reliable trend direction.
    private var lastSampleValue: Int?

    // MARK: - CGMManager protocol

    public weak var cgmManagerDelegate: CGMManagerDelegate? {
        get { delegate.delegate }
        set { delegate.delegate = newValue }
    }

    public var delegateQueue: DispatchQueue! {
        get { delegate.queue }
        set { delegate.queue = newValue }
    }

    private let delegate = WeakSynchronizedDelegate<CGMManagerDelegate>()

    /// We scan over BLE → we provide the "heartbeat" to Loop.
    public var providesBLEHeartbeat: Bool = true

    public var managedDataInterval: TimeInterval? { 3 * 60 * 60 } // 3 hours in seconds

    public var shouldSyncToRemoteService: Bool { state.uploadReadings }

    public var glucoseDisplay: GlucoseDisplayable? { latestDisplay }

    /// Readings older than this are treated as missing: Loop is told there is
    /// no valid sensor session (closed loop is disallowed) and the HUD marks
    /// the value as invalid.
    public static let readingStaleInterval: TimeInterval = 15 * 60

    /// Signal-loss alert fires after this long without a reading.
    public static let signalLossAlertInterval: TimeInterval = 20 * 60

    /// True only while recent readings are arriving from the selected sensor
    /// and the sensor session (when known) has not ended.
    public var hasValidSensorSession: Bool {
        let now = Date()
        guard state.sensorSerial?.isEmpty == false,
              let last = state.latestReadingDate,
              now.timeIntervalSince(last) <= Self.readingStaleInterval
        else { return false }
        if let end = sensorSessionEndDate, now >= end { return false }
        return true
    }

    public var cgmManagerStatus: CGMManagerStatus {
        CGMManagerStatus(
            hasValidSensorSession: hasValidSensorSession,
            lastCommunicationDate: state.latestReadingDate,
            device: device
        )
    }

    public var device: HKDevice? {
        HKDevice(
            name: state.sensorSerial ?? "DiaExpert Sensor 2",
            manufacturer: "DiaExpert",
            model: "DiaExpert Sensor 2",
            hardwareVersion: nil,
            firmwareVersion: nil,
            softwareVersion: "LinxCGMKit",
            localIdentifier: state.sensorSerial,
            udiDeviceIdentifier: nil
        )
    }

    public static let pluginIdentifier: String = "LinxCGMManager"

    public let localizedTitle = "LinX CGM (experimental)"

    public let isOnboarded = true

    public var appURL: URL? { nil }

    public var debugDescription: String {
        """
        ## LinxCGMManager
        sensorSerial: \(String(describing: state.sensorSerial))
        calA: \(state.calibration.calA) calB: \(state.calibration.calB)
        calPoints: \(state.calibration.points.count)
        gattCalA: \(state.gattCalibration.calA) gattCalB: \(state.gattCalibration.calB)
        gattCalPoints: \(state.gattCalibration.points.count)
        latestReadingDate: \(String(describing: state.latestReadingDate))
        lastStatus: \(lastStatus)
        """
    }

    // MARK: - Init

    public init() {
        lockedState = LinxCGMManagerState()
        scanner.delegate = self
    }

    public required init?(rawState: RawStateValue) {
        lockedState = LinxCGMManagerState(rawValue: rawState)
        scanner.delegate = self
    }

    public var rawState: RawStateValue { state.rawValue }

    // MARK: - Calibration control (called by UI)

    @discardableResult
    public func addCalibration(glu10: Int, mmol: Double) -> LinxCalibrationResult {
        var result = LinxCalibrationResult.rejectedNoReading
        mutateState { state in
            if self.scanner.isReceivingViaGATT {
                // GATT input is mg/dL; ~1 mmol/L span needed for a slope fit.
                result = state.gattCalibration.addPoint(
                    glu10: glu10,
                    mmol: mmol,
                    baseSlope: LinxCalibration.gattDefaultCalA,
                    minInputSpan: 18
                )
            } else {
                // Raw advertisement input; ~1 mmol/L span on the base curve.
                result = state.calibration.addPoint(
                    glu10: glu10,
                    mmol: mmol,
                    baseSlope: LinxCalibration.defaultCalA,
                    minInputSpan: 15
                )
            }
        }
        if result == .accepted {
            resetSmoothingAfterCalibrationChange()
        }
        return result
    }

    public func resetCalibration() {
        mutateState { state in
            if self.scanner.isReceivingViaGATT {
                state.gattCalibration = .gattDefault
            } else {
                state.calibration.reset()
            }
        }
        resetSmoothingAfterCalibrationChange()
    }

    public func setSensorSerial(_ serial: String?) {
        mutateState { state in
            state.sensorSerial = (serial?.isEmpty == true) ? nil : serial
        }
    }

    /// Called by the picker UI on open: immediately starts scanning so the in-range
    /// Linx sensor list fills quickly (Loop would otherwise trigger scanning only ~every 5 minutes).
    public func startScanningForPicker() {
        scanner.resumeScanning()
    }

    public var currentStatusText: String { lastStatus }
    public var isReceivingViaGATT: Bool { scanner.isReceivingViaGATT }

    // MARK: - CGMManager methods

    public func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        // CoreBluetooth and the reading pipeline run on the main queue; Loop
        // calls this from its own queue, so hop over to avoid data races.
        DispatchQueue.main.async {
            self.scanner.restartScanIfStale(lastDataAt: self.lastSampleSentAt)
            if !self.scanner.isReceivingViaGATT {
                self.scanner.resumeScanning()
                self.logBackgroundScanDiagnostics(trigger: "heartbeat")
            }
            self.evaluateSignalLoss()
        }
        completion(.noData)
    }

    // MARK: - Signal loss

    private static let signalLossAlertIdentifier: Alert.AlertIdentifier = "LinxSignalLoss"
    private var signalLossAlertIssued = false
    private var lastReportedSessionValidity: Bool?

    private var signalLossAlertID: Alert.Identifier {
        Alert.Identifier(managerIdentifier: Self.pluginIdentifier, alertIdentifier: Self.signalLossAlertIdentifier)
    }

    /// Called on every heartbeat and every reading (main queue). Tells Loop when
    /// the session validity changes (time passing alone changes it) and raises
    /// or clears the signal-loss alert.
    private func evaluateSignalLoss() {
        let valid = hasValidSensorSession
        if valid != lastReportedSessionValidity {
            lastReportedSessionValidity = valid
            let status = cgmManagerStatus
            delegateQueue?.async {
                self.cgmManagerDelegate?.cgmManager(self, didUpdate: status)
            }
        }

        guard state.sensorSerial?.isEmpty == false else { return }
        let reference = state.latestReadingDate
        let silentFor = reference.map { Date().timeIntervalSince($0) } ?? 0
        if reference != nil, silentFor >= Self.signalLossAlertInterval {
            guard !signalLossAlertIssued else { return }
            signalLossAlertIssued = true
            let minutes = Int(silentFor / 60)
            let content = Alert.Content(
                title: "LinX: sin datos",
                body: "No se reciben lecturas del sensor LinX desde hace \(minutes) minutos. Loop no puede ajustar la insulina automáticamente. Comprueba el sensor y el Bluetooth.",
                acknowledgeActionButtonLabel: "OK"
            )
            let alert = Alert(
                identifier: signalLossAlertID,
                foregroundContent: content,
                backgroundContent: content,
                trigger: .immediate
            )
            delegateQueue?.async {
                self.cgmManagerDelegate?.issueAlert(alert)
            }
        } else if signalLossAlertIssued, silentFor < Self.readingStaleInterval {
            signalLossAlertIssued = false
            let identifier = signalLossAlertID
            delegateQueue?.async {
                self.cgmManagerDelegate?.retractAlert(identifier: identifier)
            }
        }
    }

    public func acknowledgeAlert(
        alertIdentifier _: Alert.AlertIdentifier,
        completion: @escaping (Error?) -> Void
    ) {
        completion(nil)
    }

    public func getSoundBaseURL() -> URL? { nil }
    public func getSounds() -> [Alert.Sound] { [] }

    /// Loop calls this on CGM deletion. First stop the scanner and release
    /// CBCentralManager so a later re-add starts from a clean state (otherwise the old
    /// BLE manager and the new one can collide due to shared State Restoration ID →
    /// "does not support BLE" error).
    public func notifyDelegateOfDeletion(completion: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.scanner.stop()
            self.delegateQueue?.async {
                self.cgmManagerDelegate?.cgmManagerWantsDeletion(self)
                completion()
            }
        }
    }

    /// `CGMManager.delete(completion:)` has a protocol-extension default that would
    /// bypass the method above (and leave the BLE scanner running). Override it.
    public func delete(completion: @escaping () -> Void) {
        notifyDelegateOfDeletion(completion: completion)
    }

    // MARK: - Private

    private func logDeviceCommunication(_ message: String, type: DeviceLogEntryType = .receive) {
        cgmManagerDelegate?.deviceManager(
            self,
            logEventForDeviceIdentifier: state.sensorSerial,
            type: type,
            message: message,
            completion: nil
        )
    }

    private func logBackgroundScanDiagnostics(trigger: String) {
        let appState = linxAppStateLabel()

        let sampleAge: String
        if let sentAt = lastSampleSentAt {
            sampleAge = String(format: "%.0fs", Date().timeIntervalSince(sentAt))
        } else {
            sampleAge = "never"
        }
        let advAge: String
        if let advAt = scanner.lastAdvertisementAt {
            advAge = String(format: "%.0fs", Date().timeIntervalSince(advAt))
        } else {
            advAge = "never"
        }
        let restartAge: String
        if let restartAt = scanner.lastScanRestartAt {
            restartAge = String(format: "%.0fs", Date().timeIntervalSince(restartAt))
        } else {
            restartAge = "never"
        }

        let message = """
        Linx bg-scan [\(trigger)]: app=\(appState) scanning=\(scanner.isScanning) \
        lastSample=\(sampleAge) lastAdv=\(advAge) lastRestart=\(restartAge)
        """
        os_log("%{public}@", log: log, type: .info, message)
        logDeviceCommunication(message, type: .connection)
    }

    private func linxAppStateLabel() -> String {
        #if canImport(UIKit)
            let state: UIApplication.State
            if Thread.isMainThread {
                state = UIApplication.shared.applicationState
            } else {
                state = DispatchQueue.main.sync {
                    UIApplication.shared.applicationState
                }
            }
            switch state {
            case .active: return "active"
            case .inactive: return "inactive"
            case .background: return "background"
            @unknown default: return "unknown(\(state.rawValue))"
            }
        #else
            return "unknown"
        #endif
    }

    /// Latest reading as GlucoseDisplayable (for HUD).
    /// Trend arrow comes from our OWN computed value (lastComputedTrend),
    /// not the unreliable sensor trend bit.
    private var latestDisplay: LinxGlucoseDisplay? {
        guard let r = latestReading else { return nil }
        return LinxGlucoseDisplay(
            reading: r,
            trend: lastComputedTrend,
            trendRate: lastComputedTrendRate,
            isStateValid: hasValidSensorSession
        )
    }

    /// Last trend we computed ourselves (from delta).
    private var lastComputedTrend: GlucoseTrend = .flat
    /// Last trend rate we computed ourselves (mg/dL/min).
    private var lastComputedTrendRate: HKQuantity?

    /// A changed curve must take effect on the next value without being blended
    /// with samples produced by the previous curve. Keep the Loop cadence intact.
    private func resetSmoothingAfterCalibrationChange() {
        rawBuffer.removeAll()
        lastSampleValue = nil
        lastComputedTrend = .flat
        lastComputedTrendRate = nil
    }

    // MARK: - Smoothing (accuracy while moving)

    // Broadcast sends the RAW value, which can jump while moving (the official AiDEX app
    // smooths from history). Here we buffer every incoming raw value, and the value passed
    // to Loop is the weighted moving average over the last ~10 minutes (moderate smoothing,
    // fixed). With spike filtering.
    // 10 minutes: enough to filter noise, but not too much lag on rapid drops.
    private var rawBuffer: [(date: Date, mgdl: Int)] = []
    /// Smoothing window length (seconds) — moderate: ~10 minutes.
    private let smoothingWindow: TimeInterval = 10 * 60
    /// Max realistic change mg/dL per minute — beyond this is a spike.
    private let smoothingMaxRatePerMin: Double = 1.5 * 18.0

    /// Buffer a raw value and return the smoothed (weighted moving average) value
    /// for the current window.
    private func smoothedValue(rawMgdl: Int, at date: Date) -> Int {
        rawBuffer.append((date, rawMgdl))
        // Drop old samples outside the window.
        let cutoff = date.addingTimeInterval(-smoothingWindow)
        rawBuffer.removeAll { $0.date < cutoff }
        guard rawBuffer.count >= 2 else { return rawMgdl }

        let sorted = rawBuffer.sorted { $0.date < $1.date }
        var weightedSum = 0.0
        var weightTotal = 0.0
        for (i, s) in sorted.enumerated() {
            var w = Double(i + 1) // linear weight: newer = larger
            if i > 0 {
                let prev = sorted[i - 1]
                let dtMin = max(s.date.timeIntervalSince(prev.date) / 60.0, 0.5)
                let rate = abs(Double(s.mgdl - prev.mgdl)) / dtMin
                if rate > smoothingMaxRatePerMin { w *= 0.3 } // spike → low weight
            }
            weightedSum += Double(s.mgdl) * w
            weightTotal += w
        }
        guard weightTotal > 0 else { return rawMgdl }
        return Int((weightedSum / weightTotal).rounded())
    }

    /// From delta of two consecutive (Loop-passed) values, compute mg/dL/min rate
    /// and GlucoseTrend from it — same as Dexcom/Libre.
    /// Thresholds follow Dexcom conventions.
    private func computeTrend(currentMgdl: Int, currentDate: Date)
        -> (trend: GlucoseTrend, rate: HKQuantity?)
    {
        guard let prevValue = lastSampleValue, let prevAt = lastSampleSentAt else {
            // No previous value → cannot compute trend yet.
            return (.flat, nil)
        }
        let elapsedMin = currentDate.timeIntervalSince(prevAt) / 60.0
        guard elapsedMin > 0.5 else {
            // Interval too short → keep previous.
            return (lastComputedTrend, lastComputedTrendRate)
        }
        // mg/dL per minute.
        let ratePerMin = Double(currentMgdl - prevValue) / elapsedMin
        let rateQuantity = HKQuantity(
            unit: HKUnit(from: "mg/dL").unitDivided(by: .minute()),
            doubleValue: ratePerMin
        )
        let trend: GlucoseTrend
        switch ratePerMin {
        case let r where r >= 3.0: trend = .upUpUp // ⇈ very rapid rise
        case let r where r >= 2.0: trend = .upUp // ⬆ rapid rise
        case let r where r >= 1.0: trend = .up // ↗ rise
        case let r where r <= -3.0: trend = .downDownDown // ⇊ very rapid fall
        case let r where r <= -2.0: trend = .downDown // ⬇ rapid fall
        case let r where r <= -1.0: trend = .down // ↘ fall
        default: trend = .flat // → stable (-1..+1)
        }
        return (trend, rateQuantity)
    }
}

// MARK: - LinxScannerDelegate

extension LinxCGMManager: LinxScannerDelegate {
    public func linxScanner(_: LinxScanner, didRead reading: LinxGlucoseReading) {
        let effectiveReading: LinxGlucoseReading
        if reading.source == .gatt {
            let calibration = state.gattCalibration
            let calibratedMgdl = LinxDecoder.mmolToMgdl(calibration.mmol(forRaw10: reading.raw10))
            effectiveReading = LinxGlucoseReading(
                receivedAt: reading.receivedAt,
                glucoseMgdl: calibratedMgdl,
                trend: reading.trend,
                raw10: reading.raw10,
                serial: reading.serial,
                rawHex: reading.rawHex,
                source: reading.source
            )
        } else {
            effectiveReading = reading
        }

        // Always keep the latest value for HUD display.
        latestReading = effectiveReading

        // SMOOTHING: buffer every incoming raw value (even BEFORE the gate) so the
        // smoothing window fills from per-minute packets.
        let rawClamped = min(max(effectiveReading.glucoseMgdl, 40), 400)
        let smoothed = smoothedValue(rawMgdl: rawClamped, at: effectiveReading.receivedAt)

        // FIVE-MINUTE GATE: buffer every minute value, but only activate Loop
        // once per standard AID cycle. A small tolerance absorbs BLE phase drift.
        if let sentAt = lastSampleSentAt,
           effectiveReading.receivedAt.timeIntervalSince(sentAt) < (Self.loopCycleInterval - 10)
        {
            // Still within loopCycleInterval window → do not activate Loop
            // (but the raw value already entered the smoothing buffer above).
            updateDelegate(with: .noData)
            return
        }

        let unit = HKUnit(from: "mg/dL")
        // Pass the SMOOTHED value to Loop (more stable while moving).
        let clamped = min(max(smoothed, 40), 400)
        let quantity = HKQuantity(unit: unit, doubleValue: Double(clamped))

        // OWN trend calculation: from delta of previous and current (Loop-passed)
        // values — BEFORE updating lastSample* fields.
        let (computedTrend, computedRate) = computeTrend(
            currentMgdl: clamped,
            currentDate: effectiveReading.receivedAt
        )
        lastComputedTrend = computedTrend
        lastComputedTrendRate = computedRate

        lastSampleSentAt = effectiveReading.receivedAt
        lastSampleValue = clamped
        mutateState { state in
            state.latestReadingDate = effectiveReading.receivedAt
        }

        logDeviceCommunication(
            "Linx didRead \(effectiveReading.glucoseMgdl) mg/dL "
                + "(raw10=\(effectiveReading.raw10)) trend=\(computedTrend)"
        )

        let sample = NewGlucoseSample(
            date: effectiveReading.receivedAt,
            quantity: quantity,
            condition: nil,
            trend: computedTrend,
            trendRate: computedRate,
            isDisplayOnly: false,
            wasUserEntered: false,
            syncIdentifier: syncIdentifier(for: effectiveReading),
            device: device
        )

        updateDelegate(with: .newData([sample]))
        evaluateSignalLoss()
    }

    public func linxScanner(_: LinxScanner, didUpdateStatus status: String) {
        lastStatus = status
        if status.hasPrefix("GATT:") {
            logDeviceCommunication(status, type: .connection)
        }
        stateObservers.forEach { $0.linxStatusDidUpdate(status) }
    }

    public func linxScanner(
        _: LinxScanner,
        didUpdateSensorSessionStartDate startDate: Date?,
        endDate: Date?
    ) {
        sensorSessionStartDate = startDate
        sensorSessionEndDate = endDate
        stateObservers.forEach {
            $0.linxSensorSessionDidUpdate(startDate: startDate, endDate: endDate)
        }
    }

    public func calibrationForLinxScanner(_: LinxScanner) -> LinxCalibration {
        state.calibration
    }

    public func sensorSerialForLinxScanner(_: LinxScanner) -> String? {
        state.sensorSerial
    }

    public func linxScanner(_: LinxScanner, didDiscoverDeviceNamed advName: String, rssi: Int) {
        let trimmed = advName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let previous = nearbyDevicesByName[trimmed]
        nearbyDevicesByName[trimmed] = (rssi: rssi, seen: Date())

        // Notify the UI only when a new device appears, or signal strength
        // changed meaningfully (≥4 dBm) — avoids unnecessary churn.
        let isNew = previous == nil
        let rssiChanged = (previous.map { abs($0.rssi - rssi) >= 4 }) ?? true
        if isNew || rssiChanged {
            let snapshot = nearbyDevices
            let observers = stateObservers
            // Observers hop to the main queue themselves; do not depend on Loop's
            // delegateQueue, which may not be set yet during onboarding.
            observers.forEach { $0.linxNearbyDevicesDidUpdate(snapshot) }
        }
    }

    private func syncIdentifier(for reading: LinxGlucoseReading) -> String {
        // Stable but unique per-reading identifier for Loop de-duplication.
        let secs = Int(reading.receivedAt.timeIntervalSince1970)
        return "Linx-\(state.sensorSerial ?? "any")-\(secs)-\(reading.glucoseMgdl)"
    }

    private func updateDelegate(with result: CGMReadingResult) {
        delegateQueue?.async {
            self.cgmManagerDelegate?.cgmManager(self, hasNew: result)
        }
    }
}

// MARK: - GlucoseDisplayable

public struct LinxGlucoseDisplay: GlucoseDisplayable {
    private let reading: LinxGlucoseReading
    private let computedTrend: GlucoseTrend
    private let computedTrendRate: HKQuantity?
    public let isStateValid: Bool

    public init(
        reading: LinxGlucoseReading,
        trend: GlucoseTrend,
        trendRate: HKQuantity?,
        isStateValid: Bool
    ) {
        self.reading = reading
        computedTrend = trend
        computedTrendRate = trendRate
        self.isStateValid = isStateValid
    }
    /// Show HUD arrow from our computed trend (not the sensor bit).
    public var trendType: GlucoseTrend? { computedTrend }
    public var trendRate: HKQuantity? { computedTrendRate }
    public var isLocal: Bool { true }
    public var glucoseRangeCategory: GlucoseRangeCategory? { nil }
}
