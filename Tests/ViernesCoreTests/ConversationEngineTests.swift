import XCTest
@testable import ViernesCore

final class ConversationEngineTests: XCTestCase {
    private let reminderCall = #"<tool>{"name":"create_reminder","args":{"title":"Llamar a Ana","due":"2026-11-05T09:00"}}</tool>"#

    private func makeEngine(
        script: [[String]], executor: ToolExecutor? = RecordingExecutor(), confirmer: ConfirmationProvider? = RecordingConfirmer(approve: true),
        memory: MemoryStore = InMemoryMemoryStore(), config: ConversationConfig = ConversationConfig()
    ) -> (ConversationEngine, ScriptedEngine) {
        let scripted = ScriptedEngine(script: script)
        return (ConversationEngine(engine: scripted, memory: memory, executor: executor, confirmer: confirmer, config: config), scripted)
    }

    func testPlainReplyStreamsAndStoresHistory() async {
        let (engine, _) = makeEngine(script: [["Hola, ", "¿en qué te ayudo?"]])
        let events = await collect(await engine.send("Hola"))
        XCTAssertEqual(events.completedMessage?.text, "Hola, ¿en qué te ayudo?")
        XCTAssertTrue(events.actionRecords.isEmpty)
        let history = await engine.snapshot()
        XCTAssertEqual(history.map(\.role), [.user, .assistant])
    }

    func testThinkBlocksAreNeverShown() async {
        let (engine, _) = makeEngine(script: [["<think>pienso en voz", " alta</think>Respuesta limpia."]])
        let events = await collect(await engine.send("Hola"))
        XCTAssertEqual(events.completedMessage?.text, "Respuesta limpia.")
    }

    func testSensitiveToolRequiresConfirmationAndReportsRealResult() async {
        let executor = RecordingExecutor()
        executor.outcome = .success("Recordatorio creado")
        let confirmer = RecordingConfirmer(approve: true)
        let (engine, scripted) = makeEngine(
            script: [[String(reminderCall.prefix(30)), String(reminderCall.dropFirst(30))], ["Listo, quedó creado."]],
            executor: executor, confirmer: confirmer)
        let events = await collect(await engine.send("Recuérdame llamar a Ana mañana a las 9"))

        XCTAssertEqual(confirmer.requests.count, 1)
        XCTAssertEqual(confirmer.requests.first?.tool, "create_reminder")
        XCTAssertEqual(executor.calls.map(\.name), ["create_reminder"])
        XCTAssertEqual(events.completedMessage?.actions.first?.outcome, .executed("Recordatorio creado"))
        XCTAssertEqual(events.completedMessage?.text, "Listo, quedó creado.")

        // El modelo vio el resultado REAL en la segunda ronda.
        XCTAssertEqual(scripted.requests.count, 2)
        let secondRoundLastTurn = scripted.requests[1].turns.last?.content ?? ""
        XCTAssertTrue(secondRoundLastTurn.contains(Persona.resultMarker))
        XCTAssertTrue(secondRoundLastTurn.contains("ÉXITO"))
        // Y alternancia estricta user/assistant.
        let roles = scripted.requests[1].turns.map(\.role)
        for pair in zip(roles, roles.dropFirst()) { XCTAssertNotEqual(pair.0, pair.1) }
    }

    func testDeclinedConfirmationDoesNotExecute() async {
        let executor = RecordingExecutor()
        let (engine, scripted) = makeEngine(
            script: [[reminderCall], ["Entendido, no lo creo."]],
            executor: executor, confirmer: RecordingConfirmer(approve: false))
        let events = await collect(await engine.send("Recuérdame llamar a Ana"))
        XCTAssertTrue(executor.calls.isEmpty)
        XCTAssertEqual(events.completedMessage?.actions.first?.outcome, .declined)
        XCTAssertTrue((scripted.requests[1].turns.last?.content ?? "").contains("RECHAZADA"))
    }

    func testInvalidToolIsRejectedWithoutAskingUser() async {
        let executor = RecordingExecutor()
        let confirmer = RecordingConfirmer(approve: true)
        let bad = #"<tool>{"name":"open_url","args":{"url":"http://insegura.com"}}</tool>"#
        let (engine, _) = makeEngine(script: [[bad], ["No pude abrir ese enlace."]], executor: executor, confirmer: confirmer)
        let events = await collect(await engine.send("Abre insegura.com"))
        XCTAssertTrue(confirmer.requests.isEmpty)
        XCTAssertTrue(executor.calls.isEmpty)
        if case .failed? = events.completedMessage?.actions.first?.outcome {} else { XCTFail("Debía fallar la validación") }
    }

    func testUnknownToolIsRejected() async {
        let bogus = #"<tool>{"name":"format_disk","args":{}}</tool>"#
        let executor = RecordingExecutor()
        let (engine, _) = makeEngine(script: [[bogus], ["No puedo hacer eso."]], executor: executor)
        let events = await collect(await engine.send("Haz algo raro"))
        XCTAssertTrue(executor.calls.isEmpty)
        if case .failed? = events.actionRecords.first?.outcome {} else { XCTFail("Debía fallar") }
    }

