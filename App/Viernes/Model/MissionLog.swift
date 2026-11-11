import Foundation
import ViernesCore

/// Historial de misiones de ESTE perfil, cifrado con su clave. Guarda el estado de cada misión tras cada paso, así una misión
/// interrumpida por un cierre inesperado se puede reconocer y reanudar. Se conservan las 30 más recientes.
actor MissionLog: MissionStore {
    private var states: [UUID: MissionState] = [:]
    private let vault: Vault
    private let fileURL: URL
    private static let capacity = 30

    /// `path`: ruta relativa a «Application Support» (ver `ProfileStorageLayout.missionsPath`).
    init(vault: Vault, path: String, base: URL? = nil) {
        self.vault = vault
        let root = base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        fileURL = root.appendingPathComponent(path)
        if let data = try? Data(contentsOf: fileURL), let loaded = try? vault.open([MissionState].self, from: data) {
            for state in loaded { states[state.id] = state }
        }
    }

    func save(_ state: MissionState) async {
        states[state.id] = state
        if states.count > Self.capacity {
            let keep = states.values.sorted { $0.createdAt > $1.createdAt }.prefix(Self.capacity)
            states = Dictionary(uniqueKeysWithValues: keep.map { ($0.id, $0) })
        }
        persist()
    }

    func loadAll() async -> [MissionState] { states.values.sorted { $0.createdAt > $1.createdAt } }

    func deleteAll() async {
        states = [:]
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persist() {
        guard let sealed = try? vault.seal(Array(states.values)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? sealed.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
