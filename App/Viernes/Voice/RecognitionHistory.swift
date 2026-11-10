import Foundation
import ViernesCore

/// Historial LOCAL de reconocimiento de voz para diagnóstico: texto (nunca audio) de cada frase dictada, con lo que entregó el
/// reconocedor, lo corregido, lo editado y —si estaba activada— la transcripción en la nube para compararla.
/// Se guarda CIFRADO con la misma clave del Llavero que usa la memoria. Si el usuario eligió no guardar historial
/// (o conservar «nada» de las conversaciones), solo vive en memoria hasta cerrar la app.
@MainActor
final class RecognitionHistory: ObservableObject {
    @Published private(set) var records: [RecognitionRecord] = []
    private static let capacity = 100
    private let fileURL: URL
    private let vault: Vault
    private(set) var persist = true

    init(vault: Vault = Vault(), fileName: String = "recognition-history.bin") {
        self.vault = vault
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent(fileName)
        // El nombre puede incluir la carpeta del perfil («Viernes/profiles/<id>/…»).
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// Carga lo guardado (si el usuario permite guardar historial).
    func load(persist: Bool) {
        self.persist = persist
        guard persist, let data = try? Data(contentsOf: fileURL),
              let loaded = try? vault.open([RecognitionRecord].self, from: data) else { return }
        records = loaded
    }

    func setPersist(_ value: Bool) {
        persist = value
        if value { save() } else { try? FileManager.default.removeItem(at: fileURL) }
    }

    func add(_ record: RecognitionRecord) {
        records.append(record)
        if records.count > Self.capacity { records.removeFirst(records.count - Self.capacity) }
        save()
    }

    func update(_ id: UUID, _ change: (inout RecognitionRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        save()
    }

    func clear() {
        records.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    var stats: RecognitionStats { RecognitionStats.summarize(records) }

    /// Texto para copiar y pegar en un informe (sin audio). Incluye lo que dijo cada versión para poder compararlas.
    func report() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_CO")
        formatter.dateFormat = "d MMM HH:mm:ss"
        return records.suffix(30).map { record in
            var lines = ["\(formatter.string(from: record.date)) · \(record.mode) · \(record.locale) · \(record.onDevice ? "en el dispositivo" : "Apple por internet") · \(String(format: "%.1f", record.duration)) s · fin: \(record.endReason.rawValue)"]
            if let input = record.input { lines.append("  entrada: \(input)") }
            lines.append("  oído: «\(record.raw)»")
            if let corrected = record.corrected, corrected != record.raw { lines.append("  corregido: «\(corrected)»") }
            if let cloud = record.cloudText { lines.append("  Whisper: «\(cloud)»") }
            if let edited = record.edited { lines.append("  tú dejaste: «\(edited)»") }
            if let error = record.error { lines.append("  error: \(error)") }
            if record.retried { lines.append("  se reinició el reconocimiento") }
            if record.interrupted { lines.append("  hubo una interrupción del audio") }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func save() {
        guard persist else { return }
        guard let data = try? vault.seal(records) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
