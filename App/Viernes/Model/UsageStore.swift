import Foundation
import ViernesCore

/// Consumo de los proveedores en la nube de ESTE perfil: historial cifrado (con la clave del perfil), ajustes de presupuesto y lo último que
/// informó cada proveedor sobre sus límites. Es seguro entre hilos porque el motor de red lo consulta fuera del hilo principal.
final class UsageStore: ObservableObject, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRecords: [UsageRecord] = []
    private var storedSettings: UsageSettings = .default
    private var storedLimits: [String: ProviderLimitsSnapshot] = [:]
    private let vault: Vault
    private let fileURL: URL

    /// `path`: ruta relativa a «Application Support» (ver `ProfileStorageLayout.usageHistoryPath`).
    init(vault: Vault, path: String, base: URL? = nil) {
        self.vault = vault
        let root = base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        fileURL = root.appendingPathComponent(path)
        if let data = try? Data(contentsOf: fileURL), let loaded = try? vault.open([UsageRecord].self, from: data) {
            storedRecords = UsageSummary.pruned(loaded, now: Date())
        }
    }

    var records: [UsageRecord] { lock.withLock { storedRecords } }
    var limits: [String: ProviderLimitsSnapshot] { lock.withLock { storedLimits } }
    var settings: UsageSettings {
        get { lock.withLock { storedSettings } }
        set {
            lock.withLock { storedSettings = newValue.sanitized() }
            notify()
        }
    }

    private func notify() { DispatchQueue.main.async { self.objectWillChange.send() } }

    /// Se consulta antes de cada petición a un proveedor en la nube.
    func gate(providerID: String, model: String, now: Date = Date()) -> UsageGateDecision {
        UsageGate.check(providerID: providerID, model: model, settings: settings, records: records, now: now)
    }

    /// Anota una petición con el consumo REAL si el proveedor lo informó, o estimado (marcado) si no.
    func record(providerID: String, model: String, usage: TokenUsage, now: Date = Date()) {
        let cost = UsageCost.cost(usage, price: settings.price(providerID: providerID, model: model))
        let entry = UsageRecord(date: now, providerID: providerID, model: model, input: usage.input, output: usage.output,
                                isEstimate: usage.isEstimate, costUSD: cost)
        let snapshot: [UsageRecord] = lock.withLock {
            storedRecords.append(entry)
            storedRecords = UsageSummary.pruned(storedRecords, now: now)
            return storedRecords
        }
        persist(snapshot)
        notify()
    }

    func setLimits(_ providerID: String, _ snapshot: ProviderLimitsSnapshot) {
        lock.withLock { storedLimits[providerID] = snapshot }
        notify()
    }

    func clear() {
        lock.withLock {
            storedRecords = []
            storedLimits = [:]
        }
        try? FileManager.default.removeItem(at: fileURL)
        notify()
    }

    private func persist(_ snapshot: [UsageRecord]) {
        guard let sealed = try? vault.seal(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? sealed.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
