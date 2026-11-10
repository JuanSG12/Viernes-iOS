import Foundation

/// Protocolo del WebSocket de **Text-to-Speech** de ElevenLabs (`/v1/text-to-speech/{voice_id}/stream-input`).
///
/// ⚠️ NO es el WebSocket de **Text-to-Dialogue** (`/v1/text-to-dialogue/stream-input`): ese es otro protocolo (mensajes con `inputs`,
/// `voices` registradas en el primer mensaje, `close_socket`, `keep_alive`) y solo acepta modelos `eleven_v3*` y `eleven_v4*`
/// (como `eleven_v4_turbo`). El WebSocket de Text-to-Speech NO acepta esos modelos: según la documentación de ElevenLabs, para un
/// asistente de una sola voz se usa este con un modelo Flash o Multilingual. Los dos protocolos nunca se mezclan aquí.
/// Solo mensajes, URL y errores; la red vive en la app. Puro y comprobable.
public enum ElevenLabsRealtime {
    public static let websocketHost = "wss://api.elevenlabs.io"
    /// PCM de 16 bits little-endian a 24 kHz: sin decodificación de MP3 en el teléfono. No exige plan de pago (el de 44,1 kHz sí).
    public static let outputFormat = "pcm_24000"
    public static let sampleRate = 24_000.0
    /// Modelo de respaldo para este protocolo (el predeterminado de Viernes: baja latencia y español).
    public static let fallbackModelID = ElevenLabsSettings.defaultModelID
    /// Si pasan tantos segundos sin enviar texto, el servidor cierra la conexión (máximo permitido por la API: 180).
    public static let inactivityTimeoutSeconds = 60

    /// Cómo se reparte el texto antes de generar audio.
    public enum Tuning: String, Sendable {
        /// `auto_mode`: sin esperas ni colchones del servidor; pensado para enviar frases completas (lo que hace Viernes).
        case fast
        /// `chunk_length_schedule` más corto que el predeterminado: algo más de entonación a costa de esperar más texto.
        case balanced
    }

    /// ¿El modelo funciona en el WebSocket de Text-to-Speech? Los `eleven_v3*` y `eleven_v4*` son de Text-to-Dialogue.
    public static func isRealtimeCompatible(modelID: String) -> Bool {
        let id = modelID.lowercased()
        if id.hasPrefix("eleven_v3") || id.hasPrefix("eleven_v4") || id.hasPrefix("eleven_ttv") { return false }
        return id.hasPrefix("eleven_flash") || id.hasPrefix("eleven_turbo") || id.hasPrefix("eleven_multilingual")
    }

    /// El modelo a usar en este protocolo: el elegido si es compatible; si no, el de respaldo.
    public static func compatibleModelID(_ modelID: String) -> String {
        isRealtimeCompatible(modelID: modelID) ? modelID : fallbackModelID
    }

    /// `language_code` solo lo admiten los modelos v2.5 (no `multilingual_v2`, que lo ignora).
    public static func supportsLanguageCode(modelID: String) -> Bool {
        let id = modelID.lowercased()
        return id.hasPrefix("eleven_flash_v2_5") || id.hasPrefix("eleven_turbo_v2_5")
    }

    public static func websocketURL(voiceID: String, modelID: String, tuning: Tuning = .fast, languageCode: String = "es") -> URL? {
        guard ElevenLabsProtocol.isValidVoiceID(voiceID) else { return nil }
        let model = compatibleModelID(modelID)
        var query = ["model_id=\(model)", "output_format=\(outputFormat)", "inactivity_timeout=\(inactivityTimeoutSeconds)", "sync_alignment=true"]
        if supportsLanguageCode(modelID: model) { query.append("language_code=\(languageCode)") }
        if tuning == .fast { query.append("auto_mode=true") }
        return URL(string: "\(websocketHost)/v1/text-to-speech/\(voiceID)/stream-input?\(query.joined(separator: "&"))")
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Primer mensaje: un único espacio como texto, más los ajustes de voz. La clave va en la cabecera `xi-api-key`, no aquí.
    public static func initialMessage(speed: Double, tuning: Tuning = .fast) -> String {
        var object: [String: Any] = [
            "text": " ",
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.75, "speed": min(max(speed, 0.7), 1.2)]
        ]
        if tuning == .balanced { object["generation_config"] = ["chunk_length_schedule": [80, 120, 200, 260]] }
        return json(object)
    }

