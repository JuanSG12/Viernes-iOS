import Foundation

/// Resúmenes de conversación y propuestas de recuerdos usando el MISMO modelo local (sin red).
public enum ConversationSummarizer {
    /// Consume el flujo del motor y retira bloques <think>.
    static func collect(_ engine: LanguageModelEngine, _ request: GenerationRequest) async throws -> String {
        let filter = StreamingTagFilter(specs: [.init(open: "<think>", close: "</think>", capture: false)])
        var text = ""
        for try await delta in engine.generate(request) { text += filter.feed(delta) }
        text += filter.finish()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func transcript(_ messages: [ChatMessage], maxChars: Int = 5_000) -> String {
        var lines: [String] = []
        var used = 0
        for message in messages.reversed() where message.role != .tool {
            let line = (message.role == .user ? "Usuario: " : "Viernes: ") + message.text
            if used + line.count > maxChars { break }
            used += line.count
            lines.append(line)
        }
        return lines.reversed().joined(separator: "\n")
    }

    /// Resumen breve y sin datos sensibles (se redacta después de generarlo, por si el modelo los copia).
    public static func summarize(_ messages: [ChatMessage], using engine: LanguageModelEngine) async throws -> String {
        let system = """
        Resume la siguiente conversación en español, en 2 a 4 frases, centrándote en decisiones, preferencias del usuario \
        y proyectos mencionados. No incluyas contraseñas, números de tarjeta, documentos de identidad ni claves. \
        No inventes nada que no esté en la conversación. Responde solo con el resumen.
        """
        let request = GenerationRequest(system: system, turns: [ChatTurn(role: .user, content: transcript(messages))], maxTokens: 220, temperature: 0.3)
        let raw = try await collect(engine, request)
        return SensitiveDataRedactor.scan(raw).redacted
    }

    public struct Suggestion: Equatable, Sendable {
        public let kind: MemoryKind
        public let text: String
    }

    /// Pide al modelo candidatos a recuerdo. SIEMPRE se guardan como pendientes de aprobación.
    public static func suggestMemories(from messages: [ChatMessage], using engine: LanguageModelEngine) async throws -> [Suggestion] {
        let system = """
        Extrae de la conversación como máximo 3 datos duraderos que el usuario probablemente querría que se recordaran \
        (preferencias, proyectos en curso). Ignora cualquier dato sensible, efímero o dicho de pasada. \
        Responde SOLO con un arreglo JSON, por ejemplo: [{"kind":"preference","text":"Prefiere respuestas breves"}]. \
        Los valores de kind son preference, project o fact. Si no hay nada, responde [].
        """
        let request = GenerationRequest(system: system, turns: [ChatTurn(role: .user, content: transcript(messages))], maxTokens: 300, temperature: 0.2)
        return parseSuggestions(try await collect(engine, request))
    }

    /// Tolerante a texto alrededor del JSON (los modelos pequeños añaden prosa).
    public static func parseSuggestions(_ raw: String) -> [Suggestion] {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        var result: [Suggestion] = []
        for entry in array.prefix(3) {
            guard let text = (entry["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  !SensitiveDataRedactor.scan(text).isSensitive else { continue }
            let kind = (entry["kind"] as? String).flatMap(MemoryKind.init(rawValue:)).flatMap { $0 == .summary ? nil : $0 } ?? .fact
            result.append(Suggestion(kind: kind, text: String(text.prefix(300))))
        }
        return result
    }
}
