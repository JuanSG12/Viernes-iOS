import Foundation

/// Un evento del calendario reducido a lo que necesita la búsqueda. EventKit se queda en la app: aquí todo es puro y comprobable.
public struct CalendarEventInfo: Equatable, Sendable {
    /// Identificador REAL de EventKit (nunca inventado por el modelo).
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let location: String
    public let calendarTitle: String
    public let isAllDay: Bool
    public let isRecurring: Bool
    public let allowsModifications: Bool

    public init(id: String, title: String, start: Date, end: Date, location: String = "", calendarTitle: String = "",
                isAllDay: Bool = false, isRecurring: Bool = false, allowsModifications: Bool = true) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.calendarTitle = calendarTitle
        self.isAllDay = isAllDay
        self.isRecurring = isRecurring
        self.allowsModifications = allowsModifications
    }

    public var durationMinutes: Int { max(1, Int((end.timeIntervalSince(start) / 60).rounded())) }
}

/// Evento que Viernes creó y que sigue siendo suyo de referenciar («el que acabamos de crear»). Se guarda en el teléfono.
public struct CreatedEventRecord: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let createdAt: Date

    public init(id: String, title: String, start: Date, createdAt: Date) {
        self.id = id
        self.title = title
        self.start = start
        self.createdAt = createdAt
    }
}

/// Cómo pidió el modelo encontrar un evento (los argumentos `event_id`, `title`, `date`, `time` y `just_created`).
public struct EventQuery: Equatable, Sendable {
    public var eventID: String?
    public var title: String?
    public var date: String?
    public var time: String?
    public var justCreated: Bool

    public init(eventID: String? = nil, title: String? = nil, date: String? = nil, time: String? = nil, justCreated: Bool = false) {
        self.eventID = eventID
        self.title = title
        self.date = date
        self.time = time
        self.justCreated = justCreated
    }

