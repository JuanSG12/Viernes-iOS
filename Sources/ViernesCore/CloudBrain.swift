import Foundation

/// Proveedor de IA en la nube con API compatible con OpenAI. Solo HTTPS y solo estos presets: la clave del usuario
/// nunca se envía a una URL escrita a mano.
public struct CloudProviderPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    /// Sin barra final.
    public let baseURL: String
    public let defaultModel: String
    public let keyPageURL: String
    public let note: String

    public init(id: String, displayName: String, baseURL: String, defaultModel: String, keyPageURL: String, note: String) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.keyPageURL = keyPageURL
        self.note = note
    }
}

public enum CloudProviders {
    public static let groq = CloudProviderPreset(
        id: "groq", displayName: "Groq",
        baseURL: "https://api.groq.com/openai/v1",
        defaultModel: "llama-3.3-70b-versatile",
        keyPageURL: "https://console.groq.com/keys",
        note: "Muy rápido. Plan gratuito sin tarjeta, con límites por minuto y por día que fija Groq (consúltalos en su consola)."
    )
    public static let gemini = CloudProviderPreset(
        id: "gemini", displayName: "Google Gemini",
        baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
        defaultModel: "gemini-2.5-flash",
        keyPageURL: "https://aistudio.google.com/apikey",
        note: "Clave desde Google AI Studio. Los modelos y límites del plan gratuito cambian con frecuencia: usa «Probar conexión» para ver los disponibles."
    )

    public static let all: [CloudProviderPreset] = [groq, gemini]

    public static func preset(id: String) -> CloudProviderPreset { all.first { $0.id == id } ?? groq }
}

public struct CloudBrainSettings: Codable, Equatable, Sendable {
    public var providerID: String
    public var model: String

    public static let `default` = CloudBrainSettings(providerID: CloudProviders.groq.id, model: CloudProviders.groq.defaultModel)

    public init(providerID: String, model: String) {
        self.providerID = providerID
        self.model = model
    }

    public var preset: CloudProviderPreset { CloudProviders.preset(id: providerID) }

    public func sanitized() -> CloudBrainSettings {
        var copy = self
        if !CloudProviders.all.contains(where: { $0.id == providerID }) { copy.providerID = CloudProviders.groq.id }
        let cleaned = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = !cleaned.isEmpty && cleaned.count <= 100
            && !cleaned.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        copy.model = valid ? cleaned : copy.preset.defaultModel
        return copy
    }
}

extension AppSettings {
    /// Configuración efectiva del cerebro en la nube (el campo guardado es opcional para no invalidar ajustes antiguos).
    public var cloudBrain: CloudBrainSettings { cloud ?? .default }
}

/// Formato de la API de chat compatible con OpenAI: cuerpo de la petición, flujo SSE y errores. Puro y comprobable.
public enum OpenAIChatProtocol {
    public enum StreamChunk: Equatable, Sendable {
        case delta(String)
        case done
        case ignore
    }

    public static func endpoint(_ preset: CloudProviderPreset, path: String) -> URL? {
        guard preset.baseURL.hasPrefix("https://") else { return nil }
        return URL(string: preset.baseURL + "/" + path)
    }

    public static func requestBody(model: String, system: String, turns: [ChatTurn], maxTokens: Int, temperature: Double) throws -> Data {
        var messages: [[String: String]] = [["role": "system", "content": system]]
        for turn in turns {
            messages.append(["role": turn.role == .user ? "user" : "assistant", "content": turn.content])
        }
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            "max_tokens": maxTokens,
            "temperature": temperature
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Interpreta una línea del flujo `text/event-stream`.
    public static func parseStreamLine(_ line: String) -> StreamChunk {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return .ignore }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String, !content.isEmpty
        else { return .ignore }
        return .delta(content)
    }

    /// Mensaje en español para un error HTTP. Nunca incluye la clave.
    public static func errorMessage(status: Int, body: String, provider: String, model: String) -> String {
        let detail = providerDetail(body)
        switch status {
        case 401, 403:
            return "\(provider) rechazó la clave (error \(status)). Revísala en Ajustes › Cerebro en la nube."
        case 404:
            return "\(provider) no encontró el modelo «\(model)». Usa «Probar conexión» para ver los disponibles."
        case 429:
            return "Alcanzaste el límite del plan gratuito de \(provider). Espera un minuto e inténtalo de nuevo."
        case 500...599:
            return "\(provider) tiene problemas ahora mismo (error \(status)). Inténtalo en un momento."
        default:
            return "\(provider) respondió con error \(status)" + (detail.map { ": \($0)" } ?? ".")
        }
    }

    static func providerDetail(_ body: String) -> String? {
        guard let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let object: [String: Any]?
        if let dict = json as? [String: Any] { object = dict } else { object = (json as? [[String: Any]])?.first }
        guard let message = (object?["error"] as? [String: Any])?["message"] as? String else { return nil }
        let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(200))
    }

    /// Identificadores de modelo de `GET /models` (Gemini antepone «models/»).
    public static func parseModelIDs(_ data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["id"] as? String }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
            .sorted()
    }
}

/// Validación de la clave pegada por el usuario (antes de guardarla en el Llavero).
public enum APIKeyFormat {
    public static func clean(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (20...300).contains(key.count),
              key.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { return nil }
        return key
    }
}
