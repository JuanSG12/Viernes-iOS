import Foundation

// MARK: Paquete de exportación de un perfil

public struct ExportedConversation: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]

    public init(id: UUID, title: String, startedAt: Date, updatedAt: Date, messages: [ChatMessage]) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.messages = messages
    }
}

public struct LibraryExport: Codable, Equatable, Sendable {
    public var collections: [KnowledgeCollection]
    public var items: [KnowledgeItem]
    public var chunks: [KnowledgeChunk]

    public init(collections: [KnowledgeCollection] = [], items: [KnowledgeItem] = [], chunks: [KnowledgeChunk] = []) {
        self.collections = collections
        self.items = items
        self.chunks = chunks
    }
}

/// Copia portátil de UN perfil: ajustes, recuerdos, biblioteca (texto y referencias) y conversaciones.
/// **No incluye** claves de API ni la clave de cifrado del perfil: esos secretos no salen del Llavero de este iPhone.
/// El archivo contiene datos personales en claro (la app puede cifrarlo con una contraseña al exportarlo).
public struct ProfileBundle: Codable, Equatable, Sendable {
    public static let formatName = "viernes.profile"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var profileName: String
    public var profileCreatedAt: Date
    public var settings: AppSettings
    public var memories: [MemoryItem]
    public var library: LibraryExport
    public var conversations: [ExportedConversation]
    /// Si los fragmentos llevan el vector de significado. Sin él, lo importado se busca por texto hasta volver a guardarlo.
    public var includesVectors: Bool
    public var notes: [String]

    public init(format: String = ProfileBundle.formatName, version: Int = ProfileBundle.currentVersion, exportedAt: Date,
                profileName: String, profileCreatedAt: Date, settings: AppSettings, memories: [MemoryItem], library: LibraryExport,
                conversations: [ExportedConversation], includesVectors: Bool, notes: [String] = ProfileBundle.defaultNotes) {
        self.format = format
        self.version = version
        self.exportedAt = exportedAt
        self.profileName = profileName
        self.profileCreatedAt = profileCreatedAt
        self.settings = settings
        self.memories = memories
        self.library = library
        self.conversations = conversations
        self.includesVectors = includesVectors
        self.notes = notes
    }

    public static let defaultNotes = [
        "No incluye claves de API ni la clave de cifrado: no salen del Llavero del iPhone.",
        "Contiene datos personales en claro: guárdalo como guardarías tus documentos."
    ]
}

public enum ProfileBundleError: Error, Equatable, LocalizedError {
    case tooLarge(Int)
    case notAProfile
    case newerVersion(Int)
    case corrupted(String)
    case overLimit(String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let mb): return "El archivo es demasiado grande (más de \(mb) MB) para ser un perfil de Viernes."
        case .notAProfile: return "Este archivo no es una copia de un perfil de Viernes."
        case .newerVersion(let v): return "Este perfil se exportó con una versión más nueva de Viernes (formato \(v)). Actualiza la app para importarlo."
        case .corrupted(let reason): return "El archivo está dañado y no se importó nada (\(reason))."
        case .overLimit(let what): return "El archivo supera un límite de seguridad (\(what)) y no se importó."
        }
    }
}

public enum ProfileBundleCodec {
    public static let maxBytes = 128 * 1024 * 1024
    public static let maxMemories = 5_000
    public static let maxConversations = 500
    public static let maxMessagesPerConversation = 2_000
    public static let maxChunks = 24_000
    public static let maxMemoryTextLength = 2_000

    // Fechas en su representación numérica exacta (no ISO 8601, que pierde las fracciones de segundo): ida y vuelta sin cambios.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder { JSONDecoder() }

    public static func encode(_ bundle: ProfileBundle) throws -> Data {
        let data = try makeEncoder().encode(bundle)
        guard data.count <= maxBytes else { throw ProfileBundleError.tooLarge(maxBytes / 1_048_576) }
        return data
    }

    /// El archivo es un dato NO confiable: se comprueba formato, versión y límites antes de usar nada de él.
    public static func decode(_ data: Data) throws -> ProfileBundle {
        guard data.count <= maxBytes else { throw ProfileBundleError.tooLarge(maxBytes / 1_048_576) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["format"] as? String == ProfileBundle.formatName else { throw ProfileBundleError.notAProfile }
        if let version = object["version"] as? Int, version > ProfileBundle.currentVersion { throw ProfileBundleError.newerVersion(version) }
        let bundle: ProfileBundle
        do {
            bundle = try makeDecoder().decode(ProfileBundle.self, from: data)
        } catch {
            throw ProfileBundleError.corrupted(String(describing: error).prefix(120).description)
        }
        guard bundle.version >= 1 else { throw ProfileBundleError.notAProfile }
        guard bundle.memories.count <= maxMemories else { throw ProfileBundleError.overLimit("recuerdos") }
        guard bundle.conversations.count <= maxConversations,
              bundle.conversations.allSatisfy({ $0.messages.count <= maxMessagesPerConversation }) else { throw ProfileBundleError.overLimit("conversaciones") }
        guard bundle.library.items.count <= KnowledgeLimits.maxItems, bundle.library.chunks.count <= maxChunks else {
            throw ProfileBundleError.overLimit("biblioteca")
        }
        let characters = bundle.library.chunks.reduce(0) { $0 + $1.text.count }
        guard characters <= KnowledgeLimits.maxTotalCharacters else { throw ProfileBundleError.overLimit("texto de la biblioteca") }
        return bundle
    }
}

// MARK: Crear y restaurar

public struct RestoreOptions: Sendable, Equatable {
    /// Los recuerdos importados quedan PENDIENTES de aprobación: no entran en ningún prompt hasta que el usuario los apruebe
    /// (un archivo ajeno o manipulado podría traer textos pensados para dirigir al asistente).
    public var memoriesAsPending: Bool
    /// Conservar las instrucciones personales y los ajustes de pronunciación del archivo. Apagado por defecto por la misma razón.
    public var trustPersonalization: Bool

