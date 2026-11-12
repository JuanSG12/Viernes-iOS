import Foundation
import ViernesCore

/// Prueba el proveedor elegido por el enrutador y, SOLO si falla por algo que otro proveedor sí puede resolver (cuota, saldo,
/// servicio caído), pasa al siguiente de la lista que el usuario ya autorizó. Reglas de privacidad:
/// - únicamente proveedores que el usuario autorizó (el enrutador no los incluye si no);
/// - nunca reenvía una petición con fragmentos de la biblioteca, archivos o imágenes (`request.sensitive`);
/// - nunca cambia después de haber empezado a responder, ni por errores de configuración (clave, modelo, petición);
/// - cada cambio se avisa en pantalla y la respuesta queda marcada con el proveedor que de verdad respondió.
final class FailoverEngine: LanguageModelEngine, EngineStatusReporting, @unchecked Sendable {
    struct Candidate {
        let engine: LanguageModelEngine
        let label: String
    }

    private let candidates: [Candidate]
    private let lock = NSLock()
    private var current: ModelDescriptor
    /// Avisos para la pantalla (esperas y cambios de proveedor); se pasan también a los motores internos.
    var onStatus: (@Sendable (String?) -> Void)? {
        didSet {
            for candidate in candidates { (candidate.engine as? EngineStatusReporting)?.onStatus = onStatus }
        }
    }

    init(candidates: [Candidate]) {
        precondition(!candidates.isEmpty, "FailoverEngine necesita al menos un motor")
        self.candidates = candidates
        self.current = candidates[0].engine.descriptor
    }

    /// El descriptor del motor que está respondiendo (cambia si hubo un cambio de proveedor).
    var descriptor: ModelDescriptor {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    private func setCurrent(_ descriptor: ModelDescriptor) {
        lock.lock()
        current = descriptor
        lock.unlock()
    }

    func availability() async -> EngineAvailability { await candidates[0].engine.availability() }
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws { try await candidates[0].engine.prepare(progress: progress) }
    func unload() async {}

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var lastError: Error = EngineError.generationFailed("No hay ningún proveedor disponible.")
                for (index, candidate) in self.candidates.enumerated() {
                    var yielded = false
                    self.setCurrent(candidate.engine.descriptor)
                    do {
                        for try await piece in candidate.engine.generate(request) {
                            yielded = true
                            continuation.yield(piece)
                        }
                        self.onStatus?(nil)
                        continuation.finish()
                        return
                    } catch let error as ProviderFailureError {
                        lastError = error
                        let isLast: Bool = index == self.candidates.count - 1
                        if yielded || request.sensitive || !error.failure.allowsFailover || isLast { break }
                        let next: String = self.candidates[index + 1].label
                        Diagnostics.shared.log("cambio de proveedor: \(candidate.label) falló (\(error.failure.kind.rawValue)); se prueba \(next), autorizado por el usuario")
                        self.onStatus?("\(candidate.label): \(error.failure.kind.title). Probando \(next), que autorizaste…")
                        continue
                    } catch {
                        lastError = error
                        break
                    }
                }
                self.onStatus?(nil)
                continuation.finish(throwing: lastError)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
