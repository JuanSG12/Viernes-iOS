import Foundation

// MARK: Recuperación para la conversación

public struct KnowledgeRetrieval: Sendable {
    public var hits: [KnowledgeHit]
    /// Cuántos elementos indexados tiene la biblioteca (para decir «busqué en N documentos y no hallé nada»).
    public var searchedItems: Int
    /// El usuario habló expresamente de sus documentos.
    public var explicit: Bool
    public var isEmpty: Bool { hits.isEmpty }
    public init(hits: [KnowledgeHit], searchedItems: Int, explicit: Bool) {
        self.hits = hits
        self.searchedItems = searchedItems
        self.explicit = explicit
    }
}

public protocol KnowledgeProvider: AnyObject, Sendable {
    func retrieve(query: String, limit: Int, explicitLibrary: Bool) async -> KnowledgeRetrieval
}

/// ¿La pregunta habla de los documentos del usuario? («mis documentos», «mi contrato», «en la biblioteca»…)
public enum KnowledgeGate {
    static let phrases = ["mis documentos", "mi documento", "mis archivos", "mi archivo", "mi biblioteca", "la biblioteca", "mis notas", "mi nota",
                          "mis pdf", "documentos guardados", "archivos guardados", "lo que guarde", "lo que te di", "en mis papeles"]
    static let ownedDocumentPattern = "\\bmis?\\s+(contrato|factura|informe|reporte|recibo|poliza|cotizacion|carta|presupuesto|extracto|declaracion|acta|certificado|hoja de vida|cv|pasaporte|libro|apuntes|tesis|propuesta)s?\\b"

    public static func mentionsLibrary(_ query: String) -> Bool {
        let folded = TextNormalizer.fold(query)
        if phrases.contains(where: { folded.contains($0) }) { return true }
        return folded.range(of: ownedDocumentPattern, options: .regularExpression) != nil
    }
}

// MARK: Ingestión

public struct IngestSource: Sendable {
    public var sourceName: String
    public var contentHash: String
    public var byteCount: Int
    public var kind: KnowledgeKind
    public var sourceDate: Date?
    public var thumbnail: Data?
    public init(sourceName: String, contentHash: String, byteCount: Int, kind: KnowledgeKind = .document, sourceDate: Date? = nil, thumbnail: Data? = nil) {
        self.sourceName = sourceName
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.kind = kind
        self.sourceDate = sourceDate
        self.thumbnail = thumbnail
    }
}

public struct IngestOptions: Sendable {
    public var title: String?
    public var collectionID: UUID?
    public var tags: [String]
    /// Guardar aunque ya exista algo igual.
    public var allowDuplicate: Bool
    public init(title: String? = nil, collectionID: UUID? = nil, tags: [String] = [], allowDuplicate: Bool = false) {
        self.title = title
        self.collectionID = collectionID
        self.tags = tags
        self.allowDuplicate = allowDuplicate
    }
}

public enum DuplicateReason: String, Sendable {
    case sameFile, sameText, similar

    public var explanation: String {
        switch self {
        case .sameFile: return "es exactamente el mismo archivo"
        case .sameText: return "tiene el mismo texto (quizá en otro formato)"
        case .similar: return "es casi idéntico"
        }
    }
}

public enum IngestResult: Sendable {
    case indexed(KnowledgeItem)
    case duplicate(existing: KnowledgeItem, reason: DuplicateReason)
}

// MARK: Motor

