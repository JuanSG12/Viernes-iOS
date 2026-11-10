import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Quita el prefijo de espacio de nombres: «w:p» → «p», «r:id» → «id».
private func localName(_ qualified: String) -> String {
    if let index = qualified.lastIndex(of: ":") { return String(qualified[qualified.index(after: index)...]) }
    return qualified
}

/// Lectores de DOCX y XLSX sobre `ZipArchive` + `XMLParser` (sin dependencias). Cada uno devuelve texto con referencias.
public enum OfficeParsers {

    // MARK: Apertura segura

    private static func openArchive(_ data: Data, name: String) throws -> ZipArchive {
        do {
            return try ZipArchive(data: data)
        } catch ZipArchive.Failure.encrypted {
            throw AttachmentError.encrypted(name: name)
        } catch ZipArchive.Failure.unsafe {
            throw AttachmentError.unsafeArchive(name: name)
        } catch ZipArchive.Failure.unsupported(let what) {
            throw AttachmentError.corrupt(name: name, reason: "usa una característica no compatible (\(what)).")
        } catch {
            throw AttachmentError.corrupt(name: name, reason: "el archivo está dañado o no es un documento válido.")
        }
    }

    private static func read(_ archive: ZipArchive, _ path: String, name: String) throws -> Data? {
        do {
            return try archive.data(named: path)
        } catch ZipArchive.Failure.unsafe {
            throw AttachmentError.unsafeArchive(name: name)
        } catch {
            throw AttachmentError.corrupt(name: name, reason: "una parte interna está dañada (\(path)).")
        }
    }

    private static func parse(_ data: Data, with delegate: XMLParserDelegate) -> Bool {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        return parser.parse()
    }

    // MARK: DOCX

    private final class DocxHandler: NSObject, XMLParserDelegate {
        struct Block {
            var style: String?
            var text: String
            var isList: Bool
            var renderedBreaks: Int
            var explicitBreaks: Int
        }
        var blocks: [Block] = []
        var totalRendered = 0
        var totalExplicit = 0

        private var inText = false
        private var paragraph = ""
        private var style: String?
        private var listItem = false
        private var tableDepth = 0
        private var cell = ""
        private var rowCells: [String] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            switch localName(elementName) {
            case "p":
                paragraph = ""
                style = nil
                listItem = false
            case "pStyle": style = attributeDict["w:val"] ?? attributeDict["val"]
            case "numPr": listItem = true
            case "t": inText = true
            case "tab": paragraph += "\t"
            case "cr": paragraph += "\n"
            case "br":
                let type = attributeDict["w:type"] ?? attributeDict["type"]
                if type == "page" { totalExplicit += 1 } else { paragraph += "\n" }
            case "lastRenderedPageBreak": totalRendered += 1
            case "tbl": tableDepth += 1
            case "tr": if tableDepth == 1 { rowCells = [] }
            case "tc": if tableDepth == 1 { cell = "" }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { paragraph += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            switch localName(elementName) {
            case "t": inText = false
            case "p":
                let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                if tableDepth > 0 {
                    if !text.isEmpty { cell += (cell.isEmpty ? "" : " ") + text }
                } else if !text.isEmpty {
                    blocks.append(Block(style: style, text: text, isList: listItem, renderedBreaks: totalRendered, explicitBreaks: totalExplicit))
                }
            case "tc": if tableDepth == 1 { rowCells.append(cell.trimmingCharacters(in: .whitespacesAndNewlines)) }
            case "tr":
                if tableDepth == 1, rowCells.contains(where: { !$0.isEmpty }) {
                    blocks.append(Block(style: nil, text: rowCells.joined(separator: " | "), isList: false,
                                        renderedBreaks: totalRendered, explicitBreaks: totalExplicit))
                }
            case "tbl": tableDepth = max(0, tableDepth - 1)
            default: break
            }
        }
    }

    static func isHeadingStyle(_ style: String?) -> Bool {
        guard let style = style?.lowercased() else { return false }
        return style.hasPrefix("heading") || style.hasPrefix("ttulo") || style.hasPrefix("titulo") || style.hasPrefix("título")
            || style == "title" || style == "subtitle"
    }

