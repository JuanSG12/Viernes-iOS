import XCTest
import ViernesCore
@testable import Viernes

final class CompanionClientTests: XCTestCase {
    func testTheCertificateFingerprintIsASha256InLowercaseHex() {
        XCTAssertEqual(CompanionClient.fingerprint(ofCertificate: Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testRequestsToNonLocalAddressesNeverLeaveTheApp() async {
        let hex = String(repeating: "ab", count: 32)
        let client = CompanionClient(settings: CompanionSettings(host: "8.8.8.8", port: 8443, fingerprint: hex))
        do {
            _ = try await client.call(CompanionRequests.status, token: "token-de-prueba-123456789012345")
            XCTFail("No debía enviar nada a una dirección pública")
        } catch let error as CompanionError {
            guard case .unreachable = error else { return XCTFail("Se esperaba «inalcanzable»: \(error)") }
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
    }

    func testTheTokenLivesInTheKeychainNotInTheSettings() throws {
        defer { CompanionToken.delete() }
        CompanionToken.delete()
        XCTAssertNil(CompanionToken.read())
        let token = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"
        XCTAssertTrue(CompanionToken.save(token))
        XCTAssertEqual(CompanionToken.read(), token)
        let settings = CompanionSettings(host: "192.168.1.20", port: 8443, fingerprint: String(repeating: "ab", count: 32))
        let encoded = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        XCTAssertFalse(encoded.contains(token), "El token no forma parte de los ajustes")
        XCTAssertTrue(CloudKeyStore.providerIDs.contains(CompanionToken.providerID), "Al borrar el perfil se borra su token")
        CompanionToken.delete()
        XCTAssertNil(CompanionToken.read())
    }
}
