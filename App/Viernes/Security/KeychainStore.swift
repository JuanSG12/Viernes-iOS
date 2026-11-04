import Foundation
import Security

enum KeychainError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)
    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status): return "Error del llavero (código \(status))."
        }
    }
}

/// Envoltorio mínimo sobre el llavero (Keychain) para datos pequeños. Nunca se guardan secretos en código ni en UserDefaults.
struct KeychainStore {
    let service: String

    /// Las pruebas fijan `VIERNES_KEYCHAIN_SERVICE` para no tocar la clave real del usuario en el simulador.
    static var defaultService: String {
        ProcessInfo.processInfo.environment["VIERNES_KEYCHAIN_SERVICE"] ?? "com.example.viernes"
    }

    init(service: String = KeychainStore.defaultService) { self.service = service }

    private func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.unexpectedStatus(status)
        }
    }

    /// `AfterFirstUnlockThisDeviceOnly`: no sale del dispositivo (ni en copias de seguridad) y está disponible
    /// tras el primer desbloqueo, que es lo que necesitan los Atajos/Siri al lanzar la app.
    func write(_ data: Data, account: String) throws {
        var query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
    }
}
