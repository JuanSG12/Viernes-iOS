import Foundation
import CryptoKit

enum VaultError: Error, LocalizedError {
    case corrupted
    var errorDescription: String? { "No se pudo descifrar un dato guardado (¿datos dañados?)." }
}

/// Cifrado en reposo de memoria e historial: AES-256-GCM con una clave aleatoria guardada en el llavero.
/// La base de datos SwiftData solo contiene bloques cifrados; sin la clave (que no sale del dispositivo) no son legibles.
struct Vault {
    private let keychain: KeychainStore
    private let account = "vault.key.v1"

    init(keychain: KeychainStore = KeychainStore()) { self.keychain = keychain }

    /// Serializa la creación de la clave: dos actores no deben crear dos claves distintas la primera vez.
    private static let keyLock = NSLock()

    private func key() throws -> SymmetricKey {
        Self.keyLock.lock(); defer { Self.keyLock.unlock() }
        if let data = try keychain.read(account: account), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let fresh = SymmetricKey(size: .bits256)
        try keychain.write(fresh.withUnsafeBytes { Data($0) }, account: account)
        return fresh
    }

    func seal<T: Encodable>(_ value: T) throws -> Data {
        let plain = try JSONEncoder.vault.encode(value)
        let box = try AES.GCM.seal(plain, using: try key())
        guard let combined = box.combined else { throw VaultError.corrupted }
        return combined
    }

    func open<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            let plain = try AES.GCM.open(box, using: try key())
            return try JSONDecoder.vault.decode(type, from: plain)
        } catch is KeychainError {
            throw VaultError.corrupted
        } catch let error as CryptoKitError {
            _ = error
            throw VaultError.corrupted
        }
    }

    /// Borrar la clave hace ilegibles TODOS los datos cifrados (borrado criptográfico).
    func destroyKey() throws { try keychain.delete(account: account) }
}

extension JSONEncoder {
    static let vault: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let vault: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
