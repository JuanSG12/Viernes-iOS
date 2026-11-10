import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Un fragmento localizable de un documento: sabe de dónde viene (página, sección, líneas) para poder citarlo.
public struct DocumentSection: Equatable, Codable, Sendable {
    public var title: String?
    public var page: Int?
    public var firstLine: Int?
    public var lastLine: Int?
    public var text: String

    public init(title: String? = nil, page: Int? = nil, firstLine: Int? = nil, lastLine: Int? = nil, text: String) {
        self.title = title
        self.page = page
        self.firstLine = firstLine
        self.lastLine = lastLine
        self.text = text
    }

    /// «pág. 3, «Cláusula 5»», «líneas 40–88»…: lo que se cita al usuario.
    public var reference: String {
        var parts: [String] = []
        if let page = page { parts.append("pág. \(page)") }
        if let title = title, !title.isEmpty { parts.append("«\(title)»") }
        if let first = firstLine, let last = lastLine { parts.append(first == last ? "línea \(first)" : "líneas \(first)–\(last)") }
        return parts.joined(separator: ", ")
    }
}

/// Tabla extraída de una hoja de cálculo o un CSV (para compararlas sin pedirle al modelo que adivine).
public struct TableData: Equatable, Sendable {
    public var name: String
    public var rows: [[String]]
    public init(name: String, rows: [[String]]) {
        self.name = name
        self.rows = rows
    }
}

/// Resultado de leer un archivo: texto con referencias, listo para fragmentar, indexar y citar.
public struct ExtractedDocument: Equatable, Sendable {
    public var name: String
    public var kind: AttachmentKind
    public var sections: [DocumentSection]
    public var pageCount: Int?
    /// Las páginas son una estimación (DOCX no tiene páginas fijas).
    public var pagesApproximate: Bool
    /// El texto se recortó por tamaño.
    public var truncated: Bool
    /// Texto obtenido por OCR (puede tener errores de lectura).
    public var recognizedByOCR: Bool
    public var warnings: [String]
    public var tables: [TableData]

    public init(name: String, kind: AttachmentKind, sections: [DocumentSection], pageCount: Int? = nil,
                pagesApproximate: Bool = false, truncated: Bool = false, recognizedByOCR: Bool = false,
                warnings: [String] = [], tables: [TableData] = []) {
        self.name = name
        self.kind = kind
        self.sections = sections
        self.pageCount = pageCount
        self.pagesApproximate = pagesApproximate
        self.truncated = truncated
        self.recognizedByOCR = recognizedByOCR
        self.warnings = warnings
        self.tables = tables
    }

    public var characterCount: Int { sections.reduce(0) { $0 + $1.text.count } }
    public var hasText: Bool { sections.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    public var fullText: String { sections.map(\.text).joined(separator: "\n\n") }
}

// MARK: Decodificación de texto

public enum TextDecoder {
    /// UTF-8 (con o sin BOM), UTF-16 con BOM o, si no, Windows-1252/Latin-1. `nil` solo si no hay forma de leerlo.
    public static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(3))
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        return String(data: data, encoding: .isoLatin1)
    }
}

// MARK: CSV

public enum CSVParser {
    /// Delimitador más probable según las primeras líneas (fuera de comillas).
    public static func detectDelimiter(_ text: String) -> Unicode.Scalar {
        let candidates: [Unicode.Scalar] = [",", ";", "\t", "|"]
        var best = candidates[0]
        var bestScore = 0
        let lines = text.split(separator: "\n", maxSplits: 8, omittingEmptySubsequences: true).prefix(6)
        for candidate in candidates {
            var minimum = Int.max
            for line in lines {
                var inQuotes = false
                var count = 0
                for scalar in line.unicodeScalars {
                    if scalar == "\"" { inQuotes.toggle() } else if scalar == candidate && !inQuotes { count += 1 }
                }
                minimum = min(minimum, count)
            }
            if minimum != Int.max, minimum > bestScore {
                bestScore = minimum
                best = candidate
            }
        }
        return best
    }