    public init(args: [String: String]) {
        func clean(_ key: String) -> String? {
            guard let value = args[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        self.init(eventID: clean("event_id"), title: clean("title"), date: clean("date"), time: clean("time"),
                  justCreated: CalendarEventMatcher.isTrue(args["just_created"]))
    }

    public var hasCriteria: Bool { eventID != nil || title != nil || date != nil || time != nil || justCreated }
}

public enum EventResolution: Equatable, Sendable {
    /// Exactamente un evento coincide.
    case found(CalendarEventInfo)
    /// Ninguno coincide (mensaje para el modelo, con el criterio usado).
    case notFound(String)
    /// Varios coinciden: el mensaje lista las opciones con sus identificadores reales; el modelo debe preguntar cuál.
    case ambiguous(String, candidates: [CalendarEventInfo])
    /// La petición no trae criterio suficiente.
    case invalid(String)
}

/// Encuentra EL evento que el usuario quiso decir, sin adivinar: si hay más de uno, lo dice; si no hay ninguno, también.
public enum CalendarEventMatcher {
    /// «El evento que acabamos de crear» solo alcanza a lo creado en las últimas horas.
    public static let recentCreationWindow: TimeInterval = 12 * 3_600
    public static let maxListed = 6
    /// Palabras tan genéricas que no distinguen un evento de otro («la reunión», «la cita»…).
    private static let genericWords: Set<String> = ["evento", "eventos", "cita", "citas", "reunion", "reuniones", "recordatorio",
                                                    "calendario", "agenda", "junta", "compromiso"]

    public static func isTrue(_ value: String?) -> Bool {
        guard let value = value else { return false }
        return ["true", "si", "yes", "1", "verdadero"].contains(TextNormalizer.fold(value).trimmingCharacters(in: .whitespaces))
    }

    /// «15:30», «08:00» o «8» (24 h) → minutos desde medianoche.
    public static func minutes(fromClock text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2, let hour = Int(parts[0]), (0...23).contains(hour) else { return nil }
        var minute = 0
        if parts.count == 2 {
            guard parts[1].count == 2, let value = Int(parts[1]), (0...59).contains(value) else { return nil }
            minute = value
        }
        return hour * 60 + minute
    }

    public static func clock(_ minutes: Int) -> String {
        let hour: String = minutes / 60 < 10 ? "0\(minutes / 60)" : "\(minutes / 60)"
        let minute: String = minutes % 60 < 10 ? "0\(minutes % 60)" : "\(minutes % 60)"
        return hour + ":" + minute
    }

    private static func minutesOfDay(_ date: Date, _ calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// Rango de fechas donde buscar los candidatos: el día indicado, o desde hace una semana hasta cuatro meses adelante.
    public static func searchWindow(for query: EventQuery, now: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        if let date = query.date, let range = CalendarRange.resolve(date: date, days: 1, now: now, calendar: calendar) { return range }
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 120, to: today) ?? today.addingTimeInterval(120 * 86_400)
        return (start, end)
    }

    /// El título buscado coincide con el del evento (sin mayúsculas ni tildes; las palabras genéricas son opcionales).
    public static func titleMatches(query: String, title: String) -> Bool {
        let foldedQuery = TextNormalizer.fold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !foldedQuery.isEmpty else { return true }
        if TextNormalizer.fold(title).contains(foldedQuery) { return true }
        let queryTokens = TextNormalizer.tokens(query).filter { !genericWords.contains($0) }.map(TextNormalizer.stem)
        guard !queryTokens.isEmpty else { return true }          // solo palabras genéricas: no filtra por título
        let titleTokens = TextNormalizer.tokens(title, dropStopwords: false).map(TextNormalizer.stem)
        return queryTokens.allSatisfy { token in
            titleTokens.contains { $0 == token || $0.hasPrefix(token) || (token.count >= 4 && token.hasPrefix($0) && $0.count >= 4) }
        }
    }

    public static func resolve(query: EventQuery, candidates: [CalendarEventInfo], recent: [CreatedEventRecord] = [],
                               now: Date, calendar: Calendar = .current) -> EventResolution {
        guard query.hasCriteria else {
            return .invalid("Falta indicar cuál evento: dime su título, el día o la hora para buscarlo.")
        }
        if let id = query.eventID {
            if let hit = candidates.first(where: { $0.id == id }) { return .found(hit) }
            return .notFound("No existe un evento con ese identificador (quizá ya se eliminó). No inventes identificadores: búscalo por título, día u hora.")
        }

        var pool = candidates
        if query.justCreated {
            let ids = Set(recent.filter { now.timeIntervalSince($0.createdAt) <= recentCreationWindow }.map(\.id))
            pool = pool.filter { ids.contains($0.id) }
        }
        if let date = query.date, let range = CalendarRange.resolve(date: date, days: 1, now: now, calendar: calendar) {
            pool = pool.filter { $0.start >= range.start && $0.start < range.end }
        }
        if let time = query.time, let target = minutes(fromClock: time) {
            pool = pool.filter { minutesOfDay($0.start, calendar) == target }
        }
        if let title = query.title {
            pool = pool.filter { titleMatches(query: title, title: $0.title) }
        }
        pool.sort { $0.start < $1.start }

        switch pool.count {
        case 0:
            return .notFound(notFoundText(query))
        case 1:
            return .found(pool[0])
        default:
            let shown = Array(pool.prefix(maxListed))
            var lines = shown.enumerated().map { "\($0.offset + 1). \(describe($0.element, calendar: calendar)) [id: \($0.element.id)]" }
            if pool.count > shown.count { lines.append("(y \(pool.count - shown.count) más)") }
            let message = "Hay \(pool.count) eventos que coinciden. NO elijas tú: pregúntale al usuario cuál (por la hora o el título) y luego vuelve a llamar con event_id exacto.\n"
                + lines.joined(separator: "\n")
            return .ambiguous(message, candidates: shown)
        }
    }

    private static func notFoundText(_ query: EventQuery) -> String {
        if query.justCreated {
            return "Viernes no ha creado ningún evento en las últimas horas que siga existiendo (o no coincide con lo pedido)."
        }
        var parts: [String] = []
        if let title = query.title { parts.append("título «\(title)»") }
        if let date = query.date { parts.append("día \(date)") }
        if let time = query.time { parts.append("hora \(time)") }
        return "No encontré ningún evento con " + parts.joined(separator: ", ") + ". Díselo al usuario; no modifiques ni borres otro evento."
    }

    /// «Reunión con Wendy» — vie 6 nov, 15:45–16:45 (calendario Casa)
    public static func describe(_ event: CalendarEventInfo, calendar: Calendar = .current) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "es_CO")
        day.timeZone = calendar.timeZone
        day.dateFormat = "EEE d MMM"
        let hour = DateFormatter()
        hour.locale = Locale(identifier: "es_CO")
        hour.timeZone = calendar.timeZone
        hour.dateFormat = "HH:mm"
        var text = "«\(event.title)» — \(day.string(from: event.start))"
        text += event.isAllDay ? ", todo el día" : ", \(hour.string(from: event.start))–\(hour.string(from: event.end))"
        if !event.location.isEmpty { text += ", en \(event.location)" }
        if !event.calendarTitle.isEmpty { text += " (calendario \(event.calendarTitle))" }
        if event.isRecurring { text += " [se repite]" }
        return text
    }
}

