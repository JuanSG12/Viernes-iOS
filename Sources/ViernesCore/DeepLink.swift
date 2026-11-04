import Foundation

/// Enlaces profundos propios: `viernes://listen`, `viernes://ask?q=…`, `viernes://claude-result?nonce=…&result=…`.
/// Cualquier app o web puede abrir un enlace `viernes://`, así que NADA se ejecuta automáticamente:
/// `ask` solo precarga el texto; `claude-result` exige un nonce de una petición pendiente.
public enum DeepLink: Equatable, Sendable {
    case home
    case listen
    case ask(String)
    case claudeResult(nonce: String, text: String?)
    case claudeCancelled(nonce: String)
    case unknown

    public static func parse(_ url: URL) -> DeepLink {
        guard url.scheme?.lowercased() == "viernes",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return .unknown }
        let host = (components.host ?? "").lowercased()
        func query(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value
        }
        switch host {
        case "", "home": return .home
        case "listen": return .listen
        case "ask":
            guard let text = query("q")?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return .unknown }
            return .ask(String(text.prefix(1_000)))
        case "claude-result":
            guard let nonce = query("nonce"), !nonce.isEmpty else { return .unknown }
            return .claudeResult(nonce: nonce, text: query("result").map { String($0.prefix(8_000)) })
        case "claude-cancel":
            guard let nonce = query("nonce"), !nonce.isEmpty else { return .unknown }
            return .claudeCancelled(nonce: nonce)
        default: return .unknown
        }
    }
}
