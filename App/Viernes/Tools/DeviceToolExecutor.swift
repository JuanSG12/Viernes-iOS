import UIKit
import EventKit
import Contacts
import ViernesCore

/// Ejecuta las herramientas permitidas por iOS. Cada resultado describe lo que REALMENTE ocurrió (o por qué no).
/// Las validaciones y confirmaciones ya se hicieron en `ConversationEngine`; aquí solo se aplican las APIs públicas de Apple.
@MainActor
final class DeviceToolExecutor: ToolExecutor {
    private let eventStore = EKEventStore()
    private let claude: ClaudeCoordinator
    private let mailDrafts: MailDraftCenter
    private let ledger: EventLedger

    init(claude: ClaudeCoordinator, mailDrafts: MailDraftCenter? = nil, ledger: EventLedger? = nil) {
        self.claude = claude
        self.mailDrafts = mailDrafts ?? MailDraftCenter()
        self.ledger = ledger ?? EventLedger()
    }

    /// Borra el registro local de eventos creados por Viernes (al borrar todos los datos).
    func clearLedger() { ledger.removeAll() }

    /// Localiza el evento real ANTES de confirmar o ejecutar una modificación o eliminación (ver `ToolExecutor.resolve`).
    func resolve(_ call: ToolCall) async -> ToolResolution? {
        guard call.name == "update_event" || call.name == "delete_event" else { return nil }
        switch await locateEvent(call.args) {
        case .blocked(let message, let askUser):
            return .blocked(message, askUser: askUser)
        case .found(_, _, let info):
            if let blocked = modificationBlock(info) { return .blocked(blocked, askUser: false) }
            var pinned = call.args
            pinned["event_id"] = info.id
            let calendar = Calendar.current
            let target = CalendarEventMatcher.describe(info, calendar: calendar)
            if call.name == "delete_event" {
                return .ready(ToolCall(name: call.name, args: pinned), detail: "Eliminar \(target)")
            }
            switch EventChanges.from(args: call.args, original: info, now: Date(), calendar: calendar) {
            case .failure(let error):
                return .blocked(error.message, askUser: false)
            case .success(let changes):
                guard !changes.isEmpty else { return .blocked("No se indicó ningún cambio para el evento.", askUser: true) }
                return .ready(ToolCall(name: call.name, args: pinned), detail: "Modificar \(target) → \(changes.summaryText)")
            }
        }
    }

    func execute(_ call: ToolCall) async -> ToolOutcome {
        switch call.name {
        case "update_event": return await updateEvent(call.args)
        case "delete_event": return await deleteEvent(call.args)
        case "open_app": return await openApp(call.args["app"] ?? "")
        case "open_url": return await openURL(call.args["url"] ?? "")
        case "create_reminder": return await createReminder(call.args)
        case "list_reminders": return await listReminders(limit: Int(call.args["limit"] ?? "") ?? 10)
        case "complete_reminder": return await completeReminder(title: call.args["title"] ?? "")
        case "create_event": return await createEvent(call.args)
        case "run_shortcut": return await runShortcut(name: call.args["name"] ?? "", input: call.args["input"])
        case "device_info": return deviceInfo(what: (call.args["what"] ?? "all").lowercased())
        case "ask_claude": return await claude.ask(call.args["prompt"] ?? "")
        case "get_weather": return await weather(city: call.args["city"] ?? "")
        case "list_events": return await listEvents(date: call.args["date"] ?? "today", days: Int(call.args["days"] ?? "") ?? 1)
        case "find_contact": return await findContact(name: call.args["name"] ?? "")
        case "compose_email": return await composeEmail(call.args)
        case "compose_message": return await composeMessage(call.args)
        case "call_phone": return await callPhone(call.args)
        default: return .failure("Herramienta no implementada: \(call.name).")
        }
    }

    // MARK: Clima (Open-Meteo, sin clave)

