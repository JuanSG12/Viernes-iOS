import XCTest
@testable import ViernesCore

// Viernes 2.0: modificar y eliminar eventos, correos dictados, límites de Groq y dictado (corrección, aprendizaje, diagnóstico).
// Todo es lógica pura o el motor con dobles de prueba: ningún resultado se simula en la app.

private let bogota = TimeZone(identifier: "America/Bogota")!

private func bogotaCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = bogota
    return calendar
}

private func at(_ iso: String) -> Date { DateParsing.parse(iso, timeZone: bogota)! }

private func makeEvent(_ id: String, _ title: String, _ start: String, minutes: Int = 60, location: String = "") -> CalendarEventInfo {
    let begin = at(start)
    return CalendarEventInfo(id: id, title: title, start: begin, end: begin.addingTimeInterval(TimeInterval(minutes * 60)),
                             location: location, calendarTitle: "Casa")
}

final class CalendarEventMatcherTests: XCTestCase {
    private let calendar = bogotaCalendar()
    private let now = at("2026-11-06T15:20")          // viernes

    func testFindsTheOnlyEventThatMatchesTitleAndDay() {
        let events = [makeEvent("A", "Reunión con Wendy Ramírez", "2026-11-06T15:45"), makeEvent("B", "Almuerzo", "2026-11-06T12:00")]
        let result = CalendarEventMatcher.resolve(query: EventQuery(title: "wendy ramirez", date: "today"), candidates: events, now: now, calendar: calendar)
        XCTAssertEqual(result, .found(events[0]), "Sin tildes ni mayúsculas")
    }

    func testSeveralMatchesAreNeverGuessedAndListRealIdentifiers() {
        let events = [makeEvent("A", "Reunión de equipo", "2026-11-06T09:00"), makeEvent("B", "Reunión con Wendy", "2026-11-06T15:45")]
        let result = CalendarEventMatcher.resolve(query: EventQuery(title: "reunión", date: "hoy"), candidates: events, now: now, calendar: calendar)
        guard case .ambiguous(let message, let candidates) = result else { return XCTFail("Debía ser ambiguo: \(result)") }
        XCTAssertEqual(candidates.map(\.id), ["A", "B"])
        XCTAssertTrue(message.contains("[id: A]") && message.contains("[id: B]"))
        XCTAssertTrue(message.contains("NO elijas"))
    }

    func testNothingMatchingNeverFallsBackToAnotherEvent() {
        let events = [makeEvent("A", "Reunión con Wendy", "2026-11-06T15:45")]
        let result = CalendarEventMatcher.resolve(query: EventQuery(title: "dentista", date: "today"), candidates: events, now: now, calendar: calendar)
        guard case .notFound(let message) = result else { return XCTFail("Debía ser notFound: \(result)") }
        XCTAssertTrue(message.contains("dentista"))
    }

    func testStartTimeFiltersEventsOfTheSameDay() {
        let events = [makeEvent("A", "Gimnasio", "2026-11-07T08:00"), makeEvent("B", "Dentista", "2026-11-07T15:00")]
        let result = CalendarEventMatcher.resolve(query: EventQuery(date: "tomorrow", time: "08:00"), candidates: events, now: now, calendar: calendar)
        XCTAssertEqual(result, .found(events[0]))
    }

    func testJustCreatedOnlyConsidersEventsViernesCreatedRecently() {
        let events = [makeEvent("A", "Reunión con Wendy", "2026-11-06T15:45"), makeEvent("B", "Reunión de equipo", "2026-11-06T09:00")]
        let fresh = [CreatedEventRecord(id: "A", title: "Reunión con Wendy", start: events[0].start, createdAt: now.addingTimeInterval(-300))]
        XCTAssertEqual(CalendarEventMatcher.resolve(query: EventQuery(justCreated: true), candidates: events, recent: fresh, now: now, calendar: calendar),
                       .found(events[0]), "«El que acabamos de crear» es el creado por Viernes, no «el más reciente» del calendario")
        let old = [CreatedEventRecord(id: "A", title: "x", start: events[0].start, createdAt: now.addingTimeInterval(-13 * 3_600))]
        guard case .notFound = CalendarEventMatcher.resolve(query: EventQuery(justCreated: true), candidates: events, recent: old, now: now, calendar: calendar) else {
            return XCTFail("Un evento creado hace más de 12 horas ya no es «el que acabamos de crear»")
        }
        guard case .notFound = CalendarEventMatcher.resolve(query: EventQuery(justCreated: true), candidates: events, recent: [], now: now, calendar: calendar) else {
            return XCTFail("Sin eventos creados por Viernes no se adivina ninguno")
        }
    }

    func testAnExplicitIdentifierMustExist() {
        let events = [makeEvent("A", "Reunión", "2026-11-06T15:45")]
        XCTAssertEqual(CalendarEventMatcher.resolve(query: EventQuery(eventID: "A"), candidates: events, now: now, calendar: calendar), .found(events[0]))
        guard case .notFound = CalendarEventMatcher.resolve(query: EventQuery(eventID: "INVENTADO"), candidates: events, now: now, calendar: calendar) else {
            return XCTFail("Un identificador inventado no puede resolverse")
        }
    }

