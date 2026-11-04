import AppIntents
import Foundation

/// Comandos que llegan desde Siri / Atajos. Si la app está cerrada, el intent la abre (`openAppWhenRun`) y el modelo
/// recoge los comandos pendientes al arrancar.
enum IntentCommand: Equatable {
    case open
    case listen
    case ask(String)
}

@MainActor
final class IntentBridge {
    static let shared = IntentBridge()
    private(set) var queue: [IntentCommand] = []
    var onCommand: ((IntentCommand) -> Void)? {
        didSet { drain() }
    }

    func submit(_ command: IntentCommand) {
        queue.append(command)
        drain()
    }

    private func drain() {
        guard let handler = onCommand, !queue.isEmpty else { return }
        let pending = queue
        queue.removeAll()
        pending.forEach(handler)
    }
}

// MARK: Intents (App Intents, iOS 16+; aquí iOS 18+)

struct OpenViernesIntent: AppIntent {
    static let title: LocalizedStringResource = "Abrir Viernes"
    static let description = IntentDescription("Abre Viernes y muestra el núcleo.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.shared.submit(.open)
        return .result()
    }
}

struct TalkToViernesIntent: AppIntent {
    static let title: LocalizedStringResource = "Hablar con Viernes"
    static let description = IntentDescription("Abre Viernes y empieza a escucharte (micrófono activo mientras la app está abierta).")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.shared.submit(.listen)
        return .result()
    }
}

struct AskViernesIntent: AppIntent {
    static let title: LocalizedStringResource = "Preguntar a Viernes"
    static let description = IntentDescription("Envía un mensaje de texto a Viernes. Responde en la app.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Mensaje", requestValueDialog: "¿Qué quieres decirle a Viernes?")
    var message: String

    static var parameterSummary: some ParameterSummary {
        Summary("Preguntar a Viernes \(\.$message)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { IntentBridge.shared.submit(.ask(String(text.prefix(1_000)))) }
        return .result()
    }
}

/// Frases de Siri. Siempre incluyen el nombre de la app, como exige Apple. Viernes NO reemplaza a Siri:
/// Siri sigue siendo quien te escucha; estas frases solo le enseñan a abrir Viernes o pasarle un mensaje.
struct ViernesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenViernesIntent(),
            phrases: ["Abre \(.applicationName)", "Abrir \(.applicationName)", "Muestra \(.applicationName)"],
            shortTitle: "Abrir Viernes",
            systemImageName: "circle.hexagongrid"
        )
        AppShortcut(
            intent: TalkToViernesIntent(),
            phrases: ["Habla con \(.applicationName)", "Hablar con \(.applicationName)", "Escucha \(.applicationName)"],
            shortTitle: "Hablar con Viernes",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: AskViernesIntent(),
            phrases: ["Pregunta a \(.applicationName)", "Pregúntale algo a \(.applicationName)", "Dile algo a \(.applicationName)"],
            shortTitle: "Preguntar a Viernes",
            systemImageName: "text.bubble"
        )
    }
}
