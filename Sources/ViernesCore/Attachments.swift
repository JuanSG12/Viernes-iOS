import Foundation

/// Tipos de adjunto que Viernes sabe leer DE VERDAD (cada uno tiene un procesador real; ver MULTIMODAL_ARCHITECTURE.md).
public enum AttachmentKind: String, Codable, Sendable, CaseIterable {
    case image, pdf, text, markdown, code, csv, json, xml, docx, xlsx

    public var isImage: Bool { self == .image }

    public var displayName: String {
        switch self {
        case .image: return "Imagen"
        case .pdf: return "PDF"
        case .text: return "Texto"
        case .markdown: return "Markdown"
        case .code: return "Código"
        case .csv: return "CSV"
        case .json: return "JSON"
        case .xml: return "XML"
        case .docx: return "Word (DOCX)"
        case .xlsx: return "Excel (XLSX)"
        }
    }

    /// Nombre de símbolo SF para mostrar el tipo en la interfaz.
    public var symbolName: String {
        switch self {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .text, .markdown: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .csv, .xlsx: return "tablecells"
        case .json, .xml: return "curlybraces"
        case .docx: return "doc"
        }
    }
}

/// Estado de un adjunto, tal como lo muestra la interfaz.
public enum AttachmentState: Codable, Equatable, Sendable {
    case processing
    case ready
    case failed(String)
}

/// Metadatos de un adjunto (lo único que se guarda en el historial: el CONTENIDO del archivo no se persiste en esta fase).
public struct AttachmentRef: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: AttachmentKind
    public var byteCount: Int
    public var pageCount: Int?
    /// El texto extraído se recortó por tamaño.
    public var truncated: Bool
    public var warning: String?

    public init(id: UUID = UUID(), name: String, kind: AttachmentKind, byteCount: Int, pageCount: Int? = nil,
                truncated: Bool = false, warning: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.byteCount = byteCount
        self.pageCount = pageCount
        self.truncated = truncated
        self.warning = warning
    }
}

/// Límites de seguridad y de tamaño (protección contra archivos enormes o maliciosos).
public enum AttachmentLimits {
    public static let maxAttachmentsPerMessage = 6
    public static let maxImagesPerMessage = 3
    /// Documentos (PDF, Office, texto…).
    public static let maxDocumentBytes = 25 * 1024 * 1024
    /// Imagen original (antes de reducirla).
    public static let maxImageSourceBytes = 40 * 1024 * 1024
    /// Texto extraído que se conserva por documento.
    public static let maxExtractedCharacters = 600_000
    /// Páginas de un PDF que se leen (con OCR, el límite de páginas escaneadas es menor).
    public static let maxPDFPages = 300
    public static let maxOCRPages = 20
    /// Contenido descomprimido de un DOCX/XLSX (protección contra «bombas» de compresión).
    public static let maxZipEntries = 2_000
    public static let maxZipEntryBytes = 40 * 1024 * 1024
    public static let maxZipTotalBytes = 120 * 1024 * 1024
    /// Celdas leídas de una hoja de cálculo.
    public static let maxSheetRows = 5_000
    public static let maxSheetColumns = 100
    public static let maxSheetCells = 200_000
    /// Adjuntos de documentos que siguen disponibles para preguntas posteriores en la misma conversación.
    public static let maxActiveDocuments = 6
}

/// Errores de ingestión, con el mensaje que ve el usuario (nunca términos internos).
public enum AttachmentError: Error, Equatable, LocalizedError {
    case unsupportedFormat(name: String, detail: String)
    case tooLarge(name: String, bytes: Int, limit: Int)
    case empty(name: String)
    case contentMismatch(name: String, claimed: String, found: String)
    case corrupt(name: String, reason: String)
    case encrypted(name: String)
    case noReadableText(name: String)
    case tooManyAttachments(limit: Int)
    case tooManyImages(limit: Int)
    case unsafeArchive(name: String)
    case imageTooLarge(name: String)
    case unreadableImage(name: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let name, let detail):
            return "«\(name)»: \(detail)"
        case .tooLarge(let name, let bytes, let limit):
            return "«\(name)» pesa \(Self.megabytes(bytes)) y el límite es \(Self.megabytes(limit)). Prueba con una versión más pequeña."
        case .empty(let name):
            return "«\(name)» está vacío."
        case .contentMismatch(let name, let claimed, let found):
            return "«\(name)» dice ser \(claimed), pero su contenido es \(found). No lo abrí por seguridad."
        case .corrupt(let name, let reason):
            return "No pude leer «\(name)»: \(reason)"
        case .encrypted(let name):
            return "«\(name)» está protegido con contraseña o en un formato antiguo que no puedo abrir. Quítale la protección (o expórtalo de nuevo) y vuelve a adjuntarlo."
        case .noReadableText(let name):
            return "No encontré texto legible en «\(name)»."
        case .tooManyAttachments(let limit):
            return "Solo puedes adjuntar hasta \(limit) archivos por mensaje."
        case .tooManyImages(let limit):
            return "Solo puedes adjuntar hasta \(limit) imágenes por mensaje."
        case .unsafeArchive(let name):
            return "«\(name)» tiene una estructura interna sospechosa (demasiado grande o anidada) y no lo abrí por seguridad."
        case .imageTooLarge(let name):
            return "No logré reducir «\(name)» a un tamaño que se pueda enviar. Prueba con otra foto o una captura más pequeña."
        case .unreadableImage(let name):
            return "No pude abrir «\(name)» como imagen."
        }
    }

    static func megabytes(_ bytes: Int) -> String {
        let value = Double(bytes) / 1_048_576
        return value < 10 ? String(format: "%.1f MB", value) : String(format: "%.0f MB", value)
    }
}