    func testAQueryWithoutCriteriaIsInvalid() {
        guard case .invalid = CalendarEventMatcher.resolve(query: EventQuery(), candidates: [makeEvent("A", "x", "2026-11-06T10:00")], now: now, calendar: calendar) else {
            return XCTFail("Sin criterio no se elige nada")
        }
    }

    func testGenericWordsLikeMeetingDoNotBlockTheSearch() {
        let events = [makeEvent("A", "Cita con el dentista", "2026-11-07T10:00")]
        XCTAssertEqual(CalendarEventMatcher.resolve(query: EventQuery(title: "la reunión", date: "tomorrow"), candidates: events, now: now, calendar: calendar),
                       .found(events[0]), "«reunión» es genérica: el día basta cuando solo hay un evento")
        XCTAssertTrue(CalendarEventMatcher.titleMatches(query: "wendy", title: "Reunión con Wendy Ramírez"))
        XCTAssertFalse(CalendarEventMatcher.titleMatches(query: "wendy", title: "Reunión con Ana"))
    }

    func testSearchWindowIsTheDayWhenGivenAndWideOtherwise() {
        let day = CalendarEventMatcher.searchWindow(for: EventQuery(date: "tomorrow"), now: now, calendar: calendar)
        XCTAssertEqual(day.end.timeIntervalSince(day.start), 86_400, accuracy: 1)
        let wide = CalendarEventMatcher.searchWindow(for: EventQuery(title: "Wendy"), now: now, calendar: calendar)
        XCTAssertGreaterThan(wide.end.timeIntervalSince(wide.start), 100 * 86_400)
    }

    func testChangesKeepTheTimeWhenOnlyTheDayChangesAndViceVersa() throws {
        let original = makeEvent("A", "Reunión", "2026-11-06T15:45", minutes: 30)
        let day = try EventChanges.from(args: ["new_date": "lunes"], original: original, now: now, calendar: calendar).get()
        XCTAssertEqual(day.start, at("2026-11-09T15:45"), "«ponla para el lunes» conserva la hora")
        let time = try EventChanges.from(args: ["new_time": "16:00"], original: original, now: now, calendar: calendar).get()
        XCTAssertEqual(time.start, at("2026-11-06T16:00"), "«a las 4 de la tarde» conserva el día")
        let both = try EventChanges.from(args: ["new_date": "tomorrow", "new_time": "08:30"], original: original, now: now, calendar: calendar).get()
        XCTAssertEqual(both.start, at("2026-11-07T08:30"))
        let full = try EventChanges.from(args: ["new_start": "2026-11-10T09:00", "new_duration_minutes": "90", "new_location": "Oficina"],
                                         original: original, now: now, calendar: calendar).get()
        XCTAssertEqual(full.start, at("2026-11-10T09:00"))
        XCTAssertEqual(full.durationMinutes, 90)
        XCTAssertEqual(full.location, "Oficina")
        XCTAssertFalse(full.isEmpty)
        XCTAssertThrowsError(try EventChanges.from(args: ["new_duration_minutes": "0"], original: original, now: now, calendar: calendar).get())
        XCTAssertThrowsError(try EventChanges.from(args: ["new_time": "25:00"], original: original, now: now, calendar: calendar).get())
    }

    func testClockParsing() {
        XCTAssertEqual(CalendarEventMatcher.minutes(fromClock: "08:00"), 480)
        XCTAssertEqual(CalendarEventMatcher.minutes(fromClock: "8"), 480)
        XCTAssertEqual(CalendarEventMatcher.minutes(fromClock: "15:45"), 945)
        XCTAssertNil(CalendarEventMatcher.minutes(fromClock: "24:00"))
        XCTAssertNil(CalendarEventMatcher.minutes(fromClock: "8:5"))
        XCTAssertEqual(CalendarEventMatcher.clock(480), "08:00")
        XCTAssertEqual(CalendarEventMatcher.clock(945), "15:45")
    }
}

