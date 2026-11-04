import SwiftUI
import ViernesCore

/// Conversación sobre el núcleo: mensajes recientes, texto en vivo, acciones reales y respuesta en streaming.
struct ConversationView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.messages) { message in
                        MessageBubble(message: message).id(message.id)
                    }
                    if !model.liveTranscript.isEmpty {
                        bubble(text: model.liveTranscript, role: .user, dim: true).id("live")
                    }
                    ForEach(model.liveActions) { ActionChip(record: $0) }
                    if !model.streamingText.isEmpty {
                        bubble(text: model.streamingText, role: .assistant, dim: false).id("stream")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.top, 24)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.messages.count) { _, _ in scroll(proxy) }
            .onChange(of: model.streamingText) { _, _ in scroll(proxy) }
            .onChange(of: model.liveTranscript) { _, _ in scroll(proxy) }
        }
        .accessibilityIdentifier("conversation")
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private func bubble(text: String, role: ChatRole, dim: Bool) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .regular, design: .rounded))
            .foregroundStyle(role == .user ? Theme.textSecondary : Theme.textPrimary)
            .opacity(dim ? 0.7 : 1)
            .frame(maxWidth: .infinity, alignment: role == .user ? .trailing : .leading)
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            Text(message.text)
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(message.role == .user ? Theme.textSecondary : Theme.textPrimary)
                .multilineTextAlignment(message.role == .user ? .trailing : .leading)
                .textSelection(.enabled)
            ForEach(message.actions) { ActionChip(record: $0) }
            if message.role == .assistant, let engine = message.engineName {
                Text(engine.uppercased()).font(.system(size: 9, design: .monospaced)).tracking(1.5)
                    .foregroundStyle(engine == "Sistema" ? Theme.amber.opacity(0.8) : Theme.textSecondary.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}

/// Muestra lo que REALMENTE pasó con una herramienta (ejecutada / rechazada / falló).
struct ActionChip: View {
    let record: ActionRecord

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                if !record.summary.isEmpty { Text(record.summary).font(.system(size: 11)).lineLimit(2).opacity(0.85) }
                if let detail = detail { Text(detail).font(.system(size: 11)).lineLimit(3).opacity(0.85) }
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.35), lineWidth: 0.6))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("action-chip")
    }

    private var icon: String {
        switch record.outcome {
        case .executed: return "checkmark.seal"
        case .declined: return "hand.raised.slash"
        case .failed: return "exclamationmark.triangle"
        }
    }
    private var color: Color {
        switch record.outcome {
        case .executed: return Theme.cyan
        case .declined: return Theme.amber
        case .failed: return Theme.alert
        }
    }
    private var title: String {
        switch record.outcome {
        case .executed: return "Ejecutado"
        case .declined: return "Rechazado por ti"
        case .failed: return "No se ejecutó"
        }
    }
    private var detail: String? {
        switch record.outcome {
        case .executed(let text): return text
        case .failed(let reason): return reason
        case .declined: return nil
        }
    }
}
