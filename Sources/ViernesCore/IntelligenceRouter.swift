import Foundation

// Enrutador de inteligencia: clasifica cada petición ANTES de llamar a un modelo para (1) resolver sin modelo lo que el código ya sabe,
// (2) enviar solo las instrucciones y herramientas que la petición necesita, (3) limitar el espacio de salida y el historial, y
// (4) elegir el modelo menos costoso que la resuelva entre los proveedores que el USUARIO autorizó. Nada de esto manda datos a un
// proveedor que el usuario no haya autorizado, ni cambia de proveedor si la opción está apagada (por defecto lo está).

public enum RequestClass: String, Codable, CaseIterable, Sendable {
    case simpleChat, generalQuestion, localOperation, memoryQuery, toolExecution, complexReasoning, documentAnalysis, imageAnalysis, contentGeneration

    public var title: String {
        switch self {
        case .simpleChat: return "conversación sencilla"
        case .generalQuestion: return "pregunta general"
        case .localOperation: return "operación local"
        case .memoryQuery: return "consulta de memoria"
        case .toolExecution: return "uso de herramientas"
        case .complexReasoning: return "razonamiento complejo"
        case .documentAnalysis: return "análisis de documentos"
        case .imageAnalysis: return "análisis de imágenes"
        case .contentGeneration: return "generación de contenido"
        }
    }

    /// Tope de tokens de SALIDA para la nube. Algunos proveedores lo reservan contra su límite por minuto aunque no se use.
    public var outputBudget: Int {
        switch self {
        case .localOperation: return 300
        case .simpleChat, .memoryQuery: return 700
        case .toolExecution: return 900
        case .generalQuestion: return 1_000
        case .imageAnalysis: return 1_500
        case .documentAnalysis: return 1_800
        case .complexReasoning, .contentGeneration: return 2_000
        }
    }

    /// Caracteres de historial que se envían (el resto se resume localmente).
    public var historyChars: Int {
        switch self {
        case .localOperation: return 500
        case .simpleChat, .memoryQuery: return 2_000
        case .generalQuestion: return 3_000
        case .toolExecution, .imageAnalysis: return 3_500
        case .contentGeneration: return 4_000
        case .documentAnalysis: return 4_500
        case .complexReasoning: return 6_000
        }
    }

    /// ¿Merece el modelo más capaz? (razonamiento, documentos, imágenes y herramientas) El resto va al modelo económico.
    public var needsStrongModel: Bool {
        switch self {
        case .complexReasoning, .documentAnalysis, .imageAnalysis, .toolExecution: return true
        default: return false
        }
    }

    /// ¿Puede resolverlo bien el modelo local pequeño? (conversación sencilla y recuerdos: es lo más privado y no gasta cuota)
    public var localFriendly: Bool { self == .simpleChat || self == .memoryQuery }
}

// MARK: Temas de herramientas

public enum ToolGroup: String, CaseIterable, Sendable {
    case calendar, reminders, messaging, weather, web, memory, library, device, claude
}

public enum ToolGroups {
    public static func group(of tool: String) -> ToolGroup {
        switch tool {
        case "create_event", "update_event", "delete_event", "list_events": return .calendar
        case "create_reminder", "list_reminders", "complete_reminder": return .reminders
        case "find_contact", "compose_email", "compose_message", "call_phone": return .messaging
        case "get_weather": return .weather
        case "web_search", "read_page": return .web
        case "save_memory", "search_memory", "forget_memory": return .memory
        case "search_library": return .library
        case "ask_claude": return .claude
        default: return .device
        }
    }

    /// Separa las herramientas en «con detalle» (las del tema de la petición) y «solo nombre» (las demás).
    public static func split(_ tools: [ToolDefinition], focus: Set<ToolGroup>) -> (detailed: [ToolDefinition], compact: [ToolDefinition]) {
        var detailed: [ToolDefinition] = []
        var compact: [ToolDefinition] = []
        for tool in tools {
            if focus.contains(group(of: tool.name)) { detailed.append(tool) } else { compact.append(tool) }
        }
        return (detailed, compact)
    }
}

// MARK: Clasificación