final class EventToolValidationTests: XCTestCase {
    func testUpdateAndDeleteNeedACriterionAndUpdateNeedsAChange() throws {
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "delete_event", args: [:])), "Sin criterio no se borra nada")
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "update_event", args: ["title": "Wendy"])), "Sin cambio no hay nada que modificar")
        let update = try ToolValidator.validate(ToolCall(name: "update_event", args: ["title": "Wendy", "date": "mañana", "new_time": "16:00"]))
        XCTAssertEqual(update.args["new_time"], "16:00")
        let delete = try ToolValidator.validate(ToolCall(name: "delete_event", args: ["date": "tomorrow", "time": "8"]))
        XCTAssertEqual(delete.args["time"], "08:00", "La hora se normaliza")
        let created = try ToolValidator.validate(ToolCall(name: "delete_event", args: ["just_created": "Sí"]))
        XCTAssertEqual(created.args["just_created"], "true")
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "delete_event", args: ["time": "25:00"])))
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "update_event", args: ["title": "x", "new_duration_minutes": "5000"])))
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "update_event", args: ["title": "x", "new_start": "pronto"])))
    }

    func testRiskLevelsFollowTheRules() {
        XCTAssertEqual(ToolCatalog.definition(named: "delete_event")?.risk, .destructive, "Borrar siempre confirma")
        XCTAssertTrue(ToolCatalog.definition(named: "delete_event")?.risk.requiresConfirmation ?? false)
        XCTAssertEqual(ToolCatalog.definition(named: "update_event")?.risk, .reversible, "Una modificación clara no pregunta")
        XCTAssertEqual(ToolCatalog.definition(named: "list_events")?.risk, .safe)
        XCTAssertEqual(ToolCatalog.definition(named: "create_event")?.risk, .reversible)
    }

    func testSpokenEmailInAToolCallIsCleanedBeforeValidating() throws {
        let call = try ToolValidator.validate(ToolCall(name: "compose_email", args: ["body": "Hola", "to": "kisameyguy arroba gmail punto com"]))
        XCTAssertEqual(call.args["to"], "kisameyguy@gmail.com")
        let spaced = try ToolValidator.validate(ToolCall(name: "compose_email", args: ["body": "Hola", "to": "  Ana@Example.com. "]))
        XCTAssertEqual(spaced.args["to"], "ana@example.com")
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "compose_email", args: ["body": "Hola", "to": "mi jefe"])))
    }
}

final class SpokenEmailTests: XCTestCase {
    func testDictatedAddressesBecomeAddresses() {
        XCTAssertEqual(SpokenText.normalizeEmails(in: "mi correo es kisameyguy arroba gmail punto com"), "mi correo es kisameyguy@gmail.com")
        XCTAssertEqual(SpokenText.normalizeEmails(in: "juan punto perez arroba empresa punto com punto co gracias"), "juan.perez@empresa.com.co gracias")
        XCTAssertEqual(SpokenText.normalizeEmails(in: "juan guion bajo perez arroba hotmail punto com"), "juan_perez@hotmail.com")
        XCTAssertEqual(SpokenText.normalizeEmails(in: "kisameyguy @ gmail . com"), "kisameyguy@gmail.com")
        XCTAssertEqual(SpokenText.normalizeEmails(in: "Ana arroba Gmail punto com."), "ana@gmail.com")
    }

    func testOrdinaryTextIsLeftAlone() {
        for text in ["pon un punto y aparte", "nos vemos el viernes", "arroba", "escríbeme a las tres", "gmail punto com"] {
            XCTAssertEqual(SpokenText.normalizeEmails(in: text), text, text)
        }
        XCTAssertEqual(SpokenText.normalizeEmails(in: "valor arroba sin dominio"), "valor arroba sin dominio", "Sin dominio con punto no es un correo")
    }

    func testCleanEmailAddress() {
        XCTAssertEqual(SpokenText.cleanEmailAddress("Kisameyguy@Gmail.com."), "kisameyguy@gmail.com")
        XCTAssertEqual(SpokenText.cleanEmailAddress("mailto:ana@example.com"), "ana@example.com")
        XCTAssertEqual(SpokenText.cleanEmailAddress("mi jefe"), "mi jefe", "Sin «@» no se inventa nada")
    }
}

// MARK: Motor: resolver antes de actuar

private final class ResolvingExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ToolCall] = []
    var resolution: ToolResolution?
    var outcome: ToolOutcome = .success("Hecho.")
    var calls: [ToolCall] { lock.withLock { recorded } }
    func execute(_ call: ToolCall) async -> ToolOutcome {
        lock.withLock { recorded.append(call) }
        return outcome
    }
    func resolve(_ call: ToolCall) async -> ToolResolution? { resolution }
}

final class EventEditingEngineTests: XCTestCase {
    private let config = ConversationConfig(calendarReadEnabled: true)
    private let deleteCall = #"<tool>{"name":"delete_event","args":{"title":"Wendy","date":"today"}}</tool>"#
    private let updateCall = #"<tool>{"name":"update_event","args":{"title":"Wendy","date":"tomorrow","new_time":"16:00"}}</tool>"#
    private let detail = "«Reunión con Wendy Ramírez» — vie 6 nov, 15:45–16:45 (calendario Casa)"

    private func makeEngine(script: [[String]], executor: ToolExecutor?, confirmer: ConfirmationProvider?, config: ConversationConfig? = nil) -> (ConversationEngine, ScriptedEngine) {
        let scripted = ScriptedEngine(script: script)
        return (ConversationEngine(engine: scripted, memory: InMemoryMemoryStore(), executor: executor, confirmer: confirmer, config: config ?? self.config), scripted)
    }

