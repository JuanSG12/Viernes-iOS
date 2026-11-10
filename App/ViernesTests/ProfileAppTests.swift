import XCTest
import SwiftData
import ViernesCore
@testable import Viernes

/// Perfiles sobre almacenamiento REAL (archivos SwiftData en una carpeta temporal y Llavero del simulador): datos, claves y borrado.
final class ProfileStorageTests: XCTestCase {
    private var base: URL!
    private var service = ""
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("viernes-profile-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        service = "test.viernes.profiles.\(UUID().uuidString)"
        suiteName = "test.viernes.profiles.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        defaults.removePersistentDomain(forName: suiteName)
        CloudKeyStore.use(layout: ProfileStorageLayout(profileID: UUID(), isLegacy: true))
        super.tearDown()
    }

    private var keychain: KeychainStore { KeychainStore(service: service) }
    private var disk: ProfileDisk { ProfileDisk(base: base, keychain: keychain) }
    private func newLayout() -> ProfileStorageLayout { ProfileStorageLayout(profileID: UUID(), isLegacy: false) }

    func testTwoProfilesKeepSeparateEncryptedStoresAndKeys() async throws {
        let a = newLayout()
        let b = newLayout()
        let disk = self.disk
        let storesA = try disk.openStores(for: a)
        let storesB = try disk.openStores(for: b)
        let vaultA = Vault(layout: a, keychain: keychain)
        let vaultB = Vault(layout: b, keychain: keychain)

        let memoryA = SwiftDataMemoryStore(modelContainer: storesA.memory)
        memoryA.use(vault: vaultA)
        let memoryB = SwiftDataMemoryStore(modelContainer: storesB.memory)
        memoryB.use(vault: vaultB)
        try await memoryA.remember(text: "El secreto de Ana es el azafrán", kind: .fact, source: .userExplicit, policy: .default)
        try await memoryB.remember(text: "Beto guarda el mapa del tesoro", kind: .fact, source: .userExplicit, policy: .default)

        let anaItems = try await memoryA.all()
        let betoItems = try await memoryB.all()
        XCTAssertEqual(anaItems.map(\.text), ["El secreto de Ana es el azafrán"])
        XCTAssertEqual(betoItems.map(\.text), ["Beto guarda el mapa del tesoro"])

        // La clave de Beto NO abre los datos de Ana: se omiten como ilegibles.
        let intruder = SwiftDataMemoryStore(modelContainer: storesA.memory)
        intruder.use(vault: vaultB)
        let seen = try await intruder.all()
        let unreadable = await intruder.unreadableCount()
        XCTAssertTrue(seen.isEmpty)
        XCTAssertEqual(unreadable, 1)

        // Cada perfil, sus archivos; y en ellos no hay texto en claro.
        XCTAssertTrue(disk.hasFiles(for: a))
        XCTAssertTrue(disk.hasFiles(for: b))
        XCTAssertNotEqual(disk.url(a.memoryStorePath), disk.url(b.memoryStorePath))
        for file in disk.files(for: a) where FileManager.default.fileExists(atPath: file.path) {
            let bytes = try Data(contentsOf: file)
            XCTAssertNil(bytes.range(of: Data("azafrán".utf8)), "Texto en claro en \(file.lastPathComponent)")
        }

        // Eliminar el perfil A: sus archivos, su carpeta y su clave desaparecen; B sigue intacto.
        let problems = disk.erase(a, defaults: defaults)
        XCTAssertTrue(problems.isEmpty, "\(problems)")
        XCTAssertFalse(disk.hasFiles(for: a))
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.url(a.dataDirectory).path))
        XCTAssertNil(try keychain.read(account: a.vaultKeyAccount))
        XCTAssertNotNil(try keychain.read(account: b.vaultKeyAccount))
        let reopened = SwiftDataMemoryStore(modelContainer: storesB.memory)
        reopened.use(vault: vaultB)
        let after = try await reopened.all()
        XCTAssertEqual(after.count, 1)
        XCTAssertTrue(disk.erase(b, defaults: defaults).isEmpty)
    }

    func testLibrariesAreSeparatePerProfile() async throws {
        let a = newLayout()
        let b = newLayout()
        let disk = self.disk
        let storesA = try disk.openStores(for: a)
        let storesB = try disk.openStores(for: b)
        let vaultA = Vault(layout: a, keychain: keychain)
        let vaultB = Vault(layout: b, keychain: keychain)

        let storeA = SwiftDataKnowledgeStore(modelContainer: storesA.knowledge)
        storeA.use(vault: vaultA)
        let storeB = SwiftDataKnowledgeStore(modelContainer: storesB.knowledge)
        storeB.use(vault: vaultB)
        let libraryA = KnowledgeEngine(store: storeA, embedder: LibraryEmbedder.make())
        let libraryB = KnowledgeEngine(store: storeB, embedder: LibraryEmbedder.make())
        _ = try await libraryA.addNote(title: "Receta de Ana", text: "La receta secreta lleva azafrán y arroz bomba.")

        let titlesA = await libraryA.allItems().map(\.title)
        let titlesB = await libraryB.allItems().map(\.title)
        let hitsA = await libraryA.search("azafrán arroz")
        let hitsB = await libraryB.search("azafrán arroz")
        XCTAssertEqual(titlesA, ["Receta de Ana"])
        XCTAssertTrue(titlesB.isEmpty)
        XCTAssertFalse(hitsA.isEmpty)
        XCTAssertTrue(hitsB.isEmpty, "La biblioteca de B no encuentra lo de A")

        let intruder = SwiftDataKnowledgeStore(modelContainer: storesA.knowledge)
        intruder.use(vault: vaultB)
        let snapshot = try await intruder.loadAll()
        XCTAssertTrue(snapshot.items.isEmpty && snapshot.chunks.isEmpty, "Con la clave de B no se lee nada de A")

        disk.erase(a, defaults: defaults)
        disk.erase(b, defaults: defaults)
    }

    func testApiKeysAreKeptPerProfile() throws {
        let a = newLayout()
        let b = newLayout()
        defer { CloudKeyStore.deleteAll(for: a); CloudKeyStore.deleteAll(for: b) }
        CloudKeyStore.use(layout: a)
        XCTAssertTrue(try CloudKeyStore.save("test-key-aaaaaaaaaaaaaaaa1111", providerID: "groq"))
        CloudKeyStore.use(layout: b)
        XCTAssertFalse(CloudKeyStore.hasKey(providerID: "groq"), "El perfil B no ve la clave de A")
        XCTAssertTrue(try CloudKeyStore.save("test-key-bbbbbbbbbbbbbbbb2222", providerID: "groq"))
        XCTAssertEqual(CloudKeyStore.read(providerID: "groq"), "test-key-bbbbbbbbbbbbbbbb2222")
        CloudKeyStore.use(layout: a)
        XCTAssertEqual(CloudKeyStore.read(providerID: "groq"), "test-key-aaaaaaaaaaaaaaaa1111")
        CloudKeyStore.deleteAll(for: a)
        XCTAssertFalse(CloudKeyStore.hasKey(providerID: "groq"))
        CloudKeyStore.use(layout: b)
        XCTAssertTrue(CloudKeyStore.hasKey(providerID: "groq"), "Borrar las claves de A no toca las de B")
    }

    func testLegacyProfileKeepsUsingTheOriginalKeychainAccount() {
        let legacy = ProfileStorageLayout(profileID: UUID(), isLegacy: true)
        XCTAssertEqual(legacy.vaultKeyAccount, "vault.key.v1")
        // La `Vault` sin parámetros (la de siempre) y la del perfil heredado son la misma clave.
        let sealed = try? Vault(keychain: keychain).seal(MemoryItem(kind: .fact, text: "dato", source: .userExplicit))
        XCTAssertNotNil(sealed)
        XCTAssertEqual((try? Vault(layout: legacy, keychain: keychain).open(MemoryItem.self, from: sealed ?? Data()))?.text, "dato")
        try? keychain.delete(account: legacy.vaultKeyAccount)
    }
}

