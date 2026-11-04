import Foundation
@testable import ViernesCore

/// Doble de pruebas: reproduce una salida de modelo fija. SOLO se usa en tests (la app nunca simula respuestas).
final class ScriptedEngine: LanguageModelEngine, @unchecked Sendable {
    let descriptor: ModelDescriptor
    private var script: [[String]]
    private var recorded: [GenerationRequest] = []
    private let lock = NSLock()
    var failure: Error?

    init(script: [[String]], descriptor: ModelDescriptor = ModelCatalog.descriptor(id: "gemma3-1b-qat-4bit")!) {
        self.script = script
        self.descriptor = descriptor
    }

    var requests: [GenerationRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func availability() async -> EngineAvailability { .ready }
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func unload() async {}

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        recorded.append(request)
        let chunks = script.isEmpty ? [] : script.removeFirst()
        let error = failure
        lock.unlock()
        return AsyncThrowingStream { continuation in
            if let error = error {
                continuation.finish(throwing: error)
                return
            }
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

final class RecordingExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ToolCall] = []
    var outcome: ToolOutcome = .success("Hecho.")
    var calls: [ToolCall] { lock.lock(); defer { lock.unlock() }; return recorded }
    func execute(_ call: ToolCall) async -> ToolOutcome {
        lock.withLock { recorded.append(call) }
        return outcome
    }
}

final class RecordingConfirmer: ConfirmationProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ConfirmationRequest] = []
    var approve: Bool
    init(approve: Bool) { self.approve = approve }
    var requests: [ConfirmationRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    func confirm(_ request: ConfirmationRequest) async -> Bool {
        lock.withLock { recorded.append(request) }
        return approve
    }
}

func collect(_ stream: AsyncStream<ConversationEvent>) async -> [ConversationEvent] {
    var events: [ConversationEvent] = []
    for await event in stream { events.append(event) }
    return events
}

extension Array where Element == ConversationEvent {
    var completedMessage: ChatMessage? {
        for event in self { if case .completed(let message) = event { return message } }
        return nil
    }
    var failureText: String? {
        for event in self { if case .failed(let text) = event { return text } }
        return nil
    }
    var actionRecords: [ActionRecord] {
        compactMap { if case .action(let record) = $0 { return record } else { return nil } }
    }
}