    private static let weatherSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    private func weather(city: String) async -> ToolOutcome {
        guard let geocodingURL = WeatherService.geocodingURL(city: city) else { return .failure("Nombre de ciudad no válido.") }
        do {
            let (geoData, geoResponse) = try await Self.weatherSession.data(from: geocodingURL)
            guard (geoResponse as? HTTPURLResponse)?.statusCode == 200 else { return .failure("El servicio de clima no respondió.") }
            guard let place = WeatherService.parsePlace(geoData) else { return .failure("No encontré una ciudad llamada «\(city)».") }
            guard let forecastURL = WeatherService.forecastURL(latitude: place.latitude, longitude: place.longitude) else {
                return .failure("No pude construir la consulta del clima.")
            }
            let (data, response) = try await Self.weatherSession.data(from: forecastURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .failure("El servicio de clima no respondió.") }
            guard let text = WeatherService.summary(place: place, forecast: data) else { return .failure("No pude interpretar el pronóstico.") }
            // Texto real para el modelo + tarjeta nativa con los mismos datos de Open-Meteo.
            if let card = WeatherService.card(place: place, forecast: data) { return .card(text, card) }
            return .success(text)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(error.code) {
            return .failure("Sin conexión a internet: no puedo consultar el clima.")
        } catch let error as URLError where error.code == .timedOut {
            return .failure("El servicio de clima tardó demasiado en responder.")
        } catch {
            Diagnostics.shared.log("clima: \(error.localizedDescription)")
            return .failure("No pude consultar el clima ahora mismo.")
        }
    }

    // MARK: Acceso a Calendario y Recordatorios (estado REAL antes de pedir nada)

    private static let calendarSettingsHint = "Actívalo en Ajustes › Viernes › Calendarios y elige «Acceso completo»."

    private func label(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "sin solicitar"
        case .restricted: return "restringido"
        case .denied: return "denegado"
        case .fullAccess: return "acceso completo"
        case .writeOnly: return "solo escritura"
        case .authorized: return "autorizado (antiguo)"
        @unknown default: return "desconocido"
        }
    }

