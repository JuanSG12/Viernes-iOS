import Foundation

/// Un trozo de un documento con su procedencia (documento + página/sección/líneas) para poder citarlo.
public struct DocumentChunk: Equatable, Sendable {
    public let documentIndex: Int
    public let documentName: String
    public let reference: String
    public let text: String
}

public enum DocumentChunker {
    /// Parte las secciones largas (p. ej. una página de PDF) en trozos de ≤ `maxChars`, sin cortar palabras si se puede.
    public static func chunks(for documents: [ExtractedDocument], maxChars: Int = 1_200) -> [DocumentChunk] {
        var result: [DocumentChunk] = []
        for (index, document) in documents.enumerated() {
            for section in document.sections {
                let text = section.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                for piece in split(text, maxChars: maxChars) {
                    result.append(DocumentChunk(documentIndex: index, documentName: document.name, reference: section.reference, text: piece))
                }
            }
        }
        return result
    }

    static func split(_ text: String, maxChars: Int) -> [String] {
        guard text.count > maxChars else { return [text] }
        var pieces: [String] = []
        var current = ""
        func push() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pieces.append(trimmed) }
            current = ""
        }
        for paragraph in text.components(separatedBy: "\n\n") {
            if paragraph.count > maxChars {
                push()
                var remaining = Substring(paragraph)
                while remaining.count > maxChars {
                    let hardEnd = remaining.index(remaining.startIndex, offsetBy: maxChars)
                    var cut = hardEnd
                    if let space = remaining[remaining.startIndex..<hardEnd].lastIndex(where: { $0 == " " || $0 == "\n" }),
                       remaining.distance(from: remaining.startIndex, to: space) > maxChars / 2 {
                        cut = space
                    }
                    pieces.append(String(remaining[remaining.startIndex..<cut]).trimmingCharacters(in: .whitespacesAndNewlines))
                    remaining = remaining[cut...]
                }
                current = String(remaining)
            } else if current.count + paragraph.count + 2 > maxChars {
                push()
                current = paragraph
            } else {
                current += (current.isEmpty ? "" : "\n\n") + paragraph
            }
        }
        push()
        return pieces
    }
}

public struct Excerpt: Equatable, Sendable {
    public let documentIndex: Int
    public let documentName: String
    public let reference: String
    public let text: String
}

public struct ExcerptSelection: Equatable, Sendable {
    public enum Mode: String, Sendable { case all, broad, targeted }
    public var excerpts: [Excerpt]
    public var mode: Mode
    public var totalChunks: Int
    public var selectedChunks: Int
    public var isComplete: Bool { selectedChunks >= totalChunks }
    public static let empty = ExcerptSelection(excerpts: [], mode: .all, totalChunks: 0, selectedChunks: 0)
}

/// Elige qué partes de los documentos caben en la petición: todo si cabe; si no, lo más relevante para la pregunta
/// (BM25 sobre términos sin acentos ni plurales) o, para peticiones generales («resume esto»), fragmentos repartidos.
public enum ExcerptSelector {
    /// Palabras de la petición que no dicen QUÉ buscar (verbos de encargo y nombres genéricos de archivo).
    static let genericWords: Set<String> = [
        "resume", "resumen", "resumir", "analiza", "analizar", "analisis", "explica", "explicar", "revisa", "revisar", "lee", "leer",
        "documento", "documentos", "archivo", "archivos", "adjunto", "adjuntos", "pdf", "informe", "contrato", "hoja", "hojas", "calculo",
        "imagen", "imagenes", "foto", "fotos", "captura", "texto", "pagina", "paginas", "dame", "dime", "puntos", "clave", "principales",
        "principal", "lista", "tareas", "crea", "haz", "hazme", "extrae", "extraer", "datos", "compara", "comparar", "diferencias", "estos",
        "estas", "ambos", "tabla", "columna", "fila", "factura", "queire", "puedes", "podrias", "favor", "ayudame", "sobre", "dice", "contiene"
    ]

    static let referenceWords: Set<String> = [
        "documento", "archivo", "adjunto", "pdf", "imagen", "foto", "captura", "hoja", "tabla", "contrato", "factura", "informe",
        "pagina", "columna", "fila", "texto", "docx", "xlsx", "csv", "escaneo", "escaner"
    ]

