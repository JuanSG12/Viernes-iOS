import Foundation
import ViernesCore

/// Claves de API de los proveedores en la nube, SOLO en el Llavero (nunca en UserDefaults, código ni registros).
/// Cada perfil tiene sus propias claves (cuenta del Llavero con el identificador del perfil): al cambiar de perfil, las del anterior
/// dejan de estar al alcance. El perfil heredado conserva los nombres de siempre.
enum CloudKeyStore {
    private static let lock = NSLock()
    private static var currentLayout = ProfileStorageLayout(profileID: UUID(), isLegacy: true)

    /// Perfil activo. Lo fija `ProfileHost` ANTES de crear el modelo del perfil.
    static func use(layout: ProfileStorageLayout) {
        lock.lock()
        currentLayout = layout
        lock.unlock()
    }

    private static var layout: ProfileStorageLayout {
        lock.lock()
        defer { lock.unlock() }
        return currentLayout
    }

    private static func account(_ providerID: String) -> String { layout.apiKeyAccount(providerID: providerID) }

    static func read(providerID: String) -> String? {
        guard let data = try? KeychainStore().read(account: account(providerID)),
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func hasKey(providerID: String) -> Bool { read(providerID: providerID) != nil }

    /// Devuelve `false` si el formato no parece una clave (espacios, caracteres no ASCII, longitud absurda).
    @discardableResult
    static func save(_ raw: String, providerID: String) throws -> Bool {
        guard let key = APIKeyFormat.clean(raw), let data = key.data(using: .utf8) else { return false }
        try KeychainStore().write(data, account: account(providerID))
        return true
    }

    static func delete(providerID: String) {
        try? KeychainStore().delete(account: account(providerID))
    }

    /// Borra las claves del perfil ACTIVO.
    static func deleteAll() {
        for providerID in providerIDs { delete(providerID: providerID) }
    }

    /// Borra las claves de un perfil concreto (al eliminarlo), esté activo o no.
    static func deleteAll(for layout: ProfileStorageLayout) {
        for providerID in providerIDs { try? KeychainStore().delete(account: layout.apiKeyAccount(providerID: providerID)) }
    }

    static var providerIDs: [String] { CloudProviders.all.map(\.id) + [ElevenLabsProtocol.keyProviderID] }
}
