import Foundation
import SwiftData
import ViernesCore

/// Fila de memoria: solo el identificador y la fecha están en claro; el contenido va cifrado (ver Vault).
@Model
final class MemoryRecord {
    @Attribute(.unique) var id: UUID
    var updatedAt: Date
    var sealed: Data

    init(id: UUID, updatedAt: Date, sealed: Data) {
        self.id = id
        self.updatedAt = updatedAt
        self.sealed = sealed
    }
}

/// Instantánea de una conversación guardada (cifrada).
struct ConversationSnapshot: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var startedAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
}

@Model
final class ConversationRecord {
    @Attribute(.unique) var id: UUID
    var updatedAt: Date
    var sealed: Data

    init(id: UUID, updatedAt: Date, sealed: Data) {
        self.id = id
        self.updatedAt = updatedAt
        self.sealed = sealed
    }
}

enum ViernesStore {
    static var memorySchema: Schema { Schema([MemoryRecord.self, ConversationRecord.self]) }

    /// Contenedor SwiftData con protección de archivo `complete` (el archivo es ilegible con el teléfono bloqueado).
    /// Este es el almacén del perfil heredado: `Application Support/Viernes/viernes.store`.
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        if inMemory {
            return try ModelContainer(for: memorySchema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try openStore(schema: memorySchema, at: support.appendingPathComponent("Viernes", isDirectory: true).appendingPathComponent("viernes.store"))
    }

    /// Almacén de memoria e historial en la ruta que decide el perfil (ver `ProfileStorageLayout`).
    static func makeContainer(storeURL: URL) throws -> ModelContainer {
        try openStore(schema: memorySchema, at: storeURL)
    }

    /// Abre (o crea) un almacén SwiftData: carpeta con protección de archivo y excluida de copias de seguridad de iCloud/iTunes
    /// (la clave que lo cifra está ligada a este dispositivo, así que no serían legibles igualmente).
    static func openStore(schema: Schema, at url: URL) throws -> ModelContainer {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
        return container
    }
}