/// Cambios pedidos para un evento existente, ya resueltos contra el evento real (puro y comprobable).
public struct EventChanges: Equatable, Sendable {
    public var title: String?
    public var start: Date?
    public var durationMinutes: Int?
    public var location: String?

    public var isEmpty: Bool { title == nil && start == nil && durationMinutes == nil && location == nil }

    /// Traduce los argumentos `new_*` a cambios concretos. `new_date` conserva la hora del evento y `new_time` conserva el día.
    public static func from(args: [String: String], original: CalendarEventInfo, now: Date, calendar: Calendar = .current) -> Result<EventChanges, EventChangeError> {
        var changes = EventChanges()
        changes.title = args["new_title"]
        changes.location = args["new_location"]
        if let value = args["new_duration_minutes"] {
            guard let minutes = Int(value), (1...1440).contains(minutes) else { return .failure(.invalid("La duración nueva debe estar entre 1 y 1440 minutos.")) }
            changes.durationMinutes = minutes
        }

        var newStart: Date?
        if let value = args["new_start"] {
            guard let parsed = DateParsing.parse(value, timeZone: calendar.timeZone) else { return .failure(.invalid("La fecha nueva no es válida.")) }
            newStart = parsed
        }
        if let value = args["new_date"] {
            guard let range = CalendarRange.resolve(date: value, days: 1, now: now, calendar: calendar) else {
                return .failure(.invalid("No entendí el día nuevo («\(value)»)."))
            }
            let time = calendar.dateComponents([.hour, .minute], from: newStart ?? original.start)
            newStart = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: range.start)
        }
        if let value = args["new_time"] {
            guard let minutes = CalendarEventMatcher.minutes(fromClock: value) else { return .failure(.invalid("La hora nueva no es válida (usa 24 h, p. ej. 16:00).")) }
            let base = newStart ?? original.start
            newStart = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: base)
        }
        changes.start = newStart
        return .success(changes)
    }

    public var summaryText: String {
        var parts: [String] = []
        if let title = title { parts.append("título «\(title)»") }
        if let start = start {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "es_CO")
            formatter.dateFormat = "EEE d MMM, HH:mm"
            parts.append("inicio \(formatter.string(from: start))")
        }
        if let minutes = durationMinutes { parts.append("duración \(minutes) min") }
        if let location = location { parts.append("lugar «\(location)»") }
        return parts.joined(separator: ", ")
    }
}

public enum EventChangeError: Error, Equatable, Sendable {
    case invalid(String)
    public var message: String { if case .invalid(let text) = self { return text } else { return "" } }
}
