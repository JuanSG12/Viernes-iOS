import XCTest
import SwiftData
import ViernesCore
@testable import Viernes

/// Pruebas de seguridad y persistencia que necesitan APIs de iOS (Keychain, CryptoKit, SwiftData). Ejecutar en simulador.
final class SecurityStorageTests: XCTestCase {
    private var service = ""

    override func setUp() {
        super.setUp()
        service = "test.viernes.\(UUID().uuidString)"
    }

    override func tearDown() {
        try? KeychainStore(service: service).delete(account: "vault.key.v1")
        super.tearDown()
    }

    // MARK: Keychain

    func testKeychainWriteReadUpdateDelete() throws {
        let keychain = KeychainStore(service: service)
        XCTAssertNil(try keychain.read(account: "a"))
        try keychain.write(Data("uno".utf8), account: "a")
        XCTAssertEqual(try keychain.read(account: "a"), Data("uno".utf8))
        try keychain.write(Data("dos".utf8), account: "a")
        XCTAssertEqual(try keychain.read(account: "a"), Data("dos".utf8))
        try keychain.delete(account: "a")
        XCTAssertNil(try keychain.read(account: "a"))
        XCTAssertNoThrow(try keychain.delete(account: "a"))      // borrar lo inexistente no falla
    }

    // MARK: Vault

    func testVaultRoundTripAndCiphertextHidesPlaintext() throws {
        let vault = Vault(keychain: KeychainStore(service: service))
        let item = MemoryItem(kind: .project, text: "Proyecto Atlas secreto", source: .userExplicit)
        let sealed = try vault.seal(item)
        XCTAssertNil(sealed.range(of: Data("Atlas".utf8)), "El texto no debe aparecer en claro")
        XCTAssertEqual(try vault.open(MemoryItem.self, from: sealed).text, item.text)
    }

    func testVaultRejectsTamperedData() throws {
        let vault = Vault(keychain: KeychainStore(service: service))
        var sealed = try vault.seal(MemoryItem(kind: .fact, text: "dato", source: .userExplicit))
        sealed[sealed.count / 2] ^= 0xFF
        XCTAssertThrowsError(try vault.open(MemoryItem.self, from: sealed))
    }

    func testDestroyingTheKeyMakesOldDataUnreadable() throws {
        let vault = Vault(keychain: KeychainStore(service: service))
        let sealed = try vault.seal(MemoryItem(kind: .fact, text: "dato", source: .userExplicit))
        try vault.destroyKey()
        XCTAssertThrowsError(try vault.open(MemoryItem.self, from: sealed))      // se genera una clave nueva, distinta
    }

    // MARK: SwiftData cifrado

    func testMemoryStoreEncryptsAtRestAndSearches() async throws {
        let container = try ViernesStore.makeContainer(inMemory: true)
        let store = SwiftDataMemoryStore(modelContainer: container)
        defer { try? Vault().destroyKey() }
        _ = try await store.remember(text: "Mi proyecto Atlas usa SwiftUI", kind: .project, source: .userExplicit, policy: .default)
        let hits = try await store.search("proyecto atlas")
        XCTAssertEqual(hits.first?.item.text, "Mi proyecto Atlas usa SwiftUI")

        let rows = try ModelContext(container).fetch(FetchDescriptor<MemoryRecord>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].sealed.range(of: Data("Atlas".utf8)))
    }

    func testMemoryStorePersistsAcrossContainers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory); try? Vault().destroyKey() }
        let url = directory.appendingPathComponent("test.store")
        let schema = Schema([MemoryRecord.self, ConversationRecord.self])

        do {
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let store = SwiftDataMemoryStore(modelContainer: container)
            _ = try await store.remember(text: "Prefiero respuestas cortas", kind: .preference, source: .userExplicit, policy: .default)
        }
        let reopened = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let items = try await SwiftDataMemoryStore(modelContainer: reopened).all()
        XCTAssertEqual(items.map(\.text), ["Prefiero respuestas cortas"])
    }

    func testMemoryStoreEditDeleteAndWipe() async throws {
        let store = SwiftDataMemoryStore(modelContainer: try ViernesStore.makeContainer(inMemory: true))
        defer { try? Vault().destroyKey() }
        var item = try await store.remember(text: "Vivo en Bogotá", kind: .fact, source: .userExplicit, policy: .default)
        item.text = "Vivo en Medellín"
        try await store.upsert(item)
        let edited = try await store.all()
        XCTAssertEqual(edited.map(\.text), ["Vivo en Medellín"])
        try await store.delete(id: item.id)
        let afterDelete = try await store.all()
        XCTAssertTrue(afterDelete.isEmpty)
        _ = try await store.remember(text: "a", kind: .fact, source: .userExplicit, policy: .default)
        _ = try await store.remember(text: "b", kind: .fact, source: .userExplicit, policy: .default)
        try await store.deleteAll()
        let afterWipe = try await store.all()
        XCTAssertTrue(afterWipe.isEmpty)
    }

    func testConversationRepositorySavesListsAndPrunesByRetention() async throws {
        let repository = ConversationRepository(modelContainer: try ViernesStore.makeContainer(inMemory: true))
        defer { try? Vault().destroyKey() }
        let now = Date()
        let old = ConversationSnapshot(id: UUID(), title: "vieja", startedAt: now.addingTimeInterval(-40 * 86_400),
                                       updatedAt: now.addingTimeInterval(-40 * 86_400), messages: [ChatMessage(role: .user, text: "hola")])
        let fresh = ConversationSnapshot(id: UUID(), title: "nueva", startedAt: now, updatedAt: now,
                                         messages: [ChatMessage(role: .user, text: "hola"), ChatMessage(role: .assistant, text: "qué tal")])
        try await repository.save(old)
        try await repository.save(fresh)
        let listed = try await repository.list()
        XCTAssertEqual(listed.map(\.title), ["nueva", "vieja"])

        let removedForever = try await repository.prune(retention: .forever, now: now)
        XCTAssertEqual(removedForever, 0)
        let removed = try await repository.prune(retention: .days30, now: now)
        XCTAssertEqual(removed, 1)
        let remaining = try await repository.list()
        XCTAssertEqual(remaining.map(\.title), ["nueva"])
        XCTAssertEqual(remaining.first?.messages.count, 2)

        let removedAll = try await repository.prune(retention: .never, now: now.addingTimeInterval(1))
        XCTAssertEqual(removedAll, 1)
    }

    // MARK: Ajustes

    func testSettingsStoreRoundTripAndReset() {
        let defaults = UserDefaults(suiteName: "test.viernes.\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.load(), AppSettings.default)
        var settings = AppSettings.default
        settings.wakeWordEnabled = true
        settings.claude.mode = .shortcut
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
        store.markPrepared("qwen3-1.7b-4bit")
        XCTAssertEqual(store.preparedModelIDs, ["qwen3-1.7b-4bit"])
        store.reset()
        XCTAssertEqual(store.load(), AppSettings.default)
        XCTAssertTrue(store.preparedModelIDs.isEmpty)
    }

    func testNoSecretsInUserDefaultsPayload() throws {
        let data = try JSONEncoder().encode(AppSettings.default)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["sk-", "api_key", "apikey", "password", "token"] {
            XCTAssertFalse(text.lowercased().contains(forbidden), "Los ajustes no deben contener «\(forbidden)»")
        }
    }
}
