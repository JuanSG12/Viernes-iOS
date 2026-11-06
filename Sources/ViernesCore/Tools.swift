import Foundation

/// Política de confirmaciones por TIPO de acción (no se pregunta lo que el usuario ya pidió claramente):
/// - `safe`: consulta sin efectos (clima, agenda con permiso, recordatorios pendientes…). Se ejecuta directa.
/// - `reversible`: crea o modifica algo que el usuario puede deshacer o revisar (recordatorio, evento, borrador de correo
///   o mensaje, marcador). Se ejecuta directa cuando los datos bastan; el envío real lo confirma el usuario en la app destino.
/// - `sensitive`: guarda datos personales. Pide confirmación.
/// - `external`: saca datos del teléfono o lanza algo de terceros (enlaces, Atajos, Claude). Pide confirmación.
/// - `destructive`: borra. Pide confirmación.
public enum ToolRisk: String, Sendable {
    case safe, reversible, sensitive, external, destructive

    public var requiresConfirmation: Bool { self != .safe && self != .reversible }
}

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
    /// Éxito con datos estructurados para mostrar una tarjeta nativa (p. ej. clima). El texto sigue siendo lo que ve el modelo.
    case card(String, ToolCard)
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

/// Resultado de identificar el objetivo de una herramienta que actúa sobre algo YA existente (editar o borrar un evento).
public enum ToolResolution: Equatable, Sendable {
    /// El objetivo existe y es único: `call` lleva su identificador real y `detail` describe EXACTAMENTE qué se va a tocar
    /// (es lo que ve el usuario en la confirmación).
    case ready(ToolCall, detail: String)
    /// No se puede continuar. `askUser` = hay varias opciones y el modelo debe preguntar cuál (no es un fallo que enseñar).
    case blocked(String, askUser: Bool)
}

/// Ejecuta herramientas del dispositivo. La implementación vive en la app (EventKit, UIKit...).
public protocol ToolExecutor: AnyObject, Sendable {
    func execute(_ call: ToolCall) async -> ToolOutcome
    /// Antes de ejecutar (y de confirmar) una herramienta de `ToolCatalog.resolvedTools`, localiza el objeto real sobre el que actúa.
    /// `nil` = este ejecutor no necesita resolver nada.
    func resolve(_ call: ToolCall) async -> ToolResolution?
}

public extension ToolExecutor {
    func resolve(_ call: ToolCall) async -> ToolResolution? { nil }
}

/// Pide al usuario confirmar acciones sensibles (hoja de confirmación en la UI).
public protocol ConfirmationProvider: AnyObject, Sendable {
    func confirm(_ request: ConfirmationRequest) async -> Bool
}

