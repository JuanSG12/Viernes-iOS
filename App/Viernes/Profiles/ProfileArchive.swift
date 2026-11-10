import Foundation
import CryptoKit
import CommonCrypto

enum ProfileArchiveError: Error, Equatable, LocalizedError {
    case needsPassphrase
    case wrongPassphraseOrCorrupted
    case unsupported
    case emptyPassphrase
    case randomFailed

    var errorDescription: String? {
        switch self {
        case .needsPassphrase: return "Este archivo está cifrado: escribe la contraseña con la que se exportó."
        case .wrongPassphraseOrCorrupted: return "La contraseña no es correcta o el archivo está dañado. No se importó nada."
        case .unsupported: return "Este archivo cifrado usa un formato que esta versión no entiende."
        case .emptyPassphrase: return "Escribe una contraseña para cifrar el archivo."
        case .randomFailed: return "El iPhone no pudo generar la clave de cifrado."
        }
    }
}

/// Cifrado OPCIONAL del archivo de exportación de un perfil con una contraseña: PBKDF2-HMAC-SHA256 (600 000 vueltas) → AES-256-GCM.
/// La cabecera (formato, vueltas y sal) va autenticada: tocar cualquier byte hace que no se pueda abrir. La contraseña no se guarda
/// en ningún sitio; si se olvida, el archivo no se puede recuperar (no hay puerta trasera).
enum ProfileArchive {
    static let magic = Data("VIERNES-PROFILE-ENC1\n".utf8)
    static let defaultIterations = 600_000
    static let allowedIterations: ClosedRange<Int> = 10_000...5_000_000
    static let saltLength = 16

    static func isEncrypted(_ data: Data) -> Bool { data.starts(with: magic) }

    private static func derive(_ passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let normalized = passphrase.precomposedStringWithCanonicalMapping
        let saltBytes = [UInt8](salt)
        let keyLength = 32
        var derived = [UInt8](repeating: 0, count: keyLength)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), normalized, normalized.utf8.count, saltBytes, saltBytes.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &derived, keyLength)
        guard status == Int32(kCCSuccess) else { throw ProfileArchiveError.wrongPassphraseOrCorrupted }
        return SymmetricKey(data: derived)
    }

    private static func header(iterations: Int, salt: Data) -> Data {
        var head = magic
        var count = UInt32(iterations).bigEndian
        withUnsafeBytes(of: &count) { head.append(contentsOf: $0) }
        head.append(salt)
        return head
    }

    static func seal(_ plain: Data, passphrase: String, iterations: Int = ProfileArchive.defaultIterations) throws -> Data {
        guard !passphrase.isEmpty else { throw ProfileArchiveError.emptyPassphrase }
        var salt = Data(count: saltLength)
        let result = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltLength, $0.baseAddress!) }
        guard result == errSecSuccess else { throw ProfileArchiveError.randomFailed }
        let head = header(iterations: iterations, salt: salt)
        let key = try derive(passphrase, salt: salt, iterations: iterations)
        let box = try AES.GCM.seal(plain, using: key, authenticating: head)
        guard let combined = box.combined else { throw ProfileArchiveError.randomFailed }
        return head + combined
    }

    static func open(_ data: Data, passphrase: String) throws -> Data {
        guard isEncrypted(data) else { throw ProfileArchiveError.unsupported }
        guard !passphrase.isEmpty else { throw ProfileArchiveError.needsPassphrase }
        let headLength = magic.count + 4 + saltLength
        guard data.count > headLength + 28 else { throw ProfileArchiveError.wrongPassphraseOrCorrupted }
        let bytes = [UInt8](data.prefix(headLength))
        let countBytes = bytes[magic.count..<(magic.count + 4)]
        let iterations = Int(countBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        // Un archivo manipulado no puede imponer un coste absurdo de cálculo.
        guard allowedIterations.contains(iterations) else { throw ProfileArchiveError.unsupported }
        let salt = Data(bytes[(magic.count + 4)..<headLength])
        let head = Data(bytes)
        do {
            let key = try derive(passphrase, salt: salt, iterations: iterations)
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(headLength))
            return try AES.GCM.open(box, using: key, authenticating: head)
        } catch {
            throw ProfileArchiveError.wrongPassphraseOrCorrupted
        }
    }
}
