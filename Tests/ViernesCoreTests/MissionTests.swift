import XCTest
@testable import ViernesCore

/// Ejecutor de prueba: devuelve un resultado por herramienta, anota las llamadas y cuántas corrieron a la vez.
final class MapExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ToolCall] = []
    private var active = 0
    private(set) var maxActive = 0
    var results: [String: ToolOutcome] = [:]
    var delayNanoseconds: UInt64 = 0
    var failuresBeforeSuccess: [String: Int] = [:]

    var calls: [ToolCall] { lock.withLock { recorded } }
    var callNames: [String] { calls.map(\.name) }

    func execute(_ call: ToolCall) async -> ToolOutcome {
        let shouldFail: Bool = lock.withLock {
            recorded.append(call)
            active += 1
            maxActive = max(maxActive, active)
            let remaining = failuresBeforeSuccess[call.name] ?? 0
            if remaining > 0 { failuresBeforeSuccess[call.name] = remaining - 1 }
            return remaining > 0
        }
        if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
        lock.withLock { active -= 1 }
        if shouldFail { return .failure("No pude consultar el servicio. Inténtalo de nuevo.") }
        return results[call.name] ?? .success("ok \(call.name)")
    }
}

final class MissionRunnerTests: XCTestCase {
    private func step(_ id: String, _ tool: String = "list_reminders", after: [String] = [], retryable: Bool = false) -> MissionStep {
        MissionStep(id: id, title: "Paso \(id)", tool: tool, dependsOn: after, retryable: retryable)
    }

    private func execute(_ executor: MapExecutor) -> @Sendable (MissionStep) async -> StepOutcome {
        { step in
            switch await executor.execute(ToolCall(name: step.tool, args: step.args)) {
            case .success(let text), .card(let text, _): return StepOutcome(ok: true, text: text)
            case .failure(let reason): return StepOutcome(ok: false, text: reason, transient: ConversationEngine.isTransient(reason))
            }
        }
    }

    func testDependenciesAreRespected() async {
        let executor = MapExecutor()
        let plan = MissionPlan(goal: "orden", steps: [step("c", after: ["b"]), step("a"), step("b", after: ["a"])])
        let state = await MissionRunner(store: InMemoryMissionStore()).run(plan, execute: execute(executor))
        XCTAssertEqual(state.status, .completed)
        XCTAssertTrue(state.steps.allSatisfy { $0.status == .done && $0.attempts == 1 })
        XCTAssertEqual(executor.calls.count, 3)
    }

    func testSafeQueriesRunTogetherAndActionsRunOneByOne() async {
        let queries = MapExecutor()
        queries.delayNanoseconds = 120_000_000
        let plan = MissionPlan(goal: "consultas", steps: [step("a", "list_reminders"), step("b", "get_weather"), step("c", "list_events")])
        _ = await MissionRunner().run(plan, execute: execute(queries))
        XCTAssertGreaterThanOrEqual(queries.maxActive, 2, "Las consultas independientes corren en paralelo")
        XCTAssertLessThanOrEqual(queries.maxActive, MissionRunner.maxParallel)

        let actions = MapExecutor()
        actions.delayNanoseconds = 60_000_000
        let actionPlan = MissionPlan(goal: "acciones", steps: [step("a", "create_reminder"), step("b", "create_reminder")])
        _ = await MissionRunner().run(actionPlan, execute: execute(actions))
        XCTAssertEqual(actions.maxActive, 1, "Una acción que puede pedir confirmación nunca corre a la vez que otra")
    }

    func testAFailedStepSkipsWhatDependsOnItAndTheMissionIsPartial() async {
        let executor = MapExecutor()
        executor.results["list_events"] = .failure("El usuario no ha activado la lectura del calendario.")
        let plan = MissionPlan(goal: "falla", steps: [step("agenda", "list_events"), step("resumen", "list_reminders", after: ["agenda"]), step("otro", "get_weather")])
        let state = await MissionRunner().run(plan, execute: execute(executor))
        XCTAssertEqual(state.status, .partial)
        XCTAssertEqual(state.steps.first { $0.id == "agenda" }?.status, .failed)
        XCTAssertEqual(state.steps.first { $0.id == "resumen" }?.status, .skipped)
        XCTAssertTrue(state.steps.first { $0.id == "resumen" }?.failure?.contains("Paso agenda") ?? false)
        XCTAssertEqual(state.steps.first { $0.id == "otro" }?.status, .done, "Lo independiente sí se hace")
        XCTAssertFalse(executor.callNames.contains("list_reminders"), "Lo saltado no se ejecuta")
    }

