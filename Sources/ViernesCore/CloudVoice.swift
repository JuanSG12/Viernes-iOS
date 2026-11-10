import Foundation

/// Ajustes de la voz neuronal en la nube (ElevenLabs). Opcional y apagada por defecto: cada frase que Viernes dice
/// SALE del teléfono hacia ElevenLabs para convertirla en audio.
public struct ElevenLabsSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var voiceID: String
    public var voiceName: String
    public var modelID: String
    /// Voz en tiempo real por WebSocket (audio por streaming mientras el modelo escribe). Opcional para no invalidar ajustes
    /// guardados antes; `nil` = activada. Si da problemas, se apaga y se vuelve al envío por frases.
    public var realtime: Bool?

    public static let defaultModelID = "eleven_flash_v2_5"
    public static let `default` = ElevenLabsSettings(enabled: false, voiceID: "", voiceName: "", modelID: defaultModelID)

    public init(enabled: Bool, voiceID: String, voiceName: String, modelID: String, realtime: Bool? = nil) {
        self.enabled = enabled
        self.voiceID = voiceID
        self.voiceName = voiceName
        self.modelID = modelID
        self.realtime = realtime
    }

    public var realtimeEnabled: Bool { realtime ?? true }

    /// Hay una voz elegida con identificador válido.
    public var hasVoice: Bool { ElevenLabsProtocol.isValidVoiceID(voiceID) }
    /// Activada y utilizable (la clave se comprueba aparte, en el Llavero).
    public var isUsable: Bool { enabled && hasVoice }

    public func sanitized() -> ElevenLabsSettings {
        var copy = self
        if !ElevenLabsProtocol.isValidVoiceID(voiceID) { copy.voiceID = ""; copy.enabled = false }
        copy.voiceName = String(voiceName.prefix(60))
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = (1...60).contains(model.count)
            && model.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_").contains($0) }
        copy.modelID = valid ? model : Self.defaultModelID
        return copy
    }
}

public struct CloudVoiceInfo: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    /// Etiquetas legibles (acento, género, edad…) para ayudar a elegir.
    public let detail: String
    public let category: String

    public init(id: String, name: String, detail: String, category: String) {
        self.id = id
        self.name = name
        self.detail = detail
        self.category = category
    }
}

/// Formato de la API de ElevenLabs. Solo URLs, cuerpo y errores; la red vive en la app.
public enum ElevenLabsProtocol {
    public static let host = "https://api.elevenlabs.io"
    public static let keyPageURL = "https://elevenlabs.io/app/settings/api-keys"
    public static let keyProviderID = "elevenlabs"

    /// Los identificadores son alfanuméricos. Se valida porque el valor va dentro de la ruta de la URL.
    public static func isValidVoiceID(_ id: String) -> Bool {
        (10...40).contains(id.count) && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
    }

    public static func speechURL(voiceID: String) -> URL? {
        guard isValidVoiceID(voiceID) else { return nil }
        return URL(string: "\(host)/v1/text-to-speech/\(voiceID)?output_format=mp3_44100_128")
    }

    public static var voicesURL: URL? { URL(string: "\(host)/v1/voices") }

    /// `speed` de la API admite 0.7–1.2. Los ajustes de Viernes usan la escala de AVSpeech (0.5 = normal).
    public static func speed(forRate rate: Float) -> Double {
        min(max(Double(rate) / 0.5, 0.7), 1.2)
    }

    public static func requestBody(text: String, modelID: String, speed: Double) throws -> Data {
        let body: [String: Any] = [
            "text": text,
            "model_id": modelID,
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.75, "speed": speed]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    public static func parseVoices(_ data: Data) -> [CloudVoiceInfo] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["voices"] as? [[String: Any]] else { return [] }
        return list.compactMap { entry -> CloudVoiceInfo? in
            guard let id = entry["voice_id"] as? String, isValidVoiceID(id), let name = entry["name"] as? String else { return nil }
            var parts: [String] = []
            if let labels = entry["labels"] as? [String: Any] {
                for key in ["language", "accent", "gender", "age", "descriptive", "use_case"] {
                    if let value = labels[key] as? String, !value.isEmpty { parts.append(value) }
                }
            }
            return CloudVoiceInfo(id: id, name: name, detail: parts.joined(separator: " · "), category: (entry["category"] as? String) ?? "")
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Mensaje en español. ElevenLabs devuelve el motivo real en `detail.status`, que importa más que el código HTTP
    /// (p. ej. cuota agotada llega como 401). Nunca incluye la clave.
    public static func errorMessage(status: Int, body: String) -> String {
        let parsed = parseDetail(body)
        switch parsed.status {
        case "quota_exceeded":
            return "Se acabó la cuota de caracteres de tu plan de ElevenLabs. Uso la voz de Apple hasta que se renueve."
        case "payment_required", "paid_plan_required", "voice_not_fine_tuned", "can_not_use_instant_voice_cloning":
            return "Tu plan gratuito de ElevenLabs no permite usar esa voz por API. Elige otra de la lista (las predefinidas)."
        case "detected_unusual_activity":
            return "ElevenLabs bloqueó el plan gratuito por «actividad inusual» (suele pasar con VPN o proxy). Uso la voz de Apple."
        case "invalid_api_key":
            return "ElevenLabs rechazó la clave. Revísala en Voz y habla › Voz neuronal."
        default: break
        }
        switch status {
        case 401, 403:
            return "ElevenLabs rechazó la petición (error \(status))" + (parsed.message.map { ": \($0)" } ?? ". Revisa la clave.")
        case 404:
            return "ElevenLabs no encontró esa voz. Vuelve a cargar la lista y elige otra."
        case 429:
            return "ElevenLabs recibió demasiadas peticiones a la vez. Uso la voz de Apple un momento."
        case 500...599:
            return "ElevenLabs tiene problemas ahora mismo (error \(status))."
        default:
            return "ElevenLabs respondió con error \(status)" + (parsed.message.map { ": \($0)" } ?? ".")
        }
    }

    static func parseDetail(_ body: String) -> (status: String?, message: String?) {
        guard let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let detail = json["detail"]
        if let object = detail as? [String: Any] {
            let message = (object["message"] as? String).map { String($0.prefix(200)) }
            return (object["status"] as? String, message)
        }
        if let text = detail as? String { return (nil, String(text.prefix(200))) }
        return (nil, nil)
    }
}
