import Foundation

public enum ToolRisk: String, Sendable { case safe, sensitive }

public struct ToolParameter: Sendable, Equatable {
    public let name: String
    public let description: String
    public let required: Bool
    public init(_ name: String, _ description: String, required: Bool = true) {
        self.name = name
        self.description = description
        self.required = required
    }
}

public struct ToolDefinition: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let summary: String
    public let parameters: [ToolParameter]
    public let risk: ToolRisk
    public init(name: String, summary: String, parameters: [ToolParameter], risk: ToolRisk) {
        self.name = name
        self.summary = summary
        self.parameters = parameters
        self.risk = risk
    }
}

public struct ToolCall: Equatable, Sendable {
    public let name: String
    public let args: [String: String]
    public init(name: String, args: [String: String]) {
        self.name = name
        self.args = args
    }
}

public enum ToolOutcome: Equatable, Sendable {
    case success(String)
    case failure(String)
}

public struct ConfirmationRequest: Equatable, Sendable {
    public let tool: String
    public let title: String
    public let detail: String
    public init(tool: String, title: String, detail: String) {
        self.tool = tool
        self.title = title
        self.detail = detail
    }
}

/// Ejecuta herramientas del dispositivo. La implementación vive en la app (EventKit, UIKit...).
public protocol ToolExecutor: AnyObject, Sendable {
    func execute(_ call: ToolCall) async -> ToolOutcome
}

/// Pide al usuario confirmar acciones sensibles (hoja de confirmación en la UI).
public protocol ConfirmationProvider: AnyObject, Sendable {
    func confirm(_ request: ConfirmationRequest) async -> Bool
}

public enum ToolCatalog {
    /// Herramientas que el motor de conversación maneja internamente (memoria local).
    public static let memoryToolNames: Set<String> = ["save_memory", "forget_memory", "search_memory"]

    public static let all: [ToolDefinition] = [
        ToolDefinition(
            name: "open_app",
            summary: "Abre una app instalada (WhatsApp, Spotify, Mapas, Calendario, Notas, Claude, Atajos...).",
            parameters: [ToolParameter("app", "Nombre de la app, p. ej. spotify, mapas, calendario")],
            risk: .safe),
        ToolDefinition(
            name: "open_url",
            summary: "Abre un enlace https en el navegador.",
            parameters: [ToolParameter("url", "URL completa que empiece con https://")],
            risk: .sensitive),
        ToolDefinition(
            name: "create_reminder",
            summary: "Crea un recordatorio en la app Recordatorios.",
            parameters: [
                ToolParameter("title", "Texto del recordatorio"),
                ToolParameter("due", "Fecha y hora ISO 8601 local, p. ej. 2026-11-05T09:00", required: false),
                ToolParameter("notes", "Notas adicionales", required: false)
            ], risk: .sensitive),
        ToolDefinition(
            name: "list_reminders",
            summary: "Lista los recordatorios pendientes.",
            parameters: [ToolParameter("limit", "Máximo de resultados (1-20)", required: false)],
            risk: .safe),
        ToolDefinition(
            name: "complete_reminder",
            summary: "Marca como completado un recordatorio pendiente buscándolo por título.",
            parameters: [ToolParameter("title", "Título (o parte) del recordatorio")],
            risk: .sensitive),
        ToolDefinition(
            name: "create_event",
            summary: "Crea un evento en el Calendario.",
            parameters: [
                ToolParameter("title", "Título del evento"),
                ToolParameter("start", "Inicio ISO 8601 local, p. ej. 2026-11-05T15:00"),
                ToolParameter("duration_minutes", "Duración en minutos (1-1440, por defecto 60)", required: false),
                ToolParameter("location", "Lugar", required: false)
            ], risk: .sensitive),
        ToolDefinition(
            name: "run_shortcut",
            summary: "Ejecuta un Atajo de la app Atajos por su nombre exacto.",
            parameters: [
                ToolParameter("name", "Nombre exacto del atajo"),
                ToolParameter("input", "Texto de entrada opcional", required: false)
            ], risk: .sensitive),
        ToolDefinition(
            name: "device_info",
            summary: "Consulta datos del dispositivo: hora, batería, almacenamiento, modelo.",
            parameters: [ToolParameter("what", "battery, storage, time, device o all", required: false)],
            risk: .safe),
        ToolDefinition(
            name: "ask_claude",
            summary: "Envía una pregunta a la app de Claude del usuario (sale de Viernes; la respuesta no vuelve aquí salvo que exista un Atajo configurado).",
            parameters: [ToolParameter("prompt", "Pregunta completa para Claude")],
            risk: .sensitive),
        ToolDefinition(
            name: "save_memory",
            summary: "Guarda un recuerdo local (preferencia, proyecto o dato) que el usuario pidió conservar.",
            parameters: [
                ToolParameter("text", "Texto del recuerdo, redactado de forma autocontenida"),
                ToolParameter("kind", "preference, project o fact", required: false)
            ], risk: .sensitive),
        ToolDefinition(
            name: "search_memory",
            summary: "Busca en los recuerdos locales.",
            parameters: [ToolParameter("query", "Qué buscar")],
            risk: .safe),
        ToolDefinition(
            name: "forget_memory",
            summary: "Elimina el recuerdo local que mejor coincida con la consulta.",
            parameters: [ToolParameter("query", "Qué olvidar")],
            risk: .sensitive)
    ]

    public static func definition(named name: String) -> ToolDefinition? { all.first { $0.name == name } }
}

/// Extrae el JSON de `<tool>{...}</tool>` a una `ToolCall`.
public enum ToolCallParser {
    public static func parse(_ json: String) -> ToolCall? {
        guard let data = json.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String, !name.isEmpty
        else { return nil }
        var args: [String: String] = [:]
        if let raw = object["args"] as? [String: Any] {
            for (key, value) in raw {
                switch value {
                case let string as String: args[key] = string
                case let number as NSNumber: args[key] = number.stringValue
                default: continue          // objetos anidados no se admiten
                }
            }
        }
        return ToolCall(name: name, args: args)
    }
}
