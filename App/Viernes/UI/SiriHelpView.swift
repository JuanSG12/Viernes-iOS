import SwiftUI
import UIKit

struct SiriHelpView: View {
    var body: some View {
        List {
            Section {
                Text("Viernes no reemplaza a Siri: Siri sigue siendo quien te escucha cuando el iPhone está bloqueado o la app cerrada. Viernes le enseña a Siri unas frases y acciones mediante App Intents.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }.listRowBackground(Color.clear)

            Section("Frases que puedes decir") {
                phrase("«Oye Siri, abre Viernes»", "Abre la app. (Siri abre apps por nombre; si lo confunde con el día de la semana, usa la frase siguiente.)")
                phrase("«Oye Siri, habla con Viernes»", "Abre la app y empieza a escucharte.")
                phrase("«Oye Siri, pregunta a Viernes»", "Siri te pide el mensaje; Viernes lo recibe y responde en la app.")
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Configuración") {
                Text("1. Abre la app Atajos y busca «Viernes»: verás las acciones «Abrir Viernes», «Hablar con Viernes» y «Preguntar a Viernes».\n2. Puedes añadirlas a la pantalla de inicio, al Botón de Acción (iPhone 15 Pro y posteriores) o a Control Center.\n3. Si Siri no reconoce una frase, vuelve a decirla un par de veces o créala tú en Atajos con el nombre que prefieras.")
                    .font(.footnote).foregroundStyle(Theme.textPrimary)
                Button("Abrir Atajos") { UIApplication.shared.open(URL(string: "shortcuts://")!) }.buttonStyle(ChromeButtonStyle())
                Button("Ajustes de Siri en iOS") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }.buttonStyle(ChromeButtonStyle())
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Enlaces profundos") {
                Text("viernes://listen · abre y escucha\nviernes://ask?q=texto · precarga el texto (no lo envía solo)")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))
        }
        .chromeList()
        .navigationTitle("Siri y Atajos")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func phrase(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(Theme.textPrimary)
            Text(detail).font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}
