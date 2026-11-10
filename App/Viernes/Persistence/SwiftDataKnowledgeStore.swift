import Foundation
import SwiftData
import NaturalLanguage
import ViernesCore

/// Filas de la biblioteca de conocimiento: solo el identificador va en claro; el contenido (títulos, texto, vectores) va cifrado
/// con la misma clave del Llavero que la memoria (ver Vault). Almacén APARTE del de la memoria personal.
@Model
final class KnowledgeItemRecord {
    @Attribute(.unique) var id: UUID
    var updatedAt: Date
    var sealed: Data

    init(id: UUID, updatedAt: Date, sealed: Data) {
        self.id = id
        self.updatedAt = updatedAt
        self.sealed = sealed
    }
}

@Model
final class KnowledgeChunkRecord {
    @Attribute(.unique) var id: UUID
    var itemID: UUID
    var ordinal: Int
    var sealed: Data

    init(id: UUID, itemID: UUID, ordinal: Int, sealed: Data) {
        self.id = id
        self.itemID = itemID
        self.ordinal = ordinal
        self.sealed = sealed
    }
}

@Model
final class KnowledgeCollectionRecord {
    @Attribute(.unique) var id: UUID
    var sealed: Data

    init(id: UUID, sealed: Data) {
        self.id = id
        self.sealed = sealed
    }
}

extension ViernesStore {
    /// Contenedor de la biblioteca: otro archivo (`knowledge.store`), así la memoria y los documentos nunca comparten almacén
    /// (base de la separación por usuario/perfil de la fase 4) y añadir la biblioteca no toca los datos que ya existían.
    static var knowledgeSchema: Schema { Schema([KnowledgeItemRecord.self, KnowledgeChunkRecord.self, KnowledgeCollectionRecord.self]) }

    static func makeKnowledgeContainer(inMemory: Bool = false) throws -> ModelContainer {
        if inMemory {
            return try ModelContainer(for: knowledgeSchema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try openStore(schema: knowledgeSchema, at: support.appendingPathComponent("Viernes", isDirectory: true).appendingPathComponent("knowledge.store"))
    }

    /// Almacén de la biblioteca en la ruta que decide el perfil (ver `ProfileStorageLayout`).
    static func makeKnowledgeContainer(storeURL: URL) throws -> ModelContainer {
        try openStore(schema: knowledgeSchema, at: storeURL)
    }
}

/// `KnowledgeStore` sobre SwiftData con contenido cifrado. El índice de búsqueda vive en RAM (se reconstruye al abrir), así nunca queda en claro en disco.
@ModelActor
actor SwiftDataKnowledgeStore: KnowledgeStore {
    private let vaultBox = VaultBox()
    private var vault: Vault { vaultBox.current }

    /// Cifra y descifra con la clave de ESTE perfil. Sin llamarlo, usa la del perfil heredado.
    nonisolated func use(vault: Vault) { vaultBox.set(vault) }

    func loadAll() async throws -> KnowledgeSnapshot {
        var snapshot = KnowledgeSnapshot()
        // Un registro ilegible se omite: no tumba toda la biblioteca.
        for record in try modelContext.fetch(FetchDescriptor<KnowledgeItemRecord>()) {
            if let item = try? vault.open(KnowledgeItem.self, from: record.sealed) { snapshot.items.append(item) }
        }
        for record in try modelContext.fetch(FetchDescriptor<KnowledgeChunkRecord>()) {
            if let chunk = try? vault.open(KnowledgeChunk.self, from: record.sealed) { snapshot.chunks.append(chunk) }
        }
        for record in try modelContext.fetch(FetchDescriptor<KnowledgeCollectionRecord>()) {
            if let collection = try? vault.open(KnowledgeCollection.self, from: record.sealed) { snapshot.collections.append(collection) }
        }
        return snapshot
    }

    private func upsertItem(_ item: KnowledgeItem) throws {
        let sealed = try vault.seal(item)
        let id = item.id
        var descriptor = FetchDescriptor<KnowledgeItemRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.sealed = sealed
            existing.updatedAt = Date()
        } else {
            modelContext.insert(KnowledgeItemRecord(id: item.id, updatedAt: Date(), sealed: sealed))
        }
    }

    func save(item: KnowledgeItem, chunks: [KnowledgeChunk]) async throws {
        let itemID = item.id
        for old in try modelContext.fetch(FetchDescriptor<KnowledgeChunkRecord>(predicate: #Predicate { $0.itemID == itemID })) {
            modelContext.delete(old)
        }
        for chunk in chunks {
            modelContext.insert(KnowledgeChunkRecord(id: chunk.id, itemID: chunk.itemID, ordinal: chunk.ordinal, sealed: try vault.seal(chunk)))
        }
        try upsertItem(item)
        try modelContext.save()
    }

    func update(item: KnowledgeItem) async throws {
        try upsertItem(item)
        try modelContext.save()
    }

    func deleteItem(id: UUID) async throws {
        for chunk in try modelContext.fetch(FetchDescriptor<KnowledgeChunkRecord>(predicate: #Predicate { $0.itemID == id })) {
            modelContext.delete(chunk)
        }
        for record in try modelContext.fetch(FetchDescriptor<KnowledgeItemRecord>(predicate: #Predicate { $0.id == id })) {
            modelContext.delete(record)
        }
        try modelContext.save()
    }

    func save(collection: KnowledgeCollection) async throws {
        let sealed = try vault.seal(collection)
        let id = collection.id
        var descriptor = FetchDescriptor<KnowledgeCollectionRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.sealed = sealed
        } else {
            modelContext.insert(KnowledgeCollectionRecord(id: collection.id, sealed: sealed))
        }
        try modelContext.save()
    }

    func deleteCollection(id: UUID) async throws {
        for record in try modelContext.fetch(FetchDescriptor<KnowledgeCollectionRecord>(predicate: #Predicate { $0.id == id })) {
            modelContext.delete(record)
        }
        try modelContext.save()
    }

    func deleteAll() async throws {
        try modelContext.delete(model: KnowledgeChunkRecord.self)
        try modelContext.delete(model: KnowledgeItemRecord.self)
        try modelContext.delete(model: KnowledgeCollectionRecord.self)
        try modelContext.save()
    }
}

/// Vectores de frases del sistema (NaturalLanguage), en español y en el dispositivo: ningún texto sale. Si el sistema no los ofrece,
/// la biblioteca usa `HashingEmbedder` (palabras y raíces, sin sinónimos).
struct NLSentenceEmbedder: TextEmbedder, @unchecked Sendable {
    let id: String
    let strongSimilarity: Float = 0.78
    private let embedding: NLEmbedding

    init?() {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .spanish) else { return nil }
        self.embedding = embedding
        self.id = "nl-sentence-es-r\(NLEmbedding.currentSentenceEmbeddingRevision(for: .spanish))"
    }

    func embed(_ text: String) -> [Float]? {
        let trimmed = String(text.prefix(1_500))
        guard !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let vector = embedding.vector(for: trimmed) else { return nil }
        return Embedding.normalized(vector.map { Float($0) })
    }
}

enum LibraryEmbedder {
    static func make() -> TextEmbedder { NLSentenceEmbedder() ?? HashingEmbedder() }
}