    func testDeleteShowsTheExactEventAndRunsWithTheVerifiedIdentifier() async {
        let executor = ResolvingExecutor()
        executor.resolution = .ready(ToolCall(name: "delete_event", args: ["event_id": "ABC"]), detail: detail)
        executor.outcome = .success("Evento eliminado y comprobado.")
        let confirmer = RecordingConfirmer(approve: true)
        let (engine, _) = makeEngine(script: [[deleteCall], ["Listo, la eliminé."]], executor: executor, confirmer: confirmer)
        let events = await collect(await engine.send("Elimina la reunión con Wendy"))
        XCTAssertEqual(confirmer.requests.count, 1)
        XCTAssertEqual(confirmer.requests.first?.detail, detail, "La confirmación enseña el evento EXACTO, no lo que dijo el modelo")
        XCTAssertEqual(confirmer.requests.first?.title, "Eliminar evento")
        XCTAssertEqual(executor.calls.first?.args["event_id"], "ABC")
        XCTAssertEqual(events.completedMessage?.actions.first?.outcome, .executed("Evento eliminado y comprobado."))
        XCTAssertEqual(events.completedMessage?.actions.first?.summary, detail)
    }

    func testDecliningTheConfirmationDeletesNothing() async {
        let executor = ResolvingExecutor()
        executor.resolution = .ready(ToolCall(name: "delete_event", args: ["event_id": "ABC"]), detail: detail)
        let (engine, _) = makeEngine(script: [[deleteCall], ["De acuerdo, no la borro."]], executor: executor, confirmer: RecordingConfirmer(approve: false))
        let events = await collect(await engine.send("Elimina la reunión con Wendy"))
        XCTAssertTrue(executor.calls.isEmpty, "Sin confirmación no se ejecuta")
        XCTAssertEqual(events.completedMessage?.actions.first?.outcome, .declined)
    }

    func testAmbiguousTargetAsksTheUserInsteadOfActing() async {
        let executor = ResolvingExecutor()
        executor.resolution = .blocked("Hay 2 eventos que coinciden. NO elijas tú.", askUser: true)
        let confirmer = RecordingConfirmer(approve: true)
        let (engine, scripted) = makeEngine(script: [[deleteCall], ["Tengo dos: ¿la de las 9 o la de las 15:45?"]], executor: executor, confirmer: confirmer)
        let events = await collect(await engine.send("Elimina la reunión"))
        XCTAssertTrue(executor.calls.isEmpty)
        XCTAssertTrue(confirmer.requests.isEmpty, "No se confirma nada hasta saber cuál")
        XCTAssertFalse(events.completedMessage?.actions.first?.isVisible ?? true, "La ambigüedad no es un fallo para enseñar: el modelo pregunta")
        XCTAssertTrue((scripted.requests[1].turns.last?.content ?? "").contains("FALLÓ"))
        XCTAssertEqual(events.completedMessage?.text, "Tengo dos: ¿la de las 9 o la de las 15:45?")
    }

    func testEventThatDoesNotExistIsReportedAsARealFailure() async {
        let executor = ResolvingExecutor()
        executor.resolution = .blocked("No encontré ningún evento con título «Wendy».", askUser: false)
        let (engine, _) = makeEngine(script: [[deleteCall], ["No encontré esa reunión."]], executor: executor, confirmer: RecordingConfirmer(approve: true))
        let events = await collect(await engine.send("Elimina la reunión con Wendy"))
        XCTAssertTrue(executor.calls.isEmpty)
        XCTAssertTrue(events.completedMessage?.actions.first?.isVisible ?? false)
        if case .failed? = events.completedMessage?.actions.first?.outcome {} else { XCTFail("Debía quedar como fallo real") }
    }

    func testAClearModificationRunsWithoutAskingAndKeepsTheResolvedTarget() async {
        let executor = ResolvingExecutor()
        executor.resolution = .ready(ToolCall(name: "update_event", args: ["event_id": "ABC", "new_time": "16:00"]), detail: detail)
        executor.outcome = .success("Evento actualizado y comprobado.")
        let confirmer = RecordingConfirmer(approve: true)
        let (engine, _) = makeEngine(script: [[updateCall], ["Listo, quedó a las 4."]], executor: executor, confirmer: confirmer)
        let events = await collect(await engine.send("Cambia la reunión con Wendy a las 4 de la tarde"))
        XCTAssertTrue(confirmer.requests.isEmpty, "Una modificación clara y específica no pregunta")
        XCTAssertEqual(executor.calls.first?.args["event_id"], "ABC")
        XCTAssertEqual(events.completedMessage?.actions.first?.outcome, .executed("Evento actualizado y comprobado."))
    }

    func testEditToolsOnlyExistWhenCalendarReadingIsOn() async {
        let executor = ResolvingExecutor()
        let (off, offScripted) = makeEngine(script: [[deleteCall], ["No puedo."]], executor: executor, confirmer: RecordingConfirmer(approve: true), config: ConversationConfig())
        let events = await collect(await off.send("Elimina la reunión con Wendy"))
        XCTAssertFalse(offScripted.requests[0].system.contains("delete_event("))
        XCTAssertFalse(offScripted.requests[0].system.contains("update_event("))
        XCTAssertTrue(executor.calls.isEmpty, "Sin permiso de lectura no se toca el calendario")
        if case .failed? = events.completedMessage?.actions.first?.outcome {} else { XCTFail("Debía rechazarse") }

        let (on, onScripted) = makeEngine(script: [["Ok."]], executor: ResolvingExecutor(), confirmer: nil)
        _ = await collect(await on.send("Hola"))
        XCTAssertTrue(onScripted.requests[0].system.contains("delete_event("))
        XCTAssertTrue(onScripted.requests[0].system.contains("update_event("))
        XCTAssertTrue(onScripted.requests[0].system.contains("compose_email("))
    }

