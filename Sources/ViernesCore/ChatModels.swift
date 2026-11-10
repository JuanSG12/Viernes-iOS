import Foundation

public enum ChatRole: String, Codable, Sendable {
    case user, assistant, tool
}

public enum ActionOutcome: Codable, Equatable, Sendable {
    case executed(String)       // la acción se ejecutó de verdad; texto = resultado real
    case declined               // el usuario rechazó la confirmación
    case failed(String)         // se intentó y falló (o no pasó la validación)

    public var isExecuted: Bool { if case .executed = self { return true } else { return false } }
}

/// Datos estructurados de un resultado para dibujar una tarjeta nativa (no una imagen). Todo son textos ya formateados.
public struct ToolCard: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case weather }
    public var kind: Kind
    public var fields: [String: String]

    public init(kind: Kind, fields: [String: String]) {
        self.kind = kind
        self.fields = fields
    }
}

/// Registro verificable de lo que Viernes hizo realmente. La UI muestra ESTO, no lo que el modelo diga.
public struct ActionRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var tool: String
    public var summary: String
    public var outcome: ActionOutcome
    public var date: Date
    /// Tarjeta nativa opcional (opcional para que el historial guardado antes de existir siga leyéndose).
    public var card: ToolCard?
    /// `false` para errores puramente técnicos que el modelo puede corregir solo (llamada mal formada, argumentos inválidos):
    /// quedan en los diagnósticos y no se enseñan al usuario. `nil` = visible.
    public var showToUser: Bool?

    public var isVisible: Bool { showToUser != false }

    public init(id: UUID = UUID(), tool: String, summary: String, outcome: ActionOutcome, date: Date = Date(),
                card: ToolCard? = nil, showToUser: Bool? = nil) {
        self.id = id
        self.tool = tool
        self.summary = summary
        self.outcome = outcome
        self.date = date
        self.card = card
        self.showToUser = showToUser
    }
}

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var role: ChatRole
    public var text: String
    public var date: Date
    public var actions: [ActionRecord]
    /// Nombre del modelo/motor que produjo la respuesta (transparencia sobre qué cerebro respondió).
    public var engineName: String?
    /// Metadatos de los archivos adjuntos (el contenido no se guarda en el historial).
    public var attachments: [AttachmentRef]?

    public init(id: UUID = UUID(), role: ChatRole, text: String, date: Date = Date(),
                actions: [ActionRecord] = [], engineName: String? = nil, attachments: [AttachmentRef]? = nil) {
        self.attachments = attachments
        self.id = id
        self.role = role
        self.text = text
        self.date = date
        self.actions = actions
        self.engineName = engineName
    }
}

/// Un turno tal como lo recibe el motor de lenguaje.
public struct ChatTurn: Equatable, Sendable {
    public enum Role: String, Sendable { case user, assistant }
    public var role: Role
    public var content: String
    /// Imágenes del turno (solo los motores con visión las reciben).
    public var images: [ImagePart]
    public init(role: Role, content: String, images: [ImagePart] = []) {
        self.role = role
        self.content = content
        self.images = images
    }
}

public struct GenerationRequest: Sendable {
    public var system: String
    public var turns: [ChatTurn]          // el último turno es del usuario
    public var maxTokens: Int
    public var temperature: Double
    public init(system: String, turns: [ChatTurn], maxTokens: Int = 512, temperature: Double = 0.6) {
        self.system = system
        self.turns = turns
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}
