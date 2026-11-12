import Combine
import Foundation
import HealthKit
import LinxCGMKit
import LoopKit
import LoopKitUI

class LinxSettingsViewModel: ObservableObject, LinxStateObserver {
    private(set) var cgmManager: LinxCGMManager
    private var displayGlucosePreference: DisplayGlucosePreference

    @Published var sensorSerial: String
    /// Linx sensors detected in range (for the picker list).
    @Published var nearbyDevices: [LinxNearbyDevice] = []
    @Published var statusText: String
    @Published var isReceivingViaGATT: Bool
    @Published var latestGlucoseText: String
    @Published var sensorSessionStartDate: Date?
    @Published var sensorSessionEndDate: Date?
    @Published var calA: Double
    @Published var calB: Double
    @Published var calPoints: [LinxCalPoint]
    /// Feedback for the last calibration attempt (nil = nothing to show).
    @Published var calibrationMessage: String?
    @Published var calibrationMessageIsError = false

    init(cgmManager: LinxCGMManager, displayGlucosePreference: DisplayGlucosePreference) {
        self.cgmManager = cgmManager
        self.displayGlucosePreference = displayGlucosePreference

        let st = cgmManager.state
        let initialUsesGATT = cgmManager.isReceivingViaGATT
        let initialCalibration = initialUsesGATT ? st.gattCalibration : st.calibration
        sensorSerial = st.sensorSerial ?? ""
        calA = initialCalibration.calA
        calB = initialCalibration.calB
        calPoints = initialCalibration.points
        statusText = cgmManager.currentStatusText
        isReceivingViaGATT = initialUsesGATT
        sensorSessionStartDate = cgmManager.sensorSessionStartDate
        sensorSessionEndDate = cgmManager.sensorSessionEndDate
        latestGlucoseText = Self.glucoseText(
            cgmManager.latestReading,
            displayGlucosePreference: displayGlucosePreference
        )
        nearbyDevices = cgmManager.nearbyDevices

        cgmManager.addStateObserver(self)
    }

    deinit {
        cgmManager.removeStateObserver(self)
    }

    private static func glucoseText(
        _ r: LinxGlucoseReading?,
        displayGlucosePreference: DisplayGlucosePreference
    ) -> String {
        guard let r = r else { return "—" }
        let quantity = HKQuantity(
            unit: HKUnit(from: "mg/dL"),
            doubleValue: Double(r.glucoseMgdl)
        )
        return displayGlucosePreference.format(quantity)
    }

    private var displaysMgdl: Bool {
        displayGlucosePreference.unit == HKUnit(from: "mg/dL")
    }

    var calibrationInputPlaceholder: String {
        displaysMgdl ? "Ref mg/dL" : "Ref mmol/L"
    }

    var activeCurveText: String {
        let inputName = isReceivingViaGATT ? "sensor" : "raw"
        if displaysMgdl {
            return String(format: "mg/dL = %.5f·%@ + %.3f", calA * 18, inputName, calB * 18)
        }
        return String(format: "mmol/L = %.5f·%@ + %.3f", calA, inputName, calB)
    }

    var currentCalibrationInputLabel: String {
        isReceivingViaGATT ? "Sensor value (mg/dL)" : "Current raw (raw10)"
    }

    func sensorSessionDateText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    func calibrationPointInputText(_ point: LinxCalPoint) -> String {
        isReceivingViaGATT ? "sensor \(point.glu10)" : "raw \(point.glu10)"
    }

    func calibrationPointText(_ point: LinxCalPoint) -> String {
        if displaysMgdl {
            return "\(LinxDecoder.mmolToMgdl(point.mmol)) mg/dL"
        }
        return String(format: "%.1f mmol/L", point.mmol)
    }

    /// Raw glu10 value from the latest reading (for calibration).
    var currentRaw10: Int? { cgmManager.latestReading?.raw10 }

    // MARK: - Actions

    func saveSerial() {
        cgmManager.setSensorSerial(sensorSerial.trimmingCharacters(in: .whitespaces))
    }

