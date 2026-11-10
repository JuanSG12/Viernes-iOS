import Foundation

// MARK: Modelos de la biblioteca

/// Tipo de elemento de la biblioteca de conocimiento.
public enum KnowledgeKind: String, Codable, Sendable, CaseIterable {
    case document, image, note, text

    public var displayName: String {
        switch self {
        case .document: return "Documento"
        case .image: return "Imagen"
        case .note: return "Nota"
        case .text: return "Texto"
        }
    }

    public var symbolName: String {
        switch self {
        case .document: return "doc.text"
        case .image: return "photo"
        case .note: return "note.text"
        case .text: return "text.alignleft"
        }
    }
}

/// Estado de procesamiento de un elemento (se muestra tal cual en la interfaz).
public enum KnowledgeStatus: Codable, Equatable, Sendable {
    case queued
    case processing
    case indexed
    case failed(String)

    public var isIndexed: Bool { self == .indexed }
}

/// Proyecto, carpeta o colección: agrupan elementos y pueden anidarse.
public struct KnowledgeCollection: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case project, folder, collection
        public var displayName: String {
            switch self {
            case .project: return "Proyecto"
            case .folder: return "Carpeta"
            case .collection: return "Colección"
            }
        }
    }
    public var id: UUID
    public var name: String
    public var kind: Kind
    public var parentID: UUID?
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, kind: Kind = .project, parentID: UUID? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.parentID = parentID
        self.createdAt = createdAt
    }
}

/// Un documento, imagen, nota o texto de la biblioteca: identificador estable, metadatos y estado de procesamiento.
/// La biblioteca guarda el TEXTO extraído y sus referencias, no el archivo original.
public struct KnowledgeItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var kind: KnowledgeKind
    public var fileKind: AttachmentKind?
    public var sourceName: String
    /// SHA-256 del archivo original (o del texto, en notas).
    public var contentHash: String
    /// SHA-256 del texto normalizado: detecta el mismo contenido en otro formato.
    public var textHash: String
    /// Huellas cortas de cada fragmento (detección de duplicados casi idénticos).
    public var fingerprints: [String]
    public var byteCount: Int
    public var pageCount: Int?
    public var characterCount: Int
    public var chunkCount: Int
    public var importedAt: Date
    /// Fecha propia del documento si se conoce (p. ej. la de modificación del archivo).
    public var sourceDate: Date?
    public var collectionID: UUID?
    public var tags: [String]
    public var status: KnowledgeStatus
    public var recognizedByOCR: Bool
    public var truncated: Bool
    public var warnings: [String]
    /// Identificador del modelo de embeddings que generó los vectores de sus fragmentos (si hubo).
    public var embedderID: String?
    /// Miniatura JPEG pequeña (solo imágenes).
    public var thumbnail: Data?

    public init(id: UUID = UUID(), title: String, kind: KnowledgeKind, fileKind: AttachmentKind? = nil, sourceName: String,
                contentHash: String, textHash: String = "", fingerprints: [String] = [], byteCount: Int = 0, pageCount: Int? = nil,
                characterCount: Int = 0, chunkCount: Int = 0, importedAt: Date = Date(), sourceDate: Date? = nil,
                collectionID: UUID? = nil, tags: [String] = [], status: KnowledgeStatus = .queued, recognizedByOCR: Bool = false,
                truncated: Bool = false, warnings: [String] = [], embedderID: String? = nil, thumbnail: Data? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.fileKind = fileKind
        self.sourceName = sourceName
        self.contentHash = contentHash
        self.textHash = textHash
        self.fingerprints = fingerprints
        self.byteCount = byteCount
        self.pageCount = pageCount
        self.characterCount = characterCount
        self.chunkCount = chunkCount
        self.importedAt = importedAt
        self.sourceDate = sourceDate
        self.collectionID = collectionID
        self.tags = tags
        self.status = status
        self.recognizedByOCR = recognizedByOCR
        self.truncated = truncated
        self.warnings = warnings
        self.embedderID = embedderID
        self.thumbnail = thumbnail
    }
}

/// Un fragmento localizable de un elemento (con su página/sección/líneas) y, si hubo, su vector de significado.
public struct KnowledgeChunk: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var itemID: UUID
    public var ordinal: Int
    public var reference: String
    public var text: String
    /// Vector en Float32 (little-endian) del modelo `KnowledgeItem.embedderID`.
    public var embedding: Data?

    public init(id: UUID = UUID(), itemID: UUID, ordinal: Int, reference: String, text: String, embedding: Data? = nil) {
        self.id = id
        self.itemID = itemID
        self.ordinal = ordinal
        self.reference = reference
        self.text = text
        self.embedding = embedding
    }
}

