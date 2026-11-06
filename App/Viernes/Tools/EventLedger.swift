import Foundation
import ViernesCore

/// Registro LOCAL de los eventos que Viernes creó (identificador de EventKit, título, hora y cuándo). Permite entender
/// «elimina el que acabamos de crear» sin adivinar: solo cuenta lo que Viernes creó de verdad y todavía existe.
/// Guarda identificadores y títulos en este iPhone (UserDefaults); nada sale del teléfono.
final class EventLedger: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()
    private static let capacity = 30
    private static let maxAge: TimeInterval = 7 * 86_400

    init(defaults: UserDefaults = .standard, key: String = "viernes.createdEvents.v1") {
        self.defaults = defaults
        self.key = key
    }

    private func load() -> [CreatedEventRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CreatedEventRecord].self, from: data)) ?? []
    }

    private func save(_ records: [CreatedEventRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(records) { defaults.set(data, forKey: key) }
    }

    func record(_ entry: CreatedEventRecord) {
        lock.withLock {
            var records = load().filter { $0.id != entry.id }
            records.append(entry)
            save(Array(records.suffix(Self.capacity)))
        }
    }

    /// Lo creado recientemente (se descarta lo de hace más de una semana).
    func recent(now: Date = Date()) -> [CreatedEventRecord] {
        lock.withLock { load().filter { now.timeIntervalSince($0.createdAt) <= Self.maxAge } }
    }

    func remove(id: String) {
        lock.withLock { save(load().filter { $0.id != id }) }
    }

    func removeAll() {
        lock.withLock { defaults.removeObject(forKey: key) }
    }
}