public struct RequestAnalysis: Equatable, Sendable {
    public var kind: RequestClass
    public var groups: Set<ToolGroup>
    public var reason: String
}

public enum RequestClassifier {
    private static let keywords: [(ToolGroup, [String])] = [
        (.calendar, [" agenda", " calendario", " evento", " reunion", " cita ", " citas ", " junta ", " agendar", " agendame", " programame", " mi dia ", " mi semana", " organiza", " cancela la ", " mover la "]),
        (.reminders, [" recuerdame", " recordatorio", " recordarme", " avisame", " pendiente", " tarea ", " tareas ", " alarma"]),
        (.messaging, [" whatsapp", " wasap", " mensaje", " escribele", " enviale", " mandale", " manda un", " envia un", " correo", " email", " mail ", " llama a", " llamale", " llamar ", " llamada", " telefono", " contacto", " sms"]),
        (.weather, [" clima", " pronostico", " llover", " lluvia", " temperatura", " hara frio", " hara calor"]),
        (.web, [" busca en internet", " busca en la web", " buscar en internet", " investiga", " noticias", " en internet", " en linea", " googlea", " http", " pagina web"]),
        (.memory, [" recuerda que", " recuerdas", " te dije", " acuerdate", " olvida", " guarda que", " anota que", " sabes de mi", " mi memoria", " lo que sabes"]),
        (.library, [" biblioteca", " mis documentos", " mis archivos", " mis notas", " pdf"]),
        (.device, [" abre ", " abrir ", " atajo", " bateria", " almacenamiento", " version de ios", " dispositivo", " linterna"]),
        (.claude, [" claude"])
    ]

    private static let complexMarkers: [String] = [
        " analiza", " explica por que", " compara", " paso a paso", " razona", " demuestra", " estrategia", " pros y contras",
        " calcula", " resuelve", " optimiza", " depura", " codigo", " algoritmo", " diseña", " arquitectura", " evalua"
    ]
    private static let contentMarkers: [String] = [" redacta", " escribe un", " escribe una", " escribeme", " genera ", " resume", " resumen", " traduce", " poema", " carta ", " discurso", " cuento"]
    private static let questionStarts: [String] = [" que ", " quien", " como ", " cuando", " donde", " por que", " cual", " cuanto", " cuantos", " cuantas"]

    /// Texto plegado (minúsculas, sin acentos, sin signos) con un espacio a cada lado, para buscar palabras completas.
    static func padded(_ text: String) -> String {
        let folded: String = TextNormalizer.fold(text)
        var scalars: [Character] = []
        for scalar in folded.unicodeScalars {
            scalars.append(CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " ")
        }
        return " " + String(scalars) + " "
    }

    public static func groups(in text: String) -> Set<ToolGroup> {
        let padded: String = Self.padded(text)
        var found = Set<ToolGroup>()
        for (group, words) in keywords where words.contains(where: { padded.contains($0) }) { found.insert(group) }
        return found
    }

    /// `previousGroups`: temas de la petición anterior. Una respuesta corta a una pregunta del asistente («A Checho», «mañana a las 8»)
    /// sigue siendo del mismo tema aunque no repita ninguna palabra clave.
    public static func analyze(_ text: String, hasImages: Bool, hasDocuments: Bool, previousGroups: Set<ToolGroup> = [],
                               lastAssistantAskedQuestion: Bool = false) -> RequestAnalysis {
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var found: Set<ToolGroup> = groups(in: trimmed)
        let padded: String = Self.padded(trimmed)

        if hasImages { return RequestAnalysis(kind: .imageAnalysis, groups: found, reason: "hay imágenes") }
        if hasDocuments { return RequestAnalysis(kind: .documentAnalysis, groups: found.union([.library]), reason: "hay documentos") }

        if found.isEmpty, !previousGroups.isEmpty {
            let shortFollowUp: Bool = trimmed.count <= 90 || (lastAssistantAskedQuestion && trimmed.count <= 220)
            if shortFollowUp {
                found = previousGroups
                return RequestAnalysis(kind: .toolExecution, groups: found, reason: "continúa el tema anterior")
            }
        }
        if !found.isEmpty {
            if found == [.memory] { return RequestAnalysis(kind: .memoryQuery, groups: found, reason: "habla de memoria") }
            return RequestAnalysis(kind: .toolExecution, groups: found, reason: "menciona herramientas")
        }
        if trimmed.count > 400 || complexMarkers.contains(where: { padded.contains($0) }) {
            return RequestAnalysis(kind: .complexReasoning, groups: [], reason: "pide razonar o analizar")
        }
        if contentMarkers.contains(where: { padded.contains($0) }) {
            return RequestAnalysis(kind: .contentGeneration, groups: [], reason: "pide generar texto")
        }
        if trimmed.contains("?") || trimmed.contains("¿") || questionStarts.contains(where: { padded.hasPrefix($0) }) || trimmed.count > 60 {
            return RequestAnalysis(kind: .generalQuestion, groups: [], reason: "pregunta general")
        }
        return RequestAnalysis(kind: .simpleChat, groups: [], reason: "conversación corta")
    }
}