    func testExecutorsWithoutResolutionStillWork() async {
        let executor = RecordingExecutor()
        let (engine, _) = makeEngine(script: [[deleteCall], ["Hecho."]], executor: executor, confirmer: RecordingConfirmer(approve: true))
        _ = await collect(await engine.send("Elimina la reunión con Wendy"))
        XCTAssertEqual(executor.calls.first?.name, "delete_event", "Sin resolutor se ejecuta tal cual (el ejecutor real siempre resuelve)")
    }

    func testCreateEventSummaryIsReadableAndNotRawISO() {
        let call = ToolCall(name: "create_event", args: ["title": "Reunión con Wendy", "start": "2026-11-06T15:45", "duration_minutes": "60"])
        let summary = ConversationEngine.summary(for: call, timeZone: bogota)
        XCTAssertFalse(summary.contains("2026-11-06T15:45"))
        XCTAssertTrue(summary.contains("15:45"))
        XCTAssertTrue(summary.contains("Reunión con Wendy"))
        XCTAssertEqual(ConversationEngine.confirmationTitle("update_event"), "Modificar evento")
    }
}

// MARK: Límites del plan gratuito

final class RateLimitTests: XCTestCase {
    private let perMinute = #"{"error":{"message":"Rate limit reached for model `openai/gpt-oss-120b` in organization `org_x` service tier `on_demand` on tokens per minute (TPM): Limit 8000, Used 7243, Requested 1984. Please try again in 5.4s. Need more tokens? Upgrade to Dev Tier today.","type":"tokens","code":"rate_limit_exceeded"}}"#
    private let perDay = #"{"error":{"message":"Rate limit reached for model `openai/gpt-oss-120b` on tokens per day (TPD): Limit 200000, Used 199000, Requested 3000. Please try again in 1h12m3.4s.","type":"tokens","code":"rate_limit_exceeded"}}"#

    func testPerMinuteLimitIsReadAndWaitedOut() throws {
        let limit = OpenAIChatProtocol.parseRateLimit(retryAfterHeader: nil, body: perMinute)
        XCTAssertEqual(limit.window, .minute)
        XCTAssertEqual(try XCTUnwrap(limit.retryAfter), 5.4, accuracy: 0.001)
        XCTAssertTrue(limit.detail?.contains("8000") ?? false)
        XCTAssertTrue(limit.detail?.contains("7243") ?? false)
        XCTAssertTrue(limit.detail?.contains("1984") ?? false)
        XCTAssertEqual(try XCTUnwrap(OpenAIChatProtocol.automaticWait(for: limit)), 5.4, accuracy: 0.001, "Una espera corta se espera sola")
    }

    func testTheRetryAfterHeaderWinsOverTheMessage() throws {
        let limit = OpenAIChatProtocol.parseRateLimit(retryAfterHeader: "12", body: perMinute)
        XCTAssertEqual(try XCTUnwrap(limit.retryAfter), 12, accuracy: 0.001)
    }

    func testDailyLimitIsNeverWaitedOutAndSaysSoHonestly() throws {
        let limit = OpenAIChatProtocol.parseRateLimit(retryAfterHeader: nil, body: perDay)
        XCTAssertEqual(limit.window, .day)
        XCTAssertEqual(try XCTUnwrap(limit.retryAfter), 4_323.4, accuracy: 0.01)
        XCTAssertNil(OpenAIChatProtocol.automaticWait(for: limit))
        let message = OpenAIChatProtocol.rateLimitMessage(limit, provider: "Groq")
        XCTAssertTrue(message.contains("DIARIO"))
        XCTAssertTrue(message.contains("1 h 12 min"))
        XCTAssertTrue(message.contains("modelo local"))
    }

    func testLongOrUnknownWaitsAreHandledSafely() {
        XCTAssertNil(OpenAIChatProtocol.automaticWait(for: .init(retryAfter: 45, window: .minute, detail: nil)), "Más de 30 s no se espera sola")
        XCTAssertEqual(OpenAIChatProtocol.automaticWait(for: .init(retryAfter: nil, window: .unknown, detail: nil)), 8, "Sin dato, una espera prudente")
        XCTAssertEqual(OpenAIChatProtocol.automaticWait(for: .init(retryAfter: 0.2, window: .minute, detail: nil)), 1, "Nunca menos de un segundo")
        let body = OpenAIChatProtocol.errorMessage(status: 429, body: perMinute, provider: "Groq", model: "m")
        XCTAssertTrue(body.contains("límite") && body.contains("1984"))
    }

