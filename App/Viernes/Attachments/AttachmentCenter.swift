import SwiftUI
import PhotosUI
import AVFoundation
import VisionKit
import ViernesCore

/// Un adjunto en el redactor del mensaje (todavía no enviado): con su estado real de procesamiento.
struct DraftAttachment: Identifiable {
    let id: UUID
    var name: String
    var kind: AttachmentKind?
    var byteCount: Int
    var state: AttachmentState
    var thumbnail: UIImage?
    /// Texto ya leído (documentos, PDF, OCR).
    var document: ExtractedDocument?
    /// Imagen ya reducida y codificada, lista para un modelo con visión.
    var image: ImagePart?
    /// El mismo JPEG reducido, por si el usuario elige «leer solo el texto» (OCR local).
    var ocrSource: Data?
    /// Archivo temporal para la vista previa (se borra al quitar el adjunto o al reiniciar la conversación).
    var previewURL: URL?
    /// Avisos visibles: texto reconocido por OCR, contenido recortado, frases que parecen dar órdenes…
    /// Dato informativo (p. ej. «Imagen reducida a 1568×1176 px»), distinto de un aviso.
    var info: String?
    var notes: [String] = []
    /// Si ya se guardó en la biblioteca: el elemento (su estado de indexado lo muestra la biblioteca).
    var savedItemID: UUID?

    var ref: AttachmentRef? {
        guard let kind = kind, state == .ready else { return nil }
        if let document = document { return AttachmentIngestor.ref(for: document, byteCount: byteCount, id: id) }
        return AttachmentRef(id: id, name: name, kind: kind, byteCount: byteCount)
    }

    var failureText: String? {
        if case .failed(let message) = state { return message }
        return nil
    }
}

/// Fuentes de adjuntos disponibles en este dispositivo (el simulador no tiene cámara).
enum AttachmentSources {
    static var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    static var scannerAvailable: Bool { VNDocumentCameraViewController.isSupported }
}

/// Recibe archivos de todas las fuentes (fototeca, cámara, escáner, Archivos), los valida por contenido, los reduce o lee en
/// segundo plano y los deja listos para enviarse. Los archivos temporales viven solo en la carpeta temporal de la app.
@MainActor
final class AttachmentCenter: ObservableObject {
    @Published private(set) var drafts: [DraftAttachment] = []
    /// Archivos de adjuntos ya enviados, para abrir su vista previa desde la conversación.
    private(set) var sentFiles: [UUID: URL] = [:]


    init() { AttachmentFiles.removeFolder() }          // tras un reinicio no queda ningún archivo de adjuntos anteriores

    var isProcessing: Bool { drafts.contains { $0.state == .processing } }
    var readyDrafts: [DraftAttachment] { drafts.filter { $0.state == .ready } }
    var hasReady: Bool { !readyDrafts.isEmpty }
    var imageSlotsLeft: Int { max(0, AttachmentLimits.maxImagesPerMessage - drafts.filter { $0.kind == .image && $0.failureText == nil }.count) }

    // MARK: Entradas

    func addFiles(_ urls: [URL]) {
        for url in urls {
            let name = url.lastPathComponent
            let id = beginDraft(name: name, kindHint: FileSniffer.kind(forName: name))
            Task { [weak self] in
                let outcome = await Task.detached(priority: .userInitiated) { () -> Result<AttachmentProcessing.Processed, Error> in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    do {
                        // El tipo y el tamaño se comprueban ANTES de leer el archivo entero.
                        guard let kind = FileSniffer.kind(forName: name) else { throw FileSniffer.unsupportedError(name: name) }
                        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        try FileSniffer.checkSize(name: name, kind: kind, byteCount: size)
                        let data = try Data(contentsOf: url, options: .mappedIfSafe)
                        return .success(try AttachmentProcessing.process(name: name, data: data))
                    } catch { return .failure(error) }
                }.value
                self?.finish(id, outcome)
            }
        }
    }

