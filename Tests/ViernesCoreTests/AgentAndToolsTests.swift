import XCTest
@testable import ViernesCore

/// Ejecutor que falla las primeras `failures` veces con un mensaje dado y luego responde bien.
private final class FlakyExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ToolCall] = []
    private var remainingFailures: Int
    private let message: String
    init(failures: Int, message: String) { remainingFailures = failures; self.message = message }
    var calls: [ToolCall] { lock.lock(); defer { lock.unlock() }; return recorded }
    func execute(_ call: ToolCall) async -> ToolOutcome {
        let shouldFail: Bool = lock.withLock {
            recorded.append(call)
            let fail = remainingFailures > 0
            if fail { remainingFailures -= 1 }
            return fail
        }
        return shouldFail ? .failure(message) : .success("Listo.")
    }
}

final class AgentAndToolsTests: XCTestCase {
    private func makeEngine(script: [[String]], executor: ToolExecutor?, confirmer: ConfirmationProvider? = RecordingConfirmer(approve: true),
                            config: ConversationConfig = ConversationConfig()) -> (ConversationEngine, ScriptedEngine) {
        let scripted = ScriptedEngine(script: script)
        return (ConversationEngine(engine: scripted, memory: InMemoryMemoryStore(), executor: executor, confirmer: confirmer, config: config), scripted)
    }

    // MARK: Formato de contactos y calendario

    func testEmailValidation() {
        XCTAssertTrue(ContactFormat.isValidEmail("ana@example.com"))
        XCTAssertTrue(ContactFormat.isValidEmail("ana.lopez+trabajo@mail.example.co"))
        for bad in ["", "ana", "ana@", "@example.com", "ana@example", "ana@@example.com", "ana@example.com, luis@example.com", "ana @example.com", "ana@.com", "ana@example."] {
            XCTAssertFalse(ContactFormat.isValidEmail(bad), bad)
        }
    }

    func testPhoneNormalization() {
        XCTAssertEqual(ContactFormat.normalizedPhone("+57 300 123 4567"), "+573001234567")
        XCTAssertEqual(ContactFormat.normalizedPhone("(300) 123-4567"), "3001234567")
        for bad in ["", "123", "abc12345", "+57+300123456", "300+1234567", "1234567890123456", "tel:3001234567"] {
            XCTAssertNil(ContactFormat.normalizedPhone(bad), bad)
        }
    }

