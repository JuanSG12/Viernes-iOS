import UIKit
import ViernesCore

/// Gestiona la relación con Claude por las únicas vías oficiales disponibles (ver CLAUDE_INTEGRATION.md):
/// abrir la app de Claude, o ejecutar un Atajo del usuario que use «Ask Claude». NO usa la API de Anthropic.
@MainActor
final class ClaudeCoordinator {
    private(set) var pending: PendingClaudeRequest?
    var config = ClaudeBridgeConfig()
    /// Se llama cuando un Atajo devuelve texto de Claude a Viernes.
    var onResult: ((String, String) -> Void)?       // (pregunta original, respuesta)
    var onCancelled: (() -> Void)?

    func ask(_ prompt: String) async -> ToolOutcome {
        switch config.mode {
        case .disabled:
            return .failure("El modo Claude está desactivado en Ajustes.")
        case .openApp:
            let target = ClaudeLinkBuilder.newChatURL(prompt: prompt) ?? ClaudeLinkBuilder.openAppURL()
            guard await UIApplication.shared.open(target) else {
                return .failure("No pude abrir Claude. ¿Está instalada la app?")
            }
            return .success("Abrí Claude con la pregunta. La respuesta aparecerá en Claude; Viernes no la recibe. (Si no ves la pregunta precargada, cópiala: el prefill por enlace no está garantizado en la app.)")
        case .shortcut:
            let request = PendingClaudeRequest(prompt: prompt)
            guard let url = ClaudeLinkBuilder.shortcutURL(name: config.shortcutName, input: prompt, nonce: request.nonce) else {
                return .failure("No pude construir el enlace del Atajo.")
            }
            pending = request
            guard await UIApplication.shared.open(url) else {
                pending = nil
                return .failure("No pude abrir Atajos. Revisa que exista el atajo «\(config.shortcutName)».")
            }
            return .success("Pedí al Atajo «\(config.shortcutName)» que consulte a Claude. Si el atajo devuelve texto, lo mostraré aquí; si no, verás la respuesta en Claude.")
        }
    }

    /// Procesa x-success / x-cancel / x-error. Se ignora todo lo que no corresponda a una petición pendiente y vigente.
    func handle(_ link: DeepLink) {
        switch link {
        case .claudeResult(let nonce, let text):
            guard let request = pending, request.isValid(for: nonce) else { return }
            pending = nil
            if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                onResult?(request.prompt, text)
            } else {
                onCancelled?()
            }
        case .claudeCancelled(let nonce):
            guard let request = pending, request.isValid(for: nonce) else { return }
            pending = nil
            onCancelled?()
        default:
            break
        }
    }
}
