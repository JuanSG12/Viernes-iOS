import Foundation

public enum MemoryKind: String, Codable, CaseIterable, Sendable {
    case preference      // "Prefiero respuestas cortas"
    case project         // "Estoy construyendo una app de inventario"
    case fact            // datos personales que el usuario pidió recordar
    case summary         // resumen de una conversación

    public var displayName: String {
        switch self {
        case .preference: return "Preferencia"
        case .project: return "Proyecto"
        case .fact: return "Dato"
        case .summary: return "Resumen"
        }
    }
}

public enum MemorySource: String, Codable, Sendable {
    case userExplicit        // el usuario dijo "recuerda que..." o lo escribió en la pantalla Memoria
    case userApproved        // sugerida por Viernes y aprobada por el usuario
    case summary             // resumen de conversación guardado por el usuario
}

public struct MemoryItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: MemoryKind
    public var text: String
    public var tags: [String]
    public var source: MemorySource
    public var pinned: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
    /// Sugerencia pendiente de aprobación: nunca se inyecta en prompts hasta aprobarse.
    public var isPending: Bool

    public init(
        id: UUID = UUID(), kind: MemoryKind, text: String, tags: [String] = [],
        source: MemorySource, pinned: Bool = false, createdAt: Date = Date(),
        updatedAt: Date? = nil, lastUsedAt: Date? = nil, isPending: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.tags = tags
        self.source = source
        self.pinned = pinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastUsedAt = lastUsedAt
        self.isPending = isPending
    }
}

public struct ScoredMemory: Equatable, Sendable {
    public let item: MemoryItem
    public let score: Double
}

public enum TranscriptRetention: String, Codable, CaseIterable, Sendable {
    case never, days7, days30, forever

    public var displayName: String {
        switch self {
        case .never: return "No guardar transcripciones"
        case .days7: return "7 días"
        case .days30: return "30 días"
        case .forever: return "Hasta que yo las borre"
        }
    }

    /// Fecha límite: lo anterior debe borrarse. `nil` = no se borra por antigüedad.
    public func cutoff(from now: Date = Date()) -> Date? {
        switch self {
        case .never: return now            // se purga todo lo existente
        case .days7: return now.addingTimeInterval(-7 * 86_400)
        case .days30: return now.addingTimeInterval(-30 * 86_400)
        case .forever: return nil
        }
    }
}

/// Qué está permitido recordar. Todo es configurable por el usuario desde Privacidad.
public struct MemoryPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var allowPreferences: Bool
    public var allowProjects: Bool
    public var allowFacts: Bool
    public var allowSummaries: Bool
    /// Si es true, Viernes puede *proponer* recuerdos al terminar una conversación (siempre pendientes de aprobación).
    public var autoSuggest: Bool

    public static let `default` = MemoryPolicy(
        enabled: true, allowPreferences: true, allowProjects: true,
        allowFacts: true, allowSummaries: true, autoSuggest: false
    )

    public init(enabled: Bool, allowPreferences: Bool, allowProjects: Bool,
                allowFacts: Bool, allowSummaries: Bool, autoSuggest: Bool) {
        self.enabled = enabled
        self.allowPreferences = allowPreferences
        self.allowProjects = allowProjects
        self.allowFacts = allowFacts
        self.allowSummaries = allowSummaries
        self.autoSuggest = autoSuggest
    }

    public func permits(_ kind: MemoryKind) -> Bool {
        guard enabled else { return false }
        switch kind {
        case .preference: return allowPreferences
        case .project: return allowProjects
        case .fact: return allowFacts
        case .summary: return allowSummaries
        }
    }
}

public enum MemoryError: Error, Equatable, LocalizedError {
    case disabledByPolicy(MemoryKind)
    case sensitiveContent([SensitiveFinding])
    case emptyText
    case notFound

    public var errorDescription: String? {
        switch self {
        case .disabledByPolicy(let kind):
            return "La memoria de tipo «\(kind.displayName)» está desactivada en Privacidad."
        case .sensitiveContent(let findings):
            let list = findings.map(\.rawValue).joined(separator: ", ")
            return "No guardo datos sensibles (\(list))."
        case .emptyText: return "No hay nada que recordar."
        case .notFound: return "No encontré ese recuerdo."
        }
    }
}

/// Almacén de recuerdos. La app usa SwiftData cifrado; las pruebas usan `InMemoryMemoryStore`.
public protocol MemoryStore: AnyObject, Sendable {
    func all() async throws -> [MemoryItem]
    func upsert(_ item: MemoryItem) async throws
    func delete(id: UUID) async throws
    func deleteAll() async throws
}

public extension MemoryStore {
    func search(_ query: String, limit: Int = 5, now: Date = Date()) async throws -> [ScoredMemory] {
        let items = try await all().filter { !$0.isPending }
        return MemoryRetriever.rank(query: query, items: items, limit: limit, now: now)
    }

    func pending() async throws -> [MemoryItem] {
        try await all().filter(\.isPending).sorted { $0.createdAt > $1.createdAt }
    }

    /// Punto único de escritura: aplica política y filtro de datos sensibles.
    @discardableResult
    func remember(
        text: String, kind: MemoryKind, source: MemorySource,
        policy: MemoryPolicy, pending: Bool = false, now: Date = Date()
    ) async throws -> MemoryItem {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MemoryError.emptyText }
        guard policy.permits(kind) else { throw MemoryError.disabledByPolicy(kind) }
        let scan = SensitiveDataRedactor.scan(trimmed)
        guard !scan.isSensitive else { throw MemoryError.sensitiveContent(scan.findings) }

        // Evita duplicados exactos (ignorando mayúsculas y acentos).
        let folded = TextNormalizer.fold(trimmed)
        if var existing = try await all().first(where: { TextNormalizer.fold($0.text) == folded }) {
            existing.updatedAt = now
            if !pending { existing.isPending = false }
            try await upsert(existing)
            return existing
        }
        let item = MemoryItem(
            kind: kind, text: trimmed, tags: Array(Set(TextNormalizer.tokens(trimmed))).sorted().prefix(8).map { $0 },
            source: source, createdAt: now, isPending: pending
        )
        try await upsert(item)
        return item
    }
}

/// Implementación en RAM: pruebas y modo "sin persistencia".
public actor InMemoryMemoryStore: MemoryStore {
    private var items: [UUID: MemoryItem] = [:]
    public init() {}
    public func all() async throws -> [MemoryItem] { items.values.sorted { $0.createdAt < $1.createdAt } }
    public func upsert(_ item: MemoryItem) async throws { items[item.id] = item }
    public func delete(id: UUID) async throws {
        guard items.removeValue(forKey: id) != nil else { throw MemoryError.notFound }
    }
    public func deleteAll() async throws { items.removeAll() }
}
