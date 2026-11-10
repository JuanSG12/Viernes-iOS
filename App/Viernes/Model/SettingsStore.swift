import Foundation
import ViernesCore

/// Ajustes NO sensibles en UserDefaults (JSON), uno por perfil. Los secretos y los datos personales NO van aquí: ver Vault y Keychain.
struct SettingsStore {
    private let defaults: UserDefaults
    private let settingsKey: String
    /// Los modelos descargados son del DISPOSITIVO (pesos locales compartidos por todos los perfiles), no de un perfil.
    private let preparedKey = "viernes.preparedModels.v1"

    /// Sin `layout`, usa el perfil heredado (los nombres de siempre).
    init(defaults: UserDefaults = .standard, layout: ProfileStorageLayout? = nil) {
        self.defaults = defaults
        self.settingsKey = layout?.settingsKey ?? "viernes.settings.v1"
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return .default }
        return settings
    }

    func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: settingsKey) }
    }

    /// ¿Hay ajustes guardados de este perfil? (un perfil nuevo no los tiene hasta que se cambia algo).
    var hasSavedSettings: Bool { defaults.data(forKey: settingsKey) != nil }

    /// Modelos que ya se cargaron con éxito alguna vez (para recargarlos solos desde la caché local).
    var preparedModelIDs: Set<String> { Set(defaults.stringArray(forKey: preparedKey) ?? []) }
    func markPrepared(_ id: String) { defaults.set(Array(preparedModelIDs.union([id])), forKey: preparedKey) }
    func unmarkPrepared(_ id: String) { defaults.set(Array(preparedModelIDs.subtracting([id])), forKey: preparedKey) }

    /// Borra los ajustes de ESTE perfil y olvida qué modelos estaban preparados (los pesos descargados siguen en el dispositivo).
    func reset() {
        defaults.removeObject(forKey: settingsKey)
        defaults.removeObject(forKey: preparedKey)
    }

    /// Borra SOLO los ajustes de este perfil (al eliminar un perfil): lo que es del dispositivo no se toca.
    func removeSettings() {
        defaults.removeObject(forKey: settingsKey)
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
