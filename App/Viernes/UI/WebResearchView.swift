import SwiftUI
import ViernesCore

/// Investigación web: opcional y apagada por defecto. Al encenderla eliges un buscador y guardas SU clave (en el Llavero de este perfil);
/// eso es tu autorización para que las consultas salgan de tu iPhone hacia ese proveedor. Lo de internet es información de terceros,
/// separada de tu memoria, y nunca puede dar órdenes a Viernes.
struct WebResearchView: View {
    @EnvironmentObject var model: AppModel
    @State private var keyDraft = ""
    @State private var hasKey = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var history: [ResearchRecord] = []
    @State private var confirmClear = false

    private var settings: WebResearchSettings { model.settings.webSettings }

    private func update(_ change: (inout WebResearchSettings) -> Void) {
        var current = model.settings.webSettings
        change(&current)
        model.settings.web = current
    }

    private func refreshKey() { hasKey = CloudKeyStore.hasKey(providerID: settings.provider.keyProviderID) }

    var body: some View {
        List {
            Section("Investigación web") {
                Toggle("Permitir que Viernes investigue en internet", isOn: Binding(get: { settings.enabled }, set: { value in update { $0.enabled = value } }))
                    .disabled(!hasKey)
                    .accessibilityIdentifier("web-enabled-toggle")
                if !hasKey {
                    Text("Primero guarda la clave de un buscador (abajo): sin clave no hay búsqueda.").font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                Text("Qué sale del iPhone: solo el texto de la búsqueda, hacia el buscador que elijas, y las páginas que leas se descargan directamente de su sitio (que ve tu conexión). Nunca salen tu memoria, tus documentos ni tus contactos. Las búsquedas con datos sensibles (tarjetas, claves) se rechazan.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Buscador") {
                Picker("Buscador", selection: Binding(get: { settings.provider }, set: { value in update { $0.provider = value }; refreshKey(); model.refreshWebResearch() })) {
                    ForEach(WebSearchProvider.allCases) { Text($0.displayName).tag($0) }
                }
                .accessibilityIdentifier("web-provider-picker")
                Text(settings.provider.note).font(.footnote).foregroundStyle(Theme.textSecondary)
                if let url = URL(string: settings.provider.keyPageURL) { Link("Conseguir una clave de \(settings.provider.displayName)", destination: url) }
                SecureField(hasKey ? "Clave guardada (pega otra para reemplazarla)" : "Pega aquí la clave", text: $keyDraft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("web-key-field")
                HStack {
                    Button("Guardar clave") {
                        if (try? CloudKeyStore.save(keyDraft, providerID: settings.provider.keyProviderID)) == true {
                            keyDraft = ""
                            refreshKey()
                            model.refreshWebResearch()
                            testResult = nil
                        } else {
                            testResult = "La clave no parece válida (sin espacios, entre 20 y 300 caracteres)."
                        }
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    Button("Borrar clave", role: .destructive) {
                        CloudKeyStore.delete(providerID: settings.provider.keyProviderID)
                        update { $0.enabled = false }
                        refreshKey()
                        model.refreshWebResearch()
                    }
                    .disabled(!hasKey)
                }
                Button(testing ? "Probando…" : "Probar con una búsqueda de ejemplo") { runTest() }
                    .disabled(!hasKey || testing)
                if let testResult = testResult { Text(testResult).font(.footnote).foregroundStyle(Theme.textPrimary) }
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Historial de investigaciones") {
                if history.isEmpty { Text("Todavía no has investigado nada.").font(.footnote).foregroundStyle(Theme.textSecondary) }
                ForEach(history) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.query).foregroundStyle(Theme.textPrimary).lineLimit(2)
                        Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(Theme.textSecondary)
                        ForEach(record.sources, id: \.url) { source in
                            if let url = URL(string: source.url) {
                                Link(source.title, destination: url).font(.caption).lineLimit(1)
                            }
                        }
                    }
                }
                Button("Borrar el historial de investigaciones", role: .destructive) { confirmClear = true }.disabled(history.isEmpty)
                Text("Guarda qué buscaste y qué fuentes salieron, nunca el texto de las páginas. Es aparte de tu memoria personal.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))
        }
        .chromeList()
        .navigationTitle("Investigación web")
        .navigationBarTitleDisplayMode(.inline)
        .task { refreshKey(); history = await model.researchLog.all() }
        .confirmationDialog("¿Borrar el historial de investigaciones?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Borrar historial", role: .destructive) { Task { await model.researchLog.clear(); history = [] } }
        }
    }

    private func runTest() {
        testing = true
        testResult = nil
        let provider = settings.provider
        Task {
            let found = await WebResearchClient.search(provider: provider, query: "tiempo en Bogotá hoy", count: 3, language: "es")
            switch found.outcome {
            case .success where !found.results.isEmpty: testResult = "Funciona: \(provider.displayName) devolvió \(found.results.count) resultados (primero: \(found.results[0].domain))."
            case .success(let text): testResult = text
            case .card(let text, _): testResult = text
            case .failure(let reason): testResult = reason
            }
            testing = false
        }
    }
}
