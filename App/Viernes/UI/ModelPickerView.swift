import SwiftUI
import ViernesCore

struct ModelPickerView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmDownload: ModelDescriptor?

    var body: some View {
        List {
            Section {
                Text("Elige el cerebro que corre en tu iPhone. Los modelos descargados funcionan sin internet. La calidad en español de la tabla es una valoración editorial, no un benchmark; los tamaños son aproximados.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                if !EngineProvider.isFoundationModelAvailable, case .unavailable(let reason) = EngineProvider.foundationModelsAvailability() {
                    Label("Apple Intelligence: \(reason)", systemImage: "info.circle").font(.footnote).foregroundStyle(Theme.amber)
                }
            }
            .listRowBackground(Color.clear)

            ForEach(ModelCatalog.all) { descriptor in
                modelRow(descriptor)
                    .listRowBackground(Theme.carbon.opacity(model.activeModel.id == descriptor.id ? 0.9 : 0.5))
            }
        }
        .chromeList()
        .navigationTitle("Modelo local")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Descargar modelo", isPresented: Binding(get: { confirmDownload != nil }, set: { if !$0 { confirmDownload = nil } }), titleVisibility: .visible, presenting: confirmDownload) { descriptor in
            Button("Descargar y cargar (≈\(descriptor.approxDownloadMB) MB)") {
                Task { await model.activateModel(id: descriptor.id); model.loadActiveModel() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { descriptor in
            Text(model.isOnline
                 ? "Se descargará desde Hugging Face (internet) una sola vez. Conviene usar Wi-Fi. Después funciona sin conexión."
                 : "Estás sin conexión: la descarga no es posible ahora.")
        }
    }

    private func modelRow(_ descriptor: ModelDescriptor) -> some View {
        let fit = model.fit(for: descriptor)
        let isActive = model.activeModel.id == descriptor.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(descriptor.displayName).font(.headline).foregroundStyle(Theme.textPrimary)
                Spacer()
                if isActive { Text("ACTIVO").font(.system(size: 10, design: .monospaced)).tracking(2).foregroundStyle(Theme.accent) }
            }
            HStack(spacing: 8) {
                badge(fit.rawValue, tint: fit == .recommended ? Theme.accent : fit == .possible ? Theme.amber : Theme.alert)
                badge(descriptor.requiresDownload ? "≈\(descriptor.approxDownloadMB) MB" : "Sin descarga", tint: Theme.textSecondary)
                badge("Español \(String(repeating: "●", count: descriptor.spanishQuality))\(String(repeating: "○", count: 5 - descriptor.spanishQuality))", tint: Theme.textSecondary)
            }
            Text(descriptor.notes).font(.caption).foregroundStyle(Theme.textSecondary)
            Text("Licencia: \(descriptor.license) · RAM sugerida ≥ \(descriptor.minDeviceRAMGB) GB").font(.caption2).foregroundStyle(Theme.textSecondary.opacity(0.8))

            HStack {
                if !isActive {
                    Button("Usar este") { Task { await model.activateModel(id: descriptor.id) } }.buttonStyle(ChromeButtonStyle())
                } else {
                    activeControls(descriptor)
                }
                if !descriptor.isSystemModel && !isActive {
                    Button("Eliminar descarga", role: .destructive) { model.deleteDownload(of: descriptor) }
                        .buttonStyle(ChromeButtonStyle(tint: Theme.alert))
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("model-\(descriptor.id)")
    }

    @ViewBuilder
    private func activeControls(_ descriptor: ModelDescriptor) -> some View {
        switch model.engineStatus {
        case .ready:
            if !descriptor.isSystemModel {
                Button("Descargar de memoria") { model.unloadActiveModel() }.buttonStyle(ChromeButtonStyle(tint: Theme.amber))
            } else {
                Label("Listo", systemImage: "checkmark.circle").foregroundStyle(Theme.accent)
            }
        case .notLoaded:
            Button("Descargar y cargar") { confirmDownload = descriptor }.buttonStyle(ChromeButtonStyle())
                .accessibilityIdentifier("download-model")
        case .downloading(let progress):
            VStack(alignment: .leading) {
                ProgressView(value: progress).tint(Theme.accent)
                Text("Descargando \(Int(progress * 100)) %").font(.caption).foregroundStyle(Theme.textSecondary)
            }
        case .loading:
            HStack { ProgressView(); Text("Cargando en memoria…").font(.caption) }
        case .unavailable(let reason), .failed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.alert)
                if !descriptor.isSystemModel { Button("Reintentar") { model.loadActiveModel() }.buttonStyle(ChromeButtonStyle(tint: Theme.amber)) }
            }
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }
}