    func testRetriesAreLimitedAndOnlyForTransientFailuresOfRetryableSteps() async {
        let flaky = MapExecutor()
        flaky.failuresBeforeSuccess["get_weather"] = 1
        let ok = await MissionRunner(retryDelayNanoseconds: 0).run(MissionPlan(goal: "r", steps: [step("w", "get_weather", retryable: true)]), execute: execute(flaky))
        XCTAssertEqual(ok.steps[0].status, .done)
        XCTAssertEqual(ok.steps[0].attempts, 2)

        let always = MapExecutor()
        always.failuresBeforeSuccess["get_weather"] = 99
        let failed = await MissionRunner(retryDelayNanoseconds: 0).run(MissionPlan(goal: "r", steps: [step("w", "get_weather", retryable: true)]), execute: execute(always))
        XCTAssertEqual(failed.steps[0].status, .failed)
        XCTAssertEqual(failed.steps[0].attempts, MissionRunner.maxAttempts, "Reintentos limitados")

        let notRetryable = MapExecutor()
        notRetryable.failuresBeforeSuccess["get_weather"] = 99
        let single = await MissionRunner(retryDelayNanoseconds: 0).run(MissionPlan(goal: "r", steps: [step("w", "get_weather", retryable: false)]), execute: execute(notRetryable))
        XCTAssertEqual(single.steps[0].attempts, 1)

        let permanent = MapExecutor()
        permanent.results["get_weather"] = .failure("Ciudad no válida.")
        let once = await MissionRunner(retryDelayNanoseconds: 0).run(MissionPlan(goal: "r", steps: [step("w", "get_weather", retryable: true)]), execute: execute(permanent))
        XCTAssertEqual(once.steps[0].attempts, 1, "Un fallo que no es pasajero no se repite")
    }

    func testAnEmptyResultDoesNotCountAsDone() async {
        let executor = MapExecutor()
        executor.results["list_events"] = .success("   ")
        let state = await MissionRunner().run(MissionPlan(goal: "v", steps: [step("a", "list_events")]), execute: execute(executor))
        XCTAssertEqual(state.steps[0].status, .failed)
        XCTAssertTrue(state.steps[0].failure?.contains("ningún dato") ?? false)
    }

    func testCancellationStopsTheRestAndIsSaved() async throws {
        let store = InMemoryMissionStore()
        let executor = MapExecutor()
        executor.delayNanoseconds = 300_000_000
        let plan = MissionPlan(goal: "cancelar", steps: [step("a"), step("b", after: ["a"])])
        let task = Task { await MissionRunner(store: store).run(plan, execute: self.execute(executor)) }
        try await Task.sleep(nanoseconds: 60_000_000)
        task.cancel()
        let state = await task.value
        XCTAssertEqual(state.status, .cancelled)
        XCTAssertEqual(state.steps.first { $0.id == "b" }?.status, .cancelled)
        XCTAssertFalse(executor.callNames.filter { $0 == "list_reminders" }.count > 1, "El segundo paso no llegó a ejecutarse")
        let saved = await store.loadAll()
        XCTAssertEqual(saved.first?.status, .cancelled, "El estado cancelado quedó guardado")
    }

    func testStateIsPersistedAfterEveryChangeAndInterruptedMissionsCanResume() async {
        let store = InMemoryMissionStore()
        let executor = MapExecutor()
        let plan = MissionPlan(goal: "persistir", steps: [step("a"), step("b", after: ["a"])])
        let finished = await MissionRunner(store: store).run(plan, execute: execute(executor))
        let saves = await store.saveCount
        XCTAssertGreaterThanOrEqual(saves, 4, "Se guarda al empezar, en cada lote y al terminar")
        XCTAssertEqual(finished.status, .completed)

        // Un cierre inesperado a mitad: el paso «a» terminó, «b» estaba en curso.
        var crashed = finished
        crashed.status = .running
        crashed.steps[1].status = .running
        crashed.steps[1].result = nil
        let marked = MissionRunner.markInterrupted([crashed, finished])
        XCTAssertEqual(marked[0].status, .interrupted)
        XCTAssertEqual(marked[0].steps[1].status, .interrupted)
        XCTAssertEqual(marked[0].steps[0].status, .done, "Lo que sí terminó se conserva")
        XCTAssertEqual(marked[1], finished, "Una misión terminada no cambia")

        let again = MapExecutor()
        let resumed = await MissionRunner().resume(marked[0], execute: execute(again))
        XCTAssertEqual(resumed.status, .completed)
        XCTAssertEqual(again.callNames.count, 1, "Solo se repite el paso que no terminó")
    }

