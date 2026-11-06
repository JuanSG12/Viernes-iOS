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

    init(claude: ClaudeCoordinator) { self.claude = claude }

    func execute(_ call: ToolCall) async -> ToolOutcome {
        switch call.name {
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
        case "call_phone": return await callPhone(call.args["number"] ?? "")
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
            return .success("Evento creado: \(event.title ?? "") el \(formatter.string(from: start)) (\(minutes) min).")
        } catch {
            Diagnostics.shared.log("calendario: error al crear evento: \(error.localizedDescription)")
            return .failure("No pude crear el evento. Inténtalo de nuevo.")
        }
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

    private func findContact(name: String) async -> ToolOutcome {
        let store = CNContactStore()
        let before = CNContactStore.authorizationStatus(for: .contacts)
        Diagnostics.shared.log("contactos: estado antes = \(before.rawValue)")
        do {
            switch before {
            case .denied, .restricted:
                return .failure("Viernes no tiene permiso para leer tus contactos. Actívalo en Ajustes › Viernes › Contactos.")
            case .notDetermined:
                guard try await store.requestAccess(for: .contacts) else {
                    return .failure("Viernes no tiene permiso para leer tus contactos. Actívalo en Ajustes › Viernes › Contactos.")
                }
            default:
                break     // autorizado o acceso limitado (iOS 18): se lee lo que el usuario compartió
            }
            let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor,
                                           CNContactEmailAddressesKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor]
            let matches = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)
            guard !matches.isEmpty else { return .success("No encontré contactos que coincidan con «\(name)».") }
            let lines = matches.prefix(5).map { contact -> String in
                let full = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                let emails = contact.emailAddresses.map { String($0.value) }
                let phones = contact.phoneNumbers.map { $0.value.stringValue }
                var line = "• \(full.isEmpty ? "(sin nombre)" : full)"
                if !emails.isEmpty { line += " — correo: \(emails.joined(separator: ", "))" }
                if !phones.isEmpty { line += " — teléfono: \(phones.joined(separator: ", "))" }
                return line
            }
            let note = matches.count > 1 ? "\nHay \(matches.count) coincidencias: si no es claro cuál es, pregunta al usuario." : ""
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

    private func composeEmail(_ args: [String: String]) async -> ToolOutcome {
        var query = ["body=\(urlEncode(args["body"] ?? ""))"]
        if let subject = args["subject"] { query.insert("subject=\(urlEncode(subject))", at: 0) }
        let recipient = urlEncode(args["to"] ?? "", keep: "@+")
        guard let url = URL(string: "mailto:\(recipient)?\(query.joined(separator: "&"))") else { return .failure("No pude construir el borrador.") }
        let opened = await UIApplication.shared.open(url)
        return opened
            ? .success("Abrí Correo con un borrador listo. TODAVÍA NO SE ENVIÓ: el usuario debe revisarlo y pulsar Enviar.")
            : .failure("No pude abrir Correo. ¿Hay una cuenta configurada en la app Correo?")
    }

    private func composeMessage(_ args: [String: String]) async -> ToolOutcome {
        let body = urlEncode(args["body"] ?? "")
        let number = args["to"].flatMap { ContactFormat.normalizedPhone($0) }
        let isWhatsApp = args["app"] == "whatsapp"
        let urlString: String
        if isWhatsApp {
            let digits = (number ?? "").filter { $0.isNumber }
            urlString = "whatsapp://send?" + (digits.isEmpty ? "" : "phone=\(digits)&") + "text=\(body)"
        } else {
            urlString = "sms:\(number.map { urlEncode($0, keep: "+") } ?? "")&body=\(body)"
        }
        guard let url = URL(string: urlString) else { return .failure("No pude construir el borrador.") }
        let opened = await UIApplication.shared.open(url)
        let appName = isWhatsApp ? "WhatsApp" : "Mensajes"
        return opened
            ? .success("Abrí \(appName) con un borrador listo. TODAVÍA NO SE ENVIÓ: el usuario debe revisarlo y pulsar Enviar.")
            : .failure("No pude abrir \(appName)" + (isWhatsApp ? "; puede que WhatsApp no esté instalada." : "."))
    }

    private func callPhone(_ number: String) async -> ToolOutcome {
        guard let phone = ContactFormat.normalizedPhone(number), let url = URL(string: "tel:\(urlEncode(phone, keep: "+"))") else {
            return .failure("Número no válido.")
        }
        let opened = await UIApplication.shared.open(url)
        return opened
            ? .success("Abrí el marcador con \(phone). iOS pedirá confirmar antes de llamar; todavía no se llamó.")
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