    func testDurationParsing() throws {
        XCTAssertEqual(try XCTUnwrap(OpenAIChatProtocol.parseDuration("5.4s. Need more")), 5.4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(OpenAIChatProtocol.parseDuration("1m5.2s.")), 65.2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(OpenAIChatProtocol.parseDuration("450ms")), 0.45, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(OpenAIChatProtocol.parseDuration("2h3m")), 7_380, accuracy: 0.001)
        XCTAssertNil(OpenAIChatProtocol.parseDuration("pronto"))
        XCTAssertEqual(OpenAIChatProtocol.humanDuration(5.4), "6 s")
        XCTAssertEqual(OpenAIChatProtocol.humanDuration(65), "1 min 5 s")
        XCTAssertEqual(OpenAIChatProtocol.humanDuration(120), "2 min")
        XCTAssertEqual(OpenAIChatProtocol.humanDuration(3_700), "1 h 1 min")
    }
}

// MARK: Dictado

final class TranscriptCorrectionTests: XCTestCase {
    func testGlossaryFixesNamesSplitWordsAndAccents() {
        let glossary = ["Wendy Ramírez", "Kisameyguy"]
        XCTAssertEqual(TranscriptCorrector.apply("agenda una reunión con wendy ramirez", glossary: glossary, learned: []).text,
                       "agenda una reunión con Wendy Ramírez")
        XCTAssertEqual(TranscriptCorrector.apply("dile a kisame guy que llegue", glossary: glossary, learned: []).text,
                       "dile a Kisameyguy que llegue", "El reconocedor partió el nombre en dos palabras")
        XCTAssertEqual(TranscriptCorrector.apply("para kisameiguy", glossary: glossary, learned: []).text, "para Kisameyguy")
    }

    func testGlossaryDoesNotRewriteOrdinaryWords() {
        let result = TranscriptCorrector.apply("compré una marca nueva y vi a mi esposa", glossary: ["Marta", "Esposo"], learned: [])
        XCTAssertEqual(result.text, "compré una marca nueva y vi a mi esposa", "Términos cortos solo corrigen mayúsculas y tildes, no palabras parecidas")
        XCTAssertTrue(result.changes.isEmpty)
        XCTAssertEqual(TranscriptCorrector.apply("llama a marta", glossary: ["Marta"], learned: []).text, "llama a Marta")
    }

    func testLearnedCorrectionsKeepPunctuation() {
        let learned = [LearnedCorrection(heard: "pachon", meant: "Pachón")]
        XCTAssertEqual(TranscriptCorrector.apply("llama a pachon.", glossary: [], learned: learned).text, "llama a Pachón.")
        let multi = [LearnedCorrection(heard: "wen di", meant: "Wendy")]
        XCTAssertEqual(TranscriptCorrector.apply("cita con wen di mañana", glossary: [], learned: multi).text, "cita con Wendy mañana")
    }

    func testDictatedEmailIsCorrectedAndReported() {
        let result = TranscriptCorrector.apply("escríbele a kisameyguy arroba gmail punto com", glossary: [], learned: [])
        XCTAssertEqual(result.text, "escríbele a kisameyguy@gmail.com")
        XCTAssertFalse(result.changes.isEmpty)
    }

    func testEmptyAndCleanTextPassThrough() {
        XCTAssertEqual(TranscriptCorrector.apply("", glossary: ["Wendy"], learned: []).text, "")
        let clean = TranscriptCorrector.apply("¿Qué tengo hoy en mi agenda?", glossary: ["Wendy"], learned: [])
        XCTAssertEqual(clean.text, "¿Qué tengo hoy en mi agenda?")
        XCTAssertTrue(clean.changes.isEmpty)
    }

    func testLearningFromEdits() {
        XCTAssertEqual(TranscriptDiff.corrections(heard: "agenda con wen di mañana", edited: "agenda con Wendy mañana"),
                       [LearnedCorrection(heard: "wen di", meant: "Wendy")])
        XCTAssertEqual(TranscriptDiff.corrections(heard: "llama a wendy", edited: "llama a Wendy"), [LearnedCorrection(heard: "wendy", meant: "Wendy")])
        XCTAssertTrue(TranscriptDiff.corrections(heard: "hola mundo", edited: "hola mundo").isEmpty)
        XCTAssertTrue(TranscriptDiff.corrections(heard: "hola", edited: "hola mundo entero").isEmpty, "Una simple adición no es una corrección")
        XCTAssertTrue(TranscriptDiff.corrections(heard: "uno dos tres cuatro cinco", edited: "a b c d e").isEmpty, "Cambios enormes no se aprenden")
        let two = TranscriptDiff.corrections(heard: "cita con pachon en bogota", edited: "cita con Pachón en Bogotá")
        XCTAssertEqual(two.map(\.meant), ["Pachón", "Bogotá"])
    }

    func testMergingLearnedCorrectionsReplacesTheOldOneAndIsBounded() {
        let first = [LearnedCorrection(heard: "wendy", meant: "Wendi")]
        let merged = TranscriptDiff.merge([LearnedCorrection(heard: "Wendy", meant: "Wendy")], into: first)
        XCTAssertEqual(merged, [LearnedCorrection(heard: "Wendy", meant: "Wendy")])
        var many: [LearnedCorrection] = []
        for index in 0..<200 { many = TranscriptDiff.merge([LearnedCorrection(heard: "x\(index)", meant: "y\(index)")], into: many) }
        XCTAssertEqual(many.count, SpeechSettings.maxLearned)
        XCTAssertEqual(many.last?.heard, "x199")
    }
}

