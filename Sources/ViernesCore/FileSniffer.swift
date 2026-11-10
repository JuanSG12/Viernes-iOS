import Foundation

/// Formato real de un archivo según sus primeros bytes (la extensión nunca basta: un «.jpg» puede ser otra cosa).
public enum DetectedFormat: String, Equatable, Sendable {
    case jpeg, png, heic, webp, gif, pdf, zip, oleCompound, executable, unsupportedImage, text, binary

    public var displayName: String {
        switch self {
        case .jpeg: return "una imagen JPEG"
        case .png: return "una imagen PNG"
        case .heic: return "una imagen HEIC"
        case .webp: return "una imagen WebP"
        case .gif: return "una imagen GIF"
        case .pdf: return "un PDF"
        case .zip: return "un archivo comprimido ZIP"
        case .oleCompound: return "un documento de Office antiguo o protegido con contraseña"
        case .executable: return "un programa ejecutable"
        case .unsupportedImage: return "una imagen en un formato no compatible"
        case .text: return "texto"
        case .binary: return "datos binarios"
        }
    }

    public var isSupportedImage: Bool { self == .jpeg || self == .png || self == .heic || self == .webp }
}

/// Validación de formato por CONTENIDO (tipo real), nunca solo por extensión ni por el tipo que declare el sistema.
public enum FileSniffer {
    static let codeExtensions: Set<String> = [
        "swift", "py", "js", "mjs", "ts", "tsx", "jsx", "java", "kt", "kts", "c", "h", "cc", "cpp", "hpp", "m", "mm", "cs", "go", "rs",
        "rb", "php", "sh", "bash", "zsh", "ps1", "sql", "html", "htm", "css", "scss", "yml", "yaml", "toml", "ini", "cfg", "conf",
        "gradle", "dart", "lua", "r", "scala", "vue", "svelte", "tf", "dockerfile", "makefile", "bat"
    ]
    static let legacyOffice: Set<String> = ["doc", "xls", "ppt", "pptx", "odt", "ods", "rtf", "pages", "numbers", "key"]

    /// Extensiones que Viernes sabe leer.
    public static let supportedDescription = "JPG, PNG, HEIC, WebP, PDF, TXT, MD, CSV, JSON, XML, DOCX, XLSX y archivos de código"

