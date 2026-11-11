import Foundation

/// Memoria avanzada: caducidad, proyectos y relaciones entre personas y proyectos. Todo es opcional y por perfil; lo guardado antes de
/// existir esto se lee igual (sin proyecto, sin personas y sin caducidad).
public enum MemoryRelations {
    /// Los resúmenes de conversaciones (memoria episódica) caducan a los 90 días.
    public static let summaryLifetime: TimeInterval = 90 * 86_400
    public static let maxNameLength = 60
    public static let maxPeople = 6

    private static func cleanName(_ raw: String) -> String? {
        let value = UntrustedContent.safeLabel(raw, limit: maxNameLength).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Nombres de proyecto y de personas listos para guardar: sin etiquetas ni caracteres invisibles, acotados y sin repetidos.
    public static func clean(project: String?, people: [String]) -> (project: String?, people: [String]?) {
        var seen = Set<String>()
        var cleaned: [String] = []
        for raw in people {
            guard let name = cleanName(raw), seen.insert(TextNormalizer.fold(name)).inserted else { continue }
            cleaned.append(name)
            if cleaned.count >= maxPeople { break }
        }
        return (project.flatMap(cleanName), cleaned.isEmpty ? nil : cleaned)
    }

    /// «Karen, Luis» → ["Karen", "Luis"].
    public static func parsePeople(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" }).map { String($0) }
    }

    /// Texto breve para el prompt y la pantalla: «proyecto Aurora · con Karen, Luis».
    public static func summary(of item: MemoryItem) -> String? {
        var parts: [String] = []
        if let project = item.project, !project.isEmpty { parts.append("proyecto \(UntrustedContent.safeLabel(project, limit: maxNameLength))") }
        if let people = item.people, !people.isEmpty { parts.append("con " + people.map { UntrustedContent.safeLabel($0, limit: maxNameLength) }.joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

public enum MemoryExpiry {
    public static func expired(_ items: [MemoryItem], now: Date = Date()) -> [MemoryItem] { items.filter { $0.isExpired(at: now) } }
}

extension MemoryItem {
    public func isExpired(at now: Date) -> Bool { expiresAt.map { $0 <= now } ?? false }
}

public struct MemoryEntity: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case person, project }
    public var id: String { kind.rawValue + "|" + TextNormalizer.fold(name) }
    public let name: String
    public let kind: Kind
    public let count: Int
}

public struct MemoryLink: Equatable, Identifiable, Sendable {
    public var id: String { TextNormalizer.fold(person) + "|" + TextNormalizer.fold(project) }
    public let person: String
    public let project: String
    public let count: Int
}

/// Quién y qué aparece en los recuerdos, y cómo se relacionan (calculado en el teléfono con lo que el usuario o el modelo anotó).
public enum MemoryGraph {
    private static func live(_ items: [MemoryItem], _ now: Date) -> [MemoryItem] { items.filter { !$0.isPending && !$0.isExpired(at: now) } }

    public static func entities(_ items: [MemoryItem], now: Date = Date()) -> [MemoryEntity] {
        var counts: [String: (name: String, kind: MemoryEntity.Kind, count: Int)] = [:]
        for item in live(items, now) {
            if let project = item.project, !project.isEmpty {
                let key = "project|" + TextNormalizer.fold(project)
                counts[key] = (counts[key]?.name ?? project, .project, (counts[key]?.count ?? 0) + 1)
            }
            for person in item.people ?? [] where !person.isEmpty {
                let key = "person|" + TextNormalizer.fold(person)
                counts[key] = (counts[key]?.name ?? person, .person, (counts[key]?.count ?? 0) + 1)
            }
        }
        return counts.values.map { MemoryEntity(name: $0.name, kind: $0.kind, count: $0.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    /// Pares persona–proyecto que aparecen juntos en el mismo recuerdo.
    public static func links(_ items: [MemoryItem], now: Date = Date()) -> [MemoryLink] {
        var counts: [String: (person: String, project: String, count: Int)] = [:]
        for item in live(items, now) {
            guard let project = item.project, !project.isEmpty else { continue }
            for person in item.people ?? [] where !person.isEmpty {
                let key = TextNormalizer.fold(person) + "|" + TextNormalizer.fold(project)
                counts[key] = (counts[key]?.person ?? person, counts[key]?.project ?? project, (counts[key]?.count ?? 0) + 1)
            }
        }
        return counts.values.map { MemoryLink(person: $0.person, project: $0.project, count: $0.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : ($0.person, $0.project) < ($1.person, $1.project) }
    }

    /// Recuerdos de una persona o de un proyecto (para verlos o borrarlos juntos).
    public static func related(to name: String, in items: [MemoryItem], now: Date = Date()) -> [MemoryItem] {
        let wanted = TextNormalizer.fold(name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return [] }
        return items.filter { item in
            !item.isPending && (TextNormalizer.fold(item.project ?? "") == wanted || (item.people ?? []).contains { TextNormalizer.fold($0) == wanted })
        }
    }
}
