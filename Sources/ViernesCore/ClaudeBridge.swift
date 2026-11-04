import Foundation

/// Modos de relación con Claude. NINGUNO usa la API de Anthropic ni credenciales de la suscripción.
/// Ver CLAUDE_INTEGRATION.md para el análisis completo y lo que NO es posible.
public enum ClaudeMode: String, Codable, CaseIterable, Sendable {
    /// Viernes no se relaciona con Claude.
    case disabled
    /// Viernes abre la app de Claude (con la pregunta en un enlace universal). La respuesta vive en Claude, no en Viernes.
    case openApp
    /// Viernes ejecuta un Atajo creado por el usuario que usa la acción oficial "Ask Claude" de la app de Claude.
    /// Si el Atajo devuelve texto, vuelve a Viernes por x-callback-url. Requiere configuración manual y prueba en iPhone.
    case shortcut

    public var displayName: String {
        switch self {
        case .disabled: return "Desactivado"
        case .openApp: return "Abrir la app de Claude"
        case .shortcut: return "Atajo «Ask Claude»"
        }
    }

    /// Descripción HONESTA de lo que hace y de lo que no.
    public var honestDescription: String {
        switch self {
        case .disabled:
            return "Todo se resuelve con el modelo local. Claude no interviene."
        case .openApp:
            return "Viernes abre Claude con tu pregunta. Esto NO integra Claude en Viernes: la respuesta aparece en la app de Claude y Viernes no la recibe ni la lee."
        case .shortcut:
            return "Viernes ejecuta un Atajo tuyo que usa la acción oficial «Ask Claude». Usa tu suscripción desde la app de Claude y cuenta para sus límites. Si el Atajo devuelve la respuesta como texto, Viernes la mostrará; si no, solo verás la respuesta en Claude."
        }
    }
}

public struct ClaudeBridgeConfig: Codable, Equatable, Sendable {
    public var mode: ClaudeMode
    public var shortcutName: String
    public init(mode: ClaudeMode = .disabled, shortcutName: String = "Preguntar a Claude") {
        self.mode = mode
        self.shortcutName = shortcutName
    }
}

public enum ClaudeLinkBuilder {
    public static let callbackScheme = "viernes"

    /// Abre la app de Claude (esquema documentado por Anthropic para iOS/Android).
    public static func openAppURL() -> URL { URL(string: "claude://")! }

    /// Enlace universal para iniciar un chat con texto precargado. El prefill `?q=` está confirmado en claude.ai web;
    /// que la app lo intercepte como enlace universal NO está documentado: se verifica en iPhone (ver CLAUDE_INTEGRATION.md).
    public static func newChatURL(prompt: String) -> URL? {
        URL(string: "https://claude.ai/new?q=\(encode(prompt))")
    }

    /// URL x-callback-url de la app Atajos. `nonce` ata la respuesta a UNA petición pendiente.
    /// Los valores se codifican a mano (solo alfanuméricos y -._~) para que `&`, `=`, `?` o `#` del texto
    /// del usuario no rompan la consulta ni permitan inyectar parámetros.
    public static func shortcutURL(name: String, input: String, nonce: String) -> URL? {
        let success = "\(callbackScheme)://claude-result?nonce=\(encode(nonce))"
        let cancel = "\(callbackScheme)://claude-cancel?nonce=\(encode(nonce))"
        let query = [
            "name=\(encode(name))",
            "input=text",
            "text=\(encode(input))",
            "x-success=\(encode(success))",
            "x-cancel=\(encode(cancel))",
            "x-error=\(encode(cancel))"
        ].joined(separator: "&")
        return URL(string: "shortcuts://x-callback-url/run-shortcut?\(query)")
    }

    static func encode(_ value: String) -> String {
        // Solo ASCII: `.alphanumerics` incluye letras Unicode (é, ó) que algunas versiones de Foundation no aceptan en URL.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

/// Una petición a Claude en vuelo; evita que una URL externa inyecte "respuestas de Claude" no solicitadas.
public struct PendingClaudeRequest: Equatable, Sendable {
    public let nonce: String
    public let prompt: String
    public let createdAt: Date
    public init(nonce: String = UUID().uuidString, prompt: String, createdAt: Date = Date()) {
        self.nonce = nonce
        self.prompt = prompt
        self.createdAt = createdAt
    }

    public func isValid(for nonce: String, now: Date = Date(), timeout: TimeInterval = 600) -> Bool {
        nonce == self.nonce && now.timeIntervalSince(createdAt) <= timeout
    }
}
