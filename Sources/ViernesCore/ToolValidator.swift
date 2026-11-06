import Foundation

public struct AppLink: Equatable, Sendable {
    public let key: String
    public let displayName: String
    public let url: URL
}

/// Lista blanca de apps que Viernes puede abrir mediante esquemas de URL públicos.
/// Abrir una URL no requiere `LSApplicationQueriesSchemes`; sí lo requeriría `canOpenURL`.
public enum AppLinkCatalog {
    private static let entries: [(key: String, name: String, scheme: String, aliases: [String])] = [
        ("whatsapp", "WhatsApp", "whatsapp://", []),
        ("spotify", "Spotify", "spotify://", []),
        ("youtube", "YouTube", "youtube://", []),
        ("telegram", "Telegram", "tg://", []),
        ("maps", "Mapas", "maps://", ["mapas", "apple maps"]),
        ("google_maps", "Google Maps", "comgooglemaps://", ["google maps"]),
        ("waze", "Waze", "waze://", []),
        ("mail", "Correo", "message://", ["correo", "mail"]),
        ("messages", "Mensajes", "sms:", ["mensajes", "sms"]),
        ("music", "Música", "music://", ["musica", "apple music"]),
        ("claude", "Claude", "claude://", []),
        ("shortcuts", "Atajos", "shortcuts://", ["atajos"]),
        ("calendar", "Calendario", "calshow://", ["calendario"]),
        ("notes", "Notas", "mobilenotes://", ["notas"]),
        ("photos", "Fotos", "photos-redirect://", ["fotos"]),
        ("files", "Archivos", "shareddocuments://", ["archivos"])
    ]

    public static var allDisplayNames: [String] { entries.map(\.name) }

    public static func resolve(_ name: String) -> AppLink? {
        let folded = TextNormalizer.fold(name).trimmingCharacters(in: .whitespaces)
        guard !folded.isEmpty else { return nil }
        for entry in entries {
            let candidates = [entry.key, TextNormalizer.fold(entry.name)] + entry.aliases.map(TextNormalizer.fold)
            if candidates.contains(folded), let url = URL(string: entry.scheme) {
                return AppLink(key: entry.key, displayName: entry.name, url: url)
            }
        }
        return nil
    }
}

public enum ToolValidationError: Error, Equatable, LocalizedError {
    case unknownTool(String)
    case missingArgument(tool: String, argument: String)
    case invalid(tool: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name): return "No tengo una herramienta llamada «\(name)»."
        case .missingArgument(let tool, let argument): return "Falta el argumento «\(argument)» para \(tool)."
        case .invalid(let tool, let reason): return "Argumentos inválidos para \(tool): \(reason)"
        }
    }
}

public enum DateParsing {
    /// Acepta ISO 8601 completo, con o sin zona, con o sin segundos, o solo fecha. Sin zona = hora local.
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}

/// Formato de datos de contacto (puro y comprobable).
public enum ContactFormat {
    /// Dirección sencilla: una sola, sin espacios ni separadores múltiples.
    public static func isValidEmail(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard value.count <= 254, !value.contains(","), !value.contains(";"), !value.contains(" ") else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return false }
        return true
    }

    /// Devuelve solo dígitos con un «+» inicial opcional (5–15 dígitos) o nil si no parece un teléfono.
    public static func normalizedPhone(_ text: String) -> String? {
        let allowed = CharacterSet(charactersIn: "+0123456789 ()-.")
        guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.filter { $0.isNumber }
        guard (5...15).contains(digits.count) else { return nil }
        if trimmed.hasPrefix("+") && trimmed.dropFirst().contains("+") { return nil }
        if !trimmed.hasPrefix("+") && trimmed.contains("+") { return nil }
        return (trimmed.hasPrefix("+") ? "+" : "") + digits
    }
}

