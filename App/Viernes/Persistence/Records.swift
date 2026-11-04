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
    /// Contenedor SwiftData con protección de archivo `complete` (el archivo es ilegible con el teléfono bloqueado).
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([MemoryRecord.self, ConversationRecord.self])
        if inMemory {
            return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("Viernes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let url = directory.appendingPathComponent("viernes.store")
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        // Excluir de copias de seguridad de iCloud/iTunes: la clave está ligada a este dispositivo, así que no serían legibles igualmente.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
        return container
    }
}
