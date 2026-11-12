import SwiftUI
import ViernesCore

struct CloudBrainView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    @State private var keyInput = ""
    @State private var hasKey = false
    @State private var testing = false
    @State private var report: CloudConnectionTester.Report?
    @State private var keyError: String?

    private var cloud: CloudBrainSettings { model.settings.cloudBrain }
    private var preset: CloudProviderPreset { cloud.preset }

    var body: some View {
        List {
            Section {
                Text("Los modelos que caben en un iPhone no conversan como una IA de verdad. Este modo usa un modelo grande en la nube con TU clave gratuita. Es opcional y el modelo local sigue disponible sin internet.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                Label("Lo que escribas o dictes se envía a \(preset.displayName). Los planes gratuitos suelen permitir al proveedor usar los datos para mejorar sus productos: léelo en sus términos. Nunca se envían tu memoria completa ni tu clave de cifrado; sí el historial reciente y los recuerdos relevantes del mensaje.", systemImage: "exclamationmark.shield")
                    .font(.caption).foregroundStyle(Theme.amber)
            }
            .listRowBackground(Color.clear)

            Section("Proveedor") {
                Picker("Proveedor", selection: Binding(
                    get: { cloud.providerID },
                    set: { id in
                        let next = CloudProviders.preset(id: id)
                        model.settings.cloud = CloudBrainSettings(providerID: next.id, model: next.defaultModel)
                        report = nil
                        hasKey = CloudKeyStore.hasKey(providerID: next.id)
                    })) {
                    ForEach(CloudProviders.all) { Text($0.displayName).tag($0.id) }
                }
                .accessibilityIdentifier("cloud-provider")
                Text(preset.note).font(.caption).foregroundStyle(Theme.textSecondary)
                Button("Conseguir una clave gratuita") {
                    if let url = URL(string: preset.keyPageURL) { openURL(url) }
                }.buttonStyle(ChromeButtonStyle())
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section {
                if hasKey {
                    Label("Clave guardada en el Llavero de este iPhone", systemImage: "checkmark.seal").foregroundStyle(Theme.accent)
                }
                SecureField(hasKey ? "Pegar una clave nueva" : "Pega aquí tu clave", text: $keyInput)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("cloud-key")
                Button("Guardar clave") { saveKey() }
                    .buttonStyle(ChromeButtonStyle())
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("cloud-key-save")
                if let keyError { Text(keyError).font(.caption).foregroundStyle(Theme.alert) }
                if hasKey {
                    Button("Quitar la clave", role: .destructive) {
                        CloudKeyStore.delete(providerID: preset.id)
                        hasKey = false
                        report = nil
                        model.refreshCloudEngine()
                    }
                }
            } header: { Text("Clave") } footer: {
                Text("La clave se guarda solo en el Llavero (no sale de este iPhone ni entra en copias de seguridad) y solo se envía a \(preset.displayName).")
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Modelo") {
                TextField("Nombre del modelo", text: Binding(
                    get: { cloud.model },
                    set: { model.settings.cloud = CloudBrainSettings(providerID: cloud.providerID, model: $0) }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("cloud-model")
                Button(testing ? "Probando…" : "Probar conexión") { runTest() }
                    .buttonStyle(ChromeButtonStyle())
                    .disabled(testing || !hasKey)
                    .accessibilityIdentifier("cloud-test")
                if let report {
                    Label(report.message, systemImage: report.ok ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(report.ok ? Theme.accent : Theme.alert)
                    if !report.models.isEmpty {
                        // Modelos REALES de tu cuenta (los lista el proveedor con tu clave). Tocar uno lo elige; nada se cambia solo.
                        ForEach(Array(report.models.prefix(40)), id: \.self) { id in
                            Button {
                                model.settings.cloud = CloudBrainSettings(providerID: cloud.providerID, model: id)
                                self.report = CloudConnectionTester.Report(ok: true, message: "Modelo elegido: «\(id)».", models: report.models,
                                                                           suggestedLight: report.suggestedLight, suggestedStrong: report.suggestedStrong)
                            } label: {
                                HStack {
                                    Text(id).font(.footnote.monospaced()).foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    if id == cloud.model { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                                }
                            }
                        }
                        if let light = report.suggestedLight {
                            Text("Sugerido para tareas frecuentes (económico): \(light)").font(.caption2).foregroundStyle(Theme.textSecondary)
                        }
                        if let strong = report.suggestedStrong {
                            Text("Sugerido para tareas complejas: \(strong)").font(.caption2).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section {
                if model.activeModel.isCloud {
                    Label("Viernes está usando la nube como cerebro", systemImage: "cloud.fill").foregroundStyle(Theme.accent)
                    Button("Volver al modelo local") {
                        Task { await model.activateModel(id: "qwen3-1.7b-4bit") }
                    }.buttonStyle(ChromeButtonStyle(tint: Theme.amber))
                } else {
                    Button("Usar la nube como cerebro") {
                        Task { await model.activateModel(id: ModelCatalog.cloudID) }
                    }
                    .buttonStyle(ChromeButtonStyle())
                    .disabled(!hasKey)
                    .accessibilityIdentifier("cloud-activate")
                }
            }
            .listRowBackground(Theme.carbon.opacity(0.5))
        }
        .chromeList()
        .navigationTitle("Cerebro en la nube")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { hasKey = CloudKeyStore.hasKey(providerID: preset.id) }
    }

    private func saveKey() {
        do {
            if try CloudKeyStore.save(keyInput, providerID: preset.id) {
                keyInput = ""
                keyError = nil
                hasKey = true
                report = nil
                model.refreshCloudEngine()
            } else {
                keyError = "Eso no parece una clave: debe ser una sola línea de letras y números (20 a 300 caracteres), sin espacios."
            }
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func runTest() {
        testing = true
        report = nil
        let settings = cloud
        Task {
            let result = await CloudConnectionTester.test(settings)
            await MainActor.run {
                report = result
                testing = false
            }
        }
    }
}
