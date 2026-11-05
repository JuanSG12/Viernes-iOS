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
        XCTAssertNil(CalendarRange.resolve(date: "pasado mañana", days: 1, now: now, calendar: calendar))
        XCTAssertTrue(CalendarRange.isValidDateArgument("TODAY"))
        XCTAssertFalse(CalendarRange.isValidDateArgument("2026-11-10T09:00"), "Solo fecha, sin hora")
    }

    // MARK: Validación

    func testNewToolsAreValidatedAndAllSensitive() throws {
        for name in ["list_events", "find_contact", "compose_email", "compose_message", "call_phone"] {
            XCTAssertEqual(ToolCatalog.definition(named: name)?.risk, .sensitive, "\(name) debe pedir confirmación")
        }
        XCTAssertNoThrow(try ToolValidator.validate(ToolCall(name: "list_events", args: ["date": "tomorrow", "days": "2"])))
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "list_events", args: ["date": "ayer"])))
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

    func testSensitiveToolsAreNeverRetried() async {
        let reminder = #"<tool>{"name":"create_reminder","args":{"title":"Salir temprano"}}</tool>"#
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
    func testReadCalendarThenCreateReminderChainsWithRealResultsAndTwoConfirmations() async {
        let read = #"<tool>{"name":"list_events","args":{"date":"tomorrow"}}</tool>"#
        let remind = #"<tool>{"name":"create_reminder","args":{"title":"Salir para la reunión de las 9","due":"2026-11-06T08:15"}}</tool>"#
        let executor = RecordingExecutor()
        executor.outcome = .success("Eventos (1), en orden:\n• jue 6 nov 09:00–10:00: Reunión con Ana")
        let confirmer = RecordingConfirmer(approve: true)
        let (engine, scripted) = makeEngine(script: [[read], [remind], ["Listo: te avisaré a las 8:15."]], executor: executor, confirmer: confirmer,
                                            config: ConversationConfig(calendarReadEnabled: true))
        let events = await collect(await engine.send("Revisa mi agenda de mañana y recuérdame salir con tiempo"))

        XCTAssertEqual(executor.calls.map(\.name), ["list_events", "create_reminder"], "Primero consulta, luego actúa")
        XCTAssertEqual(confirmer.requests.map(\.tool), ["list_events", "create_reminder"], "Cada acción sensible pide su confirmación")
        XCTAssertEqual(scripted.requests.count, 3)
        XCTAssertTrue((scripted.requests[1].turns.last?.content ?? "").contains("Reunión con Ana"), "El modelo ve el resultado REAL antes de actuar")
        XCTAssertEqual(events.completedMessage?.text, "Listo: te avisaré a las 8:15.")
        XCTAssertEqual(events.completedMessage?.actions.count, 2)
    }

    func testDecliningTheCalendarReadStopsTheChain() async {
        let read = #"<tool>{"name":"list_events","args":{"date":"today"}}</tool>"#
        let executor = RecordingExecutor()
        let (engine, scripted) = makeEngine(script: [[read], ["De acuerdo, no leo tu calendario."]], executor: executor,
                                            confirmer: RecordingConfirmer(approve: false), config: ConversationConfig(calendarReadEnabled: true))
        let events = await collect(await engine.send("¿Qué tengo hoy?"))
        XCTAssertTrue(executor.calls.isEmpty, "Sin confirmación no se lee nada")
        XCTAssertEqual(events.completedMessage?.actions.first?.outcome, .declined)
        XCTAssertTrue((scripted.requests[1].turns.last?.content ?? "").contains("RECHAZADA"))
    }
}
