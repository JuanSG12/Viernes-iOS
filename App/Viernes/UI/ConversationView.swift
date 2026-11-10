import SwiftUI
import UIKit
import ViernesCore

/// Frases de estado en español para cada herramienta (solo se muestran cuando la herramienta se está ejecutando de verdad).
enum ToolPhrases {
    static func running(_ tool: String) -> String {
        switch tool {
        case "get_weather": return "Consultando el clima…"
        case "create_reminder": return "Creando el recordatorio…"
        case "list_reminders": return "Revisando tus recordatorios…"
        case "complete_reminder": return "Completando el recordatorio…"
        case "create_event": return "Añadiendo al calendario…"
        case "update_event": return "Modificando el evento…"
        case "delete_event": return "Buscando el evento…"
        case "compose_email": return "Preparando el borrador…"
        case "compose_message": return "Preparando el mensaje…"
        case "find_contact": return "Buscando en tus contactos…"
        case "list_events": return "Revisando tu calendario…"
        case "open_app": return "Abriendo la app…"
        case "open_url": return "Abriendo el enlace…"
        case "run_shortcut": return "Ejecutando el atajo…"
        case "ask_claude": return "Preguntando a Claude…"
        case "save_memory", "search_memory", "forget_memory": return "Consultando tu memoria…"
        case "device_info": return "Consultando el dispositivo…"
        default: return "Ejecutando una acción…"
        }
    }

    static func icon(_ tool: String) -> String {
        switch tool {
        case "get_weather": return "cloud.sun"
        case "create_reminder", "list_reminders", "complete_reminder": return "checklist"
        case "create_event", "update_event", "list_events": return "calendar"
        case "delete_event": return "calendar.badge.minus"
        case "compose_email": return "envelope"
        case "compose_message": return "message"
        case "find_contact": return "person.crop.circle"
        case "open_app", "open_url": return "arrow.up.forward.app"
        case "run_shortcut": return "bolt"
        case "ask_claude": return "sparkles"
        case "save_memory", "search_memory", "forget_memory": return "brain"
        case "device_info": return "iphone"
        default: return "gearshape"
        }
    }
}

/// Conversación: mensajes del usuario en burbuja compacta, respuestas de Viernes como texto limpio con una línea de energía,
/// tarjetas para lo que REALMENTE hicieron las herramientas y un indicador de procesamiento.
struct ConversationView: View {
    @EnvironmentObject var model: AppModel
    @State private var quickLookURL: URL?

    private var lastAssistantID: UUID? {
        model.messages.last(where: { $0.role == .assistant })?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.messages) { message in
                        if message.role == .user {
                            UserBubble(text: message.text,
                                       attachments: message.attachments ?? [],
                                       onOpenAttachment: { ref in quickLookURL = model.attachments.sentFiles[ref.id] },
                                       onCorrect: (message.id == model.lastVoiceMessageID && model.generationIdle) ? { model.correctLastMessage() } : nil)
                                .id(message.id)
                        } else {
                            AssistantMessage(message: message, isLast: message.id == lastAssistantID && model.generationIdle)
                                .id(message.id)
                        }
                    }
                    if !model.liveTranscript.isEmpty {
                        UserBubble(text: model.liveTranscript, dim: true).id("live")
                    }
                    ForEach(model.liveActions.filter { $0.isVisible }) { ActionCard(record: $0) }
                    if !model.streamingText.isEmpty {
                        StreamingMessage(text: model.streamingText).id("stream")
                    } else if model.coreState == .thinking {
                        ThinkingIndicator(label: model.engineWaitNote ?? model.busyNote ?? model.activeTool.map(ToolPhrases.running) ?? "Pensando…").id("thinking")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.top, 20)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.messages.count) { _, _ in scroll(proxy) }
            .onChange(of: model.streamingText) { _, _ in scroll(proxy) }
            .onChange(of: model.liveTranscript) { _, _ in scroll(proxy) }
            .onChange(of: model.coreState) { _, _ in scroll(proxy) }
        }
        .accessibilityIdentifier("conversation")
        .quickLookPreview($quickLookURL)
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }
}

import QuickLook

struct UserBubble: View {
    let text: String
    var dim: Bool = false
    /// Archivos que acompañaron al mensaje (solo sus datos; el contenido no se guarda en el historial).
    var attachments: [AttachmentRef] = []
    var onOpenAttachment: ((AttachmentRef) -> Void)?
    /// Si existe, aparece un lápiz para corregir lo que se transcribió (solo en la última frase dictada).
    var onCorrect: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if let onCorrect = onCorrect {
                Button(action: onCorrect) { Image(systemName: "pencil") }
                    .buttonStyle(ChromeIconButtonStyle(size: 30))
                    .accessibilityLabel("Corregir lo que dije")
                    .accessibilityIdentifier("correct-message")
            }
            VStack(alignment: .trailing, spacing: 6) {
                if !attachments.isEmpty {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(attachments) { ref in
                            SentAttachmentChip(ref: ref, onOpen: onOpenAttachment.map { open in { open(ref) } })
                        }
                    }
                }
                Text(text)
                    .font(Theme.body(15))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .chromeSurface(tint: Theme.chrome, radius: 18)
                    .opacity(dim ? 0.65 : 1)
            }
        }
        .padding(.leading, 56)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Respuesta de Viernes: texto limpio con una línea de energía a la izquierda (no una tarjeta enorme).
