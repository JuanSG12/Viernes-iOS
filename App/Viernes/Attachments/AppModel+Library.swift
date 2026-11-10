import Foundation
import UIKit
import CryptoKit
import ViernesCore

/// Resultado de guardar algo en la biblioteca.
enum LibrarySaveOutcome {
    case saved(KnowledgeItem)
    case duplicate(existing: KnowledgeItem, reason: DuplicateReason)
    case failed(String)
}

/// Biblioteca de conocimiento personal: guardar adjuntos, importar archivos y notas, y borrar. La búsqueda, el índice y el estado
/// los lleva `KnowledgeEngine` (núcleo, con pruebas); aquí solo se conecta con la interfaz.
extension AppModel {
    func reloadLibrary() async {
        libraryItems = await knowledge.allItems()
        libraryCollections = await knowledge.allCollections()
    }

    func startLibrary() async {
        await knowledge.setOnChange { [weak self] _ in
            Task { @MainActor in await self?.reloadLibrary() }
        }
        await reloadLibrary()
    }

    nonisolated private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Núcleo común: lee la imagen con OCR si hace falta y ejecuta el pipeline de la biblioteca.
    private func libraryIngest(name: String, kind: AttachmentKind, document: ExtractedDocument?, ocrSource: Data?, thumbnail: UIImage?,
                               contentHash: String, byteCount: Int, collectionID: UUID?, tags: [String], allowDuplicate: Bool) async -> LibrarySaveOutcome {
        var readable = document
        var thumbnailData: Data?
        if kind == .image {
            guard let jpeg = ocrSource else { return .failed("No tengo la imagen para leerla.") }
            let text = await Task.detached(priority: .userInitiated) { () -> String in
                (try? TextRecognizer.recognize(jpeg: jpeg)) ?? ""
            }.value
            guard !text.isEmpty else {
                return .failed("No encontré texto legible en la imagen. La biblioteca guarda y busca por texto: sin texto no habría nada que encontrar después.")
            }
            readable = ExtractedDocument(name: name, kind: .image, sections: [DocumentSection(text: text)], recognizedByOCR: true,
                                         warnings: ["Texto reconocido por OCR: puede tener errores y no describe la imagen."])
            thumbnailData = thumbnail?.jpegData(compressionQuality: 0.6)
        }
        guard let document = readable else { return .failed("No hay texto que guardar.") }
        do {
            let result = try await knowledge.ingest(
                document,
                source: IngestSource(sourceName: name, contentHash: contentHash, byteCount: byteCount,
                                     kind: kind == .image ? .image : .document, thumbnail: thumbnailData),
                options: IngestOptions(collectionID: collectionID, tags: tags, allowDuplicate: allowDuplicate))
            switch result {
            case .indexed(let item): return .saved(item)
            case .duplicate(let existing, let reason): return .duplicate(existing: existing, reason: reason)
            }
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Guarda en la biblioteca un adjunto ya leído (con su estado visible: procesando → indexado).
    func saveToLibrary(draftID: UUID, collectionID: UUID?, tags: [String], allowDuplicate: Bool = false) async -> LibrarySaveOutcome {
        guard let draft = attachments.drafts.first(where: { $0.id == draftID }), draft.state == .ready, let kind = draft.kind else {
            return .failed("Ese adjunto ya no está listo.")
        }
        var hash = ""
        if let url = draft.previewURL, let data = try? Data(contentsOf: url, options: .mappedIfSafe) { hash = Self.sha256Hex(data) }
        if hash.isEmpty { hash = ContentHash.sha256Hex(draft.document?.fullText ?? draft.name) }
        let outcome = await libraryIngest(name: draft.name, kind: kind, document: draft.document, ocrSource: draft.ocrSource, thumbnail: draft.thumbnail,
                                          contentHash: hash, byteCount: draft.byteCount, collectionID: collectionID, tags: tags, allowDuplicate: allowDuplicate)
        switch outcome {
        case .saved(let item): attachments.markSaved(draftID, itemID: item.id)
        case .duplicate, .failed: break
        }
        await reloadLibrary()
        return outcome
    }

    /// Importa archivos directamente a la biblioteca (sin pasar por un mensaje): mismo lector y mismas validaciones que los adjuntos.
    func importToLibrary(urls: [URL], collectionID: UUID?) {
        Task {
            var saved = 0
            var notices: [String] = []
            for url in urls {
                let name = url.lastPathComponent
                let read = await Task.detached(priority: .userInitiated) { () -> Result<(AttachmentProcessing.Processed, String), Error> in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    do {
                        guard let kind = FileSniffer.kind(forName: name) else { throw FileSniffer.unsupportedError(name: name) }
                        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        try FileSniffer.checkSize(name: name, kind: kind, byteCount: size)
                        let data = try Data(contentsOf: url, options: .mappedIfSafe)
                        return .success((try AttachmentProcessing.process(name: name, data: data), Self.sha256Hex(data)))
                    } catch { return .failure(error) }
                }.value
                switch read {
                case .failure(let error):
                    notices.append((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                case .success(let (processed, hash)):
                    let outcome = await libraryIngest(name: name, kind: processed.kind, document: processed.document, ocrSource: processed.ocrSource,
                                                      thumbnail: processed.thumbnail, contentHash: hash, byteCount: processed.byteCount,
                                                      collectionID: collectionID, tags: [], allowDuplicate: false)
                    switch outcome {
                    case .saved: saved += 1
                    case .duplicate(let existing, let reason): notices.append("«\(name)» ya estaba: \(reason.explanation) que «\(existing.title)».")
                    case .failed(let message): notices.append(message)
                    }
                }
            }
            await reloadLibrary()
            var parts: [String] = []
            if saved > 0 { parts.append(saved == 1 ? "Guardé 1 elemento en la biblioteca." : "Guardé \(saved) elementos en la biblioteca.") }
            parts.append(contentsOf: notices)
            libraryNotice = parts.joined(separator: "\n")
        }
    }

    /// Nota o texto escrito por el usuario.
    func addLibraryNote(title: String, text: String, kind: KnowledgeKind, collectionID: UUID?, tags: [String]) async -> LibrarySaveOutcome {
        do {
            let result = try await knowledge.addNote(title: title, text: text, kind: kind, options: IngestOptions(collectionID: collectionID, tags: tags))
            await reloadLibrary()
            switch result {
            case .indexed(let item): return .saved(item)
            case .duplicate(let existing, let reason): return .duplicate(existing: existing, reason: reason)
            }
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func deleteLibraryItem(_ id: UUID) {
        Task {
            try? await knowledge.delete(id)
            await reloadLibrary()
        }
    }

    func deleteAllLibrary() {
        Task {
            try? await knowledge.deleteAll()
            await reloadLibrary()
        }
    }
}
