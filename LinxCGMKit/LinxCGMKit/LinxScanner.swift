import CoreBluetooth
import Foundation
import os.log
#if canImport(UIKit)
    import UIKit
#endif

public protocol LinxScannerDelegate: AnyObject {
    /// A new decodable reading arrived from the specified (or any, if not
    /// filtered) sensor.
    func linxScanner(_ scanner: LinxScanner, didRead reading: LinxGlucoseReading)
    /// Scanner state changed (log/diagnostics).
    func linxScanner(_ scanner: LinxScanner, didUpdateStatus status: String)
    /// Scanner requests current calibration for decoding.
    func calibrationForLinxScanner(_ scanner: LinxScanner) -> LinxCalibration
    /// Scanner requests configured sensor serial number (nil = any).
    func sensorSerialForLinxScanner(_ scanner: LinxScanner) -> String?
    /// Linx sensor detected in range (for the picker list).
    /// advName = advertised full name ("LinX-..."), rssi = signal strength.
    func linxScanner(_ scanner: LinxScanner, didDiscoverDeviceNamed advName: String, rssi: Int)
    /// Start and expected end of the current CGM sensor session.
    func linxScanner(
        _ scanner: LinxScanner,
        didUpdateSensorSessionStartDate startDate: Date?,
        endDate: Date?
    )
}

public extension LinxScannerDelegate {
    func linxScanner(
        _: LinxScanner,
        didUpdateSensorSessionStartDate _: Date?,
        endDate _: Date?
    ) {}
}

public final class LinxScanner: NSObject {
    public weak var delegate: LinxScannerDelegate?

    /// Service UUID advertised by the Linx sensor (16-bit SIG: 181F).
    public static let linxServiceUUID = CBUUID(string: "181F")

    /// Standard CGM characteristics used by DiaExpert Sensor 2.
    private static let cgmMeasurementUUID = CBUUID(string: "2AA7")
    private static let cgmFeatureUUID = CBUUID(string: "2AA8")
    private static let cgmSessionStartTimeUUID = CBUUID(string: "2AAA")
    private static let cgmSessionRunTimeUUID = CBUUID(string: "2AAB")
    private static let cgmSpecificOpsControlPointUUID = CBUUID(string: "2AAC")

    /// In background, restart scan after this much silence (watchdog).
    public static let backgroundScanStaleInterval: TimeInterval = 4 * 60

    /// Manufacturer ID is the first 2 bytes of manufacturer data, little-endian (Nordic).
    private let expectedManufacturerID: UInt16 = 0x0059

    private let log = OSLog(subsystem: "com.linxcgmkit", category: "LinxScanner")

    private var central: CBCentralManager?
    private var lastSeen: [UUID: Date] = [:]
    /// Peripherals confirmed (by advertised name) to be the selected sensor,
    /// mapped to the serial they matched. Lets us keep accepting packets from
    /// that same peripheral when iOS delivers an advertisement without its
    /// local name (common in the background), without ever accepting an
    /// anonymous packet from an unknown sensor.
    private var confirmedPeripherals: [UUID: String] = [:]
    private var lastNoSerialNotice: Date?
    private var gattPeripheral: CBPeripheral?
    private var gattConnectionPending = false
    private var gattNotificationsActive = false
    private var gattCommunicationIntervalRequested = false
    private var gattCommunicationIntervalSetRequested = false
    private var gattE2ECRCEnabled: Bool?
    private var gattOpsControlPoint: CBCharacteristic?
    private var gattSessionStartTime: CBCharacteristic?
    private var gattSessionRunTime: CBCharacteristic?
    private var gattNotificationsStartedAt: Date?
    private var lastGATTMeasurementAt: Date?
    private var sensorSessionStartDate: Date?
    private var sensorSessionRunTime: TimeInterval?

    public private(set) var isScanning: Bool = false
    /// Time of last valid Linx manufacturer advertisement (regardless of decode).
    public private(set) var lastAdvertisementAt: Date?
    /// Time of last background scan kick / watchdog restart.
    public private(set) var lastScanRestartAt: Date?

