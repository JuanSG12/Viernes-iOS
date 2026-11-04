import SwiftUI
import ViernesCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Cerebro") {
                NavigationLink { ModelPickerView() } label: {
                    row(icon: "cpu", title: "Modelo local", detail: model.activeModel.displayName, status: engineStatusText)
                }.accessibilityIdentifier("settings-model")
                row(icon: model.isOnline ? "wifi" : "wifi.slash", title: "Conexión",
                    detail: model.isOnline ? "En línea. El modelo local funciona igual sin internet." : "Sin conexión. Todo sigue funcionando en modo local.", status: nil)
                NavigationLink { ClaudeSettingsView() } label: {
                    row(icon: "arrow.up.forward.app", title: "Claude", detail: model.settings.claude.mode.displayName, status: nil)
                }.accessibilityIdentifier("settings-claude")
            }
            .listRowBackground(Theme.deep.opacity(0.5))

            Section("Voz") {
                NavigationLink { VoicePickerView() } label: {
                    row(icon: "waveform", title: "Voz y habla", detail: currentVoiceName, status: nil)
                }.accessibilityIdentifier("settings-voice")
                NavigationLink { ListeningSettingsView() } label: {
                    row(icon: "mic", title: "Escucha y activación", detail: model.settings.wakeWordEnabled ? "Palabra «Viernes» activa (app abierta)" : "Pulsar para hablar", status: nil)
                }.accessibilityIdentifier("settings-listening")
            }
            .listRowBackground(Theme.deep.opacity(0.5))

            Section("Datos y seguridad") {
                NavigationLink { PrivacyView() } label: {
                    row(icon: "lock.shield", title: "Privacidad", detail: "Memoria, historial, borrado", status: nil)
                }.accessibilityIdentifier("settings-privacy")
                NavigationLink { PermissionsView() } label: {
                    row(icon: "checkmark.shield", title: "Permisos", detail: "Micrófono, voz, recordatorios, calendario", status: nil)
                }.accessibilityIdentifier("settings-permissions")
            }
            .listRowBackground(Theme.deep.opacity(0.5))

            Section("Siri y Atajos") {
                NavigationLink { SiriHelpView() } label: {
                    row(icon: "sparkles", title: "Siri y Atajos", detail: "Cómo abrir y hablar con Viernes", status: nil)
                }
            }
            .listRowBackground(Theme.deep.opacity(0.5))

            Section("Apariencia") {
                Toggle("Efectos reducidos (menos batería)", isOn: $model.settings.reducedEffects)
                Toggle("Respuesta háptica", isOn: $model.settings.hapticsEnabled)
            }
            .listRowBackground(Theme.deep.opacity(0.5))

            Section("Acerca de") {
                LabeledContent("Versión", value: "0.1.0 (primera versión, sin probar en iPhone)")
                Text("Viernes es una identidad original. No reemplaza a Siri ni usa la API de Anthropic.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.deep.opacity(0.5))
        }
        .holoList()
        .navigationTitle("Configuración")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
    }

    private var currentVoiceName: String {
        if let id = model.settings.voice.voiceIdentifier, let voice = model.voices.first(where: { $0.identifier == id }) { return voice.name }
        return model.voices.first.map { "\($0.name) (automática)" } ?? "Sin voces en español"
    }

    private var engineStatusText: String? {
        switch model.engineStatus {
        case .ready: return "Listo"
        case .notLoaded: return "No cargado"
        case .downloading(let p): return "Descargando \(Int(p * 100)) %"
        case .loading: return "Cargando"
        case .unavailable: return "No disponible"
        case .failed: return "Error"
        }
    }

    private func row(icon: String, title: String, detail: String, status: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.cyan).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.textPrimary)
                Text(detail).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if let status = status { Text(status).font(.caption).foregroundStyle(Theme.textSecondary) }
        }
    }
}
