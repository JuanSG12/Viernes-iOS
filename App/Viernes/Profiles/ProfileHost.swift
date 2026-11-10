import SwiftUI
import SwiftData
import ViernesCore

enum ProfileHostError: Error, LocalizedError {
    case unsupportedInTests
    var errorDescription: String? { "Esta acción no está disponible en el modo de pruebas." }
}

/// Dueño de los perfiles de este iPhone: el registro (quién existe y cuál está activo) y el `AppModel` del perfil activo.
/// Cambiar de perfil NO reutiliza nada: apaga el modelo actual y crea otro desde cero con los almacenes, la clave de cifrado,
/// los ajustes y las claves de API del perfil elegido. Así no puede quedar en memoria nada del anterior.
@MainActor
final class ProfileHost: ObservableObject {
    typealias Containers = (memory: ModelContainer, knowledge: ModelContainer)

    @Published private(set) var registry: ProfileRegistry
    @Published private(set) var model: AppModel
    /// El perfil activo es protegido y todavía no se confirmó la identidad en este arranque.
    @Published private(set) var isLocked: Bool
    /// Resultado de la última acción (cambio, borrado, importación…), para mostrarlo.
    @Published var notice: String?
    private(set) var launchError: String?

    static let registryKey = "viernes.profiles.v1"
    private let defaults: UserDefaults
    private let disk: ProfileDisk
    private let inMemory: Bool
    /// Solo en modo de pruebas de UI (almacenes en RAM): se conservan al cambiar de perfil para poder volver y ver lo guardado.
    private var memoryContainers: [UUID: Containers] = [:]

    init(inMemory: Bool = false, defaults: UserDefaults = .standard, disk: ProfileDisk = ProfileDisk()) {
        self.inMemory = inMemory
        self.defaults = defaults
        self.disk = disk
        let loaded = inMemory ? ProfileRegistry.initial() : Self.loadRegistry(defaults)
        let built = Self.build(entry: loaded.active, inMemory: inMemory, disk: disk, defaults: defaults, cache: [:])
        registry = loaded
        model = built.model
        launchError = built.error
        memoryContainers = built.cache
        isLocked = loaded.active.isProtected && !inMemory
        if !inMemory { Self.saveRegistry(loaded, to: defaults) }
        Self.cleanExports()
    }

    // MARK: Construcción

    private struct Built {
        var model: AppModel
        var error: String?
        var cache: [UUID: Containers]
    }

    private static func loadRegistry(_ defaults: UserDefaults) -> ProfileRegistry {
        guard let data = defaults.data(forKey: registryKey),
              let registry = try? JSONDecoder().decode(ProfileRegistry.self, from: data) else { return .initial() }
        return registry
    }

    private static func saveRegistry(_ registry: ProfileRegistry, to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(registry) { defaults.set(data, forKey: registryKey) }
    }

    /// Crea el modelo de un perfil. Antes fija las claves de API de ESE perfil (`CloudKeyStore`).
    private static func build(entry: ProfileEntry, inMemory: Bool, disk: ProfileDisk, defaults: UserDefaults, cache: [UUID: Containers]) -> Built {
        let layout = ProfileStorageLayout(entry: entry)
        CloudKeyStore.use(layout: layout)
        var cache = cache
        var errors: [String] = []
        let memory: ModelContainer
        let knowledge: ModelContainer
        if inMemory {
            if let cached = cache[entry.id] {
                memory = cached.memory
                knowledge = cached.knowledge
            } else {
                memory = try! ViernesStore.makeContainer(inMemory: true)
                knowledge = try! ViernesStore.makeKnowledgeContainer(inMemory: true)
                cache[entry.id] = (memory, knowledge)
            }
        } else {
            do {
                memory = try ViernesStore.makeContainer(storeURL: disk.url(layout.memoryStorePath))
            } catch let storeError {
                // Si el almacén en disco falla, se usa uno en RAM y se avisa: nada se guarda hasta resolverlo.
                memory = try! ViernesStore.makeContainer(inMemory: true)
                errors.append("No pude abrir el almacén de datos (\(storeError.localizedDescription)). Esta sesión no se guardará.")
            }
            do {
                knowledge = try ViernesStore.makeKnowledgeContainer(storeURL: disk.url(layout.knowledgeStorePath))
            } catch let storeError {
                knowledge = try! ViernesStore.makeKnowledgeContainer(inMemory: true)
                errors.append("No pude abrir el almacén de la biblioteca (\(storeError.localizedDescription)). La biblioteca no se guardará en esta sesión.")
            }
        }
        let model = AppModel(container: memory, knowledgeContainer: knowledge, entry: entry, defaults: defaults)
        return Built(model: model, error: errors.isEmpty ? nil : errors.joined(separator: "\n"), cache: cache)
    }