    /// A connected DiaExpert is delivering standard CGM notifications. While
    /// this is true, scanning is unnecessary and intentionally suspended.
    public var isReceivingViaGATT: Bool {
        gattPeripheral?.state == .connected && gattNotificationsActive
    }

    override public init() {
        super.init()
        ensureCentral()
    }

    /// LAZY, one-time creation of CBCentralManager.
    /// Important: after CGM delete→re-add, the new LinxCGMManager creates a new scanner.
    /// If we immediately created a new CBCentralManager with the same State Restoration ID
    /// while the old internal BLE state is still "alive", CoreBluetooth can get confused
    /// and end up in a bad state (possibly .unsupported-like). So we ensure we always have
    /// only ONE manager, and handle transient (.unknown/.resetting) states patiently.
    private func ensureCentral() {
        guard central == nil else { return }
        // NO State Restoration ID: the manager is created cleanly every time, and
        // CGM delete→re-add never collides.
        // (Loop keeps the app awake often anyway for pump communication, so background
        //  reading still works in practice.)
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: true
            ]
        )
    }

    public func resumeScanning() {
        ensureCentral()
        guard !isReceivingViaGATT else { return }
        switch central?.state {
        case .poweredOn:
            if isAppInBackground, isScanning {
                // In background, refresh the scan cycle on Loop heartbeat.
                restartScan(reason: "heartbeat kick")
            } else {
                startScan()
            }
        case .none,
             .some(.resetting),
             .some(.unknown):
            // Transient state — centralManagerDidUpdateState will start scanning
            // once .poweredOn. Nothing to do here.
            notify("Bluetooth starting...")
        default:
            break
        }
    }

    /// In background, if there has been no fresh data for too long, stopScan → startScan.
    public func restartScanIfStale(lastDataAt: Date?) {
        if isReceivingViaGATT {
            let lastActivity = lastGATTMeasurementAt ?? gattNotificationsStartedAt
            if let lastActivity,
               Date().timeIntervalSince(lastActivity) >= Self.backgroundScanStaleInterval,
               let central,
               let gattPeripheral
            {
                notify("GATT: no measurement for four minutes; reconnecting...")
                central.cancelPeripheralConnection(gattPeripheral)
            }
            return
        }
        guard isAppInBackground else { return }
        let reference = [lastDataAt, lastAdvertisementAt]
            .compactMap { $0 }
            .max()
        if let reference, Date().timeIntervalSince(reference) < Self.backgroundScanStaleInterval {
            return
        }
        restartScan(reason: "watchdog stale")
    }

    private func startScan() {
        guard let central = central, central.state == .poweredOn else { return }
        guard !isReceivingViaGATT else { return }
        guard !isScanning else { return }
        // In background AllowDuplicatesKey: true — against iOS throttling we get every
        // advertisement callback; the five-minute gate filters Loop output.
        // Always allow duplicates: without it iOS reports each sensor about once
        // per scan session, so a first advertisement that arrives without its
        // name (or a later glucose packet) is never delivered again.
        let allowDuplicates = true
        central.scanForPeripherals(
            withServices: [Self.linxServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates]
        )
        isScanning = true
        logScanDiagnostics(context: allowDuplicates ? "startScan(bg dup=1)" : "startScan(fg dup=0)")
        notify(allowDuplicates ? "Scan running (181F, bg duplicates)..." : "Scan running (181F)...")
    }

    private func restartScan(reason: String) {
        guard let central = central, central.state == .poweredOn else { return }
        if isScanning {
            central.stopScan()
            isScanning = false
        }
        lastScanRestartAt = Date()
        startScan()
        logScanDiagnostics(context: "restart:\(reason)")
    }

    private var isAppInBackground: Bool {
        #if canImport(UIKit)
            if Thread.isMainThread {
                return UIApplication.shared.applicationState != .active
            }
            return DispatchQueue.main.sync {
                UIApplication.shared.applicationState != .active
            }
        #else
            return false
        #endif
    }

    private func logScanDiagnostics(context: String) {
        let bg = isAppInBackground
        let advAge: String
        if let lastAdv = lastAdvertisementAt {
            advAge = String(format: "%.0fs", Date().timeIntervalSince(lastAdv))
        } else {
            advAge = "never"
        }
        let restartAge: String
        if let lastRestart = lastScanRestartAt {
            restartAge = String(format: "%.0fs", Date().timeIntervalSince(lastRestart))
        } else {
            restartAge = "never"
        }
        let msg = "Linx scan \(context) scanning=\(isScanning) bg=\(bg) lastAdv=\(advAge) lastRestart=\(restartAge)"
        os_log("%{public}@", log: log, type: .info, msg)
    }

    /// Stop scanning and release the manager (called on CGM deletion).
    /// Ensures the old CBCentralManager is freed before re-add creates a new one
    /// with the same restore ID.
    public func stop() {
        if let central, let gattPeripheral, gattPeripheral.state != .disconnected {
            central.cancelPeripheralConnection(gattPeripheral)
        }
        gattPeripheral?.delegate = nil
        gattPeripheral = nil
        gattConnectionPending = false
        gattNotificationsActive = false
        gattCommunicationIntervalRequested = false
        gattCommunicationIntervalSetRequested = false
        gattE2ECRCEnabled = nil
        gattOpsControlPoint = nil
        gattSessionStartTime = nil
        gattSessionRunTime = nil
        gattNotificationsStartedAt = nil
        lastGATTMeasurementAt = nil
        sensorSessionStartDate = nil
        sensorSessionRunTime = nil
        confirmedPeripherals.removeAll()
        if let central = central, central.state == .poweredOn, isScanning {
            central.stopScan()
        }
        isScanning = false
        central?.delegate = nil
        central = nil
    }

    /// Exact (case-insensitive) match of the advertised name against the selected
    /// serial. A serial typed without its prefix (e.g. "2222296PN2" for
    /// "LinX-2222296PN2") is accepted only as a whole suffix after a "-" and
    /// only if it is long enough to be unique.
    static func advertisedName(_ name: String, matchesSerial serial: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let s = serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !n.isEmpty, !s.isEmpty else { return false }
        if n == s { return true }
        return s.count >= 8 && n.hasSuffix("-" + s)
    }

    /// Diagnostics: a device advertising service 181F that is not in the expected
    /// LinX packet format. Shown in the settings screen's scanner status so we
    /// can tell "no sensor in range" from "sensor uses a different format".
    private var lastNonMatchingReport: [UUID: Date] = [:]

    private func reportNonMatchingDevice(peripheral: CBPeripheral, advName: String, detail: String) {
        let now = Date()
        if let last = lastNonMatchingReport[peripheral.identifier], now.timeIntervalSince(last) < 20 {
            return
        }
        lastNonMatchingReport[peripheral.identifier] = now
        let name = advName.isEmpty ? "(sin nombre)" : advName
        notify("181F seen: \(name) — \(detail) — not LinX format")
    }

    private func notify(_ s: String) {
        os_log("%{public}@", log: log, type: .info, s)
        delegate?.linxScanner(self, didUpdateStatus: s)
    }

    /// Establish the low-power standard CGM connection for DiaExpert Sensor 2.
    private func startDiaExpertGATTIfNeeded(
        central: CBCentralManager,
        peripheral: CBPeripheral,
        advertisedName: String
    ) {
        let normalizedName = advertisedName.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ).lowercased()
        guard normalizedName.contains("diaexpert") || normalizedName.contains("diaxprt") else {
            return
        }

        if let current = gattPeripheral, current.identifier != peripheral.identifier {
            return
        }

        gattPeripheral = peripheral
        peripheral.delegate = self

        guard peripheral.state == .disconnected, !gattConnectionPending else { return }
        gattConnectionPending = true
        notify("GATT: connecting to \(advertisedName)...")
        central.connect(peripheral, options: nil)
    }

    private func requestCommunicationIntervalIfReady(from peripheral: CBPeripheral) {
        guard !gattCommunicationIntervalRequested,
              let usesCRC = gattE2ECRCEnabled,
              let controlPoint = gattOpsControlPoint,
              controlPoint.isNotifying
        else { return }

        let opcode = Data([0x02])
        let request = usesCRC ? LinxDecoder.appendingCGMCRC(to: opcode) : opcode
        let hex = request.map { String(format: "%02X", $0) }.joined()
        gattCommunicationIntervalRequested = true
        notify("GATT: requesting current communication interval with \(hex)...")
        peripheral.writeValue(request, for: controlPoint, type: .withResponse)
    }

    private func readSensorSessionDatesIfReady(from peripheral: CBPeripheral) {
        guard gattE2ECRCEnabled != nil else { return }
        if let gattSessionStartTime {
            peripheral.readValue(for: gattSessionStartTime)
        }
        if let gattSessionRunTime {
            peripheral.readValue(for: gattSessionRunTime)
        }
    }

    private func publishSensorSessionDates() {
        let endDate = sensorSessionStartDate.flatMap { startDate in
            sensorSessionRunTime.map { startDate.addingTimeInterval($0) }
        }
        delegate?.linxScanner(
            self,
            didUpdateSensorSessionStartDate: sensorSessionStartDate,
            endDate: endDate
        )
    }
}