    private static func contentTokens(_ query: String) -> [String] {
        TextNormalizer.tokens(query).filter { !genericWords.contains($0) }.map(TextNormalizer.stem)
    }

    /// ¿La pregunta de seguimiento tiene que ver con los documentos que siguen activos?
    public static func isRelevant(query: String, documents: [ExtractedDocument]) -> Bool {
        guard !documents.isEmpty else { return false }
        let tokens = TextNormalizer.tokens(query, dropStopwords: false)
        if tokens.contains(where: { referenceWords.contains($0) }) { return true }
        let nameTokens = Set(documents.flatMap { TextNormalizer.tokens(($0.name as NSString).deletingPathExtension) })
        if tokens.contains(where: { nameTokens.contains($0) && $0.count >= 4 }) { return true }
        let wanted = Set(contentTokens(query).filter { $0.count >= 4 })
        if wanted.isEmpty { return false }
        for chunk in DocumentChunker.chunks(for: documents) {
            let present = Set(TextNormalizer.tokens(chunk.text).map(TextNormalizer.stem))
            if !wanted.isDisjoint(with: present) { return true }
        }
        return false
    }

    public static func select(documents: [ExtractedDocument], query: String, budget: Int) -> ExcerptSelection {
        let chunks = DocumentChunker.chunks(for: documents)
        guard !chunks.isEmpty else { return .empty }
        func cost(_ chunk: DocumentChunk) -> Int { chunk.text.count + 90 }
        let total = chunks.reduce(0) { $0 + cost($1) }
        if total <= budget {
            return ExcerptSelection(excerpts: chunks.map(excerpt), mode: .all, totalChunks: chunks.count, selectedChunks: chunks.count)
        }

        let wanted = contentTokens(query)
        var order: [Int]
        var mode: ExcerptSelection.Mode
        if wanted.isEmpty {
            order = broadOrder(chunks: chunks, budget: budget)
            mode = .broad
        } else {
            let scores = bm25(chunks: chunks, query: wanted)
            let ranked = chunks.indices.filter { scores[$0] > 0 }.sorted { scores[$0] > scores[$1] }
            if ranked.isEmpty {
                order = broadOrder(chunks: chunks, budget: budget)
                mode = .broad
            } else {
                order = ranked
                mode = .targeted
            }
        }

        var chosen: [Int] = []
        var remaining = budget
        var truncatedLast: (Int, String)?
        for index in order {
            let chunk = chunks[index]
            if cost(chunk) <= remaining {
                chosen.append(index)
                remaining -= cost(chunk)
            } else if remaining >= 400, truncatedLast == nil {
                truncatedLast = (index, String(chunk.text.prefix(remaining - 90)) + " […]")
                remaining = 0
            }
            if remaining < 150 { break }
        }
        var excerpts: [Excerpt] = []
        var indexes = chosen
        if let partial = truncatedLast { indexes.append(partial.0) }
        for index in indexes.sorted() {
            if let partial = truncatedLast, partial.0 == index {
                let chunk = chunks[index]
                excerpts.append(Excerpt(documentIndex: chunk.documentIndex, documentName: chunk.documentName, reference: chunk.reference, text: partial.1))
            } else {
                excerpts.append(excerpt(chunks[index]))
            }
        }
        return ExcerptSelection(excerpts: excerpts, mode: mode, totalChunks: chunks.count, selectedChunks: excerpts.count)
    }

    private static func excerpt(_ chunk: DocumentChunk) -> Excerpt {
        Excerpt(documentIndex: chunk.documentIndex, documentName: chunk.documentName, reference: chunk.reference, text: chunk.text)
    }

    /// Prioridad para peticiones generales: el comienzo de cada documento y luego fragmentos repartidos de forma uniforme.
    private static func broadOrder(chunks: [DocumentChunk], budget: Int) -> [Int] {
        var order: [Int] = []
        var seenDocuments = Set<Int>()
        for (index, chunk) in chunks.enumerated() where !seenDocuments.contains(chunk.documentIndex) {
            seenDocuments.insert(chunk.documentIndex)
            order.append(index)
        }
        let average = max(1, chunks.reduce(0) { $0 + $1.text.count + 90 } / chunks.count)
        let wanted = max(1, budget / average)
        let stride = max(1, chunks.count / wanted)
        var position = 0
        while position < chunks.count {
            if !order.contains(position) { order.append(position) }
            position += stride
        }
        for index in chunks.indices where !order.contains(index) { order.append(index) }
        return order
    }