    func testExplicitRememberCommandStoresMemoryAndInformsModel() async throws {
        let memory = InMemoryMemoryStore()
        let (engine, scripted) = makeEngine(script: [["Anotado."]], memory: memory)
        let events = await collect(await engine.send("Recuerda que prefiero respuestas cortas"))
        XCTAssertEqual(events.actionRecords.first?.tool, "save_memory")
        XCTAssertTrue(events.actionRecords.first?.outcome.isExecuted ?? false)
        let stored = try await memory.all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.kind, .preference)
        XCTAssertTrue((scripted.requests[0].turns.last?.content ?? "").contains("ÉXITO"))
    }

    func testSensitiveMemoryIsRefused() async throws {
        let memory = InMemoryMemoryStore()
        let (engine, _) = makeEngine(script: [["No guardo eso."]], memory: memory)
        let events = await collect(await engine.send("Recuerda que mi contraseña es hunter2"))
        if case .failed? = events.actionRecords.first?.outcome {} else { XCTFail("Debía rechazarse") }
        let stored = try await memory.all()
        XCTAssertTrue(stored.isEmpty)
    }

    func testMemoryDisabledByPolicyIsRespected() async throws {
        let memory = InMemoryMemoryStore()
        var policy = MemoryPolicy.default
        policy.enabled = false
        let (engine, scripted) = makeEngine(script: [["Ok."]], memory: memory, config: ConversationConfig(memoryPolicy: policy))
        let events = await collect(await engine.send("Recuerda que me gusta el café"))
        if case .failed? = events.actionRecords.first?.outcome {} else { XCTFail("Debía rechazarse por política") }
        let stored = try await memory.all()
        XCTAssertTrue(stored.isEmpty)
        XCTAssertFalse(scripted.requests[0].system.contains("save_memory("))   // ni siquiera se ofrece la herramienta
    }

    func testRelevantMemoriesAreInjectedIntoSystemPrompt() async throws {
        let memory = InMemoryMemoryStore()
        try await memory.upsert(MemoryItem(kind: .project, text: "Estoy construyendo una app de inventario", source: .userExplicit))
        try await memory.upsert(MemoryItem(kind: .fact, text: "Mi gato se llama Tigre", source: .userExplicit))
        let (engine, scripted) = makeEngine(script: [["Va bien."]], memory: memory)
        _ = await collect(await engine.send("¿Cómo va mi proyecto de inventario?"))
        let system = scripted.requests[0].system
        XCTAssertTrue(system.contains("inventario"))
        XCTAssertFalse(system.contains("Tigre"))
    }

    func testPendingMemoriesAreNeverInjected() async throws {
        let memory = InMemoryMemoryStore()
        try await memory.upsert(MemoryItem(kind: .project, text: "Proyecto secreto Orión", source: .userApproved, isPending: true))
        let (engine, scripted) = makeEngine(script: [["Ok."]], memory: memory)
        _ = await collect(await engine.send("Háblame del proyecto Orión"))
        XCTAssertFalse(scripted.requests[0].system.contains("Orión"))
    }

    func testEngineFailureIsReportedNotHidden() async {
        let (engine, scripted) = makeEngine(script: [[]])
        scripted.failure = EngineError.generationFailed("sin memoria")
        let events = await collect(await engine.send("Hola"))
        XCTAssertNotNil(events.failureText)
        XCTAssertNil(events.completedMessage)
    }

    func testEmptyModelOutputIsAnErrorNotAFakeReply() async {
        let (engine, _) = makeEngine(script: [[]])
        let events = await collect(await engine.send("Hola"))
        XCTAssertNotNil(events.failureText)
    }

    func testClaudeToolHiddenWhenModeDisabledAndOfferedWhenEnabled() async {
        let (disabled, s1) = makeEngine(script: [["Ok."]])
        _ = await collect(await disabled.send("Hola"))
        XCTAssertFalse(s1.requests[0].system.contains("ask_claude("))

        let (enabled, s2) = makeEngine(script: [["Ok."]], config: ConversationConfig(claudeMode: .openApp))
        _ = await collect(await enabled.send("Hola"))
        XCTAssertTrue(s2.requests[0].system.contains("ask_claude("))
    }

    func testNoDeviceToolsOfferedWithoutExecutor() async {
        let (engine, scripted) = makeEngine(script: [["Ok."]], executor: nil)
        _ = await collect(await engine.send("Hola"))
        XCTAssertFalse(scripted.requests[0].system.contains("create_reminder("))
        XCTAssertTrue(scripted.requests[0].system.contains("save_memory("))
    }

    func testHistoryTurnsAlternateAndRespectBudget() {
        let messages = [
            ChatMessage(role: .user, text: "uno"), ChatMessage(role: .user, text: "dos"),
            ChatMessage(role: .assistant, text: "tres"), ChatMessage(role: .user, text: "huérfano")
        ]
        let turns = ConversationEngine.turns(from: messages, budget: 1_000)
        XCTAssertEqual(turns.map(\.role), [.user, .assistant])
        XCTAssertEqual(turns.first?.content, "uno\ndos")

        let long = (0..<20).flatMap { i in [ChatMessage(role: .user, text: String(repeating: "x", count: 100) + "\(i)"),
                                           ChatMessage(role: .assistant, text: String(repeating: "y", count: 100) + "\(i)")] }
        let trimmed = ConversationEngine.turns(from: long, budget: 450)
        XCTAssertLessThanOrEqual(trimmed.map(\.content.count).reduce(0, +), 450 + 110)
        XCTAssertEqual(trimmed.first?.role, .user)
        XCTAssertEqual(trimmed.last?.role, .assistant)
    }
}
