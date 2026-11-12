import XCTest
import ViernesCore
@testable import Viernes

/// Pruebas de unidad (app, simulador): cambio de proveedor y pausa por fallos, con motores de prueba y SIN red ni claves reales.
private final class StubEngine: LanguageModelEngine, @unchecked Sendable {
    let descriptor: ModelDescriptor
    private let pieces: [String]
    private let error: Error?
    private let lock = NSLock()
    private var calls = 0

    init(name: String, pieces: [String] = [], error: Error? = nil) {
        descriptor = ModelDescriptor(id: "test.\(name)", displayName: name, backend: .cloud, approxDownloadMB: 0, minDeviceRAMGB: 0,
                                     license: "prueba", spanishQuality: 5, notes: "")
        self.pieces = pieces
        self.error = error
    }

    var callCount: Int { lock.withLock { calls } }

    func availability() async -> EngineAvailability { .ready }
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func unload() async {}

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<String, Error> {
        lock.withLock { calls += 1 }
        let pieces = self.pieces
        let error = self.error
        return AsyncThrowingStream { continuation in
            for piece in pieces { continuation.yield(piece) }
            continuation.finish(throwing: error)
        }
    }
}

private final class NoteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ note: String?) { if let note = note { lock.withLock { stored.append(note) } } }
    var notes: [String] { lock.withLock { stored } }
}

final class FailoverEngineTests: XCTestCase {
    private func failure(_ kind: ProviderFailureKind) -> ProviderFailureError {
        ProviderFailureError(failure: ProviderFailure(kind: kind, status: 429), message: "motivo \(kind.rawValue)")
    }

    private func run(_ engine: LanguageModelEngine, sensitive: Bool = false) async -> (text: String, error: Error?) {
        var request = GenerationRequest(system: "s", turns: [ChatTurn(role: .user, content: "hola")])
        request.sensitive = sensitive
        var text = ""
        do {
            for try await piece in engine.generate(request) { text += piece }
            return (text, nil)
        } catch {
            return (text, error)
        }
    }

    func testFailsOverToTheNextAuthorizedProviderWhenQuotaRunsOutAndSaysSo() async {
        let first = StubEngine(name: "A", error: failure(.dailyQuota))
        let second = StubEngine(name: "B", pieces: ["hola ", "desde B"])
        let engine = FailoverEngine(candidates: [.init(engine: first, label: "A"), .init(engine: second, label: "B")])
        let log = NoteLog()
        engine.onStatus = { log.add($0) }
        let result = await run(engine)
        XCTAssertEqual(result.text, "hola desde B")
        XCTAssertNil(result.error)
        XCTAssertEqual(engine.descriptor.displayName, "B", "La respuesta queda marcada con el proveedor que de verdad respondió")
        XCTAssertTrue(log.notes.contains { $0.contains("Probando B") }, "El cambio se avisa en pantalla")
    }

    func testNeverForwardsSensitiveRequestsToAnotherProvider() async {
        let first = StubEngine(name: "A", error: failure(.dailyQuota))
        let second = StubEngine(name: "B", pieces: ["no debería usarse"])
        let engine = FailoverEngine(candidates: [.init(engine: first, label: "A"), .init(engine: second, label: "B")])
        let result = await run(engine, sensitive: true)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(second.callCount, 0, "Archivos, imágenes y fragmentos de la biblioteca no se reenvían")
    }

    func testConfigurationErrorsAreShownNotWorkedAround() async {
        for kind in [ProviderFailureKind.invalidKey, .modelNotFound, .badRequest] {
            let first = StubEngine(name: "A", error: failure(kind))
            let second = StubEngine(name: "B", pieces: ["x"])
            let engine = FailoverEngine(candidates: [.init(engine: first, label: "A"), .init(engine: second, label: "B")])
            let result = await run(engine)
            XCTAssertNotNil(result.error, "\(kind)")
            XCTAssertEqual(second.callCount, 0, "\(kind) se arregla en Ajustes, no cambiando de proveedor")
        }
    }

