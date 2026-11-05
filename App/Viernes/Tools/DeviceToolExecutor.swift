import UIKit
import EventKit
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
            return .success(text)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(error.code) {
            return .failure("Sin conexión a internet: no puedo consultar el clima.")
        } catch {
            return .failure("No pude consultar el clima: \(error.localizedDescription)")
        }
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
        do {
            guard try await eventStore.requestFullAccessToReminders() else {
                return .failure("No tengo permiso para Recordatorios. Actívalo en Ajustes › Viernes.")
            }
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
            return .failure("Error al crear el recordatorio: \(error.localizedDescription)")
        }
    }

    private func incompleteReminders() async throws -> [EKReminder] {
        guard try await eventStore.requestFullAccessToReminders() else { throw ToolError.permission("Recordatorios") }
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
        } catch ToolError.permission(let area) {
            return .failure("No tengo permiso para \(area). Actívalo en Ajustes › Viernes.")
        } catch {
            return .failure("Error al leer recordatorios: \(error.localizedDescription)")
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
        } catch ToolError.permission(let area) {
            return .failure("No tengo permiso para \(area). Actívalo en Ajustes › Viernes.")
        } catch {
            return .failure("Error al completar el recordatorio: \(error.localizedDescription)")
        }
    }

    private func createEvent(_ args: [String: String]) async -> ToolOutcome {
        do {
            // Acceso de SOLO ESCRITURA: Viernes puede añadir eventos pero no lee tu calendario.
            guard try await eventStore.requestWriteOnlyAccessToEvents() else {
                return .failure("No tengo permiso para añadir eventos al Calendario. Actívalo en Ajustes › Viernes.")
            }
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
            return .failure("Error al crear el evento: \(error.localizedDescription)")
        }
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
    case permission(String)
}
