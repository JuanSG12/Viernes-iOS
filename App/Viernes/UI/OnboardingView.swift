import SwiftUI

/// Primera ejecución: explica qué hace y qué NO hace Viernes antes de pedir ningún permiso.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    let onDone: () -> Void

    var body: some View {
        ZStack {
            Theme.background
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("VIERNES").font(.system(size: 34, weight: .ultraLight)).tracking(14).foregroundStyle(Theme.textPrimary).padding(.top, 40)
                    Text("Tu asistente personal, dentro de tu iPhone.").font(.system(size: 18, weight: .light)).foregroundStyle(Theme.ice)

                    point("cpu", "Cerebro local", "Piensa en tu teléfono con un modelo de IA local. Funciona sin internet. Es pequeño: puede equivocarse y te lo dirá.")
                    point("mic", "Tú decides cuándo escucha", "El micrófono solo se abre cuando pulsas el núcleo, dices «Habla con Viernes» a Siri, o activas la palabra «Viernes» con la app abierta. Siempre hay un indicador visible. No escucha con la app cerrada: iOS no lo permite.")
                    point("lock.shield", "Privacidad", "Memoria e historial cifrados en este dispositivo. Sin cuentas, sin servidores, sin analítica. Puedes borrar todo cuando quieras.")
                    point("checkmark.seal", "Honestidad", "Viernes solo dice que hizo algo si realmente lo hizo, y te pide confirmación antes de acciones sensibles.")
                    point("arrow.up.forward.app", "Claude", "No usa la API de Anthropic. Puede abrir la app de Claude o usar un Atajo tuyo; nunca finge que Claude está integrado si solo abrió su app.")

                    Button { onDone() } label: { Text("Empezar").frame(maxWidth: .infinity) }
                        .buttonStyle(HoloButtonStyle())
                        .padding(.top, 8)
                        .accessibilityIdentifier("onboarding-start")
                    Text("Los permisos (micrófono, voz, recordatorios, calendario) se piden después, uno a uno, cuando hagan falta.")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                .padding(24)
            }
        }
    }

    private func point(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 22, weight: .light)).foregroundStyle(Theme.cyan).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Text(text).font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