/// Biblioteca de conocimiento personal: recibe documentos ya leídos, los fragmenta conservando página/sección, calcula vectores
/// (si hay modelo), los indexa, los guarda y comprueba que se recuperan; busca por texto, significado, proyecto, documento y fecha.
/// Es independiente de la memoria personal (recuerdos y preferencias): otro almacén, otro índice, otra pantalla.
public actor KnowledgeEngine: KnowledgeProvider {
    private let store: KnowledgeStore
    private let embedder: TextEmbedder?
    private let clock: @Sendable () -> Date
    private let index = KnowledgeIndex()
    private var itemsByID: [UUID: KnowledgeItem] = [:]
    private var collectionsByID: [UUID: KnowledgeCollection] = [:]
    private var loaded = false
    private var onChange: (@Sendable (KnowledgeItem) -> Void)?

    public init(store: KnowledgeStore, embedder: TextEmbedder? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.embedder = embedder
        self.clock = clock
    }

    /// Se avisa de cada cambio de estado de un elemento (procesando → indexado / error).
    public func setOnChange(_ handler: @escaping @Sendable (KnowledgeItem) -> Void) { onChange = handler }
    private func notify(_ item: KnowledgeItem) { onChange?(item) }

    public var embedderID: String? { embedder?.id }

    // MARK: Carga

    public func load() async throws {
        guard !loaded else { return }
        let snapshot = try await store.loadAll()
        index.removeAll()
        itemsByID = [:]
        for collection in snapshot.collections { collectionsByID[collection.id] = collection }
        var chunksByItem: [UUID: [KnowledgeChunk]] = [:]
        for chunk in snapshot.chunks { chunksByItem[chunk.itemID, default: []].append(chunk) }
        for var item in snapshot.items {
            if item.status == .queued || item.status == .processing {
                // La app se cerró a mitad del procesamiento: no se finge que quedó indexado.
                item.status = .failed("Se interrumpió el procesamiento. Vuelve a añadirlo.")
                try? await store.update(item: item)
            }
            if item.status.isIndexed {
                for chunk in (chunksByItem[item.id] ?? []).sorted(by: { $0.ordinal < $1.ordinal }) { index.add(chunk: chunk, title: item.title) }
            }
            itemsByID[item.id] = item
        }
        loaded = true
    }

    public func allItems() async -> [KnowledgeItem] {
        try? await load()
        return itemsByID.values.sorted { $0.importedAt > $1.importedAt }
    }

    public func allCollections() async -> [KnowledgeCollection] {
        try? await load()
        return collectionsByID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func item(_ id: UUID) async -> KnowledgeItem? {
        try? await load()
        return itemsByID[id]
    }

    /// Fragmentos de un elemento tal como están en el índice (para ver qué se guardó).
    public func fragments(of id: UUID) async -> [(reference: String, text: String)] {
        try? await load()
        return index.fragments(of: id)
    }

    public func isIndexed(_ id: UUID) -> Bool { index.containsItem(id) }
    public var indexedChunkCount: Int { index.liveCount }

    // MARK: Ingestión

    /// Texto normalizado (sin acentos, mayúsculas ni signos) para comparar contenidos entre formatos.
    static func normalizedText(_ document: ExtractedDocument) -> String {
        TextNormalizer.tokens(document.fullText, dropStopwords: false).joined(separator: " ")
    }

    static func fingerprint(_ text: String) -> String {
        String(ContentHash.sha256Hex(TextNormalizer.tokens(text, dropStopwords: false).joined(separator: " ")).prefix(12))
    }

    private func findDuplicate(contentHash: String, textHash: String, fingerprints: [String]) -> (KnowledgeItem, DuplicateReason)? {
        let candidates = itemsByID.values.filter { $0.status.isIndexed }
        if let same = candidates.first(where: { $0.contentHash == contentHash }) { return (same, .sameFile) }
        if let same = candidates.first(where: { !$0.textHash.isEmpty && $0.textHash == textHash }) { return (same, .sameText) }
        let mine = Set(fingerprints)
        guard mine.count >= 3 else { return nil }
        for candidate in candidates where candidate.fingerprints.count >= 3 {
            let theirs = Set(candidate.fingerprints)
            let overlap = Double(mine.intersection(theirs).count) / Double(mine.union(theirs).count)
            if overlap >= 0.8 { return (candidate, .similar) }
        }
        return nil
    }

    private static func cleanTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in tags {
            let tag = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(KnowledgeLimits.maxTagLength))
            guard !tag.isEmpty, seen.insert(TextNormalizer.fold(tag)).inserted else { continue }
            result.append(tag)
            if result.count >= KnowledgeLimits.maxTags { break }
        }
        return result
    }

    /// Pipeline: validar → límites → duplicados → fragmentar (con página/sección) → vectores → guardar → indexar → verificar.
    public func ingest(_ document: ExtractedDocument, source: IngestSource, options: IngestOptions = IngestOptions()) async throws -> IngestResult {
        try await load()
        guard document.hasText else { throw KnowledgeError.noReadableText(source.sourceName) }
        guard itemsByID.count < KnowledgeLimits.maxItems else {
            throw KnowledgeError.libraryFull("La biblioteca ya tiene \(KnowledgeLimits.maxItems) elementos. Borra alguno para añadir más.")
        }
        let used = itemsByID.values.reduce(0) { $0 + $1.characterCount }
        guard used + document.characterCount <= KnowledgeLimits.maxTotalCharacters else {
            throw KnowledgeError.libraryFull("No cabe en la biblioteca: el texto total superaría el límite (\(KnowledgeLimits.maxTotalCharacters / 1_000_000) millones de caracteres). Borra algo y vuelve a intentarlo.")
        }

        let prepared = DocumentChunker.chunks(for: [document], maxChars: KnowledgeLimits.chunkSize)
        let textHash = ContentHash.sha256Hex(Self.normalizedText(document))
        let fingerprints = prepared.map { Self.fingerprint($0.text) }
        if !options.allowDuplicate, let duplicate = findDuplicate(contentHash: source.contentHash, textHash: textHash, fingerprints: fingerprints) {
            return .duplicate(existing: duplicate.0, reason: duplicate.1)
        }

        let title = (options.title ?? (source.sourceName as NSString).deletingPathExtension).trimmingCharacters(in: .whitespacesAndNewlines)
        var item = KnowledgeItem(
            title: title.isEmpty ? source.sourceName : title, kind: source.kind,
            fileKind: document.kind, sourceName: source.sourceName, contentHash: source.contentHash, textHash: textHash,
            fingerprints: fingerprints, byteCount: source.byteCount, pageCount: document.pageCount, characterCount: document.characterCount,
            importedAt: clock(), sourceDate: source.sourceDate, collectionID: options.collectionID, tags: Self.cleanTags(options.tags),
            status: .processing, recognizedByOCR: document.recognizedByOCR, truncated: document.truncated, warnings: document.warnings,
            thumbnail: source.thumbnail)
        itemsByID[item.id] = item
        try await store.update(item: item)
        notify(item)
        await Task.yield()                       // deja que la interfaz muestre «procesando» antes del trabajo pesado

        do {
            var chunks: [KnowledgeChunk] = []
            var embedded = false
            for (ordinal, piece) in prepared.enumerated() {
                let vector = embedder?.embed(piece.text)
                if vector != nil { embedded = true }
                chunks.append(KnowledgeChunk(itemID: item.id, ordinal: ordinal, reference: piece.reference, text: piece.text,
                                             embedding: vector.map(Embedding.pack)))
            }
            item.chunkCount = chunks.count
            item.embedderID = embedded ? embedder?.id : nil
            item.status = .indexed
            try await store.save(item: item, chunks: chunks)
            for chunk in chunks { index.add(chunk: chunk, title: item.title) }
            guard verifyRetrieval(of: item, chunks: chunks) else { throw KnowledgeError.verificationFailed(item.title) }
            itemsByID[item.id] = item
            notify(item)
            return .indexed(item)
        } catch {
            index.removeItem(item.id)
            item.status = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            item.chunkCount = 0
            try? await store.save(item: item, chunks: [])
            itemsByID[item.id] = item
            notify(item)
            throw error
        }
    }

    /// Comprueba que un fragmento del elemento se recupera al buscar con sus propias palabras.
    private func verifyRetrieval(of item: KnowledgeItem, chunks: [KnowledgeChunk]) -> Bool {
        let middle = chunks.count / 2
        let order = Array(chunks[middle...]) + Array(chunks[..<middle])
        for chunk in order {
            let tokens = Array(TextNormalizer.tokens(chunk.text).map(TextNormalizer.stem).prefix(8))
            guard !tokens.isEmpty else { continue }
            let hits = index.search(queryTerms: tokens, literals: [], queryVector: nil, allowed: { _ in true }, limit: 12)
            return hits.contains { $0.itemID == item.id }
        }
        return false
    }

    /// Nota o texto escrito por el usuario (no un archivo).
    public func addNote(title: String, text: String, kind: KnowledgeKind = .note, options: IngestOptions = IngestOptions()) async throws -> IngestResult {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw KnowledgeError.noReadableText(title.isEmpty ? "la nota" : title) }
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = String((body.components(separatedBy: "\n").first ?? "Nota").prefix(48)) }
        let document = DocumentBuilders.plainText(name: name, kind: .text, text: body)
        var settings = options
        settings.title = name
        return try await ingest(document, source: IngestSource(sourceName: name, contentHash: ContentHash.sha256Hex(body), byteCount: body.utf8.count, kind: kind),
                                options: settings)
    }

    // MARK: Búsqueda

    private func descendants(of collectionID: UUID) -> Set<UUID> {
        var result: Set<UUID> = [collectionID]
        var changed = true
        while changed {
            changed = false
            for collection in collectionsByID.values {
                if let parent = collection.parentID, result.contains(parent), !result.contains(collection.id) {
                    result.insert(collection.id)
                    changed = true
                }
            }
        }
        return result
    }

    private func allowedItems(_ filter: KnowledgeFilter) -> Set<UUID> {
        let folders = filter.collectionID.map { descendants(of: $0) }
        let wantedTags = Set(filter.tags.map { TextNormalizer.fold($0) })
        var allowed = Set<UUID>()
        for item in itemsByID.values where item.status.isIndexed {
            if let ids = filter.itemIDs, !ids.contains(item.id) { continue }
            if let folders = folders, !(item.collectionID.map { folders.contains($0) } ?? false) { continue }
            if !wantedTags.isEmpty, !wantedTags.isSubset(of: Set(item.tags.map { TextNormalizer.fold($0) })) { continue }
            if !filter.kinds.isEmpty, !filter.kinds.contains(item.kind) { continue }
            if let range = filter.dateRange, !range.contains(item.importedAt) { continue }
            allowed.insert(item.id)
        }
        return allowed
    }

    /// Búsqueda híbrida: texto (con raíces y sin acentos), significado (si hay modelo de vectores) y fechas literales.
    public func search(_ query: String, filter: KnowledgeFilter = .all, limit: Int = 8, onlyRelevant: Bool = false) async -> [KnowledgeHit] {
        try? await load()
        let allowed = allowedItems(filter)
        guard !allowed.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var terms = ExcerptSelector.contentTokens(query)
        if terms.isEmpty { terms = TextNormalizer.tokens(query).map(TextNormalizer.stem) }
        let hits = index.search(queryTerms: terms, literals: DateQuery.variants(in: query), queryVector: embedder?.embed(query),
                                allowed: { allowed.contains($0) }, limit: onlyRelevant ? limit * 3 : limit)
        guard onlyRelevant else { return hits }
        let threshold = embedder?.strongSimilarity ?? 2
        return Array(hits.filter { $0.isLexicalMatch || $0.isStrong(semanticThreshold: threshold) }.prefix(limit))
    }

    public func retrieve(query: String, limit: Int, explicitLibrary: Bool) async -> KnowledgeRetrieval {
        try? await load()
        let total = itemsByID.values.filter { $0.status.isIndexed }.count
        guard total > 0 else { return KnowledgeRetrieval(hits: [], searchedItems: 0, explicit: explicitLibrary) }
        let found = await search(query, limit: limit * 3)
        let threshold = embedder?.strongSimilarity ?? 2
        // Con una mención expresa a los documentos basta una buena coincidencia de texto; sin ella, solo lo CLARAMENTE relacionado
        // (así una pregunta cualquiera no arrastra fragmentos ni gasta cuota).
        let chosen = found.filter { $0.isStrong(semanticThreshold: threshold) || (explicitLibrary && $0.isLexicalMatch) }
        return KnowledgeRetrieval(hits: Array(chosen.prefix(limit)), searchedItems: total, explicit: explicitLibrary)
    }

    // MARK: Gestión

    public func rename(_ id: UUID, to title: String) async throws {
        try await load()
        guard var item = itemsByID[id] else { throw KnowledgeError.notFound }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw KnowledgeError.invalidName }
        item.title = name
        try await store.update(item: item)
        itemsByID[id] = item
        if item.status.isIndexed { index.retitle(id, to: name) }
        notify(item)
    }

    public func setTags(_ id: UUID, _ tags: [String]) async throws {
        try await load()
        guard var item = itemsByID[id] else { throw KnowledgeError.notFound }
        item.tags = Self.cleanTags(tags)
        try await store.update(item: item)
        itemsByID[id] = item
        notify(item)
    }

    public func move(_ id: UUID, to collectionID: UUID?) async throws {
        try await load()
        guard var item = itemsByID[id] else { throw KnowledgeError.notFound }
        if let target = collectionID, collectionsByID[target] == nil { throw KnowledgeError.notFound }
        item.collectionID = collectionID
        try await store.update(item: item)
        itemsByID[id] = item
        notify(item)
    }

    /// Borra el elemento: sale de la lista, del índice y del almacén (y deja de aparecer en las búsquedas).
    public func delete(_ id: UUID) async throws {
        try await load()
        guard itemsByID[id] != nil else { throw KnowledgeError.notFound }
        index.removeItem(id)
        itemsByID.removeValue(forKey: id)
        try await store.deleteItem(id: id)
    }

    @discardableResult
    public func createCollection(name: String, kind: KnowledgeCollection.Kind = .project, parentID: UUID? = nil) async throws -> KnowledgeCollection {
        try await load()
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw KnowledgeError.invalidName }
        if let parent = parentID, collectionsByID[parent] == nil { throw KnowledgeError.notFound }
        let collection = KnowledgeCollection(name: String(clean.prefix(60)), kind: kind, parentID: parentID, createdAt: clock())
        try await store.save(collection: collection)
        collectionsByID[collection.id] = collection
        return collection
    }

    /// Borra un proyecto/carpeta/colección. Sus elementos NO se borran: pasan a su carpeta superior (o quedan sin carpeta).
    public func deleteCollection(_ id: UUID) async throws {
        try await load()
        guard let collection = collectionsByID[id] else { throw KnowledgeError.notFound }
        for var item in itemsByID.values where item.collectionID == id {
            item.collectionID = collection.parentID
            try await store.update(item: item)
            itemsByID[item.id] = item
        }
        for var child in collectionsByID.values where child.parentID == id {
            child.parentID = collection.parentID
            try await store.save(collection: child)
            collectionsByID[child.id] = child
        }
        try await store.deleteCollection(id: id)
        collectionsByID.removeValue(forKey: id)
    }

    public func deleteAll() async throws {
        try await store.deleteAll()
        index.removeAll()
        itemsByID.removeAll()
        collectionsByID.removeAll()
        loaded = true
    }
}