    public static func docx(name: String, data: Data) throws -> ExtractedDocument {
        let archive = try openArchive(data, name: name)
        guard let xml = try read(archive, "word/document.xml", name: name) else {
            throw AttachmentError.corrupt(name: name, reason: "no es un documento de Word válido (falta el contenido principal).")
        }
        let handler = DocxHandler()
        guard parse(xml, with: handler) else {
            throw AttachmentError.corrupt(name: name, reason: "el contenido del documento está dañado.")
        }
        // Las páginas de un DOCX no son fijas: se estiman con los saltos que Word dejó guardados (o los explícitos).
        let useRendered = handler.totalRendered > 0
        let hasPages = handler.totalRendered > 0 || handler.totalExplicit > 0
        func page(of block: DocxHandler.Block) -> Int? {
            guard hasPages else { return nil }
            return 1 + (useRendered ? block.renderedBreaks : block.explicitBreaks)
        }

        var sections: [DocumentSection] = []
        var title: String?
        var buffer: [String] = []
        var size = 0
        var sectionPage: Int?
        var characters = 0
        var truncated = false

        func flush() {
            let body = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { sections.append(DocumentSection(title: title, page: sectionPage, text: body)) }
            buffer = []
            size = 0
            sectionPage = nil
        }

        for block in handler.blocks {
            if characters > AttachmentLimits.maxExtractedCharacters { truncated = true; break }
            if isHeadingStyle(block.style) {
                flush()
                title = block.text
                sectionPage = page(of: block)
                continue
            }
            if sectionPage == nil { sectionPage = page(of: block) }
            let line = block.isList ? "• " + block.text : block.text
            buffer.append(line)
            size += line.count + 1
            characters += line.count + 1
            if size >= DocumentBuilders.sectionTarget { flush() }
        }
        flush()
        if sections.isEmpty { throw AttachmentError.noReadableText(name: name) }
        let pageCount: Int? = hasPages ? 1 + (useRendered ? handler.totalRendered : handler.totalExplicit) : nil
        var warnings = ["Las páginas de un documento Word son aproximadas; se cita la sección cuando es posible."]
        if !hasPages { warnings = [] }
        return ExtractedDocument(name: name, kind: .docx, sections: sections, pageCount: pageCount, pagesApproximate: hasPages,
                                 truncated: truncated, warnings: warnings)
    }

    // MARK: XLSX

    private final class SharedStringsHandler: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current = ""
        private var inT = false
        private var phoneticDepth = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            switch localName(elementName) {
            case "si": current = ""
            case "rPh": phoneticDepth += 1
            case "t": inT = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inT, phoneticDepth == 0 { current += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            switch localName(elementName) {
            case "t": inT = false
            case "rPh": phoneticDepth = max(0, phoneticDepth - 1)
            case "si": strings.append(current)
            default: break
            }
        }
    }

    private final class WorkbookHandler: NSObject, XMLParserDelegate {
        struct SheetRef { var name: String; var relationshipID: String; var hidden: Bool }
        var sheets: [SheetRef] = []
        var date1904 = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            switch localName(elementName) {
            case "sheet":
                let id = attributeDict.first(where: { localName($0.key) == "id" })?.value ?? ""
                let state = attributeDict["state"] ?? "visible"
                sheets.append(SheetRef(name: attributeDict["name"] ?? "Hoja", relationshipID: id, hidden: state != "visible"))
            case "workbookPr":
                let value = attributeDict["date1904"] ?? "0"
                date1904 = value == "1" || value == "true"
            default: break
            }
        }
    }

