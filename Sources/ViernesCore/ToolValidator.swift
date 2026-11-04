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
}
