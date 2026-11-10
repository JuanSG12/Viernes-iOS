import Foundation

/// Lo que viaja con un mensaje que lleva archivos: metadatos para el historial, el texto ya leído y las imágenes ya reducidas.
public struct AttachmentBundle: Sendable {
    public var refs: [AttachmentRef]
    public var documents: [ExtractedDocument]
    public var images: [ImagePart]
    /// Avisos para el modelo (p. ej. «la imagen se leyó con OCR local»).
    public var notes: [String]

    public init(refs: [AttachmentRef] = [], documents: [ExtractedDocument] = [], images: [ImagePart] = [], notes: [String] = []) {
        self.refs = refs
        self.documents = documents
        self.images = images
        self.notes = notes
    }

    public var isEmpty: Bool { refs.isEmpty && documents.isEmpty && images.isEmpty }
}

/// Ingestión de archivos que NO dependen de la plataforma: validación por contenido, límites y lectura de texto y Office.
/// PDF (PDFKit/Vision) e imágenes (ImageIO) los lee la app y entregan aquí su resultado.
public enum AttachmentIngestor {
    /// Valida nombre, tamaño y contenido real, y devuelve el tipo de procesador a usar.
    public static func classify(name: String, data: Data) throws -> AttachmentKind {
        let kind = try FileSniffer.validate(name: name, data: data)
        try FileSniffer.checkSize(name: name, kind: kind, byteCount: data.count)
        return kind
    }

    /// Lee un archivo de texto, código, CSV, JSON, XML, Markdown, DOCX o XLSX.
    public static func extract(name: String, kind: AttachmentKind, data: Data) throws -> ExtractedDocument {
        switch kind {
        case .docx: return try OfficeParsers.docx(name: name, data: data)
        case .xlsx: return try OfficeParsers.xlsx(name: name, data: data)
        case .text, .markdown, .code, .csv, .json, .xml:
            guard let text = TextDecoder.decode(data) else {
                throw AttachmentError.corrupt(name: name, reason: "no pude interpretar su codificación de texto.")
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AttachmentError.noReadableText(name: name) }
            switch kind {
            case .markdown: return DocumentBuilders.markdown(name: name, text: text)
            case .csv: return DocumentBuilders.csv(name: name, text: text)
            case .json: return DocumentBuilders.json(name: name, text: text)
            case .xml: return DocumentBuilders.xml(name: name, text: text)
            default: return DocumentBuilders.plainText(name: name, kind: kind, text: text)
            }
        case .pdf, .image:
            throw AttachmentError.unsupportedFormat(name: name, detail: "este tipo lo procesa el lector del dispositivo, no el lector de texto.")
        }
    }

    /// Metadatos del historial para un documento ya leído.
    public static func ref(for document: ExtractedDocument, byteCount: Int, id: UUID = UUID()) -> AttachmentRef {
        AttachmentRef(id: id, name: document.name, kind: document.kind, byteCount: byteCount, pageCount: document.pageCount,
                      truncated: document.truncated, warning: document.warnings.first)
    }

    /// Comprueba los límites de un conjunto de adjuntos antes de añadir uno más.
    public static func checkCapacity(existing: [AttachmentKind], adding kind: AttachmentKind) throws {
        if existing.count >= AttachmentLimits.maxAttachmentsPerMessage {
            throw AttachmentError.tooManyAttachments(limit: AttachmentLimits.maxAttachmentsPerMessage)
        }
        if kind.isImage, existing.filter({ $0.isImage }).count >= AttachmentLimits.maxImagesPerMessage {
            throw AttachmentError.tooManyImages(limit: AttachmentLimits.maxImagesPerMessage)
        }
    }

    /// Resumen para el enrutador.
    public static func summary(refs: [AttachmentRef]) -> AttachmentSummary {
        AttachmentSummary(imageNames: refs.filter { $0.kind.isImage }.map(\.name), documentNames: refs.filter { !$0.kind.isImage }.map(\.name))
    }
}