    /// `nil` si se puede LEER el calendario; si no, un mensaje claro de qué hacer. Pide el permiso solo si hace falta y se puede.
    private func calendarReadProblem() async -> String? {
        let before = EKEventStore.authorizationStatus(for: .event)
        Diagnostics.shared.log("calendario: estado antes = \(label(before))")
        switch before {
        case .fullAccess, .authorized:
            return nil
        case .denied, .restricted:
            return "Viernes no tiene permiso para leer tu calendario. \(Self.calendarSettingsHint)"
        case .notDetermined, .writeOnly:
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                Diagnostics.shared.log("calendario: solicitud de acceso completo → \(granted)")
            } catch {
                Diagnostics.shared.log("calendario: error al solicitar acceso completo: \(error.localizedDescription)")
            }
            let after = EKEventStore.authorizationStatus(for: .event)
            Diagnostics.shared.log("calendario: estado después = \(label(after))")
            switch after {
            case .fullAccess, .authorized: return nil
            case .writeOnly: return "Viernes solo tiene permiso para AÑADIR eventos, no para leerlos. \(Self.calendarSettingsHint)"
            default: return "Viernes no tiene permiso para leer tu calendario. \(Self.calendarSettingsHint)"
            }
        @unknown default:
            return "No pude comprobar el permiso del calendario. \(Self.calendarSettingsHint)"
        }
    }

    /// Para AÑADIR eventos basta con escritura (o acceso completo).
    private func calendarWriteProblem() async -> String? {
        let before = EKEventStore.authorizationStatus(for: .event)
        switch before {
        case .fullAccess, .writeOnly, .authorized: return nil
        case .denied, .restricted: return "Viernes no tiene permiso para añadir eventos. Actívalo en Ajustes › Viernes › Calendarios."
        case .notDetermined:
            do { _ = try await eventStore.requestWriteOnlyAccessToEvents() } catch {
                Diagnostics.shared.log("calendario: error al solicitar escritura: \(error.localizedDescription)")
            }
            let after = EKEventStore.authorizationStatus(for: .event)
            return (after == .writeOnly || after == .fullAccess) ? nil : "Viernes no tiene permiso para añadir eventos. Actívalo en Ajustes › Viernes › Calendarios."
        @unknown default: return "No pude comprobar el permiso del calendario."
        }
    }

    private func remindersProblem() async -> String? {
        let before = EKEventStore.authorizationStatus(for: .reminder)
        switch before {
        case .fullAccess, .authorized: return nil
        case .denied, .restricted, .writeOnly:
            return "Viernes no tiene permiso para usar tus recordatorios. Actívalo en Ajustes › Viernes › Recordatorios."
        case .notDetermined:
            do { _ = try await eventStore.requestFullAccessToReminders() } catch {
                Diagnostics.shared.log("recordatorios: error al solicitar acceso: \(error.localizedDescription)")
            }
            let after = EKEventStore.authorizationStatus(for: .reminder)
            return (after == .fullAccess || after == .authorized) ? nil : "Viernes no tiene permiso para usar tus recordatorios. Actívalo en Ajustes › Viernes › Recordatorios."
        @unknown default: return "No pude comprobar el permiso de recordatorios."
        }
    }

    /// Solicita acceso completo al calendario desde la pantalla de Permisos y devuelve un informe REAL del resultado.
    func calendarDiagnosis() async -> String {
        var lines: [String] = []
        lines.append("Estado antes: \(label(EKEventStore.authorizationStatus(for: .event)))")
        let problem = await calendarReadProblem()
        lines.append("Estado ahora: \(label(EKEventStore.authorizationStatus(for: .event)))")
        if let problem = problem {
            lines.append("Resultado: no se puede leer. \(problem)")
            return lines.joined(separator: "\n")
        }
        let store = EKEventStore()          // almacén nuevo, creado DESPUÉS de conceder el permiso
        let calendars = store.calendars(for: .event)
        lines.append("Calendarios visibles: \(calendars.count)" + (calendars.isEmpty ? "" : " (" + calendars.prefix(6).map(\.title).joined(separator: ", ") + ")"))
        let now = Date()
        let events = store.events(matching: store.predicateForEvents(withStart: now, end: now.addingTimeInterval(7 * 86_400), calendars: nil))
        lines.append("Eventos en los próximos 7 días: \(events.count)")
        if calendars.isEmpty {
            lines.append("Aviso: iOS no muestra ningún calendario. Revisa Ajustes › Calendario › Cuentas (que haya al menos una cuenta con calendarios activos).")
        } else {
            lines.append("Resultado: el acceso funciona.")
        }
        Diagnostics.shared.log("calendario: diagnóstico → \(calendars.count) calendarios, \(events.count) eventos")
        return lines.joined(separator: "\n")
    }

    // MARK: Apps y enlaces

    private func openApp(_ name: String) async -> ToolOutcome {
        guard let link = AppLinkCatalog.resolve(name) else { return .failure("App no permitida: \(name).") }
        let opened = await UIApplication.shared.open(link.url)
        return opened ? .success("Abrí \(link.displayName).") : .failure("No pude abrir \(link.displayName); puede que no esté instalada.")
    }

    private func openURL(_ string: String) async -> ToolOutcome {
        guard let url = URL(string: string) else { return .failure("Enlace inválido.") }
        let opened = await UIApplication.shared.open(url)
        return opened ? .success("Abrí el enlace.") : .failure("No pude abrir el enlace.")
    }

    private func runShortcut(name: String, input: String?) async -> ToolOutcome {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        var items = [URLQueryItem(name: "name", value: name)]
        if let input = input { items += [URLQueryItem(name: "input", value: "text"), URLQueryItem(name: "text", value: input)] }
        components.queryItems = items
        guard let url = components.url else { return .failure("No pude construir el enlace del Atajo.") }
        let opened = await UIApplication.shared.open(url)
        return opened
            ? .success("Pedí a Atajos ejecutar «\(name)». Viernes no recibe el resultado del atajo, así que no puedo confirmar que terminó bien.")
            : .failure("No pude abrir Atajos.")
    }

    // MARK: Recordatorios y calendario (EventKit)

    private func createReminder(_ args: [String: String]) async -> ToolOutcome {
        if let problem = await remindersProblem() { return .failure(problem) }
        do {
            guard let calendar = eventStore.defaultCalendarForNewReminders() else { return .failure("No hay una lista de recordatorios por defecto.") }
            let reminder = EKReminder(eventStore: eventStore)
            reminder.title = args["title"] ?? "Recordatorio"
            reminder.notes = args["notes"]
            reminder.calendar = calendar
            if let dueString = args["due"], let due = DateParsing.parse(dueString) {
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                reminder.addAlarm(EKAlarm(absoluteDate: due))
            }
            try eventStore.save(reminder, commit: true)
            return .success("Recordatorio creado en «\(calendar.title)»: \(reminder.title ?? "")" + (args["due"].map { " (\($0))" } ?? ""))
        } catch {
            Diagnostics.shared.log("recordatorios: error al crear: \(error.localizedDescription)")
            return .failure("No pude crear el recordatorio. Inténtalo de nuevo.")
        }
    }

    private func incompleteReminders() async throws -> [EKReminder] {
        if let problem = await remindersProblem() { throw ToolError.denied(problem) }
        let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in continuation.resume(returning: reminders ?? []) }
        }
    }

    private func listReminders(limit: Int) async -> ToolOutcome {
        do {
            let reminders = try await incompleteReminders()
            guard !reminders.isEmpty else { return .success("No hay recordatorios pendientes.") }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "es_CO")
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let lines = reminders.prefix(max(1, min(limit, 20))).map { reminder -> String in
                let dueDate = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
                let due = dueDate.map { " — \(formatter.string(from: $0))" } ?? ""
                return "• \(reminder.title ?? "(sin título)")\(due)"
            }
            return .success("Pendientes (\(reminders.count) en total):\n" + lines.joined(separator: "\n"))
        } catch ToolError.denied(let message) {
            return .failure(message)
        } catch {
            Diagnostics.shared.log("recordatorios: error al leer: \(error.localizedDescription)")
            return .failure("No pude leer tus recordatorios ahora mismo.")
        }
    }

    private func completeReminder(title: String) async -> ToolOutcome {
        do {
            let query = TextNormalizer.fold(title)
            let matches = try await incompleteReminders().filter { TextNormalizer.fold($0.title ?? "").contains(query) }
            guard !matches.isEmpty else { return .failure("No encontré un recordatorio pendiente que coincida con «\(title)».") }
            guard matches.count == 1, let reminder = matches.first else {
                let names = matches.prefix(5).map { "«\($0.title ?? "")»" }.joined(separator: ", ")
                return .failure("Hay varios que coinciden (\(names)). Dime cuál.")
            }
            reminder.isCompleted = true
            try eventStore.save(reminder, commit: true)
            return .success("Marqué como completado: «\(reminder.title ?? "")».")
        } catch ToolError.denied(let message) {
            return .failure(message)
        } catch {
            Diagnostics.shared.log("recordatorios: error al completar: \(error.localizedDescription)")
            return .failure("No pude completar el recordatorio.")
        }
    }

    private func createEvent(_ args: [String: String]) async -> ToolOutcome {
        // Para AÑADIR basta el acceso de solo escritura (la lectura es opcional y se activa aparte en Privacidad).
        if let problem = await calendarWriteProblem() { return .failure(problem) }
        do {
            guard let start = DateParsing.parse(args["start"] ?? "") else { return .failure("La fecha de inicio no es válida.") }
            let minutes = Int(args["duration_minutes"] ?? "") ?? 60
            let event = EKEvent(eventStore: eventStore)
            event.title = args["title"] ?? "Evento"
            event.startDate = start
            event.endDate = start.addingTimeInterval(TimeInterval(minutes * 60))
            event.location = args["location"]
            // Con acceso de solo escritura, iOS puede no exponer el calendario por defecto; si no, usa el predeterminado del sistema.
            if let calendar = eventStore.defaultCalendarForNewEvents { event.calendar = calendar }
            try eventStore.save(event, span: .thisEvent, commit: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "es_CO")
            formatter.dateStyle = .full
            formatter.timeStyle = .short
            // Se recuerda el identificador REAL de EventKit (para «elimina el que acabamos de crear») y, si se puede leer,
            // se comprueba con un almacén nuevo que el evento quedó guardado.
            var verified = ""
            if let id = event.eventIdentifier {
                ledger.record(CreatedEventRecord(id: id, title: event.title ?? "", start: start, createdAt: Date()))
                if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
                    if EKEventStore().event(withIdentifier: id) != nil {
                        verified = " Comprobé que quedó guardado" + (event.calendar.map { " en el calendario «\($0.title)»" } ?? "") + "."
                    } else {
                        Diagnostics.shared.log("calendario: el evento recién creado no se pudo volver a leer")
                    }
                }
            }
            return .success("Evento creado: \(event.title ?? "") el \(formatter.string(from: start)) (\(minutes) min)." + verified)
        } catch {
            Diagnostics.shared.log("calendario: error al crear evento: \(error.localizedDescription)")
            return .failure("No pude crear el evento. Inténtalo de nuevo.")
        }
    }

    // MARK: Modificar y eliminar eventos existentes (EventKit)

    private enum EventLocation {
        case found(EKEvent, EKEventStore, CalendarEventInfo)
        case blocked(String, askUser: Bool)
    }

    /// Identificador que Viernes entrega al modelo: el de EventKit; en eventos repetidos se añade la hora de la ocurrencia
    /// (todas las ocurrencias comparten el identificador de EventKit).
    private static func publicID(_ event: EKEvent) -> String? {
        guard let base = event.eventIdentifier else { return nil }
        return event.hasRecurrenceRules ? "\(base)#\(Int(event.startDate.timeIntervalSince1970))" : base
    }

    private static func info(_ event: EKEvent) -> CalendarEventInfo? {
        guard let id = publicID(event), let start = event.startDate, let end = event.endDate else { return nil }
        return CalendarEventInfo(id: id, title: event.title ?? "(sin título)", start: start, end: end, location: event.location ?? "",
                                 calendarTitle: event.calendar?.title ?? "", isAllDay: event.isAllDay,
                                 isRecurring: event.hasRecurrenceRules, allowsModifications: event.calendar?.allowsContentModifications ?? true)
    }

    /// Busca un evento por su identificador público dentro del almacén dado (nil si ya no existe).
    private func event(forID id: String, in store: EKEventStore) -> EKEvent? {
        if let separator = id.lastIndex(of: "#"), let stamp = TimeInterval(id[id.index(after: separator)...]) {
            let base = String(id[..<separator])
            let start = Date(timeIntervalSince1970: stamp)
            let predicate = store.predicateForEvents(withStart: start.addingTimeInterval(-60), end: start.addingTimeInterval(86_400), calendars: nil)
            return store.events(matching: predicate).first { $0.eventIdentifier == base && abs($0.startDate.timeIntervalSince(start)) < 1 }
        }
        return store.event(withIdentifier: id)
    }

    /// Vuelve a leer un evento desde un almacén NUEVO para comprobar de verdad lo que quedó guardado.
    private func refetch(baseID: String, recurring: Bool, near date: Date) -> EKEvent? {
        let store = EKEventStore()
        if !recurring { return store.event(withIdentifier: baseID) }
        let predicate = store.predicateForEvents(withStart: date.addingTimeInterval(-3_600), end: date.addingTimeInterval(86_400), calendars: nil)
        return store.events(matching: predicate).first { $0.eventIdentifier == baseID && abs($0.startDate.timeIntervalSince(date)) < 60 }
    }

    private func modificationBlock(_ info: CalendarEventInfo) -> String? {
        info.allowsModifications ? nil : "El evento «\(info.title)» está en el calendario «\(info.calendarTitle)», que no permite cambios (es de solo lectura o está suscrito). Viernes no puede modificarlo ni eliminarlo."
    }

    /// Localiza el evento pedido sin adivinar: exige permiso de lectura, busca en un almacén nuevo y distingue 0, 1 o varios.
    private func locateEvent(_ args: [String: String]) async -> EventLocation {
        if let problem = await calendarReadProblem() { return .blocked(problem, askUser: false) }
        let store = EKEventStore()          // almacén NUEVO tras comprobar el permiso: uno anterior puede devolver datos viejos
        let query = EventQuery(args: args)
        let now = Date()
        var candidates: [CalendarEventInfo] = []
        var byID: [String: EKEvent] = [:]
        if let id = query.eventID {
            if let found = event(forID: id, in: store), let info = Self.info(found) {
                candidates = [info]
                byID[info.id] = found
            }
        } else {
            let window = CalendarEventMatcher.searchWindow(for: query, now: now)
            let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: nil)
            for found in store.events(matching: predicate) {
                guard let info = Self.info(found), byID[info.id] == nil else { continue }
                candidates.append(info)
                byID[info.id] = found
            }
        }
        Diagnostics.shared.log("calendario: búsqueda de evento → \(candidates.count) candidatos")
        switch CalendarEventMatcher.resolve(query: query, candidates: candidates, recent: ledger.recent(now: now), now: now) {
        case .found(let info):
            guard let found = byID[info.id] else { return .blocked("No pude abrir el evento encontrado. Inténtalo de nuevo.", askUser: false) }
            return .found(found, store, info)
        case .notFound(let message):
            return .blocked(message, askUser: false)
        case .ambiguous(let message, _):
            return .blocked(message, askUser: true)
        case .invalid(let message):
            return .blocked(message, askUser: true)
        }
    }

    private func updateEvent(_ args: [String: String]) async -> ToolOutcome {
        let location = await locateEvent(args)
        guard case .found(let event, let store, let info) = location else {
            if case .blocked(let message, _) = location { return .failure(message) }
            return .failure("No pude localizar el evento.")
        }
        if let blocked = modificationBlock(info) { return .failure(blocked) }
        let calendar = Calendar.current
        let changes: EventChanges
        switch EventChanges.from(args: args, original: info, now: Date(), calendar: calendar) {
        case .failure(let error): return .failure(error.message)
        case .success(let value): changes = value
        }
        guard !changes.isEmpty else { return .failure("No se indicó ningún cambio para el evento.") }

        let baseID = event.eventIdentifier ?? ""
        let recurring = event.hasRecurrenceRules
        let oldDuration = event.endDate.timeIntervalSince(event.startDate)
        if let title = changes.title { event.title = title }
        if let location = changes.location { event.location = location }
        if let start = changes.start {
            if event.isAllDay { event.isAllDay = false }
            let length = changes.durationMinutes.map { TimeInterval($0 * 60) } ?? oldDuration
            event.startDate = start
            event.endDate = start.addingTimeInterval(length)
        } else if let minutes = changes.durationMinutes {
            event.endDate = event.startDate.addingTimeInterval(TimeInterval(minutes * 60))
        }
        let expectedStart: Date = event.startDate
        let expectedEnd: Date = event.endDate
        let expectedTitle = event.title ?? ""
        let expectedLocation = event.location ?? ""

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            Diagnostics.shared.log("calendario: error al modificar evento: \(error.localizedDescription)")
            return .failure("No pude guardar el cambio en «\(info.title)»: \(error.localizedDescription)")
        }

        // Comprobación real: se vuelve a leer desde un almacén nuevo y se compara con lo pedido.
        guard let saved = refetch(baseID: baseID, recurring: recurring, near: expectedStart) else {
            Diagnostics.shared.log("calendario: tras modificar, el evento no se pudo volver a leer")
            return .failure("Pedí guardar el cambio, pero no pude comprobar que quedó guardado en el calendario. Revísalo en la app Calendario antes de darlo por hecho.")
        }
        let startOK = abs(saved.startDate.timeIntervalSince(expectedStart)) < 1
        let endOK = abs(saved.endDate.timeIntervalSince(expectedEnd)) < 1
        guard startOK, endOK, (saved.title ?? "") == expectedTitle, (saved.location ?? "") == expectedLocation else {
            Diagnostics.shared.log("calendario: lo guardado no coincide con lo pedido")
            return .failure("iOS no reflejó el cambio tal como se pidió (el evento quedó distinto). Revísalo en la app Calendario.")
        }
        guard let after = Self.info(saved) else { return .success("Evento actualizado y comprobado.") }
        let note = recurring ? " Solo se cambió esta ocurrencia; el resto de la serie no se tocó." : ""
        return .success("Evento actualizado y comprobado releyéndolo del calendario: antes \(CalendarEventMatcher.describe(info, calendar: calendar)); ahora \(CalendarEventMatcher.describe(after, calendar: calendar)).\(note)")
    }

    private func deleteEvent(_ args: [String: String]) async -> ToolOutcome {
        let location = await locateEvent(args)
        guard case .found(let event, let store, let info) = location else {
            if case .blocked(let message, _) = location { return .failure(message) }
            return .failure("No pude localizar el evento.")
        }
        if let blocked = modificationBlock(info) { return .failure(blocked) }
        let baseID = event.eventIdentifier ?? ""
        let recurring = event.hasRecurrenceRules
        let start: Date = event.startDate
        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            Diagnostics.shared.log("calendario: error al eliminar evento: \(error.localizedDescription)")
            return .failure("No pude eliminar «\(info.title)»: \(error.localizedDescription)")
        }
        // Comprobación real: con un almacén nuevo, el evento ya no debe existir.
        if refetch(baseID: baseID, recurring: recurring, near: start) != nil {
            Diagnostics.shared.log("calendario: tras eliminar, el evento sigue existiendo")
            return .failure("Pedí eliminar «\(info.title)», pero el evento sigue en el calendario; no puedo confirmar que se haya borrado.")
        }
        ledger.remove(id: info.id)
        let note = recurring ? " Solo se eliminó esta ocurrencia; el resto de la serie sigue." : ""
        return .success("Evento eliminado y comprobado (ya no aparece en el calendario): \(CalendarEventMatcher.describe(info, calendar: Calendar.current)).\(note)")
    }

    // MARK: Lectura de calendario y contactos (solo si el usuario lo activó en Privacidad; ese interruptor ES la autorización)

    private func listEvents(date: String, days: Int) async -> ToolOutcome {
        guard let range = CalendarRange.resolve(date: date, days: days, now: Date()) else {
            return .failure("No entendí qué día quieres consultar. Pídeselo al usuario con una fecha o «hoy»/«mañana».")
        }
        if let problem = await calendarReadProblem() { return .failure(problem) }
        do {
            // Almacén NUEVO tras comprobar la autorización: uno creado antes de conceder el permiso puede devolver vacío.
            let store = EKEventStore()
            let calendars = store.calendars(for: .event)
            Diagnostics.shared.log("calendario: lectura \(date) → \(calendars.count) calendarios visibles")
            guard !calendars.isEmpty else {
                return .failure("iOS no muestra ningún calendario en este iPhone. Revisa Ajustes › Calendario › Cuentas.")
            }
            let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: nil)
            let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
            Diagnostics.shared.log("calendario: lectura \(date) → \(events.count) eventos")
            guard !events.isEmpty else { return .success("No hay eventos en ese rango (se revisaron \(calendars.count) calendarios).") }
            let dayFormatter = DateFormatter()
            dayFormatter.locale = Locale(identifier: "es_CO")
            dayFormatter.dateFormat = "EEE d MMM"
            let timeFormatter = DateFormatter()
            timeFormatter.locale = Locale(identifier: "es_CO")
            timeFormatter.dateFormat = "HH:mm"
            let lines = events.prefix(25).map { event -> String in
                let time = event.isAllDay ? "todo el día" : "\(timeFormatter.string(from: event.startDate))–\(timeFormatter.string(from: event.endDate))"
                let place = (event.location ?? "").isEmpty ? "" : " en \(event.location ?? "")"
                return "• \(dayFormatter.string(from: event.startDate)) \(time): \(event.title ?? "(sin título)")\(place)"
            }
            let more = events.count > 25 ? "\n(y \(events.count - 25) más)" : ""
            return .success("Eventos (\(events.count)), en orden:\n" + lines.joined(separator: "\n") + more)
        } catch {
            Diagnostics.shared.log("calendario: error al leer: \(error.localizedDescription)")
            return .failure("No pude leer tu calendario ahora mismo.")
        }
    }

    /// Política de lectura de contactos del perfil: `false` = el usuario la apagó; `nil` = nunca la tocó (se permite si iOS ya le dio acceso).
    var contactsReadSetting: Bool?
    /// Región del perfil: da el código de país a los números locales.
    var defaultRegion = "CO"
    var directory: ContactDirectory = SystemContactDirectory()

    /// Punto único para resolver a una persona: lo usan WhatsApp, SMS, llamadas y correo. Los resultados que vuelven al modelo no llevan números completos.
    private func resolveRecipient(_ name: String, kind: RecipientKind, digits: String?) async -> RecipientOutcome {
        if contactsReadSetting == false {
            return .noValue("El usuario apagó la lectura de contactos en Ajustes › Privacidad, así que no puedo buscar a «\(name)». Dile que puede activarla, o pídele el dato directamente.")
        }
        if contactsReadSetting == nil {
            let access = await directory.access()
            if !access.canRead {
                return .noValue("Para buscar a «\(name)» necesito permiso para leer los contactos. Dile al usuario que lo active en Ajustes › Privacidad › «Permitir que Viernes lea mis contactos», o pídele el dato directamente.")
            }
        }
        return await RecipientResolver.resolve(name, kind: kind, directory: directory, region: defaultRegion, digits: digits)
    }

    private func findContact(name: String) async -> ToolOutcome {
        var access = await directory.access()
        if access == .notDetermined { access = await directory.requestAccess() }
        Diagnostics.shared.log("contactos: acceso = \(access)")
        guard access.canRead else { return .failure(access.explanation) }
        do {
            let ranked = ContactResolver.rank(name, in: try await directory.allContacts(), limit: 5)
            guard !ranked.isEmpty else {
                return .success("No encontré contactos que coincidan con «\(name)»." + (access == .limited ? " " + access.explanation : ""))
            }
            let lines = ranked.map { match -> String in
                let card = match.card
                var line = "• \(card.displayName)" + (card.organization.isEmpty || card.organization == card.displayName ? "" : " (\(card.organization))")
                let phones = ContactResolver.phoneOptions(for: card, region: defaultRegion).map { "\($0.label.isEmpty ? "teléfono" : $0.label) \(PhoneNumber.display($0.e164))" }
                if !phones.isEmpty { line += " — " + phones.joined(separator: ", ") }
                if !card.emails.isEmpty { line += " — correo: " + card.emails.joined(separator: ", ") }
                return line
            }
            let note = ranked.count > 1 ? "\nHay \(ranked.count) coincidencias: si no es claro cuál es, pregunta al usuario." : ""
            return .success("Contactos:\n" + lines.joined(separator: "\n") + note)
        } catch {
            Diagnostics.shared.log("contactos: error al leer: \(error.localizedDescription)")
            return .failure("No pude leer tus contactos ahora mismo.")
        }
    }

    // MARK: Borradores y llamadas (iOS no permite enviar sin que el usuario pulse Enviar)

    /// Codifica un valor de URL con solo caracteres seguros: el texto del usuario no puede inyectar parámetros.
    private func urlEncode(_ value: String, keep: String = "") -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~" + keep)
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// Muestra una VISTA PREVIA editable del borrador y espera a que el usuario decida (abrir en Correo, copiar o descartar).
    /// Lo que se cuenta al modelo es lo que de verdad pasó: nunca «enviado» si el usuario no pulsó Enviar.
    private func composeEmail(_ args: [String: String]) async -> ToolOutcome {
        var args = args
        if args["to"] == nil, let contact = args["contact"] {
            let outcome = await resolveRecipient(contact, kind: .email, digits: nil)
            guard case .resolved(_, let email, _) = outcome else {
                return .failure((outcome.failureText ?? "No pude resolver el correo.") + " Si el usuario prefiere, prepara el borrador sin destinatario llamando de nuevo sin «contact».")
            }
            args["to"] = email
        }
        let content = MailDraftContent(to: args["to"] ?? "", subject: args["subject"] ?? "", body: args["body"] ?? "")
        Diagnostics.shared.log("correo: vista previa del borrador (\(content.to.isEmpty ? "sin destinatario" : "con destinatario"), \(content.body.count) caracteres)")
        let result = await mailDrafts.present(content)
        Diagnostics.shared.log("correo: resultado = \(result)")
        switch result {
        case .composerSent:
            return .success("El usuario envió el correo desde el compositor de Correo (él pulsó Enviar).")
        case .composerSaved:
            return .success("El usuario guardó el borrador en Correo. NO se envió.")
        case .openedExternal:
            return .success("Abrí la app de correo con el borrador listo. TODAVÍA NO SE ENVIÓ: el usuario debe revisarlo y pulsar Enviar; no puedo saber si lo hizo.")
        case .copied:
            return .success("El usuario copió el borrador al portapapeles. NO se envió nada.")
        case .composerCancelled:
            return .failure("El usuario cerró el compositor sin enviar ni guardar el correo. No se envió nada.")
        case .composerFailed(let reason):
            return .failure("Correo no pudo preparar el mensaje: \(reason). No se envió nada.")
        case .discarded:
            return .failure("El usuario descartó el borrador; no se abrió el correo ni se envió nada.")
        }
    }

    private func composeMessage(_ args: [String: String]) async -> ToolOutcome {
        let text = args["body"] ?? ""
        let isWhatsApp = args["app"] == "whatsapp"
        let appName = isWhatsApp ? "WhatsApp" : "Mensajes"
        var number: String?
        var person: String?
        if let raw = args["to"] {
            guard let e164 = PhoneNumber.e164(raw, region: defaultRegion) else {
                return .failure("No pude interpretar «\(raw)» como un teléfono con código de país (región \(defaultRegion)). Pídele al usuario el número con prefijo, p. ej. +57 300 123 4567; no inventes uno.")
            }
            number = e164
        } else if let contact = args["contact"] {
            let outcome = await resolveRecipient(contact, kind: .phone, digits: args["digits"])
            guard case .resolved(let name, let value, _) = outcome else { return .failure(outcome.failureText ?? "No pude resolver al destinatario.") }
            number = value
            person = name
        }
        Diagnostics.shared.log("mensaje: \(appName), destinatario \(person != nil ? "resuelto en contactos" : (number != nil ? "número dado" : "sin destinatario")), \(text.count) caracteres")

        var opened = false
        if isWhatsApp {
            // Enlace documentado por WhatsApp (wa.me). `universalLinksOnly` hace que falle si no hay una app que lo abra, en vez de abrir una página web.
            if let link = MessageLinks.whatsApp(e164: number, text: text) { opened = await UIApplication.shared.open(link, options: [.universalLinksOnly: true]) }
            if !opened, let alternative = MessageLinks.whatsAppScheme(e164: number, text: text) { opened = await UIApplication.shared.open(alternative) }
        } else if let link = MessageLinks.sms(e164: number, text: text) {
            opened = await UIApplication.shared.open(link)
        }
        guard opened else {
            return .failure("No pude abrir \(appName)" + (isWhatsApp ? "; puede que WhatsApp no esté instalada." : ".") + " No se envió nada.")
        }
        let target = person.map { "el chat de \($0)" } ?? (number != nil ? "el chat del número indicado" : "la lista para elegir contacto")
        return .success("Abrí \(appName) con \(target) y el texto PRECARGADO. TODAVÍA NO SE ENVIÓ: el usuario debe pulsar Enviar en \(appName). Solo sé que iOS entregó el enlace a la app; no puedo comprobar que el chat se abrió ni si el usuario lo envió.")
    }

    private func callPhone(_ args: [String: String]) async -> ToolOutcome {
        var number: String?
        var person: String?
        if let raw = args["number"] {
            guard let e164 = PhoneNumber.e164(raw, region: defaultRegion) else {
                return .failure("No pude interpretar «\(raw)» como un teléfono con código de país (región \(defaultRegion)). Pídele el número con prefijo; no inventes uno.")
            }
            number = e164
        } else if let contact = args["contact"] {
            let outcome = await resolveRecipient(contact, kind: .phone, digits: args["digits"])
            guard case .resolved(let name, let value, _) = outcome else { return .failure(outcome.failureText ?? "No pude resolver a quién llamar.") }
            number = value
            person = name
        }
        guard let phone = number, let url = MessageLinks.tel(e164: phone) else { return .failure("Número no válido.") }
        let opened = await UIApplication.shared.open(url)
        return opened
            ? .success("Abrí el marcador con \(person ?? "el número indicado"). iOS pedirá confirmar antes de llamar; todavía no se llamó.")
            : .failure("No pude abrir el marcador (los iPhone sin telefonía y el simulador no pueden llamar).")
    }

    // MARK: Dispositivo

    private func deviceInfo(what: String) -> ToolOutcome {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        var lines: [String] = []

        if what == "time" || what == "all" {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "es_CO")
            formatter.dateStyle = .full
            formatter.timeStyle = .short
            lines.append("Fecha y hora: \(formatter.string(from: Date())) (\(TimeZone.current.identifier))")
        }
        if what == "battery" || what == "all" {
            let level = device.batteryLevel
            let percent = level >= 0 ? "\(Int(level * 100)) %" : "desconocida"
            let state: String
            switch device.batteryState {
            case .charging: state = "cargando"
            case .full: state = "completa"
            case .unplugged: state = "sin cargar"
            default: state = "estado desconocido"
            }
            let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? ", modo de bajo consumo activo" : ""
            lines.append("Batería: \(percent), \(state)\(lowPower)")
        }
        if what == "storage" || what == "all" {
            if let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
               let free = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity {
                let format = ByteCountFormatter()
                format.countStyle = .file
                lines.append("Almacenamiento: \(format.string(fromByteCount: free)) libres de \(format.string(fromByteCount: Int64(total)))")
            } else {
                lines.append("Almacenamiento: no disponible")
            }
        }
        if what == "device" || what == "all" {
            let ram = ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
            lines.append("Dispositivo: \(device.model), iOS \(device.systemVersion), \(ram) de RAM")
        }
        return lines.isEmpty ? .failure("No sé consultar eso.") : .success(lines.joined(separator: "\n"))
    }
}

private enum ToolError: Error {
    /// Falta un permiso: lleva el mensaje listo para el usuario (qué hacer en Ajustes).
    case denied(String)
}