/// Procedencia de lo que se le dio al modelo para responder (se muestra como «Fuentes consultadas»).
public struct SourceRef: Identifiable, Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable { case attachment, library }
    public var id: UUID
    public var documentName: String
    public var reference: String
    public var origin: Origin
    public var itemID: UUID?

    public init(id: UUID = UUID(), documentName: String, reference: String, origin: Origin, itemID: UUID? = nil) {
        self.id = id
        self.documentName = documentName
        self.reference = reference
        self.origin = origin
        self.itemID = itemID
    }

    public var label: String { reference.isEmpty ? documentName : "\(documentName) · \(reference)" }
}

public struct KnowledgeSnapshot: Sendable {
    public var items: [KnowledgeItem]
    public var chunks: [KnowledgeChunk]
    public var collections: [KnowledgeCollection]
    public init(items: [KnowledgeItem] = [], chunks: [KnowledgeChunk] = [], collections: [KnowledgeCollection] = []) {
        self.items = items
        self.chunks = chunks
        self.collections = collections
    }
}

/// Filtros de búsqueda: por documento, proyecto/carpeta/colección, etiqueta, tipo y fecha de importación.
public struct KnowledgeFilter: Equatable, Sendable {
    public var itemIDs: Set<UUID>?
    /// Un proyecto incluye sus subcarpetas.
    public var collectionID: UUID?
    public var tags: Set<String>
    public var kinds: Set<KnowledgeKind>
    public var dateRange: ClosedRange<Date>?

    public init(itemIDs: Set<UUID>? = nil, collectionID: UUID? = nil, tags: Set<String> = [], kinds: Set<KnowledgeKind> = [],
                dateRange: ClosedRange<Date>? = nil) {
        self.itemIDs = itemIDs
        self.collectionID = collectionID
        self.tags = tags
        self.kinds = kinds
        self.dateRange = dateRange
    }

    public static let all = KnowledgeFilter()
}

/// Límites de la biblioteca (el índice vive en memoria: hay que acotarlo).
public enum KnowledgeLimits {
    public static let maxItems = 300
    public static let maxTotalCharacters = 8_000_000
    public static let maxTags = 12
    public static let maxTagLength = 32
    public static let chunkSize = 1_000
}

public enum KnowledgeError: Error, Equatable, LocalizedError {
    case libraryFull(String)
    case noReadableText(String)
    case notFound
    case verificationFailed(String)
    case invalidName

    public var errorDescription: String? {
        switch self {
        case .libraryFull(let reason): return reason
        case .noReadableText(let name): return "«\(name)» no tiene texto que guardar en la biblioteca."
        case .notFound: return "Ese elemento ya no está en la biblioteca."
        case .verificationFailed(let name): return "Guardé «\(name)», pero no pude comprobar que se recupera al buscarlo, así que no lo di por indexado."
        case .invalidName: return "El nombre no puede estar vacío."
        }
    }
}

// MARK: Almacenamiento

/// Almacén de la biblioteca. La app lo implementa con SwiftData y contenido cifrado; las pruebas usan `InMemoryKnowledgeStore`.
public protocol KnowledgeStore: AnyObject, Sendable {
    func loadAll() async throws -> KnowledgeSnapshot
    /// Guarda el elemento y REEMPLAZA todos sus fragmentos.
    func save(item: KnowledgeItem, chunks: [KnowledgeChunk]) async throws
    /// Actualiza solo los metadatos del elemento.
    func update(item: KnowledgeItem) async throws
    /// Borra el elemento y todos sus fragmentos.
    func deleteItem(id: UUID) async throws
    func save(collection: KnowledgeCollection) async throws
    func deleteCollection(id: UUID) async throws
    func deleteAll() async throws
}

public actor InMemoryKnowledgeStore: KnowledgeStore {
    private var items: [UUID: KnowledgeItem] = [:]
    private var chunks: [UUID: [KnowledgeChunk]] = [:]
    private var collections: [UUID: KnowledgeCollection] = [:]

    public init() {}

    public func loadAll() async throws -> KnowledgeSnapshot {
        KnowledgeSnapshot(items: Array(items.values), chunks: chunks.values.flatMap { $0 }, collections: Array(collections.values))
    }

    public func save(item: KnowledgeItem, chunks newChunks: [KnowledgeChunk]) async throws {
        items[item.id] = item
        chunks[item.id] = newChunks
    }

    public func update(item: KnowledgeItem) async throws { items[item.id] = item }

    public func deleteItem(id: UUID) async throws {
        items.removeValue(forKey: id)
        chunks.removeValue(forKey: id)
    }

    public func save(collection: KnowledgeCollection) async throws { collections[collection.id] = collection }
    public func deleteCollection(id: UUID) async throws { collections.removeValue(forKey: id) }

    public func deleteAll() async throws {
        items.removeAll()
        chunks.removeAll()
        collections.removeAll()
    }

    /// Solo para pruebas: cuántos fragmentos hay guardados para un elemento.
    public func storedChunkCount(for id: UUID) -> Int { chunks[id]?.count ?? 0 }
    public var storedItemCount: Int { items.count }
}