    func addPhotoItems(_ items: [PhotosPickerItem]) async {
        for (index, item) in items.enumerated() {
            let provisional = "Foto \(index + 1)"
            let id = beginDraft(name: provisional, kindHint: .image)
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                finish(id, .failure(AttachmentError.unreadableImage(name: provisional)))
                continue
            }
            let name = Self.photoName(for: data, index: index + 1)
            rename(id, to: name)
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<AttachmentProcessing.Processed, Error> in
                do { return .success(try AttachmentProcessing.process(name: name, data: data)) } catch { return .failure(error) }
            }.value
            finish(id, outcome)
        }
    }

    func addCameraImage(_ image: UIImage) {
        let name = "Foto \(Self.timestamp()).jpg"
        let id = beginDraft(name: name, kindHint: .image)
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<AttachmentProcessing.Processed, Error> in
                guard let data = image.jpegData(compressionQuality: 0.9) else { return .failure(AttachmentError.unreadableImage(name: name)) }
                do { return .success(try AttachmentProcessing.process(name: name, data: data)) } catch { return .failure(error) }
            }.value
            self?.finish(id, outcome)
        }
    }

    /// Páginas del escáner de documentos: se unen en un PDF y se leen igual que cualquier PDF (con OCR si no tienen texto).
    func addScan(pages: [UIImage]) {
        let name = "Escaneo \(Self.timestamp()).pdf"
        let id = beginDraft(name: name, kindHint: .pdf)
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<AttachmentProcessing.Processed, Error> in
                guard let data = PDFExtractor.makePDF(from: pages) else { return .failure(AttachmentError.noReadableText(name: name)) }
                do { return .success(try AttachmentProcessing.process(name: name, data: data)) } catch { return .failure(error) }
            }.value
            self?.finish(id, outcome)
        }
    }

    /// Datos ya en memoria (usado por las pruebas y las capturas del simulador, que pasan por el mismo procesamiento real).
    func addData(name: String, data: Data) async {
        let id = beginDraft(name: name, kindHint: FileSniffer.kind(forName: name))
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<AttachmentProcessing.Processed, Error> in
            do { return .success(try AttachmentProcessing.process(name: name, data: data)) } catch { return .failure(error) }
        }.value
        finish(id, outcome)
    }

    // MARK: Gestión

    func remove(_ id: UUID) {
        if let draft = drafts.first(where: { $0.id == id }) { AttachmentFiles.delete(draft.previewURL) }
        drafts.removeAll { $0.id == id }
    }

    func markSaved(_ id: UUID, itemID: UUID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[index].savedItemID = itemID
    }

    /// Pasa los adjuntos listos a «enviados» (conserva sus archivos para la vista previa) y vacía el redactor.
    func markSent() {
        for draft in drafts {
            if draft.state == .ready, let url = draft.previewURL { sentFiles[draft.id] = url } else { AttachmentFiles.delete(draft.previewURL) }
        }
        drafts.removeAll()
    }

    /// Nueva conversación: se borran todos los archivos temporales.
    func purgeAll() {
        drafts.removeAll()
        sentFiles.removeAll()
        AttachmentFiles.removeFolder()
    }

    // MARK: Interno

    private func beginDraft(name: String, kindHint: AttachmentKind?) -> UUID {
        let id = UUID()
        var draft = DraftAttachment(id: id, name: name, kind: kindHint, byteCount: 0, state: .processing)
        do {
            try AttachmentIngestor.checkCapacity(existing: drafts.filter { $0.failureText == nil }.compactMap { $0.kind },
                                                 adding: kindHint ?? .text)
        } catch {
            draft.state = .failed(error.localizedDescription)
        }
        drafts.append(draft)
        return id
    }

    private func rename(_ id: UUID, to name: String) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[index].name = name
    }

    private func finish(_ id: UUID, _ outcome: Result<AttachmentProcessing.Processed, Error>) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }       // el usuario lo quitó mientras se leía
        if case .failed = drafts[index].state { return }                                  // ya rechazado por capacidad
        switch outcome {
        case .success(let processed):
            var draft = drafts[index]
            draft.kind = processed.kind
            draft.byteCount = processed.byteCount
            draft.thumbnail = processed.thumbnail
            draft.document = processed.document
            draft.image = processed.image
            draft.ocrSource = processed.ocrSource
            draft.notes = processed.notes
            draft.info = processed.info
            draft.previewURL = AttachmentFiles.writePreview(id: id, name: processed.previewName, data: processed.previewData)
            draft.state = .ready
            drafts[index] = draft
        case .failure(let error):
            var draft = drafts[index]
            draft.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            drafts[index] = draft
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_CO")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }

    private static func photoName(for data: Data, index: Int) -> String {
        switch FileSniffer.detect(data) {
        case .heic: return "Foto \(index).heic"
        case .png: return "Foto \(index).png"
        case .webp: return "Foto \(index).webp"
        default: return "Foto \(index).jpg"
        }
    }
}