final class SpeechSettingsTests: XCTestCase {
    func testAudioNeverGoesToTheCloudWithoutDatedConsent() {
        var settings = SpeechSettings.default
        XCTAssertFalse(settings.cloudTranscription, "Apagado por defecto")
        settings.cloudTranscription = true
        XCTAssertFalse(settings.sanitized().cloudTranscription, "Sin consentimiento fechado no se envía audio")
        settings.cloudConsentAt = Date()
        XCTAssertTrue(settings.sanitized().cloudTranscription)
    }

    func testClampingAndGlossaryCleanup() {
        var settings = SpeechSettings.default
        settings.endSilenceSeconds = 99
        settings.glossary = ["Wendy", " wendy ", "", String(repeating: "x", count: 80), "Pachón"]
        let clean = settings.sanitized()
        XCTAssertEqual(clean.endSilenceSeconds, 3.5)
        XCTAssertEqual(clean.glossary, ["Wendy", "Pachón"], "Sin repetidos (ignorando mayúsculas), vacíos ni términos enormes")
        settings.endSilenceSeconds = 0.1
        XCTAssertEqual(settings.sanitized().endSilenceSeconds, 0.8)
    }

    func testContextualStringsAlwaysIncludeTheWakeWordAndTheGlossary() {
        var settings = SpeechSettings.default
        settings.glossary = ["Wendy Ramírez"]
        settings.learned = [LearnedCorrection(heard: "pachon", meant: "Pachón")]
        let strings = settings.contextualStrings(extra: ["Ana"])
        XCTAssertEqual(strings.first, "Viernes")
        XCTAssertTrue(strings.contains("Wendy Ramírez") && strings.contains("Pachón") && strings.contains("Ana"))
    }

    func testOldSettingsWithoutSpeechStillDecode() throws {
        let data = try JSONEncoder().encode(AppSettings.default)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "speech")
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: old)
        XCTAssertEqual(decoded.speechSettings, .default)
        var withSpeech = AppSettings.default
        withSpeech.speech = SpeechSettings(review: .always, endSilenceSeconds: 2, glossary: ["Wendy"], learned: [], autoCorrect: true,
                                           keepHistory: false, cloudTranscription: false, cloudConsentAt: nil)
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(withSpeech))
        XCTAssertEqual(roundTrip.speechSettings.review, .always)
    }
}

final class RecognitionDiagnosticsTests: XCTestCase {
    func testErrorPolicy() {
        XCTAssertEqual(SpeechErrorPolicy.classify(domain: "kAFAssistantErrorDomain", code: 1110, hasText: false), .benign, "No se oyó voz")
        XCTAssertEqual(SpeechErrorPolicy.classify(domain: "kAFAssistantErrorDomain", code: 203, hasText: true), .benign, "Ya hay texto: se usa")
        XCTAssertEqual(SpeechErrorPolicy.classify(domain: "kAFAssistantErrorDomain", code: 203, hasText: false), .retry)
        if case .fatal(let message) = SpeechErrorPolicy.classify(domain: "kLSRErrorDomain", code: 102, hasText: false) {
            XCTAssertTrue(message.contains("Dictado"))
        } else { XCTFail("Falta el modelo de dictado: no se reintenta") }
        XCTAssertTrue(SpeechErrorPolicy.describe(domain: "X", code: 7, message: "falló").contains("X 7"))
    }

    func testStatsSeparateCaptureRecognitionAndComparison() {
        let records = [
            RecognitionRecord(locale: "es-CO", onDevice: true, mode: "botón", duration: 3, endReason: .silence, partialCount: 4, raw: "agenda con wen di",
                              corrected: "agenda con Wendy", cloudText: "agenda con Wendy Ramírez", edited: "agenda con Wendy Ramírez", vote: .cloud),
            RecognitionRecord(locale: "es-CO", onDevice: true, mode: "botón", duration: 7, endReason: .noSpeech, partialCount: 0, raw: ""),
            RecognitionRecord(locale: "es-CO", onDevice: true, mode: "palabra", duration: 2, endReason: .error, partialCount: 0, raw: "", error: "falló", retried: true, vote: .neither),
            RecognitionRecord(locale: "es-CO", onDevice: true, mode: "botón", duration: 2, endReason: .userTap, partialCount: 2, raw: "hola", cloudText: "hola", vote: .local)
        ]
        let stats = RecognitionStats.summarize(records)
        XCTAssertEqual(stats.total, 4)
        XCTAssertEqual(stats.empty, 2)
        XCTAssertEqual(stats.withError, 1)
        XCTAssertEqual(stats.retried, 1)
        XCTAssertEqual(stats.edited, 1)
        XCTAssertEqual(stats.autoCorrected, 1)
        XCTAssertEqual(stats.cloudCompared, 2)
        XCTAssertEqual([stats.localVotes, stats.cloudVotes, stats.neitherVotes], [1, 1, 1])
        XCTAssertEqual(stats.votesCast, 3)
        XCTAssertEqual(records[0].finalText, "agenda con Wendy Ramírez", "La edición manual manda")
        XCTAssertEqual(records[3].finalText, "hola")
    }