struct AssistantMessage: View {
    let message: ChatMessage
    let isLast: Bool
    @EnvironmentObject var model: AppModel

    private var isSystemNotice: Bool { message.engineName == "Sistema" }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule()
                .fill(LinearGradient(colors: [isSystemNotice ? Theme.amber : Theme.accent, Color.clear], startPoint: .top, endPoint: .bottom))
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 8) {
                if let engine = message.engineName {
                    Text("VIERNES · \(engine.uppercased())")
                        .font(Theme.mono(9)).tracking(1.8)
                        .foregroundStyle(isSystemNotice ? Theme.amber.opacity(0.9) : Theme.textSecondary.opacity(0.8))
                }
                Text(message.text)
                    .font(Theme.body(16))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                ForEach(message.actions.filter { $0.isVisible }) { ActionCard(record: $0) }
                if isLast && !isSystemNotice { actionRow }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 12)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                if model.coreState == .speaking { model.interrupt() } else { model.replay(message.text) }
            } label: {
                Image(systemName: model.coreState == .speaking ? "stop.fill" : "speaker.wave.2")
            }
            .buttonStyle(ChromeIconButtonStyle(size: 32))
            .accessibilityLabel(model.coreState == .speaking ? "Detener la voz" : "Escuchar de nuevo")
            .accessibilityIdentifier("replay-message")

            Button { UIPasteboard.general.string = message.text } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(ChromeIconButtonStyle(size: 32))
                .accessibilityLabel("Copiar respuesta")
                .accessibilityIdentifier("copy-message")
        }
        .padding(.top, 2)
    }
}

/// Respuesta que está llegando por streaming, con un cursor de energía.
struct StreamingMessage: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule()
                .fill(LinearGradient(colors: [Theme.accent, Color.clear], startPoint: .top, endPoint: .bottom))
                .frame(width: 2)
            (Text(text) + Text(" ▍").foregroundColor(Theme.accent))
                .font(Theme.body(16))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, 12)
    }
}

/// Indicador de procesamiento real: tres puntos de energía y, si hay herramienta en curso, qué está haciendo.
struct ThinkingIndicator: View {
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.animation(minimumInterval: 0.1)) { timeline in
                let t: Double = timeline.date.timeIntervalSinceReferenceDate
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { index in
                        let wave: Double = sin(t * 4 - Double(index) * 0.8) * 0.5 + 0.5
                        Circle().fill(Theme.accent).frame(width: 6, height: 6).opacity(0.25 + 0.75 * wave * wave)
                    }
                }
            }
            Text(label).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.leading, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityIdentifier("thinking-indicator")
    }
}

/// Lo que REALMENTE pasó con una herramienta. Resultado con datos estructurados → tarjeta nativa; resultado simple → tarjeta
/// compacta; error técnico que el modelo puede corregir solo → no se muestra (queda en diagnósticos).
struct ActionCard: View {
    let record: ActionRecord

    var body: some View {
        if !record.isVisible {
            EmptyView()
        } else if record.outcome.isExecuted, let card = record.card, card.kind == .weather {
            WeatherCard(card: card)
        } else {
            standardCard
        }
    }

    private var needsSettings: Bool {
        if case .failed(let reason) = record.outcome { return reason.contains("Ajustes ›") }
        return false
    }

    private var standardCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ToolPhrases.icon(record.tool))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(Circle().fill(color.opacity(0.12)))
                .overlay(Circle().strokeBorder(color.opacity(0.45), lineWidth: 0.7))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.mono(9, weight: .semibold)).tracking(1.6).foregroundStyle(color)
                if !record.summary.isEmpty {
                    Text(record.summary).font(Theme.body(13, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(3)
                }
                if let detail = detail {
                    Text(detail).font(Theme.body(12)).foregroundStyle(Theme.textSecondary).lineLimit(6)
                }
                if needsSettings {
                    Button("Abrir Ajustes") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(ChromeButtonStyle(tint: Theme.accent))
                    .padding(.top, 4)
                    .accessibilityIdentifier("open-ios-settings")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .chromeSurface(tint: color, radius: 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("action-chip")
    }

    private var color: Color {
        switch record.outcome {
        case .executed: return Theme.accent
        case .declined: return Theme.amber
        case .failed: return Theme.alert
        }
    }
    private var title: String {
        switch record.outcome {
        case .executed: return "EJECUTADO"
        case .declined: return "RECHAZADO POR TI"
        case .failed: return "NO SE EJECUTÓ"
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
