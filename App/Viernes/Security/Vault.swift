import Foundation
import CryptoKit
import ViernesCore

enum VaultError: Error, LocalizedError {
    case corrupted
    var errorDescription: String? { "No se pudo descifrar un dato guardado (¿datos dañados?)." }
}

/// Cifrado en reposo de memoria e historial: AES-256-GCM con una clave aleatoria guardada en el llavero.
/// La base de datos SwiftData solo contiene bloques cifrados; sin la clave (que no sale del dispositivo) no son legibles.
struct Vault {
    private let keychain: KeychainStore
    /// Cuenta del Llavero de la clave. Cada perfil tiene la suya (ver `ProfileStorageLayout.vaultKeyAccount`): con la clave de
    /// un perfil NO se puede abrir nada de otro. El perfil heredado conserva el nombre de siempre.
    private let account: String

    init(keychain: KeychainStore = KeychainStore(), account: String = "vault.key.v1") {
        self.keychain = keychain
        self.account = account
    }

    init(layout: ProfileStorageLayout, keychain: KeychainStore = KeychainStore()) {
        self.init(keychain: keychain, account: layout.vaultKeyAccount)
    }

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

/// Guarda la `Vault` que usa un almacén y permite cambiarla desde fuera del actor (los almacenes SwiftData son actores generados
/// por macro: su inicializador no admite parámetros nuevos). Sin configurar, usa la clave del perfil heredado, como siempre.
final class VaultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var vault = Vault()

    func set(_ newVault: Vault) {
        lock.lock()
        vault = newVault
        lock.unlock()
    }

    var current: Vault {
        lock.lock()
        defer { lock.unlock() }
        return vault
    }
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