/// Rango de días para leer el calendario (puro y comprobable).
public enum CalendarRange {
    /// Desplazamiento en días respecto a hoy para las palabras relativas más comunes (español e inglés).
    private static let relativeDays: [String: Int] = [
        "today": 0, "hoy": 0, "tomorrow": 1, "manana": 1, "yesterday": -1, "ayer": -1,
        "pasado manana": 2, "day after tomorrow": 2
    ]
    /// Día de la semana (1 = domingo, como `Calendar`) por nombre.
    private static let weekdays: [String: Int] = [
        "domingo": 1, "lunes": 2, "martes": 3, "miercoles": 4, "jueves": 5, "viernes": 6, "sabado": 7,
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7
    ]

    private static func normalize(_ text: String) -> String {
        TextNormalizer.fold(text).trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "el ", with: "").replacingOccurrences(of: "este ", with: "")
    }

    /// Acepta `today`/`tomorrow`, sus equivalentes en español («hoy», «mañana», «pasado mañana», «ayer»),
    /// un día de la semana («viernes») o una fecha `YYYY-MM-DD`. Los modelos mezclan idiomas: se es tolerante.
    public static func isValidDateArgument(_ text: String) -> Bool {
        let folded = normalize(text)
        if relativeDays[folded] != nil || weekdays[folded] != nil { return true }
        return folded.count == 10 && DateParsing.parse(folded) != nil
    }

    /// Inicio (00:00 local) y fin (exclusivo) del rango pedido.
    public static func resolve(date: String, days: Int, now: Date, calendar: Calendar = .current) -> (start: Date, end: Date)? {
        let folded = normalize(date)
        let startOfToday = calendar.startOfDay(for: now)
        let start: Date
        if let offset = relativeDays[folded] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday) else { return nil }
            start = day
        } else if let weekday = weekdays[folded] {
            // Próxima ocurrencia estrictamente posterior a hoy («el viernes» dicho un viernes es el siguiente).
            let today = calendar.component(.weekday, from: startOfToday)
            var ahead = (weekday - today + 7) % 7
            if ahead == 0 { ahead = 7 }
            guard let day = calendar.date(byAdding: .day, value: ahead, to: startOfToday) else { return nil }
            start = day
        } else {
            guard folded.count == 10, let parsed = DateParsing.parse(folded, timeZone: calendar.timeZone) else { return nil }
            start = calendar.startOfDay(for: parsed)
        }
        let clamped = min(max(days, 1), 7)
        guard let end = calendar.date(byAdding: .day, value: clamped, to: start) else { return nil }
        return (start, end)
    }
}

/// Validación estricta ANTES de ejecutar o pedir confirmación. Nada que venga del modelo se confía.
public enum ToolValidator {
    public static let maxValueLength = 2_000
    public static let maxPromptLength = 4_000

