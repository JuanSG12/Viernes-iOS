import SwiftUI

/// «Entendí…»: lo que Viernes oyó por voz, antes de enviarlo al cerebro. El usuario puede tocar el texto para corregirlo,
/// enviarlo ya o descartarlo. En el modo breve se envía solo al terminar la cuenta atrás, salvo que el usuario lo edite.
struct TranscriptReviewBar: View {
    let pending: PendingTranscript
    @EnvironmentObject var model: AppModel
    @State private var remaining: Double = AppModel.reviewSeconds
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ENTENDÍ").font(Theme.mono(9, weight: .semibold)).tracking(1.8).foregroundStyle(Theme.accent)
                Spacer()
                if pending.autoSend {
                    Text("Se envía en \(Int(remaining.rounded(.up))) s").font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
                } else {
                    Text("Corrige y envía").font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
                }
            }
            TextField("", text: Binding(get: { pending.text }, set: { model.editPending($0) }), axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .font(Theme.body(16))
                .foregroundStyle(Theme.textPrimary)
                .accessibilityIdentifier("review-text")
            if pending.autoSend {
                ProgressView(value: max(0, remaining), total: AppModel.reviewSeconds).tint(Theme.accent)
            }
            HStack(spacing: 10) {
                Button("Descartar") { model.discardPending() }
                    .buttonStyle(ChromeButtonStyle(tint: Theme.amber))
                    .accessibilityIdentifier("review-discard")
                Spacer(minLength: 0)
                Button("Editar") { model.editPending(pending.text); focused = true }
                    .buttonStyle(ChromeButtonStyle(tint: Theme.chrome))
                    .accessibilityIdentifier("review-edit")
                Button("Enviar") { model.confirmPending() }
                    .buttonStyle(ChromeButtonStyle(tint: Theme.accent))
                    .accessibilityIdentifier("review-send")
            }
        }
        .padding(12)
        .chromeSurface(tint: Theme.accent, radius: 16)
        .task(id: pending.id) {
            remaining = AppModel.reviewSeconds
            while remaining > 0, pending.autoSend, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                remaining -= 0.1
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-bar")
    }
}