public enum ToolCatalog {
    /// Herramientas que el motor de conversación maneja internamente (memoria local).
    public static let memoryToolNames: Set<String> = ["save_memory", "forget_memory", "search_memory"]
    /// Herramientas que actúan sobre algo que ya existe: se localiza el objeto real ANTES de confirmar o ejecutar.
    public static let resolvedTools: Set<String> = ["update_event", "delete_event"]
    /// Herramientas de calendario que necesitan LEER la agenda (existen solo si el usuario activó la lectura en Privacidad).
    public static let calendarReadTools: Set<String> = ["list_events", "update_event", "delete_event"]

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
            risk: .external),
        ToolDefinition(
            name: "create_reminder",
            summary: "Crea un recordatorio en la app Recordatorios.",
            parameters: [
                ToolParameter("title", "Texto del recordatorio"),
                ToolParameter("due", "Fecha y hora ISO 8601 local, p. ej. 2026-11-05T09:00", required: false),
                ToolParameter("notes", "Notas adicionales", required: false)
            ], risk: .reversible),
        ToolDefinition(
            name: "list_reminders",
            summary: "Lista los recordatorios pendientes.",
            parameters: [ToolParameter("limit", "Máximo de resultados (1-20)", required: false)],
            risk: .safe),
        ToolDefinition(
            name: "complete_reminder",
            summary: "Marca como completado un recordatorio pendiente buscándolo por título.",
            parameters: [ToolParameter("title", "Título (o parte) del recordatorio")],
            risk: .reversible),
        ToolDefinition(
            name: "create_event",
            summary: "Crea un evento en el Calendario.",
            parameters: [
                ToolParameter("title", "Título del evento"),
                ToolParameter("start", "Inicio ISO 8601 local, p. ej. 2026-11-05T15:00"),
                ToolParameter("duration_minutes", "Duración en minutos (1-1440, por defecto 60)", required: false),
                ToolParameter("location", "Lugar", required: false)
            ], risk: .reversible),
        ToolDefinition(
            name: "update_event",
            summary: "Modifica un evento que YA existe en el Calendario (hora, día, título, duración o lugar). Lo localiza por título, día u hora; si varios coinciden la app lo dirá y debes preguntar cuál. Solo existe si el usuario activó la lectura del calendario.",
            parameters: [
                ToolParameter("title", "Parte del título del evento a buscar", required: false),
                ToolParameter("date", "Día en que está ahora: today, tomorrow, un día de la semana o YYYY-MM-DD", required: false),
                ToolParameter("time", "Hora de inicio actual, 24 h, p. ej. 08:00", required: false),
                ToolParameter("just_created", "true si el usuario habla del evento que Viernes acaba de crear", required: false),
                ToolParameter("event_id", "Identificador exacto, solo si lo dio una herramienta", required: false),
                ToolParameter("new_title", "Título nuevo", required: false),
                ToolParameter("new_start", "Inicio nuevo ISO 8601 local, p. ej. 2026-11-06T16:00", required: false),
                ToolParameter("new_date", "Cambiar solo el día y conservar la hora: tomorrow, viernes o YYYY-MM-DD", required: false),
                ToolParameter("new_time", "Cambiar solo la hora y conservar el día, 24 h, p. ej. 16:00", required: false),
                ToolParameter("new_duration_minutes", "Duración nueva en minutos (1-1440)", required: false),
                ToolParameter("new_location", "Lugar nuevo", required: false)
            ], risk: .reversible),
        ToolDefinition(
            name: "delete_event",
            summary: "Elimina un evento que YA existe en el Calendario. Lo localiza por título, día u hora; si varios coinciden la app lo dirá y debes preguntar cuál. La app muestra el evento exacto y pide confirmación. Solo existe si el usuario activó la lectura del calendario.",
            parameters: [
                ToolParameter("title", "Parte del título del evento a buscar", required: false),
                ToolParameter("date", "Día del evento: today, tomorrow, un día de la semana o YYYY-MM-DD", required: false),
                ToolParameter("time", "Hora de inicio, 24 h, p. ej. 08:00", required: false),
                ToolParameter("just_created", "true si el usuario habla del evento que Viernes acaba de crear", required: false),
                ToolParameter("event_id", "Identificador exacto, solo si lo dio una herramienta", required: false)
            ], risk: .destructive),
        ToolDefinition(
            name: "run_shortcut",
            summary: "Ejecuta un Atajo de la app Atajos por su nombre exacto.",
            parameters: [
                ToolParameter("name", "Nombre exacto del atajo"),
                ToolParameter("input", "Texto de entrada opcional", required: false)
            ], risk: .external),
        ToolDefinition(
            name: "device_info",
            summary: "Consulta datos del dispositivo: hora, batería, almacenamiento, modelo.",
            parameters: [ToolParameter("what", "battery, storage, time, device o all", required: false)],
            risk: .safe),
        ToolDefinition(
            name: "get_weather",
            summary: "Consulta el clima actual y el pronóstico de hoy y mañana de una ciudad (usa internet; solo se envía el nombre de la ciudad).",
            parameters: [ToolParameter("city", "Ciudad, p. ej. Bogotá o Medellín, Colombia")],
            risk: .safe),
        ToolDefinition(
            name: "list_events",
            summary: "Lee los eventos de tu calendario de un día o de varios días seguidos. Solo existe si el usuario activó «Permitir que Viernes lea mi calendario» en Privacidad.",
            parameters: [
                ToolParameter("date", "today, tomorrow o una fecha YYYY-MM-DD"),
                ToolParameter("days", "Cuántos días leer, de 1 a 7 (por defecto 1)", required: false)
            ], risk: .safe),
        ToolDefinition(
            name: "find_contact",
            summary: "Busca un contacto por nombre y devuelve su correo y teléfonos. Solo existe si el usuario activó «Permitir que Viernes lea mis contactos» en Privacidad.",
            parameters: [ToolParameter("name", "Nombre o apellido a buscar")],
            risk: .safe),
        ToolDefinition(
            name: "compose_email",
            summary: "Prepara un BORRADOR de correo en la app Correo. No envía nada: el usuario revisa y pulsa Enviar.",
            parameters: [
                ToolParameter("body", "Texto del correo"),
                ToolParameter("to", "Dirección de correo del destinatario", required: false),
                ToolParameter("subject", "Asunto", required: false)
            ], risk: .reversible),
        ToolDefinition(
            name: "compose_message",
            summary: "Prepara un BORRADOR de mensaje (SMS/iMessage o WhatsApp). No envía nada: el usuario revisa y pulsa Enviar.",
            parameters: [
                ToolParameter("body", "Texto del mensaje"),
                ToolParameter("to", "Teléfono del destinatario con prefijo, p. ej. +573001234567", required: false),
                ToolParameter("app", "sms (por defecto) o whatsapp", required: false)
            ], risk: .reversible),
        ToolDefinition(
            name: "call_phone",
            summary: "Abre el marcador del teléfono con un número. iOS pide su propia confirmación antes de llamar.",
            parameters: [ToolParameter("number", "Número con prefijo, p. ej. +573001234567")],
            risk: .reversible),
        ToolDefinition(
            name: "ask_claude",
            summary: "Envía una pregunta a la app de Claude del usuario (sale de Viernes; la respuesta no vuelve aquí salvo que exista un Atajo configurado).",
            parameters: [ToolParameter("prompt", "Pregunta completa para Claude")],
            risk: .external),
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
            risk: .destructive)
    ]

    public static func definition(named name: String) -> ToolDefinition? { all.first { $0.name == name } }
}

