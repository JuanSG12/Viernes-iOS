import Foundation

// Piezas PURAS de dos funciones nuevas: el enlace `mailto:` del borrador de correo y el protocolo de transcripción de Groq (Whisper).
// Nada de red ni de interfaz aquí: se comprueba con pruebas.

/// Borrador de correo tal como se muestra al usuario antes de abrir Correo.
public struct MailDraftContent: Equatable, Sendable {
    public var to: String
    public var subject: String
    public var body: String

    public init(to: String = "", subject: String = "", body: String) {
        self.to = to
        self.subject = subject
        self.body = body
    }

    /// Texto para copiar al portapapeles si no se pudo abrir Correo.
    public var plainText: String {
        var lines: [String] = []
        if !to.isEmpty { lines.append("Para: \(to)") }
        if !subject.isEmpty { lines.append("Asunto: \(subject)") }
        if !lines.isEmpty { lines.append("") }
        lines.append(body)
        return lines.joined(separator: "\n")
    }

    /// `nil` si la dirección, estando escrita, no es válida (un destinatario vacío es válido: el usuario lo añade en Correo).
    public var recipientProblem: String? {
        let cleaned = SpokenText.cleanEmailAddress(to)
        if cleaned.isEmpty { return nil }
        return ContactFormat.isValidEmail(cleaned) ? nil : "La dirección «\(to)» no parece un correo válido."
    }

    /// Enlace `mailto:` con TODO codificado: el texto del usuario no puede inyectar parámetros (`&cc=`, `?bcc=`…).
    public var mailtoURL: URL? {
        func encode(_ value: String, keep: String = "") -> String {
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~" + keep)
            return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }
        var query: [String] = []
        if !subject.isEmpty { query.append("subject=\(encode(subject))") }
        query.append("body=\(encode(body))")
        let recipient = encode(SpokenText.cleanEmailAddress(to), keep: "@+")
        return URL(string: "mailto:\(recipient)?\(query.joined(separator: "&"))")
    }
}

/// Transcripción con Whisper de Groq (`/audio/transcriptions`). El AUDIO sale del teléfono: solo con consentimiento expreso.
public enum GroqWhisper {
    public static let endpoint = "https://api.groq.com/openai/v1/audio/transcriptions"
    public static let model = "whisper-large-v3-turbo"
    /// El plan gratuito acepta archivos de hasta 25 MB; se deja margen.
    public static let maxAudioBytes = 24 * 1_024 * 1_024

    public static func contentType(boundary: String) -> String { "multipart/form-data; boundary=\(boundary)" }

    /// Frase corta con nombres y términos para sesgar a Whisper (parámetro `prompt`). Máximo ≈ 400 caracteres.
    public static func prompt(from terms: [String]) -> String? {
        var text = ""
        for term in terms {
            let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            let next = text.isEmpty ? clean : text + ", " + clean
            if next.count > 400 { break }
            text = next
        }
        return text.isEmpty ? nil : text + "."
    }

    public static func multipartBody(boundary: String, audio: Data, fileName: String = "dictado.wav", language: String = "es",
                                     prompt: String?, model: String = GroqWhisper.model) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("language", language)
        field("response_format", "json")
        field("temperature", "0")
        if let prompt = prompt, !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// Texto de la respuesta `{"text": "..."}`, sin espacios sobrantes; `nil` si no hay texto.
    public static func parseTranscript(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// Mensaje en español para un error HTTP. Nunca incluye la clave.
    public static func errorMessage(status: Int, body: String, retryAfterHeader: String? = nil) -> String {
        switch status {
        case 401, 403:
            return "Groq rechazó la clave para transcribir (error \(status)). Revísala en Ajustes › Cerebro en la nube."
        case 413:
            return "El audio es demasiado largo para transcribirlo en la nube."
        case 429:
            return OpenAIChatProtocol.rateLimitMessage(OpenAIChatProtocol.parseRateLimit(retryAfterHeader: retryAfterHeader, body: body), provider: "Groq (transcripción)")
        case 500...599:
            return "Groq tiene problemas ahora mismo (error \(status))."
        default:
            return "Groq respondió con error \(status) al transcribir."
        }
    }
}