    public init(memoriesAsPending: Bool = true, trustPersonalization: Bool = false) {
        self.memoriesAsPending = memoriesAsPending
        self.trustPersonalization = trustPersonalization
    }
}

public struct RestoreReport: Equatable, Sendable {
    public var memoriesRestored = 0
    public var memoriesSkipped = 0
    public var libraryItemsRestored = 0
    public var libraryItemsSkipped = 0
    public var collectionsRestored = 0
    public var conversationsRestored = 0
    public var settings: AppSettings = .default
    public var conversations: [ExportedConversation] = []

    public init() {}
}

public enum ProfileBundleBuilder {
    /// Reúne los datos de un perfil en un paquete. Solo se exportan los elementos de la biblioteca ya indexados.
    public static func make(profileName: String, createdAt: Date, settings: AppSettings, memory: MemoryStore, knowledge: KnowledgeStore,
                            conversations: [ExportedConversation], includeVectors: Bool = false, now: Date = Date()) async throws -> ProfileBundle {
        let memories = try await memory.all()
        let snapshot = try await knowledge.loadAll()
        var items = snapshot.items.filter { $0.status.isIndexed }.sorted { $0.importedAt < $1.importedAt }
        let keep = Set(items.map(\.id))
        var chunks = snapshot.chunks.filter { keep.contains($0.itemID) }.sorted { ($0.itemID.uuidString, $0.ordinal) < ($1.itemID.uuidString, $1.ordinal) }
        if !includeVectors {
            chunks = chunks.map { chunk in var copy = chunk; copy.embedding = nil; return copy }
            items = items.map { item in var copy = item; copy.embedderID = nil; return copy }
        }
        return ProfileBundle(
            exportedAt: now, profileName: profileName, profileCreatedAt: createdAt, settings: settings.sanitized(),
            memories: memories, library: LibraryExport(collections: snapshot.collections.sorted { $0.createdAt < $1.createdAt }, items: items, chunks: chunks),
            conversations: conversations, includesVectors: includeVectors)
    }

    /// Ajustes que un archivo puede traer. Los que envían datos fuera o abren permisos (calendario, contactos, escucha por voz,
    /// dictado en servidores, voz en la nube, Claude, permisos de adjuntos) NO se importan: se quedan apagados y los reactiva el usuario.
    static func importedSettings(_ source: AppSettings, options: RestoreOptions) -> AppSettings {
        var settings = AppSettings.default
        settings.selectedModelID = source.selectedModelID
        settings.cloud = source.cloud
        settings.voice = source.voice
        settings.voice.elevenLabs = nil
        settings.memory = source.memory
        settings.transcriptRetention = source.transcriptRetention
        settings.recognitionLocale = source.recognitionLocale
        settings.requireBiometricsForMemory = source.requireBiometricsForMemory
        settings.reducedEffects = source.reducedEffects
        settings.hapticsEnabled = source.hapticsEnabled
        settings.onboardingCompleted = true
        var profile = source.profileSettings
        if !options.trustPersonalization {
            profile.personality.personalInstructions = ""
            profile.personality.pronunciation = []
        }
        settings.profile = profile
        return settings.sanitized()
    }

    public static func restore(_ bundle: ProfileBundle, memory: MemoryStore, knowledge: KnowledgeStore,
                               options: RestoreOptions = RestoreOptions()) async throws -> RestoreReport {
        var report = RestoreReport()

        for var item in bundle.memories {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= ProfileBundleCodec.maxMemoryTextLength else { report.memoriesSkipped += 1; continue }
            item.text = text
            if options.memoriesAsPending { item.isPending = true }
            try await memory.upsert(item)
            report.memoriesRestored += 1
        }

        let knownItems = Set(bundle.library.items.map(\.id))
        var chunksByItem: [UUID: [KnowledgeChunk]] = [:]
        for chunk in bundle.library.chunks where knownItems.contains(chunk.itemID) { chunksByItem[chunk.itemID, default: []].append(chunk) }
        for collection in bundle.library.collections {
            try await knowledge.save(collection: collection)
            report.collectionsRestored += 1
        }
        for var item in bundle.library.items {
            guard item.status.isIndexed, var chunks = chunksByItem[item.id], !chunks.isEmpty else { report.libraryItemsSkipped += 1; continue }
            chunks.sort { $0.ordinal < $1.ordinal }
            if !bundle.includesVectors {
                chunks = chunks.map { chunk in var copy = chunk; copy.embedding = nil; return copy }
                item.embedderID = nil
            }
            item.chunkCount = chunks.count
            try await knowledge.save(item: item, chunks: chunks)
            report.libraryItemsRestored += 1
        }

        report.conversations = bundle.conversations
        report.conversationsRestored = bundle.conversations.count
        report.settings = importedSettings(bundle.settings, options: options)
        return report
    }
}