    func testCalendarRangeResolvesRelativeDaysAndClampsLength() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Bogota")!
        let now = try XCTUnwrap(DateParsing.parse("2026-11-05T15:30", timeZone: calendar.timeZone))
        let today = try XCTUnwrap(CalendarRange.resolve(date: "today", days: 1, now: now, calendar: calendar))
        let tomorrow = try XCTUnwrap(CalendarRange.resolve(date: "tomorrow", days: 1, now: now, calendar: calendar))
        XCTAssertEqual(tomorrow.start, today.end, "Mañana empieza donde termina hoy")
        XCTAssertEqual(calendar.component(.day, from: tomorrow.start), 6)
        XCTAssertEqual(calendar.component(.hour, from: tomorrow.start), 0)
        let week = try XCTUnwrap(CalendarRange.resolve(date: "2026-11-10", days: 99, now: now, calendar: calendar))
        XCTAssertEqual(calendar.dateComponents([.day], from: week.start, to: week.end).day, 7, "Máximo 7 días")
        XCTAssertNil(CalendarRange.resolve(date: "dentro de un rato", days: 1, now: now, calendar: calendar))
        XCTAssertTrue(CalendarRange.isValidDateArgument("TODAY"))
        XCTAssertFalse(CalendarRange.isValidDateArgument("2026-11-10T09:00"), "Solo fecha, sin hora")
    }

    /// Los modelos mezclan idiomas: «mañana» llegaba como fecha inválida y el usuario veía un error técnico.
    func testCalendarRangeAcceptsSpanishRelativeDatesAndWeekdays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Bogota")!
        let now = try XCTUnwrap(DateParsing.parse("2026-11-05T15:30", timeZone: calendar.timeZone))   // jueves
        func day(_ text: String) throws -> Int {
            let range = try XCTUnwrap(CalendarRange.resolve(date: text, days: 1, now: now, calendar: calendar), text)
            return calendar.component(.day, from: range.start)
        }
        XCTAssertEqual(try day("hoy"), 5)
        XCTAssertEqual(try day("mañana"), 6)
        XCTAssertEqual(try day("Mañana"), 6)
        XCTAssertEqual(try day("pasado mañana"), 7)
        XCTAssertEqual(try day("ayer"), 4)
        XCTAssertEqual(try day("el viernes"), 6, "El próximo viernes")
        XCTAssertEqual(try day("jueves"), 12, "Dicho un jueves, «jueves» es el siguiente")
        XCTAssertEqual(try day("domingo"), 8)
        for text in ["mañana", "hoy", "viernes", "pasado mañana", "tomorrow", "2026-11-10"] {
            XCTAssertTrue(CalendarRange.isValidDateArgument(text), text)
        }
        XCTAssertNoThrow(try ToolValidator.validate(ToolCall(name: "list_events", args: ["date": "mañana"])))
    }

    // MARK: Validación

    func testNewToolsAreValidatedAndClassifiedByRisk() throws {
        for name in ["list_events", "find_contact"] {
            XCTAssertEqual(ToolCatalog.definition(named: name)?.risk, .safe, "\(name) es una consulta: el permiso se da en Privacidad")
        }
        for name in ["compose_email", "compose_message", "call_phone"] {
            XCTAssertEqual(ToolCatalog.definition(named: name)?.risk, .reversible, "\(name) solo prepara un borrador o abre el marcador")
        }
        XCTAssertNoThrow(try ToolValidator.validate(ToolCall(name: "list_events", args: ["date": "tomorrow", "days": "2"])))
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "list_events", args: ["date": "cuando quieras"])))
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "list_events", args: ["date": "today", "days": "30"])))
        XCTAssertNoThrow(try ToolValidator.validate(ToolCall(name: "compose_email", args: ["body": "Hola", "to": "ana@example.com", "subject": "Reunión"])))
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "compose_email", args: ["body": "Hola", "to": "no-es-correo"])))
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "compose_email", args: ["body": "Hola", "subject": "uno\ndos"])))
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "compose_email", args: [:])), "Falta el cuerpo")
        let message = try ToolValidator.validate(ToolCall(name: "compose_message", args: ["body": "Voy tarde", "to": "+57 300 123 4567", "app": "WhatsApp"]))
        XCTAssertEqual(message.args["app"], "whatsapp")
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "compose_message", args: ["body": "x", "app": "telegram"])))
        let call = try ToolValidator.validate(ToolCall(name: "call_phone", args: ["number": "(300) 123-4567"]))
        XCTAssertEqual(call.args["number"], "3001234567", "El número se normaliza antes de usarse en la URL")
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "call_phone", args: ["number": "tel:123"])))
    }

    func testConfirmationTextShowsExactlyWhatWillBePrepared() throws {
        let email = try ToolValidator.validate(ToolCall(name: "compose_email", args: ["body": "Llego a las 9", "to": "ana@example.com", "subject": "Hoy"]))
        let summary = ConversationEngine.summary(for: email)
        XCTAssertTrue(summary.contains("ana@example.com"))
        XCTAssertTrue(summary.contains("Hoy"))
        XCTAssertTrue(summary.contains("Llego a las 9"))
        XCTAssertEqual(ConversationEngine.confirmationTitle("list_events"), "Leer tu calendario")
        XCTAssertEqual(ConversationEngine.confirmationTitle("compose_email"), "Preparar borrador de correo")
    }

    // MARK: Permisos de lectura apagados por defecto

    func testReadToolsDoNotExistUntilTheUserEnablesThem() async {
        let (off, s1) = makeEngine(script: [["Ok."]], executor: RecordingExecutor())
        _ = await collect(await off.send("Hola"))
        XCTAssertFalse(s1.requests[0].system.contains("list_events("))
        XCTAssertFalse(s1.requests[0].system.contains("find_contact("))
        XCTAssertTrue(s1.requests[0].system.contains("Permisos de lectura apagados"), "Debe saber que no puede y decirlo")

        let (on, s2) = makeEngine(script: [["Ok."]], executor: RecordingExecutor(),
                                  config: ConversationConfig(calendarReadEnabled: true, contactsReadEnabled: true))
        _ = await collect(await on.send("Hola"))
        XCTAssertTrue(s2.requests[0].system.contains("list_events("))
        XCTAssertTrue(s2.requests[0].system.contains("find_contact("))
        XCTAssertFalse(s2.requests[0].system.contains("Permisos de lectura apagados"))
    }

    func testCallingADisabledReadToolIsRejectedWithoutExecuting() async {
        let executor = RecordingExecutor()
        let call = #"<tool>{"name":"list_events","args":{"date":"tomorrow"}}</tool>"#
        let (engine, _) = makeEngine(script: [[call], ["No puedo leer tu calendario."]], executor: executor)
        let events = await collect(await engine.send("¿Qué tengo mañana?"))
        XCTAssertTrue(executor.calls.isEmpty)
        if case .failed? = events.completedMessage?.actions.first?.outcome {} else { XCTFail("Debía rechazarse") }
    }

    // MARK: Agente: ejecución paralela, reintento, encadenado

    func testIndependentSafeToolsRunTogetherAndKeepTheirOrder() async {
        let executor = RecordingExecutor()
        let both = #"<tool>{"name":"device_info","args":{"what":"battery"}}</tool>"# + "\n" + #"<tool>{"name":"get_weather","args":{"city":"Bogotá"}}</tool>"#
        let confirmer = RecordingConfirmer(approve: true)
        let (engine, scripted) = makeEngine(script: [[both], ["Todo listo."]], executor: executor, confirmer: confirmer)
        let events = await collect(await engine.send("Dime la batería y el clima de Bogotá"))
        XCTAssertEqual(Set(executor.calls.map(\.name)), ["device_info", "get_weather"])
        XCTAssertEqual(events.actionRecords.map(\.tool), ["device_info", "get_weather"], "Los registros conservan el orden de las llamadas")
        XCTAssertTrue(confirmer.requests.isEmpty, "Las seguras no piden confirmación")
        XCTAssertEqual(scripted.requests.count, 2)
        let started = events.compactMap { event -> String? in if case .toolStarted(let name) = event { return name } else { return nil } }
        XCTAssertEqual(Set(started), ["device_info", "get_weather"])
    }

    func testTransientFailureIsRetriedOnceAndPermanentOnesAreNot() async {
        let weather = #"<tool>{"name":"get_weather","args":{"city":"Bogotá"}}</tool>"#
        let flaky = FlakyExecutor(failures: 1, message: "Sin conexión a internet: no puedo consultar el clima.")
        let (engine, _) = makeEngine(script: [[weather], ["Hecho."]], executor: flaky)
        let events = await collect(await engine.send("Clima de Bogotá"))
        XCTAssertEqual(flaky.calls.count, 2, "Un fallo de red se reintenta una vez")
        XCTAssertEqual(events.actionRecords.first?.outcome, .executed("Listo."))

        let permanent = FlakyExecutor(failures: 5, message: "No encontré una ciudad llamada «Xyz».")
        let (engine2, _) = makeEngine(script: [[weather], ["No la encontré."]], executor: permanent)
        _ = await collect(await engine2.send("Clima de Xyz"))
        XCTAssertEqual(permanent.calls.count, 1, "Un error permanente no se reintenta")

        let alwaysOffline = FlakyExecutor(failures: 5, message: "Sin conexión a internet")
        let (engine3, _) = makeEngine(script: [[weather], ["Sin internet."]], executor: alwaysOffline)
        let events3 = await collect(await engine3.send("Clima de Bogotá"))
        XCTAssertEqual(alwaysOffline.calls.count, 2, "Como máximo un reintento")
        if case .failed? = events3.actionRecords.first?.outcome {} else { XCTFail("Debe reportar el fallo real") }
    }

    func testToolsThatNeedConfirmationAreNeverRetried() async {
        let reminder = #"<tool>{"name":"run_shortcut","args":{"name":"Salir temprano"}}</tool>"#
        let flaky = FlakyExecutor(failures: 5, message: "Sin conexión a internet")
        let confirmer = RecordingConfirmer(approve: true)
        let (engine, _) = makeEngine(script: [[reminder], ["No se pudo."]], executor: flaky, confirmer: confirmer)
        _ = await collect(await engine.send("Recuérdame salir temprano"))
        XCTAssertEqual(flaky.calls.count, 1)
        XCTAssertEqual(confirmer.requests.count, 1, "Una sola confirmación, sin repetir")
    }

    func testTransientFailureClassifier() {
        XCTAssertTrue(ConversationEngine.isTransientFailure("Sin conexión a internet: no puedo consultar el clima."))
        XCTAssertTrue(ConversationEngine.isTransientFailure("El servicio de clima no respondió."))
        XCTAssertFalse(ConversationEngine.isTransientFailure("No encontré una ciudad llamada «Xyz»."))
        XCTAssertFalse(ConversationEngine.isTransientFailure("No tengo permiso para Recordatorios."))
    }

    /// El ejemplo pedido: leer la agenda de mañana y, con datos reales, proponer un recordatorio que el usuario confirma.
    func testReadCalendarThenCreateReminderChainsWithRealResultsAndNoNeedlessQuestions() async {
        let read = #"<tool>{"name":"list_events","args":{"date":"tomorrow"}}</tool>"#
        let remind = #"<tool>{"name":"create_reminder","args":{"title":"Salir para la reunión de las 9","due":"2026-11-06T08:15"}}</tool>"#
        let executor = RecordingExecutor()
        executor.outcome = .success("Eventos (1), en orden:\n• jue 6 nov 09:00–10:00: Reunión con Ana")
        let confirmer = RecordingConfirmer(approve: true)
        let (engine, scripted) = makeEngine(script: [[read], [remind], ["Listo: te avisaré a las 8:15."]], executor: executor, confirmer: confirmer,
                                            config: ConversationConfig(calendarReadEnabled: true))
        let events = await collect(await engine.send("Revisa mi agenda de mañana y recuérdame salir con tiempo"))

        XCTAssertEqual(executor.calls.map(\.name), ["list_events", "create_reminder"], "Primero consulta, luego actúa")
        XCTAssertTrue(confirmer.requests.isEmpty, "Consultar la agenda (con permiso) y crear un recordatorio claro no piden confirmación")
        XCTAssertEqual(scripted.requests.count, 3)
        XCTAssertTrue((scripted.requests[1].turns.last?.content ?? "").contains("Reunión con Ana"), "El modelo ve el resultado REAL antes de actuar")
        XCTAssertEqual(events.completedMessage?.text, "Listo: te avisaré a las 8:15.")
        XCTAssertEqual(events.completedMessage?.actions.count, 2)
    }

    func testDecliningAnExternalActionStopsIt() async {
        let shortcut = #"<tool>{"name":"run_shortcut","args":{"name":"Enviar ubicación"}}</tool>"#
        let executor = RecordingExecutor()
        let (engine, scripted) = makeEngine(script: [[shortcut], ["De acuerdo, no lo ejecuto."]], executor: executor,
                                            confirmer: RecordingConfirmer(approve: false))
        let events = await collect(await engine.send("Ejecuta mi atajo Enviar ubicación"))
        XCTAssertTrue(executor.calls.isEmpty, "Sin confirmación no se ejecuta")
        XCTAssertEqual(events.completedMessage?.actions.first?.outcome, .declined)
        XCTAssertTrue((scripted.requests[1].turns.last?.content ?? "").contains("RECHAZADA"))
    }

    // MARK: Resultados internos y errores técnicos

    func testValidationFailuresAreHiddenFromTheUserButVisibleToTheModel() async {
        let bad = #"<tool>{"name":"list_events","args":{"date":"cuando quieras"}}</tool>"#
        let executor = RecordingExecutor()
        let (engine, scripted) = makeEngine(script: [[bad], ["¿De qué día quieres ver la agenda?"]], executor: executor,
                                            config: ConversationConfig(calendarReadEnabled: true))
        let events = await collect(await engine.send("Mira mi agenda"))
        XCTAssertTrue(executor.calls.isEmpty)
        let record = try? XCTUnwrap(events.actionRecords.first)
        XCTAssertEqual(record?.isVisible, false, "Un error de validación no se enseña al usuario")
        XCTAssertTrue((scripted.requests[1].turns.last?.content ?? "").contains("FALLÓ"), "El modelo sí lo ve para corregir")
        XCTAssertEqual(events.completedMessage?.text, "¿De qué día quieres ver la agenda?")
    }

    func testRealExecutionFailuresStayVisible() async {
        let weather = #"<tool>{"name":"get_weather","args":{"city":"Xyz"}}</tool>"#
        let executor = RecordingExecutor()
        executor.outcome = .failure("No encontré una ciudad llamada «Xyz».")
        let (engine, _) = makeEngine(script: [[weather], ["No encontré esa ciudad."]], executor: executor)
        let events = await collect(await engine.send("Clima de Xyz"))
        XCTAssertEqual(events.actionRecords.first?.isVisible, true)
    }

    func testDisabledReadToolTellsTheModelHowToEnableItAndShowsNothingTechnical() async {
        let read = #"<tool>{"name":"list_events","args":{"date":"mañana"}}</tool>"#
        let (engine, scripted) = makeEngine(script: [[read], ["Activa la lectura del calendario en Privacidad."]], executor: RecordingExecutor())
        let events = await collect(await engine.send("¿Qué tengo mañana?"))
        XCTAssertEqual(events.actionRecords.first?.isVisible, false)
        XCTAssertTrue((scripted.requests[1].turns.last?.content ?? "").contains("Privacidad"))
    }

    func testEngineSendsDiagnosticsInsteadOfShowingTechnicalErrors() async {
        final class Sink: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [String] = []
            func add(_ text: String) { lock.withLock { items.append(text) } }
            var all: [String] { lock.withLock { items } }
        }
        let sink = Sink()
        let bad = #"<tool>{"name":"get_weather","args":{}}</tool>"#
        let (engine, _) = makeEngine(script: [[bad], ["¿De qué ciudad?"]], executor: RecordingExecutor())
        await engine.setDiagnostics { sink.add($0) }
        _ = await collect(await engine.send("Clima"))
        XCTAssertTrue(sink.all.contains { $0.contains("validación de get_weather") }, "El detalle técnico va a diagnósticos: \(sink.all)")
    }

    func testToolResultEnvelopeIsInternalAndEchoesNeverReachTheConversation() async {
        let wrapped = Persona.wrapResults(["- get_weather: ÉXITO. Hay 18 grados."])
        XCTAssertTrue(wrapped.hasPrefix(Persona.resultOpen))
        XCTAssertTrue(wrapped.contains(Persona.resultClose))
        XCTAssertTrue(wrapped.contains("no lo copies"))

        // El modelo repite el sobre y una línea de resultado: nada de eso debe llegar al usuario.
        let echo = "<tool_result>\n- get_weather: ÉXITO. Hay 18 grados.\n</tool_result>\nEn Bogotá hay 18 grados."
        let weather = #"<tool>{"name":"get_weather","args":{"city":"Bogotá"}}</tool>"#
        let (engine, _) = makeEngine(script: [[weather], [echo]], executor: RecordingExecutor())
        let events = await collect(await engine.send("¿Qué clima hace en Bogotá?"))
        let text = events.completedMessage?.text ?? ""
        XCTAssertEqual(text, "En Bogotá hay 18 grados.")
        for leak in ["tool_result", "RESULTADO", "get_weather", "ÉXITO", "{\"name\""] {
            XCTAssertFalse(text.contains(leak), leak)
        }
        let deltas = events.compactMap { event -> String? in if case .delta(let piece) = event { return piece } else { return nil } }.joined()
        XCTAssertFalse(deltas.contains("ÉXITO"), "Tampoco durante el streaming (voz): \(deltas)")
    }

    func testLegacyBracketMarkerEchoIsRemovedEvenWhenSplitAcrossChunks() async {
        let chunks = ["[RESULTADO_", "HERRAMIENTA]\n- list_events: ÉXITO. No hay eventos", " en ese rango.\n\nMañana no tienes eventos."]
        let (engine, _) = makeEngine(script: [chunks], executor: RecordingExecutor())
        let events = await collect(await engine.send("¿Qué tengo mañana?"))
        XCTAssertEqual(events.completedMessage?.text, "Mañana no tienes eventos.")
    }
}