    /// Texto a sintetizar. La API pide que termine en un único espacio.
    public static func textMessage(_ text: String) -> String {
        json(["text": text.trimmingCharacters(in: .whitespacesAndNewlines) + " "])
    }

    /// Fuerza la generación de lo acumulado sin cerrar la conexión.
    public static let flushMessage = #"{"flush":true,"text":" "}"#
    /// Cierra el flujo: el servidor genera lo que quede, envía `isFinal` y cierra.
    public static let closeMessage = #"{"text":""}"#

    public enum ServerEvent: Equatable, Sendable {
        /// Audio PCM y número de caracteres del texto de entrada que cubre (de la alineación; 0 si no vino).
        case audio(Data, spokenCharacters: Int)
        case final
        case error(message: String, fatal: Bool)
        case ignore
    }

    public static func parse(_ text: String) -> ServerEvent {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .ignore }
        if let encoded = object["audio"] as? String, !encoded.isEmpty, let bytes = Data(base64Encoded: encoded) {
            var characters = 0
            if let alignment = object["alignment"] as? [String: Any], let chars = alignment["chars"] as? [Any] { characters = chars.count }
            return .audio(bytes, spokenCharacters: characters)
        }
        if (object["isFinal"] as? Bool) == true { return .final }
        var reason: String?
        for key in ["message", "error", "detail"] {
            if let value = object[key] as? String, !value.isEmpty { reason = value; break }
            if let nested = object[key] as? [String: Any], let value = (nested["message"] as? String) ?? (nested["status"] as? String), !value.isEmpty { reason = value; break }
        }
        if let reason = reason { return classify(reason) }
        return .ignore
    }

    /// Convierte el texto de un error del servidor en un mensaje en español. «Fatal» = configuración (clave, plan, voz, cuota):
    /// no tiene sentido reintentar.
    public static func classify(_ reason: String) -> ServerEvent {
        let lower = reason.lowercased()
        if lower.contains("quota") {
            return .error(message: "Se acabó la cuota de caracteres de tu plan de ElevenLabs. Uso la voz de Apple hasta que se renueve.", fatal: true)
        }
        if lower.contains("invalid_api_key") || lower.contains("unauthorized") || lower.contains("api key") {
            return .error(message: "ElevenLabs rechazó la clave. Revísala en Voz y habla › Voz neuronal.", fatal: true)
        }
        if lower.contains("payment") || lower.contains("paid_plan") || lower.contains("subscription") || lower.contains("plan") {
            return .error(message: "Tu plan de ElevenLabs no permite usar esa voz o ese modelo por API. Elige otra voz de la lista (las predefinidas).", fatal: true)
        }
        if lower.contains("voice") && (lower.contains("not found") || lower.contains("not_found") || lower.contains("invalid")) {
            return .error(message: "ElevenLabs no encontró esa voz. Vuelve a cargar la lista y elige otra.", fatal: true)
        }
        if lower.contains("unusual") {
            return .error(message: "ElevenLabs bloqueó el plan gratuito por «actividad inusual» (suele pasar con VPN o proxy). Uso la voz de Apple.", fatal: true)
        }
        return .error(message: "ElevenLabs devolvió un error: \(String(reason.prefix(160))).", fatal: false)
    }

    /// Fallo al abrir la conexión: el servidor respondió con un código HTTP en lugar de aceptar el WebSocket.
    public static func handshakeFailure(status: Int) -> (message: String, fatal: Bool) {
        (ElevenLabsProtocol.errorMessage(status: status, body: ""), [401, 402, 403, 404, 422].contains(status))
    }
}