    /// RFC 4180: comillas, comillas escapadas y saltos de línea dentro de campos.
    public static func parse(_ text: String, delimiter: Unicode.Scalar? = nil,
                             maxRows: Int = AttachmentLimits.maxSheetRows, maxColumns: Int = AttachmentLimits.maxSheetColumns) -> [[String]] {
        let separator = delimiter ?? detectDelimiter(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var wasQuoted = false
        let scalars = Array(text.unicodeScalars)
        var index = 0

        func endField() {
            if row.count < maxColumns { row.append(String(field)) }
            field = String.UnicodeScalarView()
            wasQuoted = false
        }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while index < scalars.count, rows.count < maxRows {
            let scalar = scalars[index]
            if inQuotes {
                if scalar == "\"" {
                    if index + 1 < scalars.count, scalars[index + 1] == "\"" { field.append("\""); index += 1 } else { inQuotes = false }
                } else {
                    field.append(scalar)
                }
            } else if scalar == "\"" && field.isEmpty && !wasQuoted {
                inQuotes = true
                wasQuoted = true
            } else if scalar == separator {
                endField()
            } else if scalar == "\n" {
                endRow()
            } else if scalar == "\r" {
                if index + 1 < scalars.count, scalars[index + 1] == "\n" { index += 1 }
                endRow()
            } else {
                field.append(scalar)
            }
            index += 1
        }
        if rows.count < maxRows, !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}

// MARK: Limpieza del texto de un PDF

public enum PDFTextCleaner {
    /// Normaliza el texto de cada página y quita encabezados/pies repetidos y números de página sueltos.
    public static func clean(pages: [String]) -> [String] {
        removeRepeatedLines(pages.map(normalize))
    }

    static func normalize(_ page: String) -> String {
        var text = page.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text = text.replacingOccurrences(of: "\u{0}", with: "").replacingOccurrences(of: "\u{00AD}", with: "")
        // «informa-\nción» → «información» (solo si la siguiente línea sigue en minúscula).
        if let regex = try? NSRegularExpression(pattern: "(\\p{L})-\\n(\\p{Ll})") {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "$1$2")
        }
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var trimmed = line
            while trimmed.hasSuffix(" ") || trimmed.hasSuffix("\t") { trimmed.removeLast() }
            return trimmed
        }
        var result: [String] = []
        var blank = 0
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blank += 1
                if blank <= 1 { result.append("") }
            } else {
                blank = 0
                result.append(line)
            }
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isPageNumberLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 24 else { return false }
        let patterns = ["^(p[áa]g(ina)?\\.?\\s*)?\\d{1,4}(\\s*(de|/)\\s*\\d{1,4})?$", "^-\\s*\\d{1,4}\\s*-$"]
        for pattern in patterns {
            if trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        }
        return false
    }

    static func removeRepeatedLines(_ pages: [String]) -> [String] {
        let nonEmpty = pages.filter { !$0.isEmpty }.count
        guard nonEmpty >= 4 else { return pages.map(stripPageNumbers) }
        var counts: [String: Int] = [:]
        for page in pages {
            let unique = Set(page.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0.count <= 80 })
            for line in unique { counts[line, default: 0] += 1 }
        }
        let threshold = max(3, Int(Double(nonEmpty) * 0.7))
        let repeated = Set(counts.filter { $0.value >= threshold }.map { $0.key })
        return pages.map { page in
            let kept = page.components(separatedBy: "\n").filter { !repeated.contains($0.trimmingCharacters(in: .whitespaces)) }
            return stripPageNumbers(kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Quita un número de página en la primera o la última línea con contenido.
    static func stripPageNumbers(_ page: String) -> String {
        var lines = page.components(separatedBy: "\n")
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), isPageNumberLine(lines[first]) { lines.remove(at: first) }
        if let last = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), isPageNumberLine(lines[last]) { lines.remove(at: last) }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: Construcción de documentos

public enum DocumentBuilders {
    /// Tamaño objetivo de cada sección de texto corrido o código.
    static let sectionTarget = 1_400

    static func limited(_ text: String) -> (text: String, truncated: Bool) {
        guard text.count > AttachmentLimits.maxExtractedCharacters else { return (text, false) }
        return (String(text.prefix(AttachmentLimits.maxExtractedCharacters)), true)
    }

    /// Texto plano o código: secciones de ~1 400 caracteres con su rango de líneas (se parte en líneas en blanco si se puede).
    public static func plainText(name: String, kind: AttachmentKind, text rawText: String) -> ExtractedDocument {
        let (text, truncated) = limited(rawText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }       // un salto de línea final no es una línea más
        var sections: [DocumentSection] = []
        var buffer: [String] = []
        var bufferSize = 0
        var startLine = 1

        func flush(endingAt lastLine: Int) {
            let body = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { sections.append(DocumentSection(firstLine: startLine, lastLine: lastLine, text: body)) }
            buffer = []
            bufferSize = 0
            startLine = lastLine + 1
        }

        for (offset, line) in lines.enumerated() {
            let number = offset + 1
            buffer.append(line)
            bufferSize += line.count + 1
            let atBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if bufferSize >= sectionTarget || (atBlank && bufferSize >= Int(Double(sectionTarget) * 0.7)) { flush(endingAt: number) }
        }
        if !buffer.isEmpty { flush(endingAt: lines.count) }
        return ExtractedDocument(name: name, kind: kind, sections: sections, truncated: truncated)
    }

    /// Markdown: una sección por encabezado (y se vuelve a partir si es muy larga).
    public static func markdown(name: String, text rawText: String) -> ExtractedDocument {
        let (text, truncated) = limited(rawText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var sections: [DocumentSection] = []
        var title: String?
        var buffer: [String] = []
        var startLine = 1
        var inFence = false

        func flush(endingAt lastLine: Int) {
            let body = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                if body.count > sectionTarget * 2 {
                    let pieces = plainText(name: name, kind: .markdown, text: body).sections
                    for piece in pieces {
                        sections.append(DocumentSection(title: title, firstLine: startLine, lastLine: lastLine, text: piece.text))
                    }
                } else {
                    sections.append(DocumentSection(title: title, firstLine: startLine, lastLine: lastLine, text: body))
                }
            }
            buffer = []
            startLine = lastLine + 1
        }

        for (offset, line) in lines.enumerated() {
            let number = offset + 1
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, line.hasPrefix("#") {
                let hashes = line.prefix(while: { $0 == "#" })
                let rest = line.dropFirst(hashes.count)
                if (1...6).contains(hashes.count), rest.first == " " {
                    flush(endingAt: number - 1)
                    title = rest.trimmingCharacters(in: .whitespaces)
                }
            }
            buffer.append(line)
        }
        flush(endingAt: lines.count)
        return ExtractedDocument(name: name, kind: .markdown, sections: sections, truncated: truncated)
    }

    /// PDF: una sección por página, ya limpia.
    public static func pdf(name: String, pages: [String], recognizedByOCR: Bool = false, extraWarnings: [String] = []) -> ExtractedDocument {
        let cleaned = PDFTextCleaner.clean(pages: pages)
        var sections: [DocumentSection] = []
        var total = 0
        var truncated = false
        for (index, page) in cleaned.enumerated() where !page.isEmpty {
            if total + page.count > AttachmentLimits.maxExtractedCharacters {
                truncated = true
                let remaining = AttachmentLimits.maxExtractedCharacters - total
                if remaining > 200 { sections.append(DocumentSection(page: index + 1, text: String(page.prefix(remaining)))) }
                break
            }
            total += page.count
            sections.append(DocumentSection(page: index + 1, text: page))
        }
        var warnings = extraWarnings
        if recognizedByOCR { warnings.append("Texto reconocido por OCR: puede contener errores de lectura.") }
        return ExtractedDocument(name: name, kind: .pdf, sections: sections, pageCount: pages.count, truncated: truncated,
                                 recognizedByOCR: recognizedByOCR, warnings: warnings)
    }

    /// Tabla (CSV u hoja): bloques de filas con el encabezado repetido, para poder citar «filas 31–60».
    public static func table(sheet: String?, rows: [[String]], firstRowNumber: Int = 1) -> [DocumentSection] {
        guard !rows.isEmpty else { return [] }
        func render(_ row: [String]) -> String { row.map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") }
        let prefix = sheet.map { "Hoja \($0), " } ?? ""
        let headerText = "Encabezado: " + render(rows[0])
        if rows.count == 1 {
            return [DocumentSection(title: prefix + "fila \(firstRowNumber)", text: render(rows[0]))]
        }
        var sections: [DocumentSection] = []
        var buffer: [String] = []
        var size = 0
        var chunkFirst = 1
        var chunkLast = 1

        func flush() {
            guard !buffer.isEmpty else { return }
            let first = chunkFirst + firstRowNumber
            let last = chunkLast + firstRowNumber
            let range = first == last ? "fila \(first)" : "filas \(first)–\(last)"
            sections.append(DocumentSection(title: prefix + range, text: headerText + "\n" + buffer.joined(separator: "\n")))
            buffer = []
            size = 0
        }

        for index in 1..<rows.count {
            let row = rows[index]
            if row.allSatisfy({ $0.isEmpty }) { continue }
            if buffer.isEmpty {
                chunkFirst = index
                size = headerText.count
            }
            let line = render(row)
            buffer.append(line)
            chunkLast = index
            size += line.count + 1
            if size >= sectionTarget { flush() }
        }
        flush()
        return sections
    }

    public static func csv(name: String, text: String) -> ExtractedDocument {
        let rows = CSVParser.parse(text)
        var warnings: [String] = []
        if rows.count >= AttachmentLimits.maxSheetRows { warnings.append("Solo se leyeron las primeras \(AttachmentLimits.maxSheetRows) filas.") }
        return ExtractedDocument(name: name, kind: .csv, sections: table(sheet: nil, rows: rows),
                                 truncated: rows.count >= AttachmentLimits.maxSheetRows, warnings: warnings,
                                 tables: rows.isEmpty ? [] : [TableData(name: name, rows: rows)])
    }

    /// JSON: se valida y se reescribe con sangría (legible y con estructura); si no es válido, se conserva el texto y se avisa.
    public static func json(name: String, text: String) -> ExtractedDocument {
        var warnings: [String] = []
        var body = text
        if let data = text.data(using: .utf8) {
            do {
                let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
                if let formatted = String(data: pretty, encoding: .utf8) { body = formatted }
            } catch {
                warnings.append("El JSON no es válido (\(error.localizedDescription)); se leyó como texto.")
            }
        }
        var document = plainText(name: name, kind: .json, text: body)
        document.warnings = warnings
        return document
    }

    /// XML: se comprueba que esté bien formado; el contenido se conserva como texto.
    public static func xml(name: String, text: String) -> ExtractedDocument {
        var warnings: [String] = []
        if let data = text.data(using: .utf8) {
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            if !parser.parse() {
                let line = parser.lineNumber
                warnings.append("El XML no está bien formado (línea \(line)); se leyó como texto.")
            }
        }
        var document = plainText(name: name, kind: .xml, text: text)
        document.warnings = warnings
        return document
    }
}