/// Extrae el JSON de `<tool>{...}</tool>` a una `ToolCall`. Tolera las variantes habituales de los modelos:
/// `args` / `arguments` / `parameters`, argumentos como texto JSON y el envoltorio `{"function":{…}}` del estilo OpenAI.
public enum ToolCallParser {
    private static let argumentKeys = ["args", "arguments", "parameters", "input"]

    public static func parse(_ json: String) -> ToolCall? {
        guard let data = json.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return call(from: object)
    }

    static func call(from original: [String: Any]) -> ToolCall? {
        var object = original
        if let inner = object["function"] as? [String: Any] { object = inner }
        guard var name = object["name"] as? String else { return nil }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("functions.") { name = String(name.dropFirst("functions.".count)) }
        guard !name.isEmpty else { return nil }

        var raw: [String: Any] = [:]
        for key in argumentKeys {
            if let dictionary = object[key] as? [String: Any] { raw = dictionary; break }
            if let text = object[key] as? String, let data = text.data(using: .utf8),
               let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { raw = dictionary; break }
        }
        return ToolCall(name: name, args: stringArguments(raw))
    }

    static func stringArguments(_ raw: [String: Any]) -> [String: String] {
        var args: [String: String] = [:]
        for (key, value) in raw {
            switch value {
            case let string as String: args[key] = string
            case let number as NSNumber: args[key] = number.stringValue
            default: continue          // objetos anidados no se admiten
            }
        }
        return args
    }
}
