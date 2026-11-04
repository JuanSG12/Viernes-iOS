import Foundation

/// Recuperación léxica local (sin red, sin modelos de embeddings): coincidencia de raíces,
/// bonificación por fijados y decaimiento por antigüedad. Determinista y fácil de auditar.
public enum MemoryRetriever {
    public static func rank(query: String, items: [MemoryItem], limit: Int, now: Date = Date()) -> [ScoredMemory] {
        let queryStems = Set(TextNormalizer.tokens(query).map(TextNormalizer.stem))
        guard !queryStems.isEmpty, limit > 0 else { return [] }

        var scored: [ScoredMemory] = []
        for item in items {
            let itemStems = Set(TextNormalizer.tokens(item.text + " " + item.tags.joined(separator: " ")).map(TextNormalizer.stem))
            guard !itemStems.isEmpty else { continue }
            let overlap = Double(queryStems.intersection(itemStems).count)
            guard overlap > 0 else { continue }

            // Cobertura de la consulta + precisión sobre el recuerdo.
            var score = overlap / Double(queryStems.count) * 2.0 + overlap / Double(itemStems.count)
            if item.pinned { score += 0.5 }
            let ageDays = max(0, now.timeIntervalSince(item.updatedAt) / 86_400)
            score *= 1.0 / (1.0 + ageDays / 365.0)     // decae suavemente en un año
            scored.append(ScoredMemory(item: item, score: score))
        }
        return scored.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    /// Fijados + coincidencias, sin duplicados, para inyectar en el prompt.
    public static func context(query: String, items: [MemoryItem], limit: Int, now: Date = Date()) -> [MemoryItem] {
        let active = items.filter { !$0.isPending }
        let pinned = active.filter(\.pinned).prefix(3)
        var result = Array(pinned)
        for hit in rank(query: query, items: active, limit: limit, now: now) where !result.contains(where: { $0.id == hit.item.id }) {
            result.append(hit.item)
        }
        return Array(result.prefix(limit))
    }
}