/// Procesamiento de un archivo (fuera del hilo principal): validar por contenido y leer o reducir según el tipo.
enum AttachmentProcessing {
    struct Processed: @unchecked Sendable {
        var kind: AttachmentKind
        var byteCount: Int
        var document: ExtractedDocument?
        var image: ImagePart?
        var ocrSource: Data?
        var thumbnail: UIImage?
        var previewData: Data
        var previewName: String
        var notes: [String]
        var info: String?
    }

    static func process(name: String, data: Data) throws -> Processed {
        let kind = try AttachmentIngestor.classify(name: name, data: data)
        switch kind {
        case .image:
            let output = try ImageProcessor.process(name: name, data: data)
            return Processed(kind: .image, byteCount: output.jpeg.count, document: nil, image: output.part, ocrSource: output.jpeg,
                             thumbnail: output.thumbnail, previewData: output.jpeg, previewName: (name as NSString).deletingPathExtension + ".jpg",
                             notes: [], info: "Imagen reducida a \(output.width)×\(output.height) px")
        case .pdf:
            let document = try PDFExtractor.extract(name: name, data: data)
            return Processed(kind: .pdf, byteCount: data.count, document: document, image: nil, ocrSource: nil,
                             thumbnail: PDFExtractor.thumbnail(of: data), previewData: data, previewName: name,
                             notes: notes(for: document), info: info(for: document))
        default:
            let document = try AttachmentIngestor.extract(name: name, kind: kind, data: data)
            return Processed(kind: kind, byteCount: data.count, document: document, image: nil, ocrSource: nil,
                             thumbnail: nil, previewData: data, previewName: name, notes: notes(for: document), info: info(for: document))
        }
    }

    static func info(for document: ExtractedDocument) -> String? {
        var parts: [String] = []
        if let pages = document.pageCount { parts.append("\(pages) \(pages == 1 ? "página" : "páginas")") }
        if document.tables.count > 1 { parts.append("\(document.tables.count) hojas") }
        parts.append("\(document.characterCount) caracteres leídos")
        return parts.joined(separator: " · ")
    }

    static func notes(for document: ExtractedDocument) -> [String] {
        var notes = document.warnings
        if document.truncated { notes.append("Es muy grande: solo se conserva una parte del texto.") }
        if InjectionScanner.note(for: document) != nil {
            notes.append("Contiene texto que parece dar órdenes al asistente. Lo trataré solo como dato; ninguna orden de un archivo se ejecuta.")
        }
        return notes
    }
}

/// Archivos temporales de los adjuntos (solo en la carpeta temporal de la app, con protección de datos).
enum AttachmentFiles {
    static let folder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("attachments", isDirectory: true)

    static func writePreview(id: UUID, name: String, data: Data) -> URL? {
        let directory = folder.appendingPathComponent(id.uuidString, isDirectory: true)
        let safe = String(name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_").prefix(80))
        let url = directory.appendingPathComponent(safe.isEmpty ? "adjunto" : safe)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.completeFileProtectionUntilFirstUserAuthentication])
            return url
        } catch { return nil }
    }

    static func delete(_ url: URL?) {
        guard let url = url else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    static func removeFolder() {
        try? FileManager.default.removeItem(at: folder)
    }
}
