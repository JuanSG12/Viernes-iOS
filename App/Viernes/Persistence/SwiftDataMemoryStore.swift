import Foundation
import SwiftData
import ViernesCore

/// Implementación de `MemoryStore` sobre SwiftData con contenido cifrado.
/// La búsqueda se hace en RAM sobre los recuerdos descifrados (son pocos y de texto corto), así el índice nunca queda en claro en disco.
@ModelActor
actor SwiftDataMemoryStore: MemoryStore {
    private var vault: Vault { Vault() }

    func all() async throws -> [MemoryItem] {
        let records = try modelContext.fetch(FetchDescriptor<MemoryRecord>())
        var items: [MemoryItem] = []
        for record in records {
            // Un registro ilegible se omite (y se informa por la UI de Privacidad), no tumba toda la memoria.
            if let item = try? vault.open(MemoryItem.self, from: record.sealed) { items.append(item) }
        }
        return items.sorted { $0.createdAt < $1.createdAt }
    }

    func upsert(_ item: MemoryItem) async throws {
        let sealed = try vault.seal(item)
        let id = item.id
        var descriptor = FetchDescriptor<MemoryRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.sealed = sealed
            existing.updatedAt = item.updatedAt
        } else {
            modelContext.insert(MemoryRecord(id: item.id, updatedAt: item.updatedAt, sealed: sealed))
        }
        try modelContext.save()
    }

    func delete(id: UUID) async throws {
        var descriptor = FetchDescriptor<MemoryRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { throw MemoryError.notFound }
        modelContext.delete(record)
        try modelContext.save()
    }

    func deleteAll() async throws {
        try modelContext.delete(model: MemoryRecord.self)
        try modelContext.save()
    }

    func unreadableCount() async -> Int {
        let records = (try? modelContext.fetch(FetchDescriptor<MemoryRecord>())) ?? []
        return records.filter { (try? vault.open(MemoryItem.self, from: $0.sealed)) == nil }.count
    }
}

/// Historial de conversaciones (cifrado) con retención configurable.
@ModelActor
actor ConversationRepository {
    private var vault: Vault { Vault() }

    func list() async throws -> [ConversationSnapshot] {
        let records = try modelContext.fetch(FetchDescriptor<ConversationRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
        return records.compactMap { try? vault.open(ConversationSnapshot.self, from: $0.sealed) }
    }

    func save(_ snapshot: ConversationSnapshot) async throws {
        let sealed = try vault.seal(snapshot)
        let id = snapshot.id
        var descriptor = FetchDescriptor<ConversationRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.sealed = sealed
            existing.updatedAt = snapshot.updatedAt
        } else {
            modelContext.insert(ConversationRecord(id: snapshot.id, updatedAt: snapshot.updatedAt, sealed: sealed))
        }
        try modelContext.save()
    }

    func delete(id: UUID) async throws {
        var descriptor = FetchDescriptor<ConversationRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first {
            modelContext.delete(record)
            try modelContext.save()
        }
    }

    func deleteAll() async throws {
        try modelContext.delete(model: ConversationRecord.self)
        try modelContext.save()
    }

    /// Borra conversaciones más antiguas que el límite de retención. Devuelve cuántas borró.
    @discardableResult
    func prune(retention: TranscriptRetention, now: Date = Date()) async throws -> Int {
        guard let cutoff = retention.cutoff(from: now) else { return 0 }
        let old = try modelContext.fetch(FetchDescriptor<ConversationRecord>(predicate: #Predicate { $0.updatedAt < cutoff }))
        for record in old { modelContext.delete(record) }
        try modelContext.save()
        return old.count
    }
}
