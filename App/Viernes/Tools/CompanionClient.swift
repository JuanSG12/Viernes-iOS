import Foundation
import CryptoKit
import Security
import ViernesCore

enum CompanionError: Error, LocalizedError {
    case notPaired
    case unreachable(String)
    case rejected(Int, String)
    case badAnswer

    var errorDescription: String? {
        switch self {
        case .notPaired: return "Todavía no estás emparejado con el PC."
        case .unreachable(let why): return "No pude hablar con el PC (\(why)). Comprueba que el servicio está abierto, que estás en la misma red y que la huella es la correcta."
        case .rejected(let code, let message): return message.isEmpty ? "El PC respondió con el error \(code)." : message
        case .badAnswer: return "El PC respondió algo que no entiendo."
        }
    }
}

/// Cliente del Viernes Companion de Windows. Confía SOLO en el certificado cuya huella SHA-256 se fijó al emparejar (no en las
/// autoridades del sistema: el certificado del PC es propio) y solo habla con direcciones de la red local.
final class CompanionClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    let settings: CompanionSettings
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(settings: CompanionSettings) { self.settings = settings }

    static func fingerprint(ofCertificate der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let actual = Self.fingerprint(ofCertificate: SecCertificateCopyData(leaf) as Data)
        if actual == settings.fingerprint {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)      // la huella no coincide: no se envía nada
        }
    }

    /// Envía una petición al PC. `token`: el de este perfil (nil solo para emparejar).
    func call(_ spec: CompanionRequestSpec, token: String?) async throws -> (status: Int, data: Data) {
        guard CompanionAddress.validate(host: settings.host, port: settings.port),
              let url = URL(string: "https://\(settings.host):\(settings.port)\(spec.path)") else { throw CompanionError.unreachable("dirección no válida") }
        var request = URLRequest(url: url)
        request.httpMethod = spec.method
        request.httpBody = spec.body
        if spec.body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token = token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CompanionError.badAnswer }
            return (http.statusCode, data)
        } catch let error as CompanionError {
            throw error
        } catch {
            throw CompanionError.unreachable((error as? URLError)?.localizedDescription ?? error.localizedDescription)
        }
    }
}

enum CompanionToken {
    /// El token del PC vive en el Llavero del perfil (nunca en los ajustes).
    static let providerID = "companion"
    static func read() -> String? { CloudKeyStore.read(providerID: providerID) }
    static func save(_ token: String) -> Bool { ((try? CloudKeyStore.save(token, providerID: providerID)) ?? false) }
    static func delete() { CloudKeyStore.delete(providerID: providerID) }
}