// MARK: - CBCentralManagerDelegate

extension LinxScanner: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            notify("Bluetooth ON — scan starting (181F)")
            startScan()
        case .poweredOff:
            isScanning = false
            notify("Bluetooth is off")
        case .unauthorized:
            notify("No Bluetooth permission")
        case .unsupported:
            notify("Device does not support BLE")
        case .resetting:
            // BLE stack is restarting (e.g. after CGM delete→re-add).
            // NOT a permanent error — wait until .poweredOn.
            isScanning = false
            notify("Bluetooth restarting, waiting...")
        case .unknown:
            notify("Bluetooth state loading...")
        @unknown default:
            notify("Bluetooth state: \(central.state.rawValue)")
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? ""

        // Read manufacturer data
        guard let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else {
            reportNonMatchingDevice(peripheral: peripheral, advName: advName, detail: "no manufacturer data")
            return
        }

        let bytes = [UInt8](mfg)
        let mfgID: UInt16 = bytes.count >= 2
            ? UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
            : 0

        // Safety filter: Nordic (0x0059) 27-byte Linx packet only.
        guard mfgID == expectedManufacturerID, bytes.count == 27 else {
            reportNonMatchingDevice(
                peripheral: peripheral,
                advName: advName,
                detail: String(format: "mfg id 0x%04X, %d bytes", mfgID, bytes.count)
            )
            return
        }
        lastAdvertisementAt = Date()

        // The radio signature above identifies compatible Linx hardware more
        // reliably than the advertised name. Rebranded sensors (for example
        // DiaExpert Sensor 2) use a different Bluetooth name even though they
        // broadcast the same packet format. This runs BEFORE serial filtering
        // so every compatible in-range sensor appears in the picker.
        if !advName.isEmpty {
            delegate?.linxScanner(self, didDiscoverDeviceNamed: advName, rssi: RSSI.intValue)
        }

        // SAFETY — serial filter (mandatory). Without a selected sensor we never
        // forward readings: another person's LinX in range would otherwise be
        // used for dosing.
        guard let wanted = delegate?.sensorSerialForLinxScanner(self)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !wanted.isEmpty
        else {
            let now = Date()
            if lastNoSerialNotice.map({ now.timeIntervalSince($0) > 30 }) ?? true {
                lastNoSerialNotice = now
                notify("No sensor selected — readings ignored")
            }
            return
        }

        if !advName.isEmpty {
            if Self.advertisedName(advName, matchesSerial: wanted) {
                confirmedPeripherals[peripheral.identifier] = wanted.lowercased()
            } else {
                confirmedPeripherals[peripheral.identifier] = nil
                return
            }
        } else {
            // Nameless packet: accept only from a peripheral previously confirmed
            // by name for the *currently* selected serial.
            guard confirmedPeripherals[peripheral.identifier] == wanted.lowercased() else {
                return
            }
        }

        startDiaExpertGATTIfNeeded(
            central: central,
            peripheral: peripheral,
            advertisedName: advName
        )

        // Throttle: 1 s per device
        let now = Date()
        if let last = lastSeen[peripheral.identifier], now.timeIntervalSince(last) < 1.0 {
            return
        }
        lastSeen[peripheral.identifier] = now

        // Decode with current calibration
        let cal = delegate?.calibrationForLinxScanner(self) ?? LinxCalibration()
        if let reading = LinxDecoder.decode(manufacturerData: mfg, advName: advName, calibration: cal) {
            delegate?.linxScanner(self, didRead: reading)
        }
    }

    public func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == gattPeripheral?.identifier else { return }
        gattConnectionPending = false
        gattCommunicationIntervalRequested = false
        gattCommunicationIntervalSetRequested = false
        gattE2ECRCEnabled = nil
        gattOpsControlPoint = nil
        gattSessionStartTime = nil
        gattSessionRunTime = nil
        gattNotificationsStartedAt = nil
        lastGATTMeasurementAt = nil
        sensorSessionStartDate = nil
        sensorSessionRunTime = nil
        notify("GATT: connected; discovering CGM service...")
        peripheral.discoverServices([Self.linxServiceUUID])
    }

    public func centralManager(
        _: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral.identifier == gattPeripheral?.identifier else { return }
        gattConnectionPending = false
        notify("GATT: connection failed: \(error?.localizedDescription ?? "unknown error")")
        startScan()
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral.identifier == gattPeripheral?.identifier else { return }
        let shouldReconnect = gattNotificationsActive
        gattConnectionPending = false
        gattNotificationsActive = false
        gattCommunicationIntervalRequested = false
        gattCommunicationIntervalSetRequested = false
        gattE2ECRCEnabled = nil
        gattOpsControlPoint = nil
        gattSessionStartTime = nil
        gattSessionRunTime = nil
        gattNotificationsStartedAt = nil
        lastGATTMeasurementAt = nil
        sensorSessionStartDate = nil
        sensorSessionRunTime = nil
        let reason = error?.localizedDescription ?? "without error"
        notify("GATT: disconnected \(reason); scan resumed")
        startScan()

        // Ask Core Bluetooth for an immediate low-power reconnect. Scanning is
        // active only until 2AA7 notifications have been restored.
        if shouldReconnect {
            gattConnectionPending = true
            central.connect(peripheral, options: nil)
        }
    }
}

