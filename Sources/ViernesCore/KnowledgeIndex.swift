import Foundation

// MARK: Embeddings

/// Convierte texto en un vector de «significado». El núcleo trae uno local y portable (`HashingEmbedder`); la app puede aportar
/// uno mejor del sistema (NaturalLanguage). Todo se calcula en el dispositivo: ningún texto sale por esto.
public protocol TextEmbedder: Sendable {
    var id: String { get }
    /// Similitud de coseno a partir de la cual dos textos se consideran claramente relacionados (depende del modelo).
    var strongSimilarity: Float { get }
    func embed(_ text: String) -> [Float]?
}

public enum Embedding {
    public static func pack(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func unpack(_ data: Data) -> [Float] {
        let bytes = [UInt8](data)
        guard bytes.count % 4 == 0 else { return [] }
        var vector: [Float] = []
        vector.reserveCapacity(bytes.count / 4)
        var index = 0
        while index < bytes.count {
            let bits = UInt32(bytes[index]) | (UInt32(bytes[index + 1]) << 8) | (UInt32(bytes[index + 2]) << 16) | (UInt32(bytes[index + 3]) << 24)
            vector.append(Float(bitPattern: bits))
            index += 4
        }
        return vector
    }

    /// Coseno de dos vectores ya normalizados (producto punto). 0 si no son comparables.
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var sum: Float = 0
        for index in 0..<a.count { sum += a[index] * b[index] }
        return sum
    }

    public static func normalized(_ vector: [Float]) -> [Float]? {
        var norm: Float = 0
        for value in vector { norm += value * value }
        norm = norm.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return vector.map { $0 / norm }
    }
}

/// Embedding local sin modelo: hashea palabras (sin acentos ni plurales), pares de palabras y trozos de letras en 256 dimensiones.
/// Capta palabras y raíces compartidas («facturación» ~ «factura», «contratos» ~ «contrato»); **no entiende sinónimos**. Es la
/// alternativa portable y sin descargas; la app usa además el modelo de frases del sistema cuando está disponible.
public struct HashingEmbedder: TextEmbedder {
    public let id = "hash-256-v1"
    public let strongSimilarity: Float = 0.55
    private let dimension = 256

    public init() {}

    private func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    public func embed(_ text: String) -> [Float]? {
        let tokens = TextNormalizer.tokens(text).map(TextNormalizer.stem)
        guard !tokens.isEmpty else { return nil }
        var vector = [Float](repeating: 0, count: dimension)
        func add(_ feature: String, _ weight: Float) {
            let hash = fnv1a(feature)
            let index = Int(hash % UInt64(dimension))
            vector[index] += ((hash >> 40) & 1) == 0 ? weight : -weight
        }
        for token in tokens {
            add("w:" + token, 1.0)
            let padded = Array("^" + token + "$")
            if padded.count >= 3 {
                for start in 0...(padded.count - 3) { add("c:" + String(padded[start..<(start + 3)]), 0.3) }
            }
        }
        if tokens.count > 1 {
            for index in 0..<(tokens.count - 1) { add("b:" + tokens[index] + "_" + tokens[index + 1], 0.6) }
        }
        return Embedding.normalized(vector)
    }
}

// MARK: Fechas en las preguntas

/// «¿Dónde aparece el 15 de marzo de 2023?» → variantes literales con las que buscar en el texto (ISO, dd/mm/aaaa, «15 de marzo de 2023»).
public enum DateQuery {
    static let months = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"]

    public static func variants(in query: String) -> [String] {
        let folded = TextNormalizer.fold(query)
        var found: [(day: Int, month: Int, year: Int?)] = []

        func collect(_ pattern: String, _ build: ([String]) -> (Int, Int, Int?)?) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let ns = folded as NSString
            for match in regex.matches(in: folded, range: NSRange(location: 0, length: ns.length)) {
                var groups: [String] = []
                for index in 1..<match.numberOfRanges {
                    let range = match.range(at: index)
                    groups.append(range.location == NSNotFound ? "" : ns.substring(with: range))
                }
                if let date = build(groups) { found.append((date.0, date.1, date.2)) }
            }
        }

        collect("(\\d{4})-(\\d{1,2})-(\\d{1,2})") { g in
            guard let y = Int(g[0]), let m = Int(g[1]), let d = Int(g[2]), (1...12).contains(m), (1...31).contains(d) else { return nil }
            return (d, m, y)
        }
        collect("(\\d{1,2})[/.-](\\d{1,2})[/.-](\\d{4})") { g in
            guard let d = Int(g[0]), let m = Int(g[1]), let y = Int(g[2]), (1...12).contains(m), (1...31).contains(d) else { return nil }
            return (d, m, y)
        }
        let monthNames = months.joined(separator: "|")
        collect("(\\d{1,2})\\s+de\\s+(\(monthNames))(?:\\s+de(?:l)?\\s+(\\d{4}))?") { g in
            guard let d = Int(g[0]), let m = months.firstIndex(of: g[1]), (1...31).contains(d) else { return nil }
            return (d, m + 1, Int(g[2]))
        }

