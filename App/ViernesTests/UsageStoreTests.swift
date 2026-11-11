import XCTest
import ViernesCore
@testable import Viernes

/// Consumo y presupuesto con almacenamiento real (archivo cifrado en una carpeta temporal) y el motor en la nube sin red.
final class UsageStoreTests: XCTestCase {
    private var base: URL!
    private var service = ""

    override func setUp() {
        super.setUp()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("viernes-usage-tests-\(UUID().uuidString)", isDirectory: true)
        service = "test.viernes.usage.\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        let keychain = KeychainStore(service: service)
        for account in ["vault.key.v1.a", "vault.key.v1.b"] { try? keychain.delete(account: account) }
        super.tearDown()
    }

    private func vault(_ account: String) -> Vault { Vault(keychain: KeychainStore(service: service), account: account) }

    func testRecordsAreEncryptedPerProfileAndFeedTheBudgetGate() throws {
        let store = UsageStore(vault: vault("vault.key.v1.a"), path: "usage.bin", base: base)
        var settings = UsageSettings()
        settings.setPrice(PriceEntry(providerID: "openai", model: "m", inputPerMillionUSD: 1, outputPerMillionUSD: 2))
        store.settings = settings
        store.record(providerID: "openai", model: "m", usage: TokenUsage(input: 1_000_000, output: 500_000))
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records[0].costUSD ?? -1, 2.0, accuracy: 1e-9)

        let bytes = try Data(contentsOf: base.appendingPathComponent("usage.bin"))
        XCTAssertNil(bytes.range(of: Data("openai".utf8)), "El historial no está en claro en disco")
        XCTAssertEqual(UsageStore(vault: vault("vault.key.v1.a"), path: "usage.bin", base: base).records.count, 1, "Sobrevive a reiniciar")
        XCTAssertTrue(UsageStore(vault: vault("vault.key.v1.b"), path: "usage.bin", base: base).records.isEmpty, "Con la clave de otro perfil no se lee")

        XCTAssertEqual(store.gate(providerID: "openai", model: "m"), .allow, "Sin presupuesto no hay límite")
        settings.monthlyBudgetUSD = 1
        store.settings = settings
        guard case .block = store.gate(providerID: "openai", model: "m") else { return XCTFail("Con 2 gastados y un límite de 1 debe bloquear") }

        store.clear()
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("usage.bin").path))
    }

    func testABlockedRequestNeverReachesTheNetworkNorGetsRecorded() async {
        final class Flag: @unchecked Sendable { var recorded = false }
        let flag = Flag()
        let hooks = UsageHooks(gate: { _, _ in .block("Presupuesto mensual agotado") },
                               record: { _, _, _ in flag.recorded = true }, limits: { _, _ in }, warn: { _ in })
        let engine = CloudEngine(descriptor: ModelCatalog.cloudDescriptor, settings: CloudBrainSettings(providerID: "openai", model: "m"), usage: hooks)
        var failure: Error?
        do {
            for try await _ in engine.generate(GenerationRequest(system: "s", turns: [ChatTurn(role: .user, content: "hola")])) {}
        } catch {
            failure = error
        }
        XCTAssertEqual((failure as? EngineError)?.errorDescription, EngineError.generationFailed("Presupuesto mensual agotado").errorDescription)
        XCTAssertFalse(flag.recorded, "Lo que no se envió no se anota como consumo")
    }
}
