import Foundation
import ViernesCore

/// Borrador de correo mostrado al usuario (vista previa editable) antes de abrir Correo.
struct MailDraft: Identifiable, Equatable {
    let id = UUID()
    var content: MailDraftContent
}

/// Lo que pasó con el borrador. Se le cuenta al modelo TAL CUAL: nunca «enviado» si el usuario no pulsó Enviar.
enum MailDraftResult: Equatable {
    case composerSent
    case composerSaved
    case composerCancelled
    case composerFailed(String)
    /// Se abrió otra app de correo con `mailto:`; iOS no dice qué pasó después.
    case openedExternal
    case copied
    case discarded
}

/// Puente entre la herramienta `compose_email` y la hoja de vista previa. La herramienta ESPERA a que el usuario decida:
/// abrir en Correo, copiar o descartar. Si el turno se cancela con la hoja abierta, se descarta sola.
@MainActor
final class MailDraftCenter: ObservableObject {
    @Published private(set) var current: MailDraft?
    /// Último problema al abrir Correo (para enseñarlo en la hoja sin cerrarla: el borrador se conserva para copiarlo).
    @Published var problem: String?
    private var continuation: CheckedContinuation<MailDraftResult, Never>?
    private(set) var copied = false

    func present(_ content: MailDraftContent) async -> MailDraftResult {
        finish(.discarded)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<MailDraftResult, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .discarded)
                    return
                }
                self.continuation = continuation
                self.copied = false
                self.problem = nil
                self.current = MailDraft(content: content)
            }
        } onCancel: {
            Task { @MainActor in self.finish(.discarded) }
        }
    }

    func markCopied() { copied = true }

    /// Cierra la hoja. Si el usuario copió el borrador y luego la cierra, cuenta como «copiado», no como descartado.
    func close() { finish(copied ? .copied : .discarded) }

    func finish(_ result: MailDraftResult) {
        current = nil
        problem = nil
        let pending = continuation
        continuation = nil
        pending?.resume(returning: result)
    }
}
