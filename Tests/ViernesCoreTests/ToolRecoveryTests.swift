import XCTest
@testable import ViernesCore

/// Llamadas escritas en otro formato, errores del proveedor dentro del flujo y respuestas vacías:
/// los tres motivos por los que «agendar una reunión» terminaba en «El modelo no devolvió texto».
final class ToolRecoveryTests: XCTestCase {
    // MARK: Flujo del proveedor

    func testProviderErrorInsideTheStreamIsReportedWithWhatTheModelTriedToWrite() {
        let line = #"data: {"error":{"message":"Failed to call a function.","type":"invalid_request_error","code":"tool_use_failed","failed_generation":"<function=list_events>{\"date\":\"today\"}</function>"}}"#
        guard case .providerError(let message, let failed) = OpenAIChatProtocol.parseStreamLine(line) else {
            return XCTFail("Debía reconocerse como error del proveedor")
        }
        XCTAssertTrue(message.contains("Failed to call"))
        XCTAssertEqual(failed, #"<function=list_events>{"date":"today"}</function>"#)
    }

    func testPlainStringErrorAndFinishReasonAreRecognised() {
        XCTAssertEqual(OpenAIChatProtocol.parseStreamLine(#"data: {"error":"cuota agotada"}"#),
                       .providerError(message: "cuota agotada", failedGeneration: nil))
        XCTAssertEqual(OpenAIChatProtocol.parseStreamLine(#"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#), .finish("length"))
        XCTAssertEqual(OpenAIChatProtocol.parseStreamLine(#"data: {"choices":[{"delta":{"content":"Hola"},"finish_reason":null}]}"#), .delta("Hola"))
    }

    func testFailedGenerationIsExtractedFromAnHTTPErrorBody() {
        let body = #"{"error":{"message":"Failed to call a function","code":"tool_use_failed","failed_generation":"{\"name\":\"list_events\",\"arguments\":{\"date\":\"today\"}}"}}"#
        let failed = OpenAIChatProtocol.failedGeneration(inBody: body)
        XCTAssertEqual(ToolCallRecovery.extract(from: failed ?? "").count, 1)
        XCTAssertNil(OpenAIChatProtocol.failedGeneration(inBody: "no es json"))
        XCTAssertNil(OpenAIChatProtocol.failedGeneration(inBody: #"{"error":{"message":"otro error"}}"#))
    }

    // MARK: Lectura de llamadas

    func testParserAcceptsTheCommonArgumentSpellings() {
        let a = ToolCallParser.parse(#"{"name":"list_events","arguments":{"date":"today"}}"#)
        XCTAssertEqual(a, ToolCall(name: "list_events", args: ["date": "today"]))
        let b = ToolCallParser.parse(#"{"name":"list_events","parameters":{"date":"tomorrow","days":2}}"#)
        XCTAssertEqual(b, ToolCall(name: "list_events", args: ["date": "tomorrow", "days": "2"]))
        let c = ToolCallParser.parse(#"{"name":"create_event","arguments":"{\"title\":\"Reunión\",\"start\":\"2026-11-06T15:30\"}"}"#)
        XCTAssertEqual(c, ToolCall(name: "create_event", args: ["title": "Reunión", "start": "2026-11-06T15:30"]))
        let d = ToolCallParser.parse(#"{"type":"function","function":{"name":"functions.get_weather","arguments":{"city":"Bogotá"}}}"#)
        XCTAssertEqual(d, ToolCall(name: "get_weather", args: ["city": "Bogotá"]))
    }

    func testRecoveryFindsBareJSONFunctionTagsAndHarmonyStyle() {
        let bare = ToolCallRecovery.extract(from: #"Voy a mirar tu agenda. {"name":"list_events","arguments":{"date":"today"}}"#)
        XCTAssertEqual(bare.compactMap(ToolCallParser.parse), [ToolCall(name: "list_events", args: ["date": "today"])])

        let tag = ToolCallRecovery.extract(from: #"<function=create_event>{"title":"Reunión con Wendy Ramírez","start":"2026-11-06T15:30"}</function>"#)
        XCTAssertEqual(tag.compactMap(ToolCallParser.parse).first?.args["start"], "2026-11-06T15:30")

        let harmony = ToolCallRecovery.extract(from: #"to=functions.list_events <|constrain|>json<|message|>{"date":"tomorrow"}"#)
        XCTAssertEqual(harmony.compactMap(ToolCallParser.parse), [ToolCall(name: "list_events", args: ["date": "tomorrow"])])
    }

    func testRecoveryIgnoresUnknownToolsReasoningAndPlainProse() {
        XCTAssertTrue(ToolCallRecovery.extract(from: #"{"name":"borrar_todo","args":{}}"#).isEmpty, "Solo herramientas del catálogo")
        XCTAssertTrue(ToolCallRecovery.extract(from: #"<think>quizá {"name":"list_events","args":{"date":"today"}}</think>Hola"#).isEmpty)
        XCTAssertTrue(ToolCallRecovery.extract(from: "Puedes usar functions.list_events para eso, pero no hace falta.").isEmpty)
        XCTAssertTrue(ToolCallRecovery.extract(from: "Hola, ¿en qué te ayudo?").isEmpty)
        let twice = #"{"name":"device_info","args":{"what":"battery"}} {"name":"device_info","args":{"what":"battery"}}"#
        XCTAssertEqual(ToolCallRecovery.extract(from: twice).count, 1, "Sin repetidas")
    }

    // MARK: Motor

    private func makeEngine(script: [[String]], executor: RecordingExecutor = RecordingExecutor(),
                            config: ConversationConfig = ConversationConfig(calendarReadEnabled: true)) -> (ConversationEngine, ScriptedEngine) {
        let scripted = ScriptedEngine(script: script)
        return (ConversationEngine(engine: scripted, memory: InMemoryMemoryStore(), executor: executor,
                                   confirmer: RecordingConfirmer(approve: true), config: config), scripted)
    }

    func testACallWrittenWithoutTagsIsExecutedInsteadOfLeavingTheReplyEmpty() async {
        let executor = RecordingExecutor()
        executor.outcome = .success("No hay eventos ese día.")
        let (engine, scripted) = makeEngine(
            script: [[#"{"name":"list_events","arguments":{"date":"today"}}"#], ["Hoy no tienes eventos."]], executor: executor)
        let events = await collect(await engine.send("¿Qué tengo hoy en mi calendario?"))

        XCTAssertEqual(executor.calls, [ToolCall(name: "list_events", args: ["date": "today"])])
        XCTAssertEqual(events.completedMessage?.text, "Hoy no tienes eventos.")
        XCTAssertNil(events.failureText)
        XCTAssertEqual(scripted.requests.count, 2)
    }

    func testAnEchoedCallIsNotExecutedTwice() async {
        let executor = RecordingExecutor()
        let call = #"{"name":"list_events","arguments":{"date":"today"}}"#
        let (engine, _) = makeEngine(script: [[call], [call], ["Hoy no tienes eventos."]], executor: executor)
        _ = await collect(await engine.send("¿Qué tengo hoy?"))
        XCTAssertEqual(executor.calls.count, 1)
    }

    func testAnEmptyAnswerIsAskedAgainBeforeFailing() async {
        let (engine, scripted) = makeEngine(script: [[], ["Aquí estoy."]])
        let events = await collect(await engine.send("Hola"))
        XCTAssertEqual(events.completedMessage?.text, "Aquí estoy.")
        XCTAssertNil(events.failureText)
        XCTAssertEqual(scripted.requests.count, 2)
        XCTAssertTrue(scripted.requests[1].system.contains(Persona.emptyReplyNote))
        XCTAssertFalse(scripted.requests[0].system.contains(Persona.emptyReplyNote))
    }

    func testPersistentlyEmptyAnswersEndInAnHonestError() async {
        let (engine, scripted) = makeEngine(script: [])
        let events = await collect(await engine.send("Hola"))
        XCTAssertEqual(events.failureText, ConversationEngine.emptyReplyFailure)
        XCTAssertNil(events.completedMessage)
        XCTAssertEqual(scripted.requests.count, 1 + ConversationEngine.maxEmptyRetries)
    }

    func testMissingDataNeverLeavesABlankBubble() async {
        // Falta «start»: el fallo queda oculto y el modelo no dice nada después.
        let incomplete = #"<tool>{"name":"create_event","args":{"title":"Reunión con Wendy Ramírez"}}</tool>"#
        let executor = RecordingExecutor()
        let (engine, _) = makeEngine(script: [[incomplete]], executor: executor)
        let events = await collect(await engine.send("Agenda una reunión con Wendy Ramírez"))
        XCTAssertTrue(executor.calls.isEmpty, "Sin fecha no se crea nada")
        XCTAssertEqual(events.completedMessage?.text, ConversationEngine.couldNotCompleteText)
        XCTAssertNil(events.failureText)
    }
}
