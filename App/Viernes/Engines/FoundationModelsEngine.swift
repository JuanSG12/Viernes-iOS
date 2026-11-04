import Foundation
import ViernesCore

#if canImport(FoundationModels)
import FoundationModels

/// Cerebro local #1: el modelo del sistema (Apple Intelligence). Sin descarga, sin red.
/// Requiere iOS 26+, un iPhone compatible con Apple Intelligence y que el usuario lo tenga activado.
@available(iOS 26.0, *)
final class FoundationModelsEngine: LanguageModelEngine, @unchecked Sendable {
    let descriptor: ModelDescriptor

    init() {
        descriptor = ModelCatalog.descriptor(id: ModelCatalog.appleFoundationID)!
    }

    static func currentAvailability() -> EngineAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(reason: "Este iPhone no es compatible con Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return .unavailable(reason: "Apple Intelligence está desactivado. Actívalo en Ajustes › Apple Intelligence y Siri.")
            case .modelNotReady:
                return .unavailable(reason: "El modelo del sistema aún se está descargando. Inténtalo más tarde.")
            @unknown default:
                return .unavailable(reason: "El modelo del sistema no está disponible.")
            }
        }
    }

    func availability() async -> EngineAvailability { Self.currentAvailability() }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        if case .unavailable(let reason) = Self.currentAvailability() { throw EngineError.notReady(reason) }
        progress(1)
    }

    func unload() async {}

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if case .unavailable(let reason) = Self.currentAvailability() { throw EngineError.notReady(reason) }
                    let session = LanguageModelSession(instructions: request.system)
                    let options = GenerationOptions(temperature: request.temperature, maximumResponseTokens: request.maxTokens)
                    var emitted = ""
                    for try await snapshot in session.streamResponse(to: Self.flatten(request.turns), options: options) {
                        let full = snapshot.content
                        // El framework entrega el texto ACUMULADO; el contrato del motor es emitir deltas.
                        if full.hasPrefix(emitted) {
                            let delta = String(full.dropFirst(emitted.count))
                            if !delta.isEmpty { continuation.yield(delta) }
                        }
                        emitted = full
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: EngineError.cancelled)
                } catch let error as EngineError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: EngineError.generationFailed(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// El historial se aplana a texto: cada petición es independiente (sin estado oculto en el modelo).
    static func flatten(_ turns: [ChatTurn]) -> String {
        guard let last = turns.last else { return "" }
        let previous = turns.dropLast()
        if previous.isEmpty { return last.content }
        let history = previous.map { ($0.role == .user ? "Usuario: " : "Viernes: ") + $0.content }.joined(separator: "\n")
        return "Conversación hasta ahora:\n\(history)\n\nMensaje actual del usuario:\n\(last.content)"
    }
}
#endif