        var result: [String] = []
        for date in found {
            let dd = String(format: "%02d", date.day)
            let mm = String(format: "%02d", date.month)
            let name = months[date.month - 1]
            result.append("\(date.day) de \(name)")
            if let year = date.year {
                result.append(contentsOf: ["\(year)-\(mm)-\(dd)", "\(dd)/\(mm)/\(year)", "\(date.day)/\(date.month)/\(year)", "\(dd)-\(mm)-\(year)",
                                           "\(date.day) de \(name) de \(year)", "\(date.day) \(name) \(year)"])
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }
}

// MARK: Índice

public struct KnowledgeHit: Equatable, Sendable {
    public let itemID: UUID
    public let chunkID: UUID
    public let title: String
    public let reference: String
    public let text: String
    /// Puntuación combinada (fusión por rangos de la léxica y la semántica): solo sirve para ordenar.
    public let score: Double
    public let lexicalScore: Double
    public let semanticScore: Float?
    /// Fracción de los términos de la pregunta QUE EXISTEN en la biblioteca y están en este fragmento (0…1). Los términos que no aparecen
    /// en ningún documento («cuánto», «establece») no cuentan: no dicen nada sobre este fragmento.
    public let coverage: Double
    /// Cuántos términos distintos de la pregunta contiene el fragmento.
    public let matchedTerms: Int
    /// Coincidencia literal de una fecha de la pregunta.
    public let literalMatch: Bool

    /// Coincidencia de texto razonable: contiene al menos la mitad de los términos de la pregunta que existen en la biblioteca.
    public var isLexicalMatch: Bool { lexicalScore > 0 && coverage >= 0.5 }

    /// Relación CLARA con la pregunta (criterio estricto, para consultar la biblioteca sin que el usuario la nombre): una fecha literal,
    /// al menos dos términos propios en común o una similitud semántica alta.
    public func isStrong(semanticThreshold: Float) -> Bool {
        if literalMatch { return true }
        if matchedTerms >= 2 && coverage >= 0.6 { return true }
        if let semantic = semanticScore, semantic >= semanticThreshold { return true }
        return false
    }
}

/// Índice híbrido en memoria: léxico (BM25 con raíces) + semántico (coseno), fusionados por rangos. Sin base de datos externa.
final class KnowledgeIndex {
    private struct Slot {
        let chunkID: UUID
        let itemID: UUID
        let title: String
        let reference: String
        let text: String
        let vector: [Float]?
        let terms: [String: Int]
        let length: Int
    }

    private var slots: [Slot?] = []
    private var freeSlots: [Int] = []
    private var postings: [String: [Int: Int]] = [:]
    private var itemSlots: [UUID: [Int]] = [:]
    private var totalLength = 0
    private(set) var liveCount = 0

    func add(chunk: KnowledgeChunk, title: String) {
        let vector = chunk.embedding.map { Embedding.unpack($0) }.flatMap { $0.isEmpty ? nil : $0 }
        insert(chunkID: chunk.id, itemID: chunk.itemID, title: title, reference: chunk.reference, text: chunk.text, vector: vector)
    }

    /// Cambia el título de un elemento (el título también cuenta al buscar) sin volver a calcular los vectores.
    func retitle(_ itemID: UUID, to title: String) {
        guard let indexes = itemSlots[itemID] else { return }
        let old = indexes.compactMap { slots[$0] }
        removeItem(itemID)
        for slot in old {
            insert(chunkID: slot.chunkID, itemID: slot.itemID, title: title, reference: slot.reference, text: slot.text, vector: slot.vector)
        }
    }

    /// Referencia y texto de cada fragmento de un elemento, en orden.
    func fragments(of itemID: UUID) -> [(reference: String, text: String)] {
        (itemSlots[itemID] ?? []).compactMap { index in slots[index].map { (reference: $0.reference, text: $0.text) } }
    }

    private func insert(chunkID: UUID, itemID: UUID, title: String, reference: String, text: String, vector: [Float]?) {
        let tokens = TextNormalizer.tokens(title + "\n" + text).map(TextNormalizer.stem)
        var terms: [String: Int] = [:]
        for token in tokens { terms[token, default: 0] += 1 }
        let slot = Slot(chunkID: chunkID, itemID: itemID, title: title, reference: reference, text: text,
                        vector: vector, terms: terms, length: max(1, tokens.count))
        let index: Int
        if let reused = freeSlots.popLast() {
            slots[reused] = slot
            index = reused
        } else {
            slots.append(slot)
            index = slots.count - 1
        }
        for (term, frequency) in terms { postings[term, default: [:]][index] = frequency }
        itemSlots[itemID, default: []].append(index)
        totalLength += slot.length
        liveCount += 1
    }