/// Cifrado opcional del archivo de exportación.
final class ProfileArchiveTests: XCTestCase {
    private let secret = "contraseña segura 123"
    private let fast = 10_000

    func testRoundTripAndWrongPassphrase() throws {
        let plain = Data(#"{"hola":"mundo"}"#.utf8)
        let sealed = try ProfileArchive.seal(plain, passphrase: secret, iterations: fast)
        XCTAssertTrue(ProfileArchive.isEncrypted(sealed))
        XCTAssertNil(sealed.range(of: Data("mundo".utf8)), "El contenido no debe verse en el archivo cifrado")
        XCTAssertEqual(try ProfileArchive.open(sealed, passphrase: secret), plain)
        XCTAssertThrowsError(try ProfileArchive.open(sealed, passphrase: "otra")) { XCTAssertEqual($0 as? ProfileArchiveError, .wrongPassphraseOrCorrupted) }
        XCTAssertThrowsError(try ProfileArchive.open(sealed, passphrase: "")) { XCTAssertEqual($0 as? ProfileArchiveError, .needsPassphrase) }
        XCTAssertThrowsError(try ProfileArchive.seal(plain, passphrase: "", iterations: fast)) { XCTAssertEqual($0 as? ProfileArchiveError, .emptyPassphrase) }
    }

    func testTamperingWithAnyPartIsDetected() throws {
        let sealed = try ProfileArchive.seal(Data("datos".utf8), passphrase: secret, iterations: fast)
        var body = sealed
        body[body.count - 5] ^= 0x01
        XCTAssertThrowsError(try ProfileArchive.open(body, passphrase: secret))
        var salt = sealed
        salt[ProfileArchive.magic.count + 6] ^= 0x01
        XCTAssertThrowsError(try ProfileArchive.open(salt, passphrase: secret))
        var iterations = sealed
        iterations[ProfileArchive.magic.count + 3] ^= 0x01
        XCTAssertThrowsError(try ProfileArchive.open(iterations, passphrase: secret), "La cabecera va autenticada")
        XCTAssertThrowsError(try ProfileArchive.open(Data(sealed.prefix(30)), passphrase: secret))
    }

    func testAbsurdIterationCountsAreRefusedWithoutComputing() throws {
        var sealed = try ProfileArchive.seal(Data("datos".utf8), passphrase: secret, iterations: fast)
        sealed[ProfileArchive.magic.count] = 0xFF            // ≈ 4 000 millones de vueltas
        XCTAssertThrowsError(try ProfileArchive.open(sealed, passphrase: secret)) { XCTAssertEqual($0 as? ProfileArchiveError, .unsupported) }
        XCTAssertFalse(ProfileArchive.isEncrypted(Data("{}".utf8)))
        XCTAssertThrowsError(try ProfileArchive.open(Data("{}".utf8), passphrase: secret)) { XCTAssertEqual($0 as? ProfileArchiveError, .unsupported) }
    }

    func testTwoSealsOfTheSameDataDiffer() throws {
        let plain = Data("igual".utf8)
        let one = try ProfileArchive.seal(plain, passphrase: secret, iterations: fast)
        let two = try ProfileArchive.seal(plain, passphrase: secret, iterations: fast)
        XCTAssertNotEqual(one, two, "La sal y el nonce son aleatorios")
    }

    func testAProfileBundleSurvivesEncryptionEndToEnd() async throws {
        let memory = InMemoryMemoryStore()
        try await memory.remember(text: "Prefiero respuestas cortas", kind: .preference, source: .userExplicit, policy: .default)
        let bundle = try await ProfileBundleBuilder.make(profileName: "Ana", createdAt: Date(timeIntervalSince1970: 1_700_000_000), settings: .default,
                                                         memory: memory, knowledge: InMemoryKnowledgeStore(), conversations: [])
        let plain = try ProfileBundleCodec.encode(bundle)
        let sealed = try ProfileArchive.seal(plain, passphrase: secret, iterations: fast)
        XCTAssertNil(sealed.range(of: Data("respuestas cortas".utf8)))
        let decoded = try ProfileBundleCodec.decode(try ProfileArchive.open(sealed, passphrase: secret))
        XCTAssertEqual(decoded, bundle)
    }
}

/// El dueño de los perfiles: crear, cambiar, borrar y recordar cuál está activo.
@MainActor
final class ProfileHostTests: XCTestCase {
    private var base: URL!
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("viernes-host-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        suiteName = "test.viernes.host.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        defaults.removePersistentDomain(forName: suiteName)
        CloudKeyStore.use(layout: ProfileStorageLayout(profileID: UUID(), isLegacy: true))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    func testSwitchingGivesEachProfileItsOwnSettingsAndMemory() async throws {
        let host = ProfileHost(inMemory: true, defaults: defaults)
        let first = host.registry.activeID
        host.model.settings.profile = ProfileSettings(assistantName: "Jarvis", autonomy: .cautious)
        host.model.addMemory(text: "Ana prefiere el té", kind: .preference)
        await waitUntil { !host.model.memoryItems.isEmpty }
        XCTAssertEqual(host.model.memoryItems.count, 1)

        let beto = try XCTUnwrap(host.createProfile(name: "Beto"))
        let switched = await host.switchTo(beto.id)
        XCTAssertTrue(switched)
        XCTAssertEqual(host.registry.activeID, beto.id)
        XCTAssertEqual(host.model.profileEntry.id, beto.id)
        XCTAssertEqual(host.model.settings.profileSettings, .default, "Un perfil nuevo empieza con los ajustes por defecto")
        await host.model.reloadMemory()
        XCTAssertTrue(host.model.memoryItems.isEmpty, "Beto no ve los recuerdos de Ana")
        XCTAssertTrue(host.model.messages.isEmpty)

        let back = await host.switchTo(first)
        XCTAssertTrue(back)
        XCTAssertEqual(host.model.settings.profileSettings.assistantName, "Jarvis", "Los ajustes de Ana se conservan")
        await host.model.reloadMemory()
        XCTAssertEqual(host.model.memoryItems.map(\.text), ["Ana prefiere el té"])
    }

    func testCreatingRenamingAndDeletingProfiles() async throws {
        let host = ProfileHost(inMemory: true, defaults: defaults)
        let beto = try XCTUnwrap(host.createProfile(name: "Beto"))
        XCTAssertNil(host.createProfile(name: "beto"), "Los nombres no se repiten")
        XCTAssertNotNil(host.notice)
        host.renameProfile(beto.id, to: "Roberto")
        XCTAssertEqual(host.registry.entry(id: beto.id)?.displayName, "Roberto")

        // Eliminar el perfil activo pasa antes a otro.
        _ = await host.switchTo(beto.id)
        let deleted = await host.deleteProfile(beto.id)
        XCTAssertTrue(deleted)
        XCTAssertEqual(host.registry.entries.count, 1)
        XCTAssertNotEqual(host.registry.activeID, beto.id)
        let onlyOne = await host.deleteProfile(host.registry.activeID)
        XCTAssertFalse(onlyOne, "No se puede borrar el único perfil")
    }

    func testRegistryAndDeletionOnRealFiles() async throws {
        let disk = ProfileDisk(base: base)
        var expectedNames: [String] = []
        var beto: ProfileEntry!
        do {
            let host = ProfileHost(inMemory: false, defaults: defaults, disk: disk)
            beto = try XCTUnwrap(host.createProfile(name: "Beto"))
            _ = await host.switchTo(beto.id)
            host.model.addMemory(text: "Beto toma café", kind: .preference)
            await waitUntil { !host.model.memoryItems.isEmpty }
            XCTAssertTrue(disk.hasFiles(for: ProfileStorageLayout(entry: beto)), "El perfil nuevo tiene sus propios archivos")
            host.model.settings.profile = ProfileSettings(assistantName: "Tito")
            expectedNames = host.registry.entries.map(\.displayName)
        }

        // Un arranque posterior recuerda los perfiles, cuál estaba activo y sus ajustes.
        let relaunched = ProfileHost(inMemory: false, defaults: defaults, disk: disk)
        XCTAssertEqual(relaunched.registry.entries.map(\.displayName), expectedNames)
        XCTAssertEqual(relaunched.registry.activeID, beto.id)
        XCTAssertEqual(relaunched.model.settings.profileSettings.assistantName, "Tito")

        let legacy = try XCTUnwrap(relaunched.registry.entries.first { $0.isLegacy })
        let deleted = await relaunched.deleteProfile(beto.id)
        XCTAssertTrue(deleted)
        XCTAssertFalse(disk.hasFiles(for: ProfileStorageLayout(entry: beto)))
        XCTAssertNil(defaults.data(forKey: ProfileStorageLayout(entry: beto).settingsKey), "Sus ajustes también se borran")
        XCTAssertEqual(relaunched.registry.activeID, legacy.id)

        relaunched.eraseEverything()
        XCTAssertEqual(relaunched.registry.entries.count, 1)
        XCTAssertNil(try KeychainStore().read(account: ProfileStorageLayout(entry: beto).vaultKeyAccount))
    }

    func testExportThenImportCreatesANewProfileWithoutTouchingTheCurrentOne() async throws {
        let disk = ProfileDisk(base: base)
        let host = ProfileHost(inMemory: false, defaults: defaults, disk: disk)
        host.model.addMemory(text: "Ana prefiere el té", kind: .preference)
        await waitUntil { !host.model.memoryItems.isEmpty }
        host.model.settings.profile = ProfileSettings(assistantName: "Jarvis", personality: PersonalityConfig(personalInstructions: "Háblame pausado."))

        let file = try await host.exportActiveProfile(includeVectors: false, passphrase: "clave de prueba 1")
        defer { try? FileManager.default.removeItem(at: file) }
        let raw = try Data(contentsOf: file)
        XCTAssertTrue(ProfileArchive.isEncrypted(raw))
        XCTAssertNil(raw.range(of: Data("Ana prefiere".utf8)))

        do {
            _ = try await host.importProfile(from: file, passphrase: nil, options: RestoreOptions())
            XCTFail("Sin contraseña no debe importar")
        } catch {
            XCTAssertEqual(error as? ProfileArchiveError, .needsPassphrase)
        }
        XCTAssertEqual(host.registry.entries.count, 1, "Un intento fallido no deja perfiles a medias")

        let imported = try await host.importProfile(from: file, passphrase: "clave de prueba 1", options: RestoreOptions())
        XCTAssertEqual(host.registry.entries.count, 2)
        XCTAssertFalse(imported.isLegacy)
        XCTAssertEqual(host.registry.activeID, host.registry.entries[0].id, "Importar no cambia de perfil")
        let switched = await host.switchTo(imported.id)
        XCTAssertTrue(switched)
        await host.model.reloadMemory()
        XCTAssertTrue(host.model.memoryItems.isEmpty, "Los recuerdos importados quedan pendientes de aprobar")
        XCTAssertEqual(host.model.pendingMemories.map(\.text), ["Ana prefiere el té"])
        XCTAssertEqual(host.model.settings.profileSettings.assistantName, "Jarvis")
        XCTAssertEqual(host.model.settings.profileSettings.personality.personalInstructions, "", "Las instrucciones personales de un archivo no se confían por defecto")
        XCTAssertFalse(host.model.settings.calendarReadEnabled)
        host.eraseEverything()
    }
}