    private func persist() {
        if !inMemory { Self.saveRegistry(registry, to: defaults) }
    }

    private func authenticate(_ reason: String) async -> Bool {
        if inMemory { return true }
        return await Permissions.authenticate(reason: reason)
    }

    var active: ProfileEntry { registry.active }

    // MARK: Cambiar, crear, renombrar, proteger

    @discardableResult
    func createProfile(name: String) -> ProfileEntry? {
        var next = registry
        do {
            let entry = try next.add(name: name)
            registry = next
            persist()
            notice = "Perfil «\(entry.displayName)» creado. Empieza vacío: sin recuerdos, documentos ni claves."
            return entry
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    func renameProfile(_ id: UUID, to name: String) {
        var next = registry
        do {
            try next.rename(id: id, to: name)
            registry = next
            persist()
        } catch {
            notice = error.localizedDescription
        }
    }

    @discardableResult
    func switchTo(_ id: UUID) async -> Bool {
        guard id != registry.activeID, let entry = registry.entry(id: id) else { return false }
        if entry.isProtected {
            let allowed = await authenticate("Entrar en el perfil «\(entry.displayName)»")
            guard allowed else {
                notice = "No se cambió de perfil: no se confirmó tu identidad."
                return false
            }
        }
        activate(entry)
        notice = "Ahora estás en el perfil «\(entry.displayName)»."
        return true
    }

    /// Sustituye el modelo activo por el del perfil `entry` (el anterior se apaga antes).
    private func activate(_ entry: ProfileEntry) {
        model.shutdown()
        var next = registry
        try? next.activate(id: entry.id)
        registry = next
        persist()
        let built = Self.build(entry: entry, inMemory: inMemory, disk: disk, defaults: defaults, cache: memoryContainers)
        memoryContainers = built.cache
        launchError = built.error
        model = built.model
        isLocked = false
    }

    func unlock() async {
        guard isLocked else { return }
        if await authenticate("Abrir el perfil «\(registry.active.displayName)»") { isLocked = false }
    }

    func setProtected(_ id: UUID, _ value: Bool) async {
        guard let entry = registry.entry(id: id), entry.isProtected != value else { return }
        let allowed = await authenticate(value ? "Proteger el perfil «\(entry.displayName)»" : "Quitar la protección del perfil «\(entry.displayName)»")
        guard allowed else {
            notice = "No se cambió la protección: no se pudo confirmar tu identidad (el iPhone necesita un código o Face ID/Touch ID)."
            return
        }
        var next = registry
        try? next.setProtected(id: id, value)
        registry = next
        persist()
        notice = value ? "Perfil «\(entry.displayName)» protegido." : "Perfil «\(entry.displayName)» sin protección."
    }

    // MARK: Borrar

    /// Elimina un perfil con TODOS sus datos (clave de cifrado, claves de API, almacenes, ajustes, historial de voz).
    @discardableResult
    func deleteProfile(_ id: UUID) async -> Bool {
        guard let entry = registry.entry(id: id) else { return false }
        guard registry.entries.count > 1 else {
            notice = ProfileError.lastProfile.localizedDescription
            return false
        }
        if entry.isProtected {
            guard await authenticate("Eliminar el perfil «\(entry.displayName)»") else {
                notice = "No se eliminó el perfil: no se confirmó tu identidad."
                return false
            }
        }
        if id == registry.activeID {
            // Primero se pasa a otro perfil: así se apaga y se suelta el modelo que tiene abiertos los almacenes de este.
            guard let next = registry.entries.first(where: { $0.id != id }) else { return false }
            if next.isProtected {
                guard await authenticate("Entrar en el perfil «\(next.displayName)»") else {
                    notice = "No se eliminó el perfil: para salir de él hay que entrar en «\(next.displayName)», y no se confirmó tu identidad."
                    return false
                }
            }
            activate(next)
        }
        let problems = disk.erase(ProfileStorageLayout(entry: entry), defaults: defaults)
        var updated = registry
        try? updated.remove(id: id)
        registry = updated
        persist()
        memoryContainers[id] = nil
        notice = problems.isEmpty
            ? "Perfil «\(entry.displayName)» eliminado con todos sus datos."
            : "Perfil «\(entry.displayName)» eliminado, pero no pude borrar: \(problems.joined(separator: ", "))."
        return true
    }

    /// Borra TODOS los perfiles y sus datos y deja la app como recién instalada (un perfil nuevo y vacío).
    func eraseEverything() {
        model.shutdown()
        for entry in registry.entries { disk.erase(ProfileStorageLayout(entry: entry), defaults: defaults) }
        defaults.removeObject(forKey: Self.registryKey)
        memoryContainers = [:]
        let fresh = ProfileRegistry.initial()
        registry = fresh
        persist()
        let built = Self.build(entry: fresh.active, inMemory: inMemory, disk: disk, defaults: defaults, cache: [:])
        memoryContainers = built.cache
        launchError = built.error
        model = built.model
        isLocked = false
        notice = "Se borraron todos los perfiles y sus datos."
    }

    // MARK: Exportar e importar

    private static let exportPrefix = "viernes-export-"

    /// Los archivos de exportación se escriben en la carpeta temporal: se limpian al abrir la app.
    private static func cleanExports() {
        let temp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        for name in names where name.hasPrefix(exportPrefix) { try? FileManager.default.removeItem(at: temp.appendingPathComponent(name)) }
    }

    /// Exporta el perfil ACTIVO a un archivo (cifrado con contraseña si se da una). Nunca incluye claves.
    func exportActiveProfile(includeVectors: Bool, passphrase: String?) async throws -> URL {
        let bundle = try await model.makeProfileBundle(includeVectors: includeVectors)
        var data = try ProfileBundleCodec.encode(bundle)
        let secret = passphrase ?? ""
        if !secret.isEmpty {
            let plain = data
            data = try await Task.detached { try ProfileArchive.seal(plain, passphrase: secret) }.value
        }
        var safe = ""
        for scalar in registry.active.displayName.unicodeScalars {
            safe.unicodeScalars.append(CharacterSet.alphanumerics.contains(scalar) ? scalar : "-")
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(Self.exportPrefix)\(safe)-\(stamp).viernesperfil")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Importa un archivo como un perfil NUEVO (nunca mezcla ni pisa uno existente). Si algo falla a medias, se deshace todo.
    func importProfile(from fileURL: URL, passphrase: String?, options: RestoreOptions) async throws -> ProfileEntry {
        guard !inMemory else { throw ProfileHostError.unsupportedInTests }
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= ProfileBundleCodec.maxBytes + 4_096 else { throw ProfileBundleError.tooLarge(ProfileBundleCodec.maxBytes / 1_048_576) }
        var data = try Data(contentsOf: fileURL)
        if ProfileArchive.isEncrypted(data) {
            let encrypted = data
            let secret = passphrase ?? ""
            data = try await Task.detached { try ProfileArchive.open(encrypted, passphrase: secret) }.value
        }
        let bundle = try ProfileBundleCodec.decode(data)

        var next = registry
        var created: ProfileEntry?
        let root = String(bundle.profileName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(14))
        let base = root.isEmpty ? "Perfil" : root
        for attempt in 0..<50 {
            let candidate = attempt == 0 ? "\(base) (importado)" : "\(base) (importado \(attempt + 1))"
            do {
                created = try next.add(name: candidate)
                break
            } catch ProfileError.duplicateName {
                continue
            }
        }
        guard let entry = created else { throw ProfileError.duplicateName(base) }

        let layout = ProfileStorageLayout(entry: entry)
        do {
            let containers = try disk.openStores(for: layout)
            let vault = Vault(layout: layout)
            let memory = SwiftDataMemoryStore(modelContainer: containers.memory)
            memory.use(vault: vault)
            let library = SwiftDataKnowledgeStore(modelContainer: containers.knowledge)
            library.use(vault: vault)
            let repository = ConversationRepository(modelContainer: containers.memory)
            repository.use(vault: vault)
            let report = try await ProfileBundleBuilder.restore(bundle, memory: memory, knowledge: library, options: options)
            for conversation in report.conversations {
                try await repository.save(ConversationSnapshot(id: conversation.id, title: conversation.title, startedAt: conversation.startedAt,
                                                               updatedAt: conversation.updatedAt, messages: conversation.messages))
            }
            SettingsStore(defaults: defaults, layout: layout).save(report.settings)
            notice = "Importé «\(entry.displayName)»: \(report.memoriesRestored) recuerdos (pendientes de aprobar: \(options.memoriesAsPending ? "sí" : "no")), \(report.libraryItemsRestored) elementos de la biblioteca y \(report.conversationsRestored) conversaciones. Los permisos, la escucha por voz y las claves hay que activarlos de nuevo en ese perfil."
        } catch {
            disk.erase(layout, defaults: defaults)       // no queda un perfil a medias
            throw error
        }
        registry = next
        persist()
        return entry
    }
}