// MARK: - CBPeripheralDelegate (DiaExpert standard CGM connection)

extension LinxScanner: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            notify("GATT: service discovery failed: \(error.localizedDescription)")
            return
        }

        let services = peripheral.services ?? []
        guard let cgmService = services.first(where: { $0.uuid == Self.linxServiceUUID }) else {
            notify("GATT: service 181F is unavailable")
            return
        }
        peripheral.discoverCharacteristics(
            [
                Self.cgmMeasurementUUID,
                Self.cgmFeatureUUID,
                Self.cgmSessionStartTimeUUID,
                Self.cgmSessionRunTimeUUID,
                Self.cgmSpecificOpsControlPointUUID
            ],
            for: cgmService
        )
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            notify("GATT: characteristic discovery failed: \(error.localizedDescription)")
            return
        }

        let characteristics = service.characteristics ?? []
        guard let measurement = characteristics.first(where: { $0.uuid == Self.cgmMeasurementUUID }) else {
            notify("GATT: measurement characteristic 2AA7 is unavailable")
            return
        }

        if let feature = characteristics.first(where: { $0.uuid == Self.cgmFeatureUUID }) {
            peripheral.readValue(for: feature)
        }
        gattSessionStartTime = characteristics.first(where: { $0.uuid == Self.cgmSessionStartTimeUUID })
        gattSessionRunTime = characteristics.first(where: { $0.uuid == Self.cgmSessionRunTimeUUID })
        if let controlPoint = characteristics.first(where: { $0.uuid == Self.cgmSpecificOpsControlPointUUID }) {
            gattOpsControlPoint = controlPoint
            peripheral.setNotifyValue(true, for: controlPoint)
        }
        peripheral.setNotifyValue(true, for: measurement)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            notify("GATT: \(characteristic.uuid.uuidString) setup failed: \(error.localizedDescription)")
            return
        }

        if characteristic.uuid == Self.cgmMeasurementUUID {
            gattNotificationsActive = characteristic.isNotifying
            if characteristic.isNotifying {
                gattNotificationsStartedAt = Date()
                if let central, isScanning {
                    central.stopScan()
                    isScanning = false
                }
                notify("GATT: 2AA7 active; advertisement scan paused")
            } else {
                gattNotificationsStartedAt = nil
                notify("GATT: 2AA7 inactive; advertisement scan resumed")
                startScan()
            }
        }

        if characteristic.uuid == Self.cgmSpecificOpsControlPointUUID, characteristic.isNotifying {
            gattOpsControlPoint = characteristic
            requestCommunicationIntervalIfReady(from: peripheral)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            notify("GATT: \(characteristic.uuid.uuidString) value failed: \(error.localizedDescription)")
            return
        }
        let payload = characteristic.value ?? Data()

        if characteristic.uuid == Self.cgmMeasurementUUID {
            guard let usesCRC = gattE2ECRCEnabled else { return }
            // SAFETY: drop GATT data if the selected sensor changed since connecting.
            guard let wanted = delegate?.sensorSerialForLinxScanner(self)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !wanted.isEmpty,
                confirmedPeripherals[peripheral.identifier] == wanted.lowercased()
            else {
                notify("GATT: measurement from a non-selected sensor ignored")
                return
            }
            guard let reading = LinxDecoder.decodeCGMMeasurement(
                payload,
                serial: peripheral.name,
                requiresCRC: usesCRC
            ) else {
                notify("GATT: invalid 2AA7 measurement ignored")
                return
            }
            lastGATTMeasurementAt = reading.receivedAt
            delegate?.linxScanner(self, didRead: reading)
            return
        }

        if characteristic.uuid == Self.cgmFeatureUUID, payload.count >= 3 {
            let features = UInt32(payload[0])
                | (UInt32(payload[1]) << 8)
                | (UInt32(payload[2]) << 16)
            gattE2ECRCEnabled = features & (1 << 12) != 0
            readSensorSessionDatesIfReady(from: peripheral)
            requestCommunicationIntervalIfReady(from: peripheral)
            return
        }

        if characteristic.uuid == Self.cgmSessionStartTimeUUID,
           let usesCRC = gattE2ECRCEnabled
        {
            guard let startDate = LinxDecoder.decodeCGMSessionStartTime(
                payload,
                requiresCRC: usesCRC
            ) else {
                notify("GATT: invalid session start time ignored")
                return
            }
            sensorSessionStartDate = startDate
            publishSensorSessionDates()
            return
        }

        if characteristic.uuid == Self.cgmSessionRunTimeUUID,
           let usesCRC = gattE2ECRCEnabled
        {
            guard let runTime = LinxDecoder.decodeCGMSessionRunTime(
                payload,
                requiresCRC: usesCRC
            ) else {
                notify("GATT: invalid session run time ignored")
                return
            }
            sensorSessionRunTime = runTime
            publishSensorSessionDates()
            return
        }

        if characteristic.uuid == Self.cgmSpecificOpsControlPointUUID,
           let usesCRC = gattE2ECRCEnabled,
           payload.count >= (usesCRC ? 4 : 2),
           payload[0] == 0x03
        {
            if usesCRC {
                let body = Data(payload.dropLast(2))
                let receivedCRC = UInt16(payload[payload.count - 2])
                    | (UInt16(payload[payload.count - 1]) << 8)
                guard LinxDecoder.cgmCRC(body) == receivedCRC else {
                    notify("GATT: communication interval response has invalid CRC")
                    return
                }
            }

            let interval = payload[1]
            notify("GATT: communication interval is \(interval) minute(s)")
            if interval == 0, !gattCommunicationIntervalSetRequested,
               let controlPoint = gattOpsControlPoint
            {
                let command = Data([0x01, 0x01])
                let request = usesCRC ? LinxDecoder.appendingCGMCRC(to: command) : command
                gattCommunicationIntervalSetRequested = true
                notify("GATT: enabling one-minute measurements...")
                peripheral.writeValue(request, for: controlPoint, type: .withResponse)
            }
        }
    }

    public func peripheral(
        _: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            notify("GATT: \(characteristic.uuid.uuidString) write failed: \(error.localizedDescription)")
            return
        }
    }
}