    func testReportsNeverHideWhatFailed() async {
        let executor = MapExecutor()
        executor.results["list_events"] = .failure("El usuario no ha activado la lectura del calendario.")
        executor.results["list_reminders"] = .success("Comprar leche")
        let plan = MissionPlan(goal: "informe", steps: [step("a", "list_events"), step("b", "list_reminders")], notes: ["No sé tu ciudad."])
        let state = await MissionRunner().run(plan, execute: execute(executor))
        let lines = MissionReport.resultLines(state).joined(separator: "\n")
        XCTAssertTrue(lines.contains("Comprar leche"))
        XCTAssertTrue(lines.contains("NO DISPONIBLE") && lines.contains("lectura del calendario"))
        XCTAssertTrue(lines.contains("No sé tu ciudad."))
        XCTAssertTrue(lines.contains("NO lo inventes"))
        let text = MissionReport.text(state)
        XCTAssertTrue(text.contains("✓ Paso b") && text.contains("✗ Paso a") && text.contains("parcial"))
        XCTAssertEqual(try JSONDecoder().decode(MissionState.self, from: JSONEncoder().encode(state)), state)
    }
}

final class MissionTemplateTests: XCTestCase {
    func testOnlyClearMissionPhrasesAreMissions() {
        XCTAssertEqual(MissionTemplates.match("Viernes, organiza mi mañana"), .today)
        XCTAssertEqual(MissionTemplates.match("Organízame el día"), .today)
        XCTAssertEqual(MissionTemplates.match("¿cómo viene mi día?"), .today)
        XCTAssertEqual(MissionTemplates.match("Organiza el día de mañana"), .tomorrow)
        XCTAssertEqual(MissionTemplates.match("planea mañana por favor"), .tomorrow)
        XCTAssertEqual(MissionTemplates.match("Resumen de mi semana"), .week)
        XCTAssertNil(MissionTemplates.match("¿Qué clima hace mañana?"))
        XCTAssertNil(MissionTemplates.match("Recuérdame llamar a Ana mañana"))
        XCTAssertNil(MissionTemplates.match("Hola, ¿cómo estás?"))
    }

    func testPlansUseOnlyQueriesAndExplainWhatTheyCouldNotPlan() throws {
        let withCity = MissionTemplates.plan(.today, goal: "x", context: MissionContext(city: "Medellín"))
        XCTAssertEqual(withCity.steps.map(\.tool), ["list_events", "list_reminders", "get_weather"])
        XCTAssertEqual(withCity.steps[2].args["city"], "Medellín")
        XCTAssertTrue(withCity.steps[2].retryable)
        XCTAssertTrue(withCity.notes.isEmpty)
        XCTAssertTrue(withCity.steps.allSatisfy { ToolCatalog.definition(named: $0.tool)?.risk == .safe }, "Una misión de consulta no necesita confirmaciones")

        let noCity = MissionTemplates.plan(.today, goal: "x", context: MissionContext())
        XCTAssertEqual(noCity.steps.map(\.tool), ["list_events", "list_reminders"])
        XCTAssertTrue(noCity.notes.first?.contains("ciudad") ?? false, "No inventa una ciudad")

        XCTAssertEqual(MissionTemplates.plan(.tomorrow, goal: "x", context: MissionContext()).steps[0].args["date"], "tomorrow")
        let week = MissionTemplates.plan(.week, goal: "x", context: MissionContext(city: "Cali"))
        XCTAssertEqual(week.steps[0].args["days"], "7")
        XCTAssertFalse(week.steps.contains { $0.tool == "get_weather" })
        for plan in [withCity, noCity, week] {
            for step in plan.steps { XCTAssertNoThrow(try ToolValidator.validate(ToolCall(name: step.tool, args: step.args)), step.tool) }
        }
    }

    func testTheCityComesFromTheOrderOrFromMemoryNeverFromGuessing() {
        XCTAssertEqual(MissionContext.city(in: "Organiza mi día en Medellín.", memories: []), "Medellín")
        XCTAssertEqual(MissionContext.city(in: "organiza mi mañana en Santa Marta", memories: []), "Santa Marta")
        XCTAssertNil(MissionContext.city(in: "organiza mi mañana", memories: []))
        XCTAssertNil(MissionContext.city(in: "organiza mi día en la oficina", memories: []))
        XCTAssertEqual(MissionContext.city(in: "organiza mi día", memories: [MemoryItem(kind: .fact, text: "Vivo en Cali, Colombia", source: .userExplicit)]), "Cali")
        XCTAssertNil(MissionContext.city(in: "organiza mi día", memories: [MemoryItem(kind: .fact, text: "Vivo en Cali", source: .userApproved, isPending: true)]),
                     "Una sugerencia pendiente no se usa")
    }
}

