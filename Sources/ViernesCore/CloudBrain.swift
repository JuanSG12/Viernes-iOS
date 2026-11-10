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
        defaultModel: "openai/gpt-oss-120b",
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
        /// Motivo de fin de la respuesta (`stop`, `length`…). Solo informativo.
        case finish(String)
        /// El proveedor devolvió un error DENTRO del flujo (HTTP 200). Groq lo hace cuando el modelo intenta una llamada a función
        /// nativa: entonces `failedGeneration` trae lo que el modelo quiso escribir.
        case providerError(message: String, failedGeneration: String?)
        case done
        case ignore
    }

    public static func endpoint(_ preset: CloudProviderPreset, path: String) -> URL? {
        guard preset.baseURL.hasPrefix("https://") else { return nil }
        return URL(string: preset.baseURL + "/" + path)
    }

    public static func requestBody(model: String, system: String, turns: [ChatTurn], maxTokens: Int, temperature: Double) throws -> Data {
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        for turn in turns {
            let role = turn.role == .user ? "user" : "assistant"
            if turn.images.isEmpty {
                messages.append(["role": role, "content": turn.content])
            } else {
                // Formato multimodal de la API compatible con OpenAI: texto + una parte `image_url` por imagen (URL de datos en base64).
                var parts: [[String: Any]] = [["type": "text", "text": turn.content]]
                for image in turn.images {
                    parts.append(["type": "image_url", "image_url": ["url": image.dataURL]])
                }
                messages.append(["role": role, "content": parts])
            }
        }
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            "max_tokens": maxTokens,
            "temperature": temperature
        ]
        if usesHiddenReasoning(model: model) { body["reasoning_effort"] = "low" }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Modelos que «piensan» antes de contestar (p. ej. gpt-oss). Ese razonamiento gasta `max_tokens` y puede dejar la
    /// respuesta visible vacía; se pide el esfuerzo mínimo. Solo a estos modelos: otros rechazarían el parámetro.
    public static func usesHiddenReasoning(model: String) -> Bool {
        model.lowercased().contains("gpt-oss")
    }

    /// Margen mínimo de tokens para la nube: el razonamiento oculto cuenta contra el límite y 512 se agotaba antes de responder.
    public static let minimumCloudTokens = 1_500

    /// Interpreta una línea del flujo `text/event-stream`.
    public static func parseStreamLine(_ line: String) -> StreamChunk {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return .ignore }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .ignore }

        if let error = object["error"] as? [String: Any] {
            let message = (error["message"] as? String).map { String($0.prefix(200)) } ?? "error del proveedor"
            let failed = (error["failed_generation"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(4_000)) }
            return .providerError(message: message, failedGeneration: failed)
        }
        if let error = object["error"] as? String, !error.isEmpty {
            return .providerError(message: String(error.prefix(200)), failedGeneration: nil)
        }

        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else { return .ignore }
        if let delta = first["delta"] as? [String: Any], let content = delta["content"] as? String, !content.isEmpty {
            return .delta(content)
        }
        if let reason = first["finish_reason"] as? String, !reason.isEmpty { return .finish(reason) }
        return .ignore
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
            return rateLimitMessage(parseRateLimit(retryAfterHeader: nil, body: body), provider: provider)
        case 500...599:
            return "\(provider) tiene problemas ahora mismo (error \(status)). Inténtalo en un momento."
        default:
            return "\(provider) respondió con error \(status)" + (detail.map { ": \($0)" } ?? ".")
        }
    }

    // MARK: Límites del plan gratuito (HTTP 429)

    /// Lo que el proveedor dijo sobre un límite de uso: cuánto esperar y si es el límite por minuto o el diario.
    public struct RateLimit: Equatable, Sendable {
        public enum Window: String, Sendable { case minute, day, unknown }
        public var retryAfter: TimeInterval?
        public var window: Window
        /// Cifras reales del proveedor (p. ej. «límite 8000, usados 7243, pedidos 1984»), solo para informar y diagnosticar.
        public var detail: String?
        public init(retryAfter: TimeInterval?, window: Window, detail: String?) {
            self.retryAfter = retryAfter
            self.window = window
            self.detail = detail
        }
    }

    /// Espera máxima que Viernes acepta hacer SOLA antes de reintentar; más allá se informa al usuario.
    public static let maxAutomaticWait: TimeInterval = 30
    /// Reintentos automáticos tras un 429 (por petición).
    public static let maxRateLimitRetries = 2

    /// Segundos a esperar antes de reintentar, o `nil` si no conviene esperar (límite diario o espera demasiado larga).
    public static func automaticWait(for limit: RateLimit) -> TimeInterval? {
        guard limit.window != .day else { return nil }
        let wait = limit.retryAfter ?? 8                  // sin dato del proveedor: una espera prudente
        return wait <= maxAutomaticWait ? max(wait, 1) : nil
    }

    /// Interpreta la cabecera `retry-after` y el mensaje de error del proveedor
    /// («…on tokens per minute (TPM): Limit 8000, Used 7243, Requested 1984. Please try again in 5.4s.»).
    public static func parseRateLimit(retryAfterHeader: String?, body: String) -> RateLimit {
        let message = fullMessage(body) ?? body
        let lower = message.lowercased()

        var retry: TimeInterval?
        if let header = retryAfterHeader?.trimmingCharacters(in: .whitespaces), let seconds = Double(header), seconds >= 0 { retry = seconds }
        if retry == nil, let range = message.range(of: "try again in ", options: .caseInsensitive) {
            retry = parseDuration(String(message[range.upperBound...]))
        }

        var window: RateLimit.Window = .unknown
        if lower.contains("per day") || lower.contains("(tpd)") || lower.contains("(rpd)") {
            window = .day
        } else if lower.contains("per minute") || lower.contains("(tpm)") || lower.contains("(rpm)") {
            window = .minute
        } else if let retry = retry {
            window = retry > 600 ? .day : .minute
        }

        var detail: String?
        if let regex = try? NSRegularExpression(pattern: "Limit\\s+(\\d+),\\s*Used\\s+(\\d+),\\s*Requested\\s+(\\d+)") {
            let ns = message as NSString
            if let match = regex.firstMatch(in: message, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges == 4 {
                detail = "límite \(ns.substring(with: match.range(at: 1))), usados \(ns.substring(with: match.range(at: 2))), pedidos \(ns.substring(with: match.range(at: 3)))"
            }
        }
        return RateLimit(retryAfter: retry, window: window, detail: detail)
    }

    /// «5.4s», «1m5.2s», «2h3m», «450ms» → segundos. Lee solo el principio del texto (hasta que deja de haber cantidades).
    public static func parseDuration(_ text: String) -> TimeInterval? {
        guard let regex = try? NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)(ms|d|h|m|s)") else { return nil }
        let ns = text as NSString
        var total: TimeInterval = 0
        var found = false
        var position = 0
        while position < ns.length {
            let range = NSRange(location: position, length: ns.length - position)
            guard let match = regex.firstMatch(in: text, range: range), match.range.location == position else { break }
            guard let value = Double(ns.substring(with: match.range(at: 1))) else { break }
            switch ns.substring(with: match.range(at: 2)) {
            case "ms": total += value / 1_000
            case "s": total += value
            case "m": total += value * 60
            case "h": total += value * 3_600
            default: total += value * 86_400
            }
            found = true
            position = match.range.location + match.range.length
        }
        return found ? total : nil
    }

    /// «45 s», «2 min 5 s», «1 h 5 min».
    public static func humanDuration(_ seconds: TimeInterval) -> String {
        let total = max(1, Int(seconds.rounded(.up)))
        if total < 60 { return "\(total) s" }
        if total < 3_600 { return total % 60 == 0 ? "\(total / 60) min" : "\(total / 60) min \(total % 60) s" }
        let minutes = (total % 3_600) / 60
        return minutes == 0 ? "\(total / 3_600) h" : "\(total / 3_600) h \(minutes) min"
    }

    public static func rateLimitMessage(_ limit: RateLimit, provider: String) -> String {
        let figures = limit.detail.map { " (\($0))" } ?? ""
        switch limit.window {
        case .day:
            let renewal = limit.retryAfter.map { " Se renueva en ≈ \(humanDuration($0))." } ?? ""
            return "Se agotó el límite DIARIO del plan gratuito de \(provider)\(figures).\(renewal) Puedes esperar o cambiar al modelo local en Ajustes › Modelo local."
        case .minute:
            let wait = limit.retryAfter.map { " Espera ≈ \(humanDuration($0)) e inténtalo de nuevo." } ?? " Espera un minuto e inténtalo de nuevo."
            return "\(provider) alcanzó el límite por minuto del plan gratuito\(figures).\(wait)"
        case .unknown:
            return "Alcanzaste el límite del plan gratuito de \(provider)\(figures). Espera un minuto e inténtalo de nuevo."
        }
    }

    /// Mensaje completo del error del proveedor (sin recortar), para leer las cifras del límite.
    static func fullMessage(_ body: String) -> String? {
        guard let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let object: [String: Any]?
        if let dict = json as? [String: Any] { object = dict } else { object = (json as? [[String: Any]])?.first }
        if let message = (object?["error"] as? [String: Any])?["message"] as? String, !message.isEmpty { return String(message.prefix(1_000)) }
        return nil
    }

    /// Lo que el modelo intentó escribir cuando el proveedor rechazó una llamada a función (`error.failed_generation`).
    public static func failedGeneration(inBody body: String) -> String? {
        guard let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let object: [String: Any]?
        if let dict = json as? [String: Any] { object = dict } else { object = (json as? [[String: Any]])?.first }
        guard let text = (object?["error"] as? [String: Any])?["failed_generation"] as? String, !text.isEmpty else { return nil }
        return String(text.prefix(4_000))
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
