import Foundation
import ViernesCore

/// Puente entre el motor de conversación y la hoja de confirmación de la UI.
/// Una acción sensible NO se ejecuta hasta que el usuario toca «Confirmar». Si no responde, caduca como rechazada.
/// Si el turno se cancela mientras la hoja está abierta, la confirmación se rechaza sola (no puede ejecutarse después).
@MainActor
final class ConfirmationCenter: ObservableObject, ConfirmationProvider {
    @Published private(set) var current: ConfirmationRequest?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?

    func confirm(_ request: ConfirmationRequest) async -> Bool {
        // Solo una confirmación a la vez; una nueva rechaza la anterior (no debería ocurrir: el motor es secuencial).
        resolve(false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                self.continuation = continuation
                self.current = request
                self.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 90_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.resolve(false)
                }
            }
        } onCancel: {
            Task { @MainActor in self.resolve(false) }
        }
    }

    func resolve(_ approved: Bool) {
        timeoutTask?.cancel()
        timeoutTask = nil
        current = nil
        let pending = continuation
        continuation = nil
        pending?.resume(returning: approved)
    }
}
