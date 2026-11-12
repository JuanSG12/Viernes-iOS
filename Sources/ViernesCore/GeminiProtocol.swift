import Foundation

// API nativa de Gemini (REST `generateContent` / `streamGenerateContent`). Puro y probado: sin red ni claves.
// Documentación: https://ai.google.dev/gemini-api/docs (la clave va en la cabecera `x-goog-api-key`, nunca en la URL).

public struct GeminiChunk: Equatable, Sendable {
    public var text: String = ""
    public var finishReason: String?
    public var blockReason: String?
    /// Consumo ACUMULADO que informa Google en el flujo (la última cifra manda).
    public var usage: TokenUsage?
    /// Si el flujo trajo un error en vez de contenido: el JSON crudo (para clasificarlo).
    public var errorBody: String?
    public init() {}
}

public enum GeminiProtocol {
    public static let baseURL = "https://generativelanguage.googleapis.com/v1beta"

    /// Los identificadores de modelo son letras, números, punto, guion y guion bajo: nada más entra en una URL.
    public static func isValidModelID(_ model: String) -> Bool {
        guard !model.isEmpty, model.count <= 100 else { return false }
        return model.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122) || scalar == "." || scalar == "-" || scalar == "_"
        }
    }

    public static func streamURL(model: String) -> URL? {
        guard isValidModelID(model) else { return nil }
        return URL(string: "\(baseURL)/models/\(model):streamGenerateContent?alt=sse")
    }

    public static func modelsURL(pageToken: String? = nil) -> URL? {
        var text = "\(baseURL)/models?pageSize=200"
        if let token = pageToken, !token.isEmpty,
           let encoded = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            text += "&pageToken=\(encoded)"
        }
        return URL(string: text)
    }

    /// Cuerpo de `streamGenerateContent`: instrucción de sistema, turnos alternados usuario/modelo (los consecutivos del mismo
    /// rol se unen), imágenes como `inlineData` y topes de salida. No se envía ningún parámetro opcional de «pensamiento»:
    /// cambian entre modelos y uno no soportado haría fallar la petición.
    public static func requestBody(system: String, turns: [ChatTurn], maxOutputTokens: Int, temperature: Double) throws -> Data {
        var contents: [[String: Any]] = []
        var lastRole: String?
        for turn in turns {
            let role: String = turn.role == .user ? "user" : "model"
            if contents.isEmpty && role == "model" { continue }              // la conversación debe empezar con el usuario
            var parts: [[String: Any]] = []
            if !turn.content.isEmpty { parts.append(["text": turn.content]) }
            for image in turn.images {
                parts.append(["inlineData": ["mimeType": image.mimeType, "data": image.base64]])
            }
            if parts.isEmpty { continue }
            if lastRole == role, var previous = contents.last, var previousParts = previous["parts"] as? [[String: Any]] {
                previousParts.append(contentsOf: parts)
                previous["parts"] = previousParts
                contents[contents.count - 1] = previous
            } else {
                contents.append(["role": role, "parts": parts])
            }
            lastRole = role
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": contents,
            "generationConfig": ["maxOutputTokens": maxOutputTokens, "temperature": temperature]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Interpreta una línea del flujo `text/event-stream`. `nil` = línea sin contenido (vacía, comentario, «[DONE]»).
    public static func parseStreamLine(_ line: String) -> GeminiChunk? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]", let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var chunk = GeminiChunk()
        if object["error"] != nil {
            chunk.errorBody = payload
            return chunk
        }
        if let feedback = object["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
            chunk.blockReason = reason
        }
        if let candidates = object["candidates"] as? [[String: Any]], let first = candidates.first {
            if let content = first["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] {
                for part in parts {
                    if (part["thought"] as? Bool) == true { continue }                 // el razonamiento interno no se muestra
                    if let text = part["text"] as? String { chunk.text += text }
                }
            }
            if let reason = first["finishReason"] as? String, !reason.isEmpty { chunk.finishReason = reason }
        }
        if let usage = object["usageMetadata"] as? [String: Any] {
            let input: Int? = usage["promptTokenCount"] as? Int
            let candidates: Int = (usage["candidatesTokenCount"] as? Int) ?? 0
            let thoughts: Int = (usage["thoughtsTokenCount"] as? Int) ?? 0         // el razonamiento se factura como salida
            if input != nil || candidates > 0 || thoughts > 0 {
                chunk.usage = TokenUsage(input: input ?? 0, output: candidates + thoughts)
            }
        }
        return chunk
    }

    /// Validación de la respuesta completa: si no llegó texto, dice por qué en vez de dejarla vacía. `nil` = todo bien.
    public static func validationError(producedText: Bool, finishReason: String?, blockReason: String?) -> String? {
        if let block = blockReason, !producedText {
            return "Gemini bloqueó la solicitud (\(block)). Reformula el mensaje."
        }
        if producedText { return nil }
        switch finishReason {
        case "MAX_TOKENS":
            return "El modelo agotó su espacio de respuesta antes de escribir. Inténtalo de nuevo con un mensaje más corto."
        case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII":
            return "Gemini detuvo la respuesta por sus filtros (\(finishReason ?? "")). Reformula el mensaje."
        case .some(let reason) where reason != "STOP":
            return "Gemini terminó sin texto (\(reason)). Inténtalo de nuevo."
        default:
            return nil          // STOP sin texto: lo trata el reintento de respuesta vacía del motor de conversación
        }
    }
}

