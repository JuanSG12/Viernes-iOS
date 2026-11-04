import SwiftUI
import ViernesCore

/// Hoja obligatoria antes de cualquier acción sensible: muestra EXACTAMENTE lo que se va a hacer.
struct ConfirmationSheet: View {
    let request: ConfirmationRequest
    @EnvironmentObject var confirmation: ConfirmationCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Theme.label("Confirmación requerida")
            Text(request.title).font(.system(size: 24, weight: .light)).foregroundStyle(Theme.textPrimary)
            GlassPanel(tint: Theme.amber) {
                Text(request.detail)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("confirmation-detail")
            }
            Text("Viernes solo actuará si confirmas. Si no respondes, la acción se cancela.")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
            Spacer()
            HStack(spacing: 12) {
                Button("Cancelar") { confirmation.resolve(false) }
                    .buttonStyle(HoloButtonStyle(tint: Theme.amber))
                    .accessibilityIdentifier("confirm-cancel")
                Button("Confirmar") { confirmation.resolve(true) }
                    .buttonStyle(HoloButtonStyle(tint: Theme.cyan))
                    .accessibilityIdentifier("confirm-accept")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
    }
}