    func testNeverSwitchesAfterTheAnswerHasStarted() async {
        let first = StubEngine(name: "A", pieces: ["parcial"], error: failure(.unavailable))
        let second = StubEngine(name: "B", pieces: ["otra respuesta"])
        let engine = FailoverEngine(candidates: [.init(engine: first, label: "A"), .init(engine: second, label: "B")])
        let result = await run(engine)
        XCTAssertEqual(result.text, "parcial")
        XCTAssertNotNil(result.error)
        XCTAssertEqual(second.callCount, 0, "No se mezclan dos respuestas")
    }

    func testReportsTheLastErrorWhenEveryProviderFails() async {
        let first = StubEngine(name: "A", error: failure(.tokensPerMinute))
        let second = StubEngine(name: "B", error: failure(.insufficientCredit))
        let engine = FailoverEngine(candidates: [.init(engine: first, label: "A"), .init(engine: second, label: "B")])
        let result = await run(engine)
        XCTAssertEqual((result.error as? ProviderFailureError)?.failure.kind, .insufficientCredit)
        XCTAssertEqual(first.callCount, 1)
        XCTAssertEqual(second.callCount, 1)
    }

    func testASingleProviderBehavesLikeTheProviderItself() async {
        let only = StubEngine(name: "A", pieces: ["uno"])
        let engine = FailoverEngine(candidates: [.init(engine: only, label: "A")])
        let result = await run(engine)
        XCTAssertEqual(result.text, "uno")
        XCTAssertNil(result.error)
    }
}

/// El interruptor de seguridad detiene la petición ANTES de pedir la clave o tocar la red.
final class ProviderPauseTests: XCTestCase {
    override func tearDown() {
        for preset in CloudProviders.all { ProviderHealth.breaker.reset(preset.id) }
        ProviderHealth.breaker.reset("prueba")
        super.tearDown()
    }

    func testAPausedProviderFailsFastWithAClearReason() {
        ProviderHealth.breaker.recordFailure("prueba", failure: ProviderFailure(kind: .dailyQuota, status: 429, retryAfter: 600), message: "cuota diaria")
        XCTAssertThrowsError(try ProviderHTTP.checkBreaker(providerID: "prueba", providerName: "Prueba")) { error in
            let failure = error as? ProviderFailureError
            XCTAssertEqual(failure?.failure.kind, .dailyQuota)
            XCTAssertTrue(failure?.message.contains("en pausa") ?? false)
        }
        ProviderHealth.breaker.reset("prueba")
        XCTAssertNoThrow(try ProviderHTTP.checkBreaker(providerID: "prueba", providerName: "Prueba"))
    }

    func testEnginesDoNotSendAnythingWhileTheirProviderIsPaused() async {
        for id in [CloudProviders.openAI.id, CloudProviders.gemini.id] {
            ProviderHealth.breaker.recordFailure(id, failure: ProviderFailure(kind: .insufficientCredit, status: 429), message: "sin crédito")
            let settings = CloudBrainSettings(providerID: id, model: "m")
            let engine = EngineProvider.makeCloudEngine(descriptor: ModelCatalog.cloudDescriptor, settings: settings, usage: nil)
            var thrown: Error?
            do {
                for try await _ in engine.generate(GenerationRequest(system: "s", turns: [ChatTurn(role: .user, content: "hola")])) {}
            } catch {
                thrown = error
            }
            XCTAssertEqual((thrown as? ProviderFailureError)?.failure.kind, .insufficientCredit, id)
        }
    }

    func testTheFactoryUsesTheNativeGeminiEngineAndTheCompatibleOneForTheRest() {
        let descriptor = ModelCatalog.cloudDescriptor
        XCTAssertTrue(EngineProvider.makeCloudEngine(descriptor: descriptor, settings: CloudBrainSettings(providerID: "gemini", model: "m"), usage: nil) is GeminiEngine)
        for id in ["groq", "openai", "cerebras"] {
            XCTAssertTrue(EngineProvider.makeCloudEngine(descriptor: descriptor, settings: CloudBrainSettings(providerID: id, model: "m"), usage: nil) is CloudEngine, id)
        }
    }
}
