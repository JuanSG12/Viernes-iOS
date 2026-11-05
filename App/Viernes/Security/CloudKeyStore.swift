import Foundation
import ViernesCore

/// Claves de API de los proveedores en la nube, SOLO en el Llavero (nunca en UserDefaults, código ni registros).
enum CloudKeyStore {
    private static func account(_ providerID: String) -> String { "cloud-api-key.\(providerID)" }

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

    static func deleteAll() {
        for preset in CloudProviders.all { delete(providerID: preset.id) }
        delete(providerID: ElevenLabsProtocol.keyProviderID)
    }
}