/// Un modelo que Google dice que la clave puede usar.
public struct GeminiModelInfo: Equatable, Sendable, Identifiable {
    public var id: String                    // sin el prefijo «models/»
    public var displayName: String
    public var methods: [String]
    public var inputTokenLimit: Int?
    public var outputTokenLimit: Int?

    public var supportsGenerateContent: Bool { methods.contains("generateContent") }
}

public enum GeminiModels {
    public enum Tier: String, Sendable { case light, strong }

    public static func parseList(_ data: Data) -> (models: [GeminiModelInfo], nextPageToken: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], nil) }
        let list: [[String: Any]] = (object["models"] as? [[String: Any]]) ?? []
        var models: [GeminiModelInfo] = []
        for entry in list {
            guard let name = entry["name"] as? String else { continue }
            let id: String = name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
            let info = GeminiModelInfo(
                id: id,
                displayName: (entry["displayName"] as? String) ?? id,
                methods: (entry["supportedGenerationMethods"] as? [String]) ?? [],
                inputTokenLimit: entry["inputTokenLimit"] as? Int,
                outputTokenLimit: entry["outputTokenLimit"] as? Int)
            models.append(info)
        }
        let next: String? = (object["nextPageToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (models, next)
    }

    /// Modelos útiles para conversar: Gemini con `generateContent`, sin los de embeddings, imagen, voz, audio en vivo ni uso de equipo.
    public static func chatModels(_ models: [GeminiModelInfo]) -> [GeminiModelInfo] {
        let excluded: [String] = ["embedding", "aqa", "imagen", "veo", "tts", "image", "live", "audio", "robotics", "computer-use", "learnlm"]
        let filtered: [GeminiModelInfo] = models.filter { model in
            guard model.supportsGenerateContent, model.id.hasPrefix("gemini") else { return false }
            return !excluded.contains { model.id.contains($0) }
        }
        return filtered.sorted { sortKey($0) < sortKey($1) }
    }

    public static func isPreview(_ id: String) -> Bool {
        id.contains("preview") || id.contains("-exp") || id.contains("experimental")
    }

    /// (versión, familia) de «gemini-2.5-flash-lite» → (2.5, «flash-lite»). Sin versión reconocible: (0, id).
    static func versionAndFamily(_ id: String) -> (version: Double, family: String) {
        guard let regex = try? NSRegularExpression(pattern: "^gemini-(\\d+(?:\\.\\d+)?)-(.+)$") else { return (0, id) }
        let ns = id as NSString
        guard let match = regex.firstMatch(in: id, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges == 3,
              let version = Double(ns.substring(with: match.range(at: 1))) else { return (0, id) }
        return (version, ns.substring(with: match.range(at: 2)))
    }

    private static func sortKey(_ model: GeminiModelInfo) -> String { model.id }

    /// SUGERENCIA (nunca se aplica sola): el modelo estable más nuevo de cada nivel entre los realmente disponibles.
    /// `light` = la familia «flash-lite» (tareas frecuentes); `strong` = «flash» (o «pro» si no hay).
    public static func suggest(_ tier: Tier, from models: [GeminiModelInfo]) -> String? {
        let candidates: [GeminiModelInfo] = chatModels(models)
        func matches(_ family: String, _ wanted: String) -> Bool {
            if family == wanted { return true }
            guard family.hasPrefix(wanted + "-") else { return false }
            if wanted == "flash" && family.contains("lite") { return false }
            return true
        }
        func best(matching families: [String], allowPreview: Bool) -> String? {
            let pool: [GeminiModelInfo] = candidates.filter { model in
                let family: String = versionAndFamily(model.id).family
                guard families.contains(where: { matches(family, $0) }) else { return false }
                return allowPreview || !isPreview(model.id)
            }
            return pool.max { versionAndFamily($0.id).version < versionAndFamily($1.id).version }?.id
        }
        switch tier {
        case .light:
            return best(matching: ["flash-lite"], allowPreview: false) ?? best(matching: ["flash"], allowPreview: false)
                ?? best(matching: ["flash-lite", "flash"], allowPreview: true)
        case .strong:
            return best(matching: ["flash"], allowPreview: false) ?? best(matching: ["pro"], allowPreview: false)
                ?? best(matching: ["flash", "pro"], allowPreview: true)
        }
    }
}

/// Filtro de modelos «de conversación» para las listas de proveedores compatibles con OpenAI (Groq, OpenAI, Cerebras…):
/// quita los de embeddings, voz, imagen y moderación. Solo para mostrar la lista: no decide nada por el usuario.
public enum CloudModelFilter {
    public static func chatCandidates(_ ids: [String]) -> [String] {
        let excluded: [String] = ["embed", "whisper", "tts", "dall-e", "moderation", "transcribe", "realtime", "audio", "image", "guard", "davinci", "babbage", "rerank", "sora"]
        return ids.filter { id in
            let lowered: String = id.lowercased()
            return !excluded.contains { lowered.contains($0) }
        }.sorted()
    }
}
