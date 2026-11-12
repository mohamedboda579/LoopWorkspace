import LinxCGMKit
import LoopKit
import LoopKitUI
import SwiftUI

struct LinxSettingsView: View {
    @ObservedObject var viewModel: LinxSettingsViewModel
    var didFinish: () -> Void
    var deleteCGM: () -> Void

    @State private var refInput: String = ""
    @State private var showDeleteConfirm = false

    var body: some View {
        List {
            warningSection
            statusSection
            serialSection
            nearbySection
            sensorLifetimeSection
            calibrationSection
            deleteSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("LinX CGM")
        .navigationBarItems(trailing: Button("Hecho", action: didFinish))
        .onAppear { viewModel.startScanning() }
    }

    private var warningSection: some View {
        Section {
            Label {
                Text("Plugin experimental y no oficial. La conversión del valor bruto no usa la calibración de fábrica de LinX. Úsalo primero en lazo abierto y compara con la app oficial y con glucemias capilares antes de activar el lazo cerrado.")
                    .font(.footnote)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }
            if viewModel.sensorSerial.isEmpty {
                Label {
                    Text("Elige tu sensor en la lista de abajo. Sin sensor seleccionado no se envían lecturas a Loop.")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundColor(.red)
                }
            }
        }
    }

    private var statusSection: some View {
        Section(header: Text("Estado")) {
            HStack {
                Text("Última lectura")
                Spacer()
                Text(viewModel.latestGlucoseText).foregroundColor(.secondary)
            }
            HStack {
                Text("Escáner")
                Spacer()
                Text(viewModel.statusText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Text("Loop recibe una lectura nueva cada 5 minutos aproximadamente.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var serialSection: some View {
        Section(
            header: Text("Número de serie del sensor (obligatorio)"),
            footer: Text("Nombre completo tal como aparece en la lista (p. ej. LinX-2222296PN2), o solo la parte tras el guion si tiene al menos 8 caracteres. Solo se aceptan lecturas de este sensor.")
        ) {
            TextField("LinX-…", text: $viewModel.sensorSerial)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Guardar número de serie") {
                viewModel.saveSerial()
            }
        }
    }

    // MARK: - Picker: nearby compatible sensors

    private var nearbySection: some View {
        Section(
            header: Text("Sensores LinX cercanos"),
            footer: Text("Toca tu sensor para seleccionarlo. Comprueba el número de serie con el del aplicador o la app oficial.")
        ) {
            if viewModel.nearbyDevices.isEmpty {
                HStack {
                    Text(viewModel.isReceivingViaGATT ? "Conectado por GATT" : "Buscando…")
                        .foregroundColor(.secondary)
                    Spacer()
                    if viewModel.isReceivingViaGATT {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        ProgressView()
                    }
                }
            } else {
                ForEach(viewModel.nearbyDevices) { device in
                    Button {
                        viewModel.selectDevice(device)
                    } label: {
                        HStack(spacing: 12) {
                            Image(
                                systemName: device.name == viewModel.sensorSerial
                                    ? "checkmark.circle.fill" : "circle"
                            )
                            .foregroundColor(device.name == viewModel.sensorSerial ? .accentColor : .secondary)
                            deviceNameLabel(device.name)
                            Spacer()
                            rssiLabel(device.rssi)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var sensorLifetimeSection: some View {
        Section(header: Text("Vida del sensor")) {
            HStack {
                Text("Inicio")
                Spacer()
                Text(viewModel.sensorSessionDateText(viewModel.sensorSessionStartDate))
                    .foregroundColor(.secondary)
            }
            HStack {
                Text("Fin")
                Spacer()
                Text(viewModel.sensorSessionDateText(viewModel.sensorSessionEndDate))
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Shows the full name with the last 2 characters in bold.
    private func deviceNameLabel(_ name: String) -> some View {
        let head = name.count > 2 ? String(name.dropLast(2)) : ""
        let tail = name.count >= 2 ? String(name.suffix(2)) : name
        return (
            Text(head).foregroundColor(.primary)
                + Text(tail).bold().foregroundColor(.accentColor)
        )
        .lineLimit(1)
        .truncationMode(.middle)
    }

    /// Signal strength with a small icon and dBm value.
    private func rssiLabel(_ rssi: Int) -> some View {
        HStack(spacing: 4) {
            Image(
                systemName: rssi >= -60 ? "wifi"
                    : (rssi >= -75 ? "wifi" : "wifi.exclamationmark")
            )
            .font(.caption)
            Text("\(rssi) dBm")
                .font(.caption)
        }
        .foregroundColor(.secondary)
    }

    private var calibrationSection: some View {
        Section(
            header: Text("Calibración"),
            footer: Text(
                "Introduce una glucemia capilar tomada ahora, con la glucosa estable. Un punto corrige el desplazamiento; dos puntos separados al menos ~18 mg/dL (1 mmol/L) ajustan también la pendiente. Se rechazan valores fuera de 40–400 mg/dL, a más de 100 mg/dL del sensor o que den una curva no plausible."
            )
        ) {
            // Active curve
            HStack {
                Text("Curva activa")
                Spacer()
                Text(viewModel.activeCurveText)
                    .font(.footnote.monospaced())
                    .foregroundColor(.secondary)
            }

            // Current raw value
            if let raw = viewModel.currentRaw10 {
                HStack {
                    Text(viewModel.currentCalibrationInputLabel)
                    Spacer()
                    Text("\(raw)").foregroundColor(.secondary)
                }
            } else {
                Text("Esperando la primera lectura…")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            // Recorded points
            if viewModel.calPoints.isEmpty {
                Text("Sin puntos de calibración (curva por defecto).")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(viewModel.calPoints.enumerated()), id: \.offset) { _, p in
                    HStack {
                        Text(viewModel.calibrationPointInputText(p))
                        Spacer()
                        Text(viewModel.calibrationPointText(p)).foregroundColor(.secondary)
                    }
                    .font(.footnote)
                }
            }

            // Record new point
            HStack {
                TextField(viewModel.calibrationInputPlaceholder, text: $refInput)
                    .keyboardType(.decimalPad)
                Button("Guardar") {
                    if let v = Double(refInput.replacingOccurrences(of: ",", with: ".")) {
                        viewModel.addCalibration(referenceValue: v)
                        refInput = ""
                    }
                }
                .disabled(viewModel.currentRaw10 == nil || refInput.isEmpty)
            }

            if let message = viewModel.calibrationMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(viewModel.calibrationMessageIsError ? .red : .green)
            }

            Button(role: .destructive) {
                viewModel.resetCalibration()
            } label: {
                Text("Restablecer calibración (curva por defecto)")
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                HStack {
                    Spacer()
                    Text("Eliminar LinX CGM")
                    Spacer()
                }
            }
            .confirmationDialog(
                "¿Seguro que quieres eliminar LinX CGM?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Eliminar", role: .destructive, action: deleteCGM)
                Button("Cancelar", role: .cancel) {}
            }
        }
    }
}
