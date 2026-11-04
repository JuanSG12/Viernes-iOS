import Foundation
import ViernesCore

/// Ajustes NO sensibles en UserDefaults (JSON). Los secretos y los datos personales NO van aquí: ver Vault y Keychain.
struct SettingsStore {
    private let defaults: UserDefaults
    private let settingsKey = "viernes.settings.v1"
    private let preparedKey = "viernes.preparedModels.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return .default }
        return settings
    }

    func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: settingsKey) }
    }

    /// Modelos que ya se cargaron con éxito alguna vez (para recargarlos solos desde la caché local).
    var preparedModelIDs: Set<String> { Set(defaults.stringArray(forKey: preparedKey) ?? []) }
    func markPrepared(_ id: String) { defaults.set(Array(preparedModelIDs.union([id])), forKey: preparedKey) }
    func unmarkPrepared(_ id: String) { defaults.set(Array(preparedModelIDs.subtracting([id])), forKey: preparedKey) }

    func reset() {
        defaults.removeObject(forKey: settingsKey)
        defaults.removeObject(forKey: preparedKey)
    }
}

/// Utilidades de disco para modelos descargados (caché de Hugging Face dentro de Documentos de la app).
enum ModelStorage {
    /// Borra, si existe, el directorio descargado del repositorio. La ruta exacta depende de la versión del cliente de
    /// Hugging Face, así que se busca de forma robusta bajo Documentos y Caches (ver LOCAL_MODELS.md).
    @discardableResult
    static func deleteCachedModel(repo: String) -> Bool {
        let fileManager = FileManager.default
        let roots = [fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
                     fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first].compactMap { $0 }
        var removed = false
        for root in roots {
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            var matches: [URL] = []
            for case let url as URL in enumerator {
                if url.path.hasSuffix(repo) || url.path.hasSuffix(repo.replacingOccurrences(of: "/", with: "--")) {
                    matches.append(url)
                    enumerator.skipDescendants()
                }
            }
            for url in matches where (try? fileManager.removeItem(at: url)) != nil { removed = true }
        }
        return removed
    }

    static func downloadedSizeBytes(repo: String) -> Int64 {
        let fileManager = FileManager.default
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
              let enumerator = fileManager.enumerator(at: documents, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else { return 0 }
        var total: Int64 = 0
        var inside = false
        for case let url as URL in enumerator {
            if url.path.contains(repo) {
                inside = true
                if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { total += Int64(size) }
            }
        }
        return inside ? total : 0
    }
}
