import Foundation
import ViernesCore

/// Marcador honesto cuando no hay ningún motor utilizable: nunca inventa respuestas, solo explica por qué no puede responder.
final class UnavailableEngine: LanguageModelEngine, @unchecked Sendable {
    let descriptor: ModelDescriptor
    let reason: String

    init(descriptor: ModelDescriptor, reason: String) {
        self.descriptor = descriptor
        self.reason = reason
    }

    func availability() async -> EngineAvailability { .unavailable(reason: reason) }
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws { throw EngineError.notReady(reason) }
    func unload() async {}
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: EngineError.notReady(reason)) }
    }
}
