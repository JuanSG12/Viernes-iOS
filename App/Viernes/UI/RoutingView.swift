import SwiftUI
import ViernesCore

/// Enrutador de inteligencia: qué proveedor y modelo atiende cada tipo de petición, ahorro de tokens y cambio de proveedor si uno falla.
/// Todo apagado por defecto: mientras esté apagado Viernes usa SIEMPRE el cerebro que elegiste y no manda nada a otro proveedor.
struct RoutingView: View {
    @EnvironmentObject var model: AppModel

    private var routing: RoutingSettings { model.settings.routingSettings }

    private func update(_ change: (inout RoutingSettings) -> Void) {
        var current = model.settings.routingSettings
        change(&current)
        model.settings.routing = current.sanitized()
    }

    private func tierBinding(_ providerID: String, strong: Bool) -> Binding<String> {
        Binding(
            get: {
                let tiers = model.settings.routingSettings.tiers[providerID]
                return (strong ? tiers?.strong : tiers?.light) ?? ""
            },
            set: { value in
                update { settings in
                    var tiers = settings.tiers[providerID] ?? TierModels()
                    let cleaned: String? = value.isEmpty ? nil : value
                    if strong { tiers.strong = cleaned } else { tiers.light = cleaned }
                    settings.tiers[providerID] = tiers
                }
            })
    }

    var body: some View {
        List {
            Section {
                Text("Viernes clasifica cada mensaje antes de llamar a un modelo: la hora y la fecha las calcula él solo (sin tokens), y el resto va al modelo económico o al más capaz según lo que pidas. Solo usa proveedores con clave guardada que tú autorizaste en «Consumo y presupuesto».")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Color.clear)

            Section("Ahorro de tokens") {
                Toggle(isOn: Binding(get: { model.settings.tokenSaverEnabled }, set: { model.settings.tokenSaver = $0 })) {
                    Text("Enviar solo lo necesario a la nube").foregroundStyle(Theme.textPrimary)
                }
                .accessibilityIdentifier("routing-saver")
                Text("Con un cerebro en la nube, cada petición envía solo las instrucciones y herramientas del tema, un historial acotado (con un resumen de lo recortado), un tope de respuesta según la tarea y repite sin gastar una respuesta idéntica reciente. No afecta al modelo local ni a las respuestas con calendario, clima o contactos.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Elegir proveedor según la tarea") {
                Toggle(isOn: Binding(get: { routing.enabled }, set: { value in update { $0.enabled = value } })) {
                    Text("Enrutador de inteligencia").foregroundStyle(Theme.textPrimary)
                }
                .accessibilityIdentifier("routing-enabled")
                Toggle(isOn: Binding(get: { routing.preferLocalForSimple }, set: { value in update { $0.preferLocalForSimple = value } })) {
                    Text("Conversación sencilla con el modelo local").foregroundStyle(Theme.textPrimary)
                }
                .disabled(!routing.enabled)
                .accessibilityIdentifier("routing-local")
                Toggle(isOn: Binding(get: { routing.allowFailover }, set: { value in update { $0.allowFailover = value } })) {
                    Text("Si un proveedor falla, usar otro que autoricé").foregroundStyle(Theme.textPrimary)
                }
                .disabled(!routing.enabled)
                .accessibilityIdentifier("routing-failover")
                Picker("Proveedor económico", selection: Binding(get: { routing.economyProviderID ?? "" },
                                                                 set: { value in update { $0.economyProviderID = value.isEmpty ? nil : value } })) {
                    Text("Según el orden").tag("")
                    ForEach(CloudProviders.all) { Text($0.displayName).tag($0.id) }
                }
                .disabled(!routing.enabled)
                .accessibilityIdentifier("routing-economy")
                Text("Orden por defecto: Gemini, Cerebras, OpenAI, Groq. El cambio por fallo solo ocurre ante cuota, saldo o caída del servicio, antes de que empiece la respuesta, y nunca reenvía mensajes con archivos, imágenes ni fragmentos de tu biblioteca. Se avisa en pantalla y la respuesta indica qué proveedor respondió.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                if let note = model.lastRouteNote {
                    Text("Última decisión: \(note)").font(.caption).foregroundStyle(Theme.accent)
                }
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Modelos por proveedor") {
                ForEach(CloudProviders.all) { preset in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preset.displayName).foregroundStyle(Theme.textPrimary)
                        TextField("Económico (por defecto \(preset.defaultModel))", text: tierBinding(preset.id, strong: false))
                            .textInputAutocapitalization(.never).autocorrectionDisabled().font(.footnote.monospaced())
                        TextField("Capaz (por defecto el mismo o el que elegiste)", text: tierBinding(preset.id, strong: true))
                            .textInputAutocapitalization(.never).autocorrectionDisabled().font(.footnote.monospaced())
                    }
                }
                Text("Escribe aquí el modelo de cada nivel o déjalo vacío. Para ver los modelos que tu clave puede usar: Ajustes › Cerebro en la nube › Probar conexión. Viernes nunca cambia a otro modelo en silencio.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))
        }
        .chromeList()
        .navigationTitle("Enrutador de inteligencia")
        .navigationBarTitleDisplayMode(.inline)
    }
}
