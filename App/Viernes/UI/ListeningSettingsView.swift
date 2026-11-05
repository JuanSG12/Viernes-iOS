import SwiftUI
import ViernesCore

struct ListeningSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section {
                Toggle("Escuchar la palabra «Viernes»", isOn: $model.settings.wakeWordEnabled)
                    .accessibilityIdentifier("wake-toggle")
                Text("Solo funciona MIENTRAS la app está abierta y en pantalla. El micrófono permanece abierto en ese modo y la app lo indica con un punto rojo. iOS no permite a una app de terceros escuchar con la app cerrada o el teléfono bloqueado, y Viernes no lo intenta. Para activarla en esos casos usa Siri: «Oye Siri, abre Viernes» o «Habla con Viernes». Consume más batería mientras está activa.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            } header: { Text("Palabra de activación") }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section {
                Toggle("Conversación continua", isOn: $model.settings.continuousConversation)
                Text("Al terminar de hablar, Viernes vuelve a escucharte sola. Apágalo para controlar tú cada turno.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            } header: { Text("Manos libres") }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section {
                Picker("Idioma", selection: $model.settings.recognitionLocale) {
                    Text("Español (Colombia)").tag("es-CO")
                    Text("Español (México)").tag("es-MX")
                    Text("Español (EE. UU.)").tag("es-US")
                    Text("Español (España)").tag("es-ES")
                }
                Toggle("Permitir reconocimiento de Apple por internet", isOn: $model.settings.allowServerRecognition)
                    .accessibilityIdentifier("server-recognition-toggle")
                Text("Apagado (recomendado): Viernes solo transcribe EN el dispositivo y el audio nunca sale del teléfono. Si tu iPhone no tiene el dictado del idioma elegido descargado, verás un aviso; descárgalo en Ajustes › General › Teclado › Dictado. Si lo enciendes, cuando no haya modelo local Apple podrá procesar tu audio en sus servidores.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            } header: { Text("Reconocimiento de voz") }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Siempre disponible") {
                Label("Botón del micrófono y toque sobre el núcleo", systemImage: "mic")
                Label("Teclado para escribir sin voz", systemImage: "keyboard")
            }
            .foregroundStyle(Theme.textPrimary)
            .listRowBackground(Theme.carbon.opacity(0.5))
        }
        .chromeList()
        .navigationTitle("Escucha y activación")
        .navigationBarTitleDisplayMode(.inline)
    }
}