// MARK: Respuestas deterministas (sin modelo)

public enum DeterministicAnswers {
    private static let timePhrases: Set<String> = ["que hora es", "que hora son", "dime la hora", "me das la hora", "la hora", "hora actual", "que hora tienes", "tienes hora", "que horas son"]
    private static let datePhrases: Set<String> = ["que dia es hoy", "que dia es", "que fecha es hoy", "que fecha es", "fecha de hoy", "a que fecha estamos", "a cuanto estamos", "que dia estamos", "en que dia estamos"]

    /// Respuesta calculada por código (hora y fecha) o `nil`. Solo frases exactas: ante la duda, se pregunta al modelo.
    public static func answer(for text: String, now: Date, timeZone: TimeZone) -> String? {
        var key: String = RequestClassifier.padded(text).split(separator: " ").joined(separator: " ")
        for prefix in ["viernes ", "oye viernes ", "hola viernes ", "disculpa ", "oye "] where key.hasPrefix(prefix) { key = String(key.dropFirst(prefix.count)) }
        for suffix in [" viernes", " por favor", " porfa"] where key.hasSuffix(suffix) { key = String(key.dropLast(suffix.count)) }
        key = key.trimmingCharacters(in: .whitespaces)
        if timePhrases.contains(key) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "es_CO")
            formatter.timeZone = timeZone
            formatter.dateFormat = "h:mm a"
            return "Son las \(formatter.string(from: now))."
        }
        if datePhrases.contains(key) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "es_CO")
            formatter.timeZone = timeZone
            formatter.dateFormat = "EEEE d 'de' MMMM 'de' yyyy"
            return "Hoy es \(formatter.string(from: now))."
        }
        return nil
    }
}

// MARK: Historial: ventana + resumen local

public enum HistoryCompactor {
    /// Mensajes (los más antiguos) que NO caben en la ventana de `budget` caracteres.
    public static func dropped(from messages: [ChatMessage], budget: Int) -> [ChatMessage] {
        var used = 0
        var keptCount = 0
        for message in messages.reversed() where message.role != .tool {
            let cost: Int = message.text.count
            if used + cost > budget, keptCount > 0 { break }
            used += cost
            keptCount += 1
        }
        let eligible: [ChatMessage] = messages.filter { $0.role != .tool }
        guard eligible.count > keptCount else { return [] }
        return Array(eligible.prefix(eligible.count - keptCount))
    }

    /// Resumen EXTRACTIVO (sin llamar a ningún modelo) de lo que quedó fuera de la ventana: qué pidió el usuario. Ayuda a no perder el
    /// hilo con una ventana pequeña. Es un resumen recortado y se presenta como tal.
    public static func digest(_ dropped: [ChatMessage], maxChars: Int = 420) -> String? {
        let users: [String] = dropped.filter { $0.role == .user }.map { message in
            let clean: String = message.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return clean.count > 90 ? String(clean.prefix(90)) + "…" : clean
        }.filter { !$0.isEmpty }
        guard !users.isEmpty else { return nil }
        var lines: [String] = []
        var total = 0
        for line in users.reversed() {                      // lo más reciente primero
            if total + line.count + 4 > maxChars { break }
            lines.append("• \(line)")
            total += line.count + 4
        }
        guard !lines.isEmpty else { return nil }
        return "Resumen automático y recortado de lo que el usuario pidió antes en esta conversación (puede omitir detalles):\n" + lines.reversed().joined(separator: "\n")
    }
}