    /// Puntuación BM25 de cada fragmento para los términos de la pregunta.
    static func bm25(chunks: [DocumentChunk], query: [String]) -> [Double] {
        let queryTerms = Set(query)
        var termFrequencies: [[String: Int]] = []
        var lengths: [Double] = []
        var documentFrequency: [String: Int] = [:]
        for chunk in chunks {
            let tokens = TextNormalizer.tokens(chunk.text).map(TextNormalizer.stem)
            var frequencies: [String: Int] = [:]
            for token in tokens where queryTerms.contains(token) { frequencies[token, default: 0] += 1 }
            for term in frequencies.keys { documentFrequency[term, default: 0] += 1 }
            termFrequencies.append(frequencies)
            lengths.append(Double(max(1, tokens.count)))
        }
        let average = lengths.reduce(0, +) / Double(max(1, lengths.count))
        let count = Double(chunks.count)
        let k1 = 1.2
        let b = 0.75
        var scores = [Double](repeating: 0, count: chunks.count)
        for index in chunks.indices {
            for term in queryTerms {
                guard let tf = termFrequencies[index][term].map(Double.init), let df = documentFrequency[term].map(Double.init) else { continue }
                let idf = log(1 + (count - df + 0.5) / (df + 0.5))
                scores[index] += idf * (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * lengths[index] / average))
            }
        }
        return scores
    }
}

/// Diferencias calculadas en el teléfono entre dos documentos (más fiable y barato que pedirle al modelo que las busque).
public enum DocumentComparator {
    public struct TextDiff: Equatable, Sendable {
        public var added: [String]
        public var removed: [String]
        public var unchanged: Int
    }

    public struct CellChange: Equatable, Sendable {
        public var row: String
        public var column: String
        public var old: String
        public var new: String
    }

    public struct TableDiff: Equatable, Sendable {
        public var addedRows: [String]
        public var removedRows: [String]
        public var changedCells: [CellChange]
        public var keyedByFirstColumn: Bool
        public var isIdentical: Bool { addedRows.isEmpty && removedRows.isEmpty && changedCells.isEmpty }
    }