    public static func fileExtension(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    /// Tipo declarado por la extensión. `nil` si no hay un procesador real para ella.
    public static func kind(forName name: String) -> AttachmentKind? {
        let ext = fileExtension(name)
        switch ext {
        case "jpg", "jpeg", "png", "heic", "heif", "webp": return .image
        case "pdf": return .pdf
        case "txt", "text", "log": return .text
        case "md", "markdown": return .markdown
        case "csv", "tsv": return .csv
        case "json": return .json
        case "xml": return .xml
        case "docx": return .docx
        case "xlsx": return .xlsx
        default: return codeExtensions.contains(ext) ? .code : nil
        }
    }

    /// Mensaje claro para una extensión sin procesador.
    public static func unsupportedError(name: String) -> AttachmentError {
        let ext = fileExtension(name)
        if legacyOffice.contains(ext) {
            return .unsupportedFormat(name: name, detail: "el formato .\(ext) no tiene lector en Viernes. Expórtalo como PDF o DOCX/XLSX y vuelve a adjuntarlo.")
        }
        if ext == "gif" || ext == "bmp" || ext == "tiff" || ext == "tif" || ext == "avif" || ext == "svg" {
            return .unsupportedFormat(name: name, detail: "las imágenes .\(ext) no son compatibles todavía. Usa JPG, PNG, HEIC o WebP.")
        }
        let shown = ext.isEmpty ? "sin extensión" : ".\(ext)"
        return .unsupportedFormat(name: name, detail: "el formato \(shown) no es compatible. Puedo leer: \(supportedDescription).")
    }

    /// Formato real según la cabecera (y un vistazo al contenido para distinguir texto de binario).
    public static func detect(_ data: Data) -> DetectedFormat {
        let head = [UInt8](data.prefix(64))
        if head.count >= 3, head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF { return .jpeg }
        if head.count >= 8, Array(head[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return .png }
        if head.count >= 6, String(decoding: head[0..<6], as: UTF8.self).hasPrefix("GIF8") { return .gif }
        if head.count >= 12, String(decoding: head[0..<4], as: UTF8.self) == "RIFF", String(decoding: head[8..<12], as: UTF8.self) == "WEBP" {
            return .webp
        }
        if head.count >= 12, String(decoding: head[4..<8], as: UTF8.self) == "ftyp" {
            let brand = String(decoding: head[8..<12], as: UTF8.self)
            if ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"].contains(brand) { return .heic }
            if brand == "avif" || brand == "avis" { return .unsupportedImage }
            return .binary
        }
        if head.count >= 4 {
            let magic = Array(head[0..<4])
            if magic == [0x50, 0x4B, 0x03, 0x04] || magic == [0x50, 0x4B, 0x05, 0x06] { return .zip }
            if magic == [0x7F, 0x45, 0x4C, 0x46] { return .executable }                                  // ELF
            if magic == [0xFE, 0xED, 0xFA, 0xCE] || magic == [0xFE, 0xED, 0xFA, 0xCF] || magic == [0xCE, 0xFA, 0xED, 0xFE]
                || magic == [0xCF, 0xFA, 0xED, 0xFE] || magic == [0xCA, 0xFE, 0xBA, 0xBE] { return .executable }   // Mach-O
        }
        if head.count >= 8, Array(head[0..<8]) == [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] { return .oleCompound }
        if head.count >= 2, head[0] == 0x4D, head[1] == 0x5A { return .executable }                       // MZ (Windows)
        // El PDF empieza por «%PDF-»; la especificación tolera hasta 1024 bytes previos, pero solo se acepta así si el archivo no es texto
        // (un .txt que mencione «%PDF-» no es un PDF).
        if head.count >= 5, Array(head[0..<5]) == [0x25, 0x50, 0x44, 0x46, 0x2D] { return .pdf }
        let isText = looksLikeText(data)
        if !isText, String(decoding: data.prefix(1024), as: UTF8.self).contains("%PDF-") { return .pdf }
        return isText ? .text : .binary
    }

    /// ¿Es texto? UTF-8, UTF-16 con BOM, o Latin-1/Windows-1252 sin bytes de control raros ni ceros.
    public static func looksLikeText(_ data: Data) -> Bool {
        let sample = [UInt8](data.prefix(8_192))
        if sample.isEmpty { return true }
        if sample.count >= 2, (sample[0] == 0xFF && sample[1] == 0xFE) || (sample[0] == 0xFE && sample[1] == 0xFF) { return true }
        var control = 0
        for byte in sample {
            if byte == 0 { return false }
            if byte < 9 || (byte > 13 && byte < 32) { control += 1 }
        }
        return Double(control) / Double(sample.count) < 0.02
    }

    /// Comprueba que el CONTENIDO coincide con lo que dice el nombre y devuelve el tipo de procesador a usar.
    public static func validate(name: String, data: Data) throws -> AttachmentKind {
        guard let claimed = kind(forName: name) else { throw unsupportedError(name: name) }
        if data.isEmpty { throw AttachmentError.empty(name: name) }
        let found = detect(data)
        if found == .executable { throw AttachmentError.contentMismatch(name: name, claimed: claimed.displayName, found: found.displayName) }
        switch claimed {
        case .image:
            if found.isSupportedImage { return claimed }
            if found == .gif || found == .unsupportedImage { throw AttachmentError.unsupportedFormat(name: name, detail: "ese formato de imagen no es compatible. Usa JPG, PNG, HEIC o WebP.") }
            throw AttachmentError.contentMismatch(name: name, claimed: "una imagen", found: found.displayName)
        case .pdf:
            if found == .pdf { return claimed }
            throw AttachmentError.contentMismatch(name: name, claimed: "un PDF", found: found.displayName)
        case .docx, .xlsx:
            if found == .zip { return claimed }
            if found == .oleCompound { throw AttachmentError.encrypted(name: name) }
            throw AttachmentError.contentMismatch(name: name, claimed: claimed.displayName, found: found.displayName)
        case .text, .markdown, .code, .csv, .json, .xml:
            if found == .text { return claimed }
            throw AttachmentError.contentMismatch(name: name, claimed: "un archivo de texto", found: found.displayName)
        }
    }

    /// Límite de tamaño por tipo.
    public static func checkSize(name: String, kind: AttachmentKind, byteCount: Int) throws {
        let limit = kind.isImage ? AttachmentLimits.maxImageSourceBytes : AttachmentLimits.maxDocumentBytes
        if byteCount > limit { throw AttachmentError.tooLarge(name: name, bytes: byteCount, limit: limit) }
    }
}