final class MissionConversationTests: XCTestCase {
    private func makeEngine(config: ConversationConfig, executor: MapExecutor, confirmer: RecordingConfirmer = RecordingConfirmer(approve: true),
                            store: MissionStore = InMemoryMissionStore()) -> (ConversationEngine, ScriptedEngine) {
        let scripted = ScriptedEngine(script: [["Resumen listo."]])
        return (ConversationEngine(engine: scripted, memory: InMemoryMemoryStore(), executor: executor, confirmer: confirmer, config: config, missions: store), scripted)
    }

    func testOrganizeMyDayRunsTheQueriesAndGivesTheModelOnlyRealResults() async throws {
        let executor = MapExecutor()
        executor.results["list_events"] = .success("09:00 Reunión de ventas; 09:30 Llamada con Ana")
        executor.results["list_reminders"] = .success("Comprar leche")
        executor.results["get_weather"] = .success("Parcialmente nublado, 18 grados")
        let confirmer = RecordingConfirmer(approve: true)
        let store = InMemoryMissionStore()
        let (engine, scripted) = makeEngine(config: ConversationConfig(calendarReadEnabled: true), executor: executor, confirmer: confirmer, store: store)
        let events = await collect(await engine.send("Viernes, organiza mi día en Bogotá"))
        XCTAssertEqual(Set(executor.callNames), ["list_events", "list_reminders", "get_weather"])
        XCTAssertTrue(confirmer.requests.isEmpty, "Las consultas no piden confirmación")
        let content = try XCTUnwrap(scripted.requests[0].turns.last?.content)
        XCTAssertTrue(content.contains("Reunión de ventas") && content.contains("Comprar leche") && content.contains("18 grados"))
        XCTAssertTrue(content.contains("NO lo inventes") && content.contains(Persona.resultMarker))
        XCTAssertEqual(scripted.requests.count, 1, "Una sola respuesta del modelo: los pasos los ejecuta la misión")
        XCTAssertEqual(events.completedMessage?.actions.count, 3)
        XCTAssertEqual(events.actionRecords.count, 3)
        let saved = await store.loadAll()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].status, .completed)
    }

    func testWithoutCalendarPermissionTheMissionSaysSoInsteadOfInventing() async throws {
        let executor = MapExecutor()
        executor.results["list_reminders"] = .success("Nada pendiente")
        let (engine, scripted) = makeEngine(config: ConversationConfig(), executor: executor)
        _ = await collect(await engine.send("organiza mi mañana"))
        XCTAssertFalse(executor.callNames.contains("list_events"), "Sin el permiso del usuario no se lee el calendario")
        let content = try XCTUnwrap(scripted.requests[0].turns.last?.content)
        XCTAssertTrue(content.contains("NO DISPONIBLE") && content.contains("calendario"), content)
        XCTAssertTrue(content.contains("ciudad"), "Y dice que no sabe la ciudad")
        let history = await engine.missionHistory()
        XCTAssertEqual(history.first?.status, .partial)
    }

    func testOrdinaryQuestionsAndDisabledMissionsDoNotStartOne() async {
        let executor = MapExecutor()
        let (engine, scripted) = makeEngine(config: ConversationConfig(calendarReadEnabled: true), executor: executor)
        _ = await collect(await engine.send("¿Qué clima hace mañana?"))
        XCTAssertTrue(executor.calls.isEmpty)
        XCTAssertFalse(scripted.requests[0].turns.last?.content.contains("Misión") ?? true)

        let off = MapExecutor()
        let (disabled, _) = makeEngine(config: ConversationConfig(calendarReadEnabled: true, missionsEnabled: false), executor: off)
        _ = await collect(await disabled.send("organiza mi día"))
        XCTAssertTrue(off.calls.isEmpty, "Con las misiones apagadas no se ejecuta nada")
    }

    func testInterruptedMissionsAreRecoveredAndCanBeResumed() async {
        let store = InMemoryMissionStore()
        var crashed = MissionState(plan: MissionTemplates.plan(.today, goal: "organiza mi día", context: MissionContext()))
        crashed.steps[0].status = .done
        crashed.steps[0].result = "ya hecho"
        crashed.steps[1].status = .running
        await store.save(crashed)
        let executor = MapExecutor()
        executor.results["list_reminders"] = .success("Comprar leche")
        let (engine, _) = makeEngine(config: ConversationConfig(calendarReadEnabled: true), executor: executor, store: store)
        await engine.recoverMissions()
        let recovered = await engine.missionHistory()
        XCTAssertEqual(recovered.first?.status, .interrupted, "Un cierre inesperado nunca se cuenta como terminada")
        let resumed = await engine.resumeMission(recovered[0])
        XCTAssertEqual(resumed.status, .completed)
        XCTAssertEqual(executor.callNames, ["list_reminders"], "Solo se repitió el paso que no terminó")
        XCTAssertEqual(resumed.steps[0].result, "ya hecho")
    }
}