// MARK: Caché de respuestas (solo en memoria, con caducidad)

public final class ResponseCache: @unchecked Sendable {
    private struct Entry { var text: String; var expires: Date }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let capacity: Int
    private let ttl: TimeInterval

    public init(capacity: Int = 40, ttl: TimeInterval = 600) {
        self.capacity = max(1, capacity)
        self.ttl = ttl
    }

    private static let volatileMarkers: [String] = [
        " hoy ", " ahora", " manana", " ayer", " actual", " clima", " tiempo ", " noticias", " agenda", " calendario", " contacto",
        " precio", " cotizacion", " dolar", " trm ", " resultado", " partido", " esta semana", " este mes", " ultimo", " ultima", " reciente", " hora "
    ]

    /// Solo preguntas generales y de generación, sin documentos, imágenes ni herramientas, y sin palabras de información que cambia
    /// (calendario, clima, contactos, noticias, precios…): esas NUNCA se reutilizan.
    public static func isCacheable(text: String, kind: RequestClass) -> Bool {
        guard kind == .generalQuestion || kind == .contentGeneration else { return false }
        let padded: String = RequestClassifier.padded(text)
        return !volatileMarkers.contains { padded.contains($0) } && text.count <= 600
    }

    public static func key(provider: String, model: String, userText: String, context: String) -> String {
        "\(provider)|\(model)|\(TextNormalizer.fold(userText))|\(context.hashValue)"
    }

    public func get(_ key: String, now: Date = Date()) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        if entry.expires <= now {
            entries[key] = nil
            order.removeAll { $0 == key }
            return nil
        }
        return entry.text
    }

    public func put(_ key: String, text: String, now: Date = Date()) {
        guard !text.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if entries[key] == nil { order.append(key) }
        entries[key] = Entry(text: text, expires: now.addingTimeInterval(ttl))
        while order.count > capacity {
            let oldest: String = order.removeFirst()
            entries[oldest] = nil
        }
    }

    public func clear() {
        lock.lock()
        entries = [:]
        order = []
        lock.unlock()
    }
}

// MARK: Enrutado entre proveedores (siempre con autorización del usuario)

public enum ModelTier: String, Codable, Sendable { case light, strong }

public struct TierModels: Codable, Equatable, Sendable {
    public var light: String?
    public var strong: String?
    public init(light: String? = nil, strong: String? = nil) {
        self.light = light
        self.strong = strong
    }
}

public struct RoutingSettings: Codable, Equatable, Sendable {
    /// Apagado por defecto: mientras lo esté, se usa SIEMPRE el cerebro que elegiste, sin enrutar.
    public var enabled: Bool
    /// Conversación sencilla y recuerdos con el modelo local (si está listo): lo más privado y no gasta cuota.
    public var preferLocalForSimple: Bool
    /// Si un proveedor falla (cuota, saldo, servicio caído), usar OTRO que ya autorizaste. Apagado por defecto.
    public var allowFailover: Bool
    /// Proveedor preferido para tareas frecuentes (el económico). `nil` = el orden de preferencia.
    public var economyProviderID: String?
    public var order: [String]
    public var tiers: [String: TierModels]

    public static let defaultOrder: [String] = ["gemini", "cerebras", "openai", "groq"]
    public static let `default` = RoutingSettings(enabled: false, preferLocalForSimple: false, allowFailover: false,
                                                  economyProviderID: nil, order: defaultOrder, tiers: [:])

    public init(enabled: Bool, preferLocalForSimple: Bool, allowFailover: Bool, economyProviderID: String?, order: [String], tiers: [String: TierModels]) {
        self.enabled = enabled
        self.preferLocalForSimple = preferLocalForSimple
        self.allowFailover = allowFailover
        self.economyProviderID = economyProviderID
        self.order = order
        self.tiers = tiers
    }

