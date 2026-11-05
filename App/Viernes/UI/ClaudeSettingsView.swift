import SwiftUI
import UIKit
import ViernesCore

struct ClaudeSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section {
                Text("Viernes NO usa la API de Anthropic ni credenciales de tu suscripción, y no puede enviar peticiones a Claude por su cuenta. Estos modos usan solo mecanismos oficiales de iOS y de la app de Claude. Cada uno se describe con lo que realmente hace.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Color.clear)

            Section("Modo") {
                ForEach(ClaudeMode.allCases, id: \.self) { mode in
                    Button { model.settings.claude.mode = mode } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mode.displayName).foregroundStyle(Theme.textPrimary)
                                Text(mode.honestDescription).font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if model.settings.claude.mode == mode { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                    .accessibilityIdentifier("claude-mode-\(mode.rawValue)")
                }
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            if model.settings.claude.mode == .shortcut {
                Section {
                    TextField("Nombre exacto del atajo", text: $model.settings.claude.shortcutName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("claude-shortcut-name")
                    Text("Crea en la app Atajos un atajo con ese nombre: acción «Recibir entrada de atajo» → acción «Ask Claude» (de la app de Claude, iOS 18+) con esa entrada → «Detener y dar resultado». Si «Ask Claude» devuelve el texto como resultado, Viernes lo mostrará. Eso no está documentado por Anthropic: compruébalo en tu iPhone.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    Button("Abrir app Atajos") { UIApplication.shared.open(URL(string: "shortcuts://")!) }.buttonStyle(ChromeButtonStyle())
                } header: { Text("Atajo") } footer: {
                    Text("Usa tu suscripción desde la app de Claude y cuenta para sus límites de uso.")
                }
                .listRowBackground(Theme.carbon.opacity(0.5))
            }

            Section("Privacidad") {
                Text("Cuando Viernes envía una pregunta a Claude, ese texto sale del dispositivo hacia la app de Claude y se rige por la política de Anthropic. Viernes se niega a enviar mensajes con contraseñas, tarjetas o documentos, y siempre te pide confirmar antes.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                if !model.isOnline { Label("Sin conexión: Claude no responderá hasta que vuelva internet.", systemImage: "wifi.slash").foregroundStyle(Theme.amber).font(.caption) }
            }
            .listRowBackground(Theme.carbon.opacity(0.5))
        }
        .chromeList()
        .navigationTitle("Claude")
        .navigationBarTitleDisplayMode(.inline)
    }
}