    private final class RelationshipsHandler: NSObject, XMLParserDelegate {
        var targets: [String: String] = [:]
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            if localName(elementName) == "Relationship", let id = attributeDict["Id"], let target = attributeDict["Target"] {
                targets[id] = target
            }
        }
    }

    private final class StylesHandler: NSObject, XMLParserDelegate {
        var customFormats: [Int: String] = [:]
        var cellFormatIDs: [Int] = []
        private var inCellXfs = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            switch localName(elementName) {
            case "numFmt":
                if let id = Int(attributeDict["numFmtId"] ?? ""), let code = attributeDict["formatCode"] { customFormats[id] = code }
            case "cellXfs": inCellXfs = true
            case "xf": if inCellXfs { cellFormatIDs.append(Int(attributeDict["numFmtId"] ?? "") ?? 0) }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if localName(elementName) == "cellXfs" { inCellXfs = false }
        }

        /// Índices de estilo de celda cuyo formato es de fecha/hora.
        var dateStyleIndexes: Set<Int> {
            var result = Set<Int>()
            for (index, formatID) in cellFormatIDs.enumerated() where OfficeParsers.isDateFormat(id: formatID, custom: customFormats) {
                result.insert(index)
            }
            return result
        }
    }

    /// Formatos de número integrados de fecha/hora (14–22, 45–47) y personalizados que usan d, m, y, h o s fuera de comillas.
    static func isDateFormat(id: Int, custom: [Int: String]) -> Bool {
        if (14...22).contains(id) || (45...47).contains(id) { return true }
        guard let code = custom[id] else { return false }
        var cleaned = ""
        var inQuotes = false
        var inBrackets = false
        var escaped = false
        for character in code {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if character == "[" { inBrackets = true; continue }
            if character == "]" { inBrackets = false; continue }
            if inBrackets { continue }
            cleaned.append(character)
        }
        let lower = cleaned.lowercased()
        if lower == "general" { return false }
        return lower.contains("d") || lower.contains("y") || lower.contains("h") || lower.contains("s") || (lower.contains("m") && !lower.contains("0"))
    }

    /// Número de serie de Excel → «2025-03-14» o «2025-03-14 09:30».
    static func excelDateString(serial: Double, date1904: Bool) -> String? {
        guard serial.isFinite, serial >= 0, serial < 2_958_466 else { return nil }
        // 1900: el día 0 es 1899-12-30 (compensa el error histórico del año bisiesto 1900). 1904: día 0 = 1904-01-01.
        let epoch: Double = date1904 ? -2_082_844_800 : -2_209_161_600
        let seconds = epoch + (serial * 86_400).rounded()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let hasTime = abs(serial - serial.rounded(.down)) > 0.000_01
        formatter.dateFormat = hasTime ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    /// «AB12» → columna 28 (base 1).
    static func columnNumber(_ reference: String) -> Int {
        var value = 0
        for scalar in reference.unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 || (scalar.value >= 97 && scalar.value <= 122) else { break }
            let upper = scalar.value >= 97 ? scalar.value - 32 : scalar.value
            value = value * 26 + Int(upper - 64)
        }
        return value
    }

    private final class SheetHandler: NSObject, XMLParserDelegate {
        let shared: [String]
        let dateStyles: Set<Int>
        let date1904: Bool
        var rows: [Int: [Int: String]] = [:]
        var truncated = false
        private var cells = 0

        private var rowNumber = 0
        private var reference = ""
        private var type = "n"
        private var style = 0
        private var value = ""
        private var inline = ""
        private var inV = false
        private var inInlineText = false

        init(shared: [String], dateStyles: Set<Int>, date1904: Bool) {
            self.shared = shared
            self.dateStyles = dateStyles
            self.date1904 = date1904
            super.init()
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            switch localName(elementName) {
            case "row":
                if let number = Int(attributeDict["r"] ?? "") { rowNumber = number } else { rowNumber += 1 }
                if rowNumber > AttachmentLimits.maxSheetRows { truncated = true; parser.abortParsing() }
            case "c":
                reference = attributeDict["r"] ?? ""
                type = attributeDict["t"] ?? "n"
                style = Int(attributeDict["s"] ?? "") ?? 0
                value = ""
                inline = ""
            case "v": inV = true
            case "t": if type == "inlineStr" { inInlineText = true }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inV { value += string } else if inInlineText { inline += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            switch localName(elementName) {
            case "v": inV = false
            case "t": inInlineText = false
            case "c":
                let column = OfficeParsers.columnNumber(reference)
                guard column >= 1, column <= AttachmentLimits.maxSheetColumns else { return }
                let text = rendered()
                guard !text.isEmpty else { return }
                cells += 1
                if cells > AttachmentLimits.maxSheetCells { truncated = true; parser.abortParsing(); return }
                rows[rowNumber, default: [:]][column] = text
            default: break
            }
        }

        private func rendered() -> String {
            switch type {
            case "s":
                if let index = Int(value.trimmingCharacters(in: .whitespaces)), shared.indices.contains(index) { return shared[index] }
                return ""
            case "inlineStr": return inline
            case "b": return value.trimmingCharacters(in: .whitespaces) == "1" ? "VERDADERO" : "FALSO"
            case "str", "e", "d": return value
            default:
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if dateStyles.contains(style), let serial = Double(trimmed), let date = OfficeParsers.excelDateString(serial: serial, date1904: date1904) {
                    return date
                }
                return trimmed
            }
        }
    }

    private static func resolveSheetPath(_ target: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        return "xl/" + target
    }

    public static func xlsx(name: String, data: Data) throws -> ExtractedDocument {
        let archive = try openArchive(data, name: name)
        guard let workbookXML = try read(archive, "xl/workbook.xml", name: name) else {
            throw AttachmentError.corrupt(name: name, reason: "no es una hoja de cálculo válida (falta el libro).")
        }
        let workbook = WorkbookHandler()
        guard parse(workbookXML, with: workbook) else { throw AttachmentError.corrupt(name: name, reason: "el libro está dañado.") }

        let relationships = RelationshipsHandler()
        if let relsXML = try read(archive, "xl/_rels/workbook.xml.rels", name: name) { _ = parse(relsXML, with: relationships) }

        let sharedHandler = SharedStringsHandler()
        if let sharedXML = try read(archive, "xl/sharedStrings.xml", name: name) { _ = parse(sharedXML, with: sharedHandler) }

        let styles = StylesHandler()
        if let stylesXML = try read(archive, "xl/styles.xml", name: name) { _ = parse(stylesXML, with: styles) }
        let dateStyles = styles.dateStyleIndexes

        var sections: [DocumentSection] = []
        var tables: [TableData] = []
        var warnings: [String] = []
        var truncated = false
        var sheetIndex = 0

        for sheet in workbook.sheets {
            sheetIndex += 1
            if sheet.hidden { warnings.append("La hoja «\(sheet.name)» está oculta y no se leyó."); continue }
            let target = relationships.targets[sheet.relationshipID] ?? "worksheets/sheet\(sheetIndex).xml"
            guard let sheetXML = try read(archive, resolveSheetPath(target), name: name) else { continue }
            let handler = SheetHandler(shared: sharedHandler.strings, dateStyles: dateStyles, date1904: workbook.date1904)
            let parsedOK = parse(sheetXML, with: handler)
            if !parsedOK && !handler.truncated { throw AttachmentError.corrupt(name: name, reason: "la hoja «\(sheet.name)» está dañada.") }
            if handler.truncated {
                truncated = true
                warnings.append("La hoja «\(sheet.name)» es muy grande: solo se leyó una parte (hasta \(AttachmentLimits.maxSheetRows) filas).")
            }
            guard let firstRow = handler.rows.keys.min(), let lastRow = handler.rows.keys.max() else { continue }
            let widest = handler.rows.values.compactMap { $0.keys.max() }.max() ?? 0
            var grid: [[String]] = []
            for number in firstRow...min(lastRow, firstRow + AttachmentLimits.maxSheetRows) {
                let cells = handler.rows[number] ?? [:]
                var line = [String](repeating: "", count: widest)
                for (column, text) in cells { line[column - 1] = text }
                grid.append(line)
            }
            tables.append(TableData(name: sheet.name, rows: grid))
            sections.append(contentsOf: DocumentBuilders.table(sheet: "«\(sheet.name)»", rows: grid, firstRowNumber: firstRow))
        }
        if sections.isEmpty { throw AttachmentError.noReadableText(name: name) }
        return ExtractedDocument(name: name, kind: .xlsx, sections: sections, truncated: truncated, warnings: warnings, tables: tables)
    }
}
