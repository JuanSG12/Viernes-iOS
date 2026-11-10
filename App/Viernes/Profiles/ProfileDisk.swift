import Foundation
import SwiftData
import ViernesCore

/// Todo lo que un perfil toca en el disco y en el Llavero: abrir sus almacenes y borrarlos por completo.
/// Las rutas y los nombres los decide `ProfileStorageLayout` (función pura y probada); aquí solo se aplican.
struct ProfileDisk {
    /// Carpeta base («Application Support»). Las pruebas usan una carpeta temporal.
    let base: URL
    let keychain: KeychainStore

    init(base: URL? = nil, keychain: KeychainStore = KeychainStore()) {
        if let base = base {
            self.base = base
        } else {
            self.base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
        }
        self.keychain = keychain
    }

    func url(_ relativePath: String) -> URL { base.appendingPathComponent(relativePath) }

    func openStores(for layout: ProfileStorageLayout) throws -> (memory: ModelContainer, knowledge: ModelContainer) {
        let memory = try ViernesStore.makeContainer(storeURL: url(layout.memoryStorePath))
        let knowledge = try ViernesStore.makeKnowledgeContainer(storeURL: url(layout.knowledgeStorePath))
        return (memory, knowledge)
    }

    /// Los archivos de SwiftData de un perfil (el almacén, su registro WAL y su memoria compartida) y su historial de voz.
    func files(for layout: ProfileStorageLayout) -> [URL] {
        var urls: [URL] = []
        for path in [layout.memoryStorePath, layout.knowledgeStorePath] {
            for suffix in ["", "-shm", "-wal"] { urls.append(url(path + suffix)) }
        }
        urls.append(url(layout.recognitionHistoryPath))
        return urls
    }

    /// ¿Queda en disco algún archivo de datos de este perfil?
    func hasFiles(for layout: ProfileStorageLayout) -> Bool {
        files(for: layout).contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Borra TODO lo de un perfil. Primero la clave de cifrado (aunque algún archivo sobreviviera, sería ilegible: borrado
    /// criptográfico), luego las claves de API, los ajustes, el registro de eventos y los archivos. Devuelve lo que NO pudo borrar
    /// (vacío = todo borrado).
    @discardableResult
    func erase(_ layout: ProfileStorageLayout, defaults: UserDefaults = .standard) -> [String] {
        var problems: [String] = []
        do { try Vault(layout: layout, keychain: keychain).destroyKey() } catch { problems.append("la clave de cifrado") }
        for providerID in CloudKeyStore.providerIDs {
            do { try keychain.delete(account: layout.apiKeyAccount(providerID: providerID)) } catch { problems.append("la clave de \(providerID)") }
        }
        SettingsStore(defaults: defaults, layout: layout).removeSettings()
        defaults.removeObject(forKey: layout.createdEventsKey)

        for file in files(for: layout) where FileManager.default.fileExists(atPath: file.path) {
            do { try FileManager.default.removeItem(at: file) } catch { problems.append(file.lastPathComponent) }
        }
        if !layout.isLegacy {
            let directory = url(layout.dataDirectory)
            if FileManager.default.fileExists(atPath: directory.path) {
                do { try FileManager.default.removeItem(at: directory) } catch { problems.append("la carpeta del perfil") }
            }
        }
        return problems
    }
}