    @discardableResult
    public static func validate(_ call: ToolCall, timeZone: TimeZone = .current) throws -> ToolCall {
        guard let definition = ToolCatalog.definition(named: call.name) else {
            throw ToolValidationError.unknownTool(call.name)
        }
        let allowed = Set(definition.parameters.map(\.name))
        var args: [String: String] = [:]
        for (key, value) in call.args where allowed.contains(key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count <= maxPromptLength else {
                throw ToolValidationError.invalid(tool: call.name, reason: "«\(key)» es demasiado largo.")
            }
            if !trimmed.isEmpty { args[key] = trimmed }
        }
        for parameter in definition.parameters where parameter.required && args[parameter.name] == nil {
            throw ToolValidationError.missingArgument(tool: call.name, argument: parameter.name)
        }

        func fail(_ reason: String) -> ToolValidationError { .invalid(tool: call.name, reason: reason) }

        switch call.name {
        case "open_app":
            guard AppLinkCatalog.resolve(args["app"]!) != nil else {
                throw fail("app desconocida o no permitida. Permitidas: \(AppLinkCatalog.allDisplayNames.joined(separator: ", ")).")
            }
        case "open_url":
            guard let components = URLComponents(string: args["url"]!),
                  components.scheme?.lowercased() == "https",
                  let host = components.host, host.contains("."),
                  components.user == nil, components.password == nil
            else { throw fail("solo se permiten enlaces https válidos sin credenciales.") }
        case "create_reminder":
            try requireTitle(args["title"]!, tool: call.name)
            if let due = args["due"], DateParsing.parse(due, timeZone: timeZone) == nil {
                throw fail("fecha «due» no válida; usa ISO 8601, p. ej. 2026-11-05T09:00.")
            }
        case "complete_reminder":
            try requireTitle(args["title"]!, tool: call.name)
        case "create_event":
            try requireTitle(args["title"]!, tool: call.name)
            guard DateParsing.parse(args["start"]!, timeZone: timeZone) != nil else {
                throw fail("fecha «start» no válida; usa ISO 8601, p. ej. 2026-11-05T15:00.")
            }
            if let minutes = args["duration_minutes"] {
                guard let value = Int(minutes), (1...1440).contains(value) else {
                    throw fail("«duration_minutes» debe estar entre 1 y 1440.")
                }
            }
        case "list_reminders":
            if let limit = args["limit"] {
                guard let value = Int(limit), (1...20).contains(value) else { throw fail("«limit» debe estar entre 1 y 20.") }
            }
        case "run_shortcut":
            let name = args["name"]!
            guard name.count <= 100, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw fail("nombre de atajo no válido.")
            }
        case "device_info":
            if let what = args["what"], !["battery", "storage", "time", "device", "all"].contains(what.lowercased()) {
                throw fail("«what» debe ser battery, storage, time, device o all.")
            }
        case "list_events":
            guard CalendarRange.isValidDateArgument(args["date"]!) else {
                throw fail("«date» debe ser today, tomorrow o una fecha YYYY-MM-DD.")
            }
            if let days = args["days"] {
                guard let value = Int(days), (1...7).contains(value) else { throw fail("«days» debe estar entre 1 y 7.") }
            }
        case "find_contact":
            guard args["name"]!.count <= 100 else { throw fail("el nombre es demasiado largo.") }
        case "update_event", "delete_event":
            try validateEventTarget(&args, tool: call.name, timeZone: timeZone)
            if call.name == "update_event" { try validateEventChanges(&args, tool: call.name, timeZone: timeZone) }
        case "compose_email":
            if let rawTo = args["to"] {
                // Una dirección dictada («juan arroba gmail punto com») o con espacios se limpia antes de validar.
                let cleaned = SpokenText.cleanEmailAddress(rawTo)
                guard ContactFormat.isValidEmail(cleaned) else {
                    throw fail("la dirección «\(rawTo)» no parece un correo válido. Pídele al usuario que la escriba o la deletree, o prepara el borrador sin destinatario.")
                }
                args["to"] = cleaned
            }
            if let subject = args["subject"], subject.count > 200 || subject.contains("\n") { throw fail("asunto no válido.") }
        case "compose_message":
            if let to = args["to"], ContactFormat.normalizedPhone(to) == nil { throw fail("teléfono no válido.") }
            if let app = args["app"] {
                let folded = app.lowercased()
                guard ["sms", "whatsapp"].contains(folded) else { throw fail("«app» debe ser sms o whatsapp.") }
                args["app"] = folded
            }
        case "call_phone":
            guard let phone = ContactFormat.normalizedPhone(args["number"]!) else { throw fail("teléfono no válido.") }
            args["number"] = phone
        case "get_weather":
            let city = args["city"]!
            guard city.count <= 80, !city.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw fail("nombre de ciudad no válido.")
            }
        case "ask_claude":
            let scan = SensitiveDataRedactor.scan(args["prompt"]!)
            guard !scan.isSensitive else {
                throw fail("el mensaje contiene datos sensibles (\(scan.findings.map(\.rawValue).joined(separator: ", "))); no lo envío a Claude.")
            }
        case "save_memory":
            if let kind = args["kind"], MemoryKind(rawValue: kind) == nil || kind == "summary" {
                throw fail("«kind» debe ser preference, project o fact.")
            }
        default:
            break
        }
        return ToolCall(name: call.name, args: args)
    }

    private static func requireTitle(_ title: String, tool: String) throws {
        guard title.count <= 200 else { throw ToolValidationError.invalid(tool: tool, reason: "el título supera 200 caracteres.") }
    }

    /// Hora de 24 h válida («8», «08:00», «15:45»), normalizada a «HH:mm».
    private static func normalizedClock(_ text: String) -> String? {
        CalendarEventMatcher.minutes(fromClock: text).map(CalendarEventMatcher.clock)
    }

    /// Cómo se localiza el evento: al menos un criterio, con fecha y hora bien formadas.
    private static func validateEventTarget(_ args: inout [String: String], tool: String, timeZone: TimeZone) throws {
        func fail(_ reason: String) -> ToolValidationError { .invalid(tool: tool, reason: reason) }
        if let title = args["title"], title.count > 200 { throw fail("el título buscado es demasiado largo.") }
        if let date = args["date"], !CalendarRange.isValidDateArgument(date) {
            throw fail("«date» debe ser today, tomorrow, un día de la semana o una fecha YYYY-MM-DD.")
        }
        if let time = args["time"] {
            guard let normalized = normalizedClock(time) else { throw fail("«time» debe ser una hora de 24 h, p. ej. 08:00 o 15:45.") }
            args["time"] = normalized
        }
        if let flag = args["just_created"] {
            guard ["true", "false", "si", "sí", "yes", "no", "1", "0"].contains(flag.lowercased()) else { throw fail("«just_created» debe ser true o false.") }
            args["just_created"] = CalendarEventMatcher.isTrue(flag) ? "true" : "false"
            if args["just_created"] == "false" { args["just_created"] = nil }
        }
        if let id = args["event_id"], id.count > 200 || id.contains(" ") { throw fail("«event_id» no es válido.") }
        guard EventQuery(args: args).hasCriteria else {
            throw fail("indica cuál evento: título, día u hora (o just_created si es el que acabas de crear).")
        }
    }

    /// Qué se quiere cambiar: al menos un cambio y cada uno bien formado.
    private static func validateEventChanges(_ args: inout [String: String], tool: String, timeZone: TimeZone) throws {
        func fail(_ reason: String) -> ToolValidationError { .invalid(tool: tool, reason: reason) }
        let changeKeys = ["new_title", "new_start", "new_date", "new_time", "new_duration_minutes", "new_location"]
        guard changeKeys.contains(where: { args[$0] != nil }) else {
            throw fail("indica qué cambiar: new_title, new_start, new_date, new_time, new_duration_minutes o new_location.")
        }
        if let title = args["new_title"], title.count > 200 { throw fail("el título nuevo es demasiado largo.") }
        if let place = args["new_location"], place.count > 200 { throw fail("el lugar nuevo es demasiado largo.") }
        if let start = args["new_start"], DateParsing.parse(start, timeZone: timeZone) == nil {
            throw fail("«new_start» no es válido; usa ISO 8601, p. ej. 2026-11-06T16:00.")
        }
        if let date = args["new_date"], !CalendarRange.isValidDateArgument(date) {
            throw fail("«new_date» debe ser today, tomorrow, un día de la semana o YYYY-MM-DD.")
        }
        if let time = args["new_time"] {
            guard let normalized = normalizedClock(time) else { throw fail("«new_time» debe ser una hora de 24 h, p. ej. 16:00.") }
            args["new_time"] = normalized
        }
        if let minutes = args["new_duration_minutes"] {
            guard let value = Int(minutes), (1...1440).contains(value) else { throw fail("«new_duration_minutes» debe estar entre 1 y 1440.") }
        }
    }
}