    /// Persist the sensor chosen from the picker list: we only filter to it,
    /// no connection is needed (we read from Linx advertisements). We save the
    /// full advertised name so the scanner filters to exactly this one sensor.
    func selectDevice(_ device: LinxNearbyDevice) {
        sensorSerial = device.name
        cgmManager.setSensorSerial(device.name)
    }

    /// Called when opening settings: starts scanning and loads the currently
    /// known sensor list.
    func startScanning() {
        cgmManager.startScanningForPicker()
        isReceivingViaGATT = cgmManager.isReceivingViaGATT
        refresh()
        nearbyDevices = cgmManager.nearbyDevices
    }

    /// Record a new calibration point in the user's display unit against
    /// the CURRENT raw glu10 value.
    func addCalibration(referenceValue: Double) {
        guard let raw10 = currentRaw10 else {
            show(.rejectedNoReading)
            return
        }
        let refMmol = displaysMgdl ? referenceValue / 18 : referenceValue
        let result = cgmManager.addCalibration(glu10: raw10, mmol: refMmol)
        show(result)
        refresh()
    }

    private func show(_ result: LinxCalibrationResult) {
        calibrationMessageIsError = result != .accepted
        switch result {
        case .accepted:
            calibrationMessage = "Punto de calibración guardado."
        case .rejectedReferenceOutOfRange:
            calibrationMessage = "Rechazado: el valor de referencia debe estar entre 40 y 400 mg/dL (2,2–22,2 mmol/L)."
        case .rejectedTooFarFromSensor:
            calibrationMessage = "Rechazado: la referencia se aleja más de 100 mg/dL (5,5 mmol/L) del valor del sensor. Revisa el valor y la unidad."
        case .rejectedImplausibleCurve:
            calibrationMessage = "Rechazado: la curva resultante no es plausible. Repite la medición capilar o restablece la calibración."
        case .rejectedNoReading:
            calibrationMessage = "Rechazado: todavía no hay lectura del sensor."
        }
    }

    func resetCalibration() {
        cgmManager.resetCalibration()
        calibrationMessage = nil
        refresh()
    }

    private func activeCalibration(from state: LinxCGMManagerState) -> LinxCalibration {
        isReceivingViaGATT ? state.gattCalibration : state.calibration
    }

    private func refresh() {
        let st = cgmManager.state
        let calibration = activeCalibration(from: st)
        calA = calibration.calA
        calB = calibration.calB
        calPoints = calibration.points
    }

    // MARK: - LinxStateObserver

    func linxStateDidUpdate(_ state: LinxCGMManagerState) {
        DispatchQueue.main.async {
            let calibration = self.activeCalibration(from: state)
            self.calA = calibration.calA
            self.calB = calibration.calB
            self.calPoints = calibration.points
            if self.sensorSerial.isEmpty, let s = state.sensorSerial { self.sensorSerial = s }
            self.latestGlucoseText = Self.glucoseText(
                self.cgmManager.latestReading,
                displayGlucosePreference: self.displayGlucosePreference
            )
        }
    }

    func linxStatusDidUpdate(_ status: String) {
        DispatchQueue.main.async {
            self.statusText = status
            self.isReceivingViaGATT = self.cgmManager.isReceivingViaGATT
            let calibration = self.activeCalibration(from: self.cgmManager.state)
            self.calA = calibration.calA
            self.calB = calibration.calB
            self.calPoints = calibration.points
            self.latestGlucoseText = Self.glucoseText(
                self.cgmManager.latestReading,
                displayGlucosePreference: self.displayGlucosePreference
            )
        }
    }

    func linxNearbyDevicesDidUpdate(_ devices: [LinxNearbyDevice]) {
        DispatchQueue.main.async {
            self.nearbyDevices = devices
        }
    }

    func linxSensorSessionDidUpdate(startDate: Date?, endDate: Date?) {
        DispatchQueue.main.async {
            self.sensorSessionStartDate = startDate
            self.sensorSessionEndDate = endDate
        }
    }
}