    func removeItem(_ itemID: UUID) {
        guard let indexes = itemSlots.removeValue(forKey: itemID) else { return }
        for index in indexes {
            guard let slot = slots[index] else { continue }
            for term in slot.terms.keys {
                postings[term]?.removeValue(forKey: index)
                if postings[term]?.isEmpty == true { postings.removeValue(forKey: term) }
            }
            totalLength -= slot.length
            liveCount -= 1
            slots[index] = nil
            freeSlots.append(index)
        }
    }

    func removeAll() {
        slots.removeAll()
        freeSlots.removeAll()
        postings.removeAll()
        itemSlots.removeAll()
        totalLength = 0
        liveCount = 0
    }

    func containsItem(_ id: UUID) -> Bool { itemSlots[id] != nil }

    /// Texto de los fragmentos de un elemento, en orden (para mostrar y para pruebas).
    func chunkTexts(of itemID: UUID) -> [String] {
        (itemSlots[itemID] ?? []).compactMap { slots[$0]?.text }
    }

    func search(queryTerms: [String], literals: [String], queryVector: [Float]?, allowed: (UUID) -> Bool, limit: Int) -> [KnowledgeHit] {
        let terms = Array(Set(queryTerms))
        let presentTerms = terms.filter { postings[$0] != nil }.count
        let count = Double(max(1, liveCount))
        let average = Double(max(1, totalLength)) / count
        var bm25: [Int: Double] = [:]
        var matched: [Int: Int] = [:]
        for term in terms {
            guard let list = postings[term] else { continue }
            let documentFrequency = Double(list.count)
            let idf = log(1 + (count - documentFrequency + 0.5) / (documentFrequency + 0.5))
            for (index, frequency) in list {
                guard let slot = slots[index], allowed(slot.itemID) else { continue }
                let tf = Double(frequency)
                bm25[index, default: 0] += idf * (tf * 2.2) / (tf + 1.2 * (0.25 + 0.75 * Double(slot.length) / average))
                matched[index, default: 0] += 1
            }
        }

        var literalHits = Set<Int>()
        let needles = literals.map { TextNormalizer.fold($0) }.filter { !$0.isEmpty }
        if !needles.isEmpty {
            for (index, optional) in slots.enumerated() {
                guard let slot = optional, allowed(slot.itemID) else { continue }
                let haystack = TextNormalizer.fold(slot.text)
                if needles.contains(where: { haystack.contains($0) }) { literalHits.insert(index) }
            }
        }

        var semantic: [Int: Float] = [:]
        if let query = queryVector {
            for (index, optional) in slots.enumerated() {
                guard let slot = optional, let vector = slot.vector, vector.count == query.count, allowed(slot.itemID) else { continue }
                semantic[index] = Embedding.similarity(query, vector)
            }
        }

        // Fusión por rangos (RRF): cada lista aporta 1 / (60 + posición).
        var fused: [Int: Double] = [:]
        func lexicalRank(_ index: Int) -> Double {
            let base: Double = bm25[index] ?? 0
            let bonus: Double = literalHits.contains(index) ? 100 : 0
            return base + bonus
        }
        let lexicalRanking = Set(bm25.keys).union(literalHits).sorted { lexicalRank($0) > lexicalRank($1) }
        for (rank, index) in lexicalRanking.prefix(60).enumerated() { fused[index, default: 0] += 1 / Double(60 + rank + 1) }
        let semanticRanking = semantic.filter { $0.value >= 0.2 }.sorted { $0.value > $1.value }.prefix(60)
        for (rank, element) in semanticRanking.enumerated() { fused[element.key, default: 0] += 1 / Double(60 + rank + 1) }

        let ranked = fused.sorted { $0.value > $1.value }.prefix(limit)
        return ranked.compactMap { element -> KnowledgeHit? in
            guard let slot = slots[element.key] else { return nil }
            let coverage = presentTerms == 0 ? 0 : Double(matched[element.key] ?? 0) / Double(presentTerms)
            return KnowledgeHit(itemID: slot.itemID, chunkID: slot.chunkID, title: slot.title, reference: slot.reference, text: slot.text,
                                score: element.value, lexicalScore: bm25[element.key] ?? 0, semanticScore: semantic[element.key],
                                coverage: coverage, matchedTerms: matched[element.key] ?? 0, literalMatch: literalHits.contains(element.key))
        }
    }
}