    public func sanitized() -> RoutingSettings {
        var copy = self
        let known: Set<String> = Set(CloudProviders.all.map(\.id))
        var seen = Set<String>()
        var cleanOrder: [String] = []
        for id in order where known.contains(id) && !seen.contains(id) { cleanOrder.append(id); seen.insert(id) }
        for id in Self.defaultOrder where !seen.contains(id) { cleanOrder.append(id) }
        copy.order = cleanOrder
        if let eco = economyProviderID, !known.contains(eco) { copy.economyProviderID = nil }
        var cleanTiers: [String: TierModels] = [:]
        for (id, value) in tiers where known.contains(id) {
            cleanTiers[id] = TierModels(light: Self.cleanModel(value.light), strong: Self.cleanModel(value.strong))
        }
        copy.tiers = cleanTiers
        return copy
    }

    private static func cleanModel(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value.count <= 100,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    /// Modelo de un proveedor para un nivel: el que elegiste; si no, el predeterminado del proveedor (o, para el nivel fuerte,
    /// el que ya tenías seleccionado en ese proveedor). Nunca se inventa un identificador.
    public func model(for providerID: String, tier: ModelTier, selected: CloudBrainSettings) -> String {
        let preset: CloudProviderPreset = CloudProviders.preset(id: providerID)
        let configured: TierModels? = tiers[providerID]
        switch tier {
        case .light:
            return configured?.light ?? preset.defaultModel
        case .strong:
            if let strong = configured?.strong { return strong }
            if let light = configured?.light { return light }
            return selected.providerID == providerID ? selected.model : preset.defaultModel
        }
    }
}

public struct RouteInputs: Sendable {
    public var configured: Set<String>      // proveedores con clave guardada
    public var authorized: Set<String>      // autorizados por el usuario (Consumo y presupuesto)
    public var healthy: Set<String>         // sin pausa del circuit breaker y dentro del presupuesto
    public var localReady: Bool
    public var selected: CloudBrainSettings

    public init(configured: Set<String>, authorized: Set<String>, healthy: Set<String>, localReady: Bool, selected: CloudBrainSettings) {
        self.configured = configured
        self.authorized = authorized
        self.healthy = healthy
        self.localReady = localReady
        self.selected = selected
    }
}

public enum RouteTarget: Equatable, Sendable {
    case local
    case cloud(providerID: String, model: String)
}

public struct IntelligenceRoute: Equatable, Sendable {
    public var kind: RequestClass
    public var target: RouteTarget
    public var fallbacks: [RouteTarget]
    public var reason: String
}

public enum IntelligenceRouter {
    /// `nil` = no enrutar (apagado, o ningún proveedor elegible): la app usa el cerebro que el usuario eligió.
    public static func decide(kind: RequestClass, settings raw: RoutingSettings, inputs: RouteInputs) -> IntelligenceRoute? {
        let settings: RoutingSettings = raw.sanitized()
        guard settings.enabled else { return nil }
        let tier: ModelTier = kind.needsStrongModel ? .strong : .light

        if kind.localFriendly, settings.preferLocalForSimple, inputs.localReady {
            return IntelligenceRoute(kind: kind, target: .local, fallbacks: [], reason: "\(kind.title) → modelo local (privado, sin cuota)")
        }
        var order: [String] = settings.order
        if tier == .light, let eco = settings.economyProviderID, let index = order.firstIndex(of: eco) {
            order.remove(at: index)
            order.insert(eco, at: 0)
        }
        let eligible: [String] = order.filter { inputs.configured.contains($0) && inputs.authorized.contains($0) && inputs.healthy.contains($0) }
        guard let first = eligible.first else { return nil }
        let model: String = settings.model(for: first, tier: tier, selected: inputs.selected)
        let fallbacks: [RouteTarget] = settings.allowFailover
            ? eligible.dropFirst().map { RouteTarget.cloud(providerID: $0, model: settings.model(for: $0, tier: tier, selected: inputs.selected)) }
            : []
        return IntelligenceRoute(kind: kind, target: .cloud(providerID: first, model: model), fallbacks: fallbacks,
                             reason: "\(kind.title) → \(CloudProviders.preset(id: first).displayName) (\(model))")
    }
}