    /// Diferencia de líneas por subsecuencia común más larga (hasta 2 500 líneas por lado; más allá, por conjuntos).
    public static func diffLines(_ a: [String], _ b: [String]) -> TextDiff {
        let left = a.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let right = b.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if left.count > 2_500 || right.count > 2_500 {
            let leftSet = Set(left)
            let rightSet = Set(right)
            return TextDiff(added: right.filter { !leftSet.contains($0) }, removed: left.filter { !rightSet.contains($0) },
                            unchanged: left.filter { rightSet.contains($0) }.count)
        }
        let n = left.count, m = right.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] = left[i] == right[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var added: [String] = []
        var removed: [String] = []
        var unchanged = 0
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, left[i] == right[j] {
                unchanged += 1; i += 1; j += 1
            } else if j < m, i == n || table[i][j + 1] >= table[i + 1][j] {
                added.append(right[j]); j += 1
            } else if i < n {
                removed.append(left[i]); i += 1
            }
        }
        return TextDiff(added: added, removed: removed, unchanged: unchanged)
    }

    /// Compara dos tablas: por la primera columna si sus valores son únicos en ambas; si no, fila a fila.
    public static func compareTables(_ a: TableData, _ b: TableData) -> TableDiff {
        let headerA = a.rows.first ?? []
        let headerB = b.rows.first ?? []
        let bodyA = Array(a.rows.dropFirst())
        let bodyB = Array(b.rows.dropFirst())
        func column(_ index: Int) -> String {
            let first = index < headerA.count ? headerA[index] : ""
            let second = index < headerB.count ? headerB[index] : ""
            if !first.isEmpty { return first }
            if !second.isEmpty { return second }
            return "columna \(index + 1)"
        }
        func value(_ row: [String], _ index: Int) -> String { index < row.count ? row[index] : "" }

        let keysA = bodyA.compactMap { $0.first }.filter { !$0.isEmpty }
        let keysB = bodyB.compactMap { $0.first }.filter { !$0.isEmpty }
        let unique = Set(keysA).count == keysA.count && Set(keysB).count == keysB.count && !keysA.isEmpty && !keysB.isEmpty

        var added: [String] = []
        var removed: [String] = []
        var changes: [CellChange] = []
        if unique {
            var mapB: [String: [String]] = [:]
            for row in bodyB { if let key = row.first, !key.isEmpty { mapB[key] = row } }
            var seen = Set<String>()
            for row in bodyA {
                guard let key = row.first, !key.isEmpty else { continue }
                seen.insert(key)
                guard let other = mapB[key] else { removed.append(row.joined(separator: " | ")); continue }
                for index in 1..<max(2, max(row.count, other.count)) where value(row, index) != value(other, index) {
                    changes.append(CellChange(row: key, column: column(index), old: value(row, index), new: value(other, index)))
                }
            }
            for row in bodyB { if let key = row.first, !key.isEmpty, !seen.contains(key) { added.append(row.joined(separator: " | ")) } }
        } else {
            let common = min(bodyA.count, bodyB.count)
            for index in 0..<common {
                let width = max(bodyA[index].count, bodyB[index].count)
                for col in 0..<width where value(bodyA[index], col) != value(bodyB[index], col) {
                    changes.append(CellChange(row: "fila \(index + 2)", column: column(col), old: value(bodyA[index], col), new: value(bodyB[index], col)))
                }
            }
            if bodyA.count > common { removed = bodyA[common...].map { $0.joined(separator: " | ") } }
            if bodyB.count > common { added = bodyB[common...].map { $0.joined(separator: " | ") } }
        }
        return TableDiff(addedRows: added, removedRows: removed, changedCells: changes, keyedByFirstColumn: unique)
    }

    /// Resumen de diferencias entre los DOS primeros documentos comparables, acotado para ir en la petición.
    public static func summary(of documents: [ExtractedDocument], limit: Int = 2_400) -> String? {
        guard documents.count >= 2 else { return nil }
        let first = documents[0], second = documents[1]
        var lines: [String] = []
        if let tableA = first.tables.first, let tableB = second.tables.first {
            let diff = compareTables(tableA, tableB)
            lines.append("Diferencias calculadas en el teléfono entre «\(UntrustedContent.safeLabel(first.name))» (A) y «\(UntrustedContent.safeLabel(second.name))» (B), hoja/tabla «\(UntrustedContent.safeLabel(tableA.name))» frente a «\(UntrustedContent.safeLabel(tableB.name))» (comparación \(diff.keyedByFirstColumn ? "por la primera columna" : "fila a fila")):")
            if diff.isIdentical { lines.append("- Las dos tablas son idénticas.") }
            for change in diff.changedCells.prefix(25) {
                lines.append("- \(change.row), «\(change.column)»: A=«\(change.old)» → B=«\(change.new)»")
            }
            if diff.changedCells.count > 25 { lines.append("- …y \(diff.changedCells.count - 25) celdas más con cambios.") }
            for row in diff.removedRows.prefix(8) { lines.append("- Solo en A: \(row)") }
            if diff.removedRows.count > 8 { lines.append("- …y \(diff.removedRows.count - 8) filas más solo en A.") }
            for row in diff.addedRows.prefix(8) { lines.append("- Solo en B: \(row)") }
            if diff.addedRows.count > 8 { lines.append("- …y \(diff.addedRows.count - 8) filas más solo en B.") }
        } else {
            let diff = diffLines(first.fullText.components(separatedBy: "\n"), second.fullText.components(separatedBy: "\n"))
            lines.append("Diferencias calculadas en el teléfono entre «\(UntrustedContent.safeLabel(first.name))» (A) y «\(UntrustedContent.safeLabel(second.name))» (B), línea a línea: \(diff.unchanged) líneas iguales, \(diff.removed.count) solo en A, \(diff.added.count) solo en B.")
            for line in diff.removed.prefix(10) { lines.append("- Solo en A: \(String(line.prefix(160)))") }
            if diff.removed.count > 10 { lines.append("- …y \(diff.removed.count - 10) líneas más solo en A.") }
            for line in diff.added.prefix(10) { lines.append("- Solo en B: \(String(line.prefix(160)))") }
            if diff.added.count > 10 { lines.append("- …y \(diff.added.count - 10) líneas más solo en B.") }
        }
        var text = lines.joined(separator: "\n")
        if text.count > limit { text = String(text.prefix(limit)) + "\n[…]" }
        return UntrustedContent.neutralize(text)
    }
}