    func testRecordsSurviveEncoding() throws {
        let record = RecognitionRecord(locale: "es-CO", onDevice: false, mode: "botón", duration: 1.5, endReason: .recognizerFinal, partialCount: 3,
                                       raw: "hola", cloudText: "hola", cloudSeconds: 0.8, vote: .local)
        let back = try JSONDecoder().decode(RecognitionRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(back, record)
    }
}

// MARK: Correo (borrador) y Whisper

final class MailDraftAndWhisperTests: XCTestCase {
    func testMailtoEncodesEverythingAndCannotInjectParameters() throws {
        let draft = MailDraftContent(to: "Ana@Example.com", subject: "Hola & adiós", body: "Línea 1\nLínea 2 & cc=otro@x.com?bcc=z")
        let url = try XCTUnwrap(draft.mailtoURL)
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:ana@example.com?"))
        XCTAssertFalse(url.absoluteString.contains(" "))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.map(\.name), ["subject", "body"], "El texto del usuario no puede añadir parámetros como cc o bcc")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "body" })?.value, draft.body)
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "subject" })?.value, "Hola & adiós")
    }

    func testADraftWithoutRecipientIsValidAndABadRecipientIsReported() throws {
        let open = MailDraftContent(subject: "Llegaré tarde", body: "Hola, mañana llegaré tarde.")
        XCTAssertNil(open.recipientProblem, "Sin destinatario el usuario lo añade en Correo")
        XCTAssertTrue(try XCTUnwrap(open.mailtoURL).absoluteString.hasPrefix("mailto:?"))
        XCTAssertNotNil(MailDraftContent(to: "mi jefe", body: "x").recipientProblem)
        XCTAssertNil(MailDraftContent(to: "jefe arroba empresa punto com", body: "x").recipientProblem, "Una dirección dictada se entiende")
    }

    func testPlainTextKeepsTheWholeDraftForCopying() {
        let draft = MailDraftContent(to: "ana@example.com", subject: "Hoy", body: "Hola Ana,\n\nLlego a las 9.")
        XCTAssertEqual(draft.plainText, "Para: ana@example.com\nAsunto: Hoy\n\nHola Ana,\n\nLlego a las 9.")
        XCTAssertEqual(MailDraftContent(body: "Solo cuerpo").plainText, "Solo cuerpo")
    }

    func testWhisperMultipartContainsTheExpectedPartsAndTheAudio() {
        let audio = Data("RIFFxxxxWAVEdatos".utf8)
        let body = GroqWhisper.multipartBody(boundary: "BND", audio: audio, prompt: "Wendy Ramírez, Kisameyguy.")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\nwhisper-large-v3-turbo"))
        XCTAssertTrue(text.contains("name=\"language\"\r\n\r\nes"))
        XCTAssertTrue(text.contains("name=\"prompt\"\r\n\r\nWendy Ramírez, Kisameyguy."))
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"dictado.wav\"\r\nContent-Type: audio/wav\r\n\r\nRIFFxxxxWAVEdatos"))
        XCTAssertTrue(text.hasSuffix("\r\n--BND--\r\n"))
        XCTAssertEqual(GroqWhisper.contentType(boundary: "BND"), "multipart/form-data; boundary=BND")
        let noPrompt = String(decoding: GroqWhisper.multipartBody(boundary: "B", audio: audio, prompt: nil), as: UTF8.self)
        XCTAssertFalse(noPrompt.contains("name=\"prompt\""))
        XCTAssertTrue(GroqWhisper.endpoint.hasPrefix("https://"), "Solo HTTPS")
    }

    func testWhisperResponsesAndErrors() {
        XCTAssertEqual(GroqWhisper.parseTranscript(Data(#"{"text":"  hola mundo "}"#.utf8)), "hola mundo")
        XCTAssertNil(GroqWhisper.parseTranscript(Data(#"{"text":""}"#.utf8)))
        XCTAssertNil(GroqWhisper.parseTranscript(Data("basura".utf8)))
        XCTAssertTrue(GroqWhisper.errorMessage(status: 401, body: "").contains("rechazó la clave"))
        XCTAssertTrue(GroqWhisper.errorMessage(status: 413, body: "").contains("largo"))
        XCTAssertTrue(GroqWhisper.errorMessage(status: 429, body: "").contains("límite"))
        XCTAssertTrue(GroqWhisper.errorMessage(status: 503, body: "").contains("problemas"))
    }

    func testWhisperPromptIsShortAndOptional() {
        XCTAssertEqual(GroqWhisper.prompt(from: ["Wendy Ramírez", " ", "Kisameyguy"]), "Wendy Ramírez, Kisameyguy.")
        XCTAssertNil(GroqWhisper.prompt(from: []))
        let many = (0..<100).map { "Nombre\($0)" }
        XCTAssertLessThanOrEqual(GroqWhisper.prompt(from: many)?.count ?? 0, 402)
    }
}
