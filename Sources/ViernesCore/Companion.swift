import Foundation

// MARK: Ajustes del compañero de Windows

/// Dónde está el compañero y la huella de su certificado (se fija al emparejar: sin ella no se confía en el servidor). El TOKEN no está
/// aquí: va en el Llavero del perfil.
public struct CompanionSettings: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    /// SHA-256 del certificado, en hexadecimal minúsculas (64 caracteres, sin «:»).
    public var fingerprint: String
    public var deviceName: String

    public init(host: String, port: Int, fingerprint: String, deviceName: String = "iPhone") {
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
        self.deviceName = deviceName
    }
}

extension AppSettings {
    public var companionSettings: CompanionSettings? { companion }
}

public enum CompanionFingerprint {
    /// «FE:70:C7…», «fe70c7…» o «SHA256:fe70…» → 64 caracteres hexadecimales en minúsculas; `nil` si no es una huella SHA-256 válida.
    public static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("sha256:") { text = String(text.dropFirst(7)) }
        let hex = text.filter { $0 != ":" && $0 != " " && $0 != "-" }
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }
}

/// El compañero solo se usa dentro de la red local: direcciones privadas o nombres de equipo sin punto / «.local». Nunca internet.
public enum CompanionAddress {
    public static func isLocal(host raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !host.isEmpty, host.count <= 253, !host.contains("/"), !host.contains(":"), !host.contains("@") else { return false }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            let numbers = parts.compactMap { Int($0) }
            guard numbers.count == 4, numbers.allSatisfy({ (0...255).contains($0) }) else { return false }
            let (a, b) = (numbers[0], numbers[1])
            return a == 10 || a == 127 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254)
        }
        if host.hasSuffix(".local") { return host.count > 6 }
        return !host.contains(".") && host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    public static func validate(host: String, port: Int) -> Bool { isLocal(host: host) && (1_024...65_535).contains(port) }
}

// MARK: Peticiones (la app las envía con URLSession y la huella fijada)

public struct CompanionRequestSpec: Equatable, Sendable {
    public var method: String
    public var path: String
    public var body: Data?
}

public enum CompanionRequests {
    private static func json(_ object: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: object) }

    public static func pair(code: String, deviceName: String) -> CompanionRequestSpec {
        CompanionRequestSpec(method: "POST", path: "/v1/pair", body: json(["code": code, "deviceName": deviceName]))
    }
    public static let status = CompanionRequestSpec(method: "GET", path: "/v1/status", body: nil)
    public static let outbox = CompanionRequestSpec(method: "GET", path: "/v1/outbox", body: nil)
    public static let revoke = CompanionRequestSpec(method: "DELETE", path: "/v1/pair", body: nil)

    public static func searchFiles(query: String, content: Bool = false, limit: Int = 20) -> CompanionRequestSpec {
        CompanionRequestSpec(method: "POST", path: "/v1/files/search", body: json(["query": query, "content": content, "limit": min(max(limit, 1), 50)]))
    }
    public static func readFile(folder: String, path: String) -> CompanionRequestSpec {
        CompanionRequestSpec(method: "POST", path: "/v1/files/read", body: json(["folder": folder, "path": path]))
    }
    public static func processes(name: String? = nil) -> CompanionRequestSpec {
        var path = "/v1/processes"
        if let name = name, !name.isEmpty { path += "?name=" + MessageLinks.encode(String(name.prefix(60))) }
        return CompanionRequestSpec(method: "GET", path: path, body: nil)
    }
    public static func githubRuns(repo: String) -> CompanionRequestSpec {
        CompanionRequestSpec(method: "POST", path: "/v1/github/runs", body: json(["repo": repo]))
    }
    public static func runScript(name: String) -> CompanionRequestSpec {
        CompanionRequestSpec(method: "POST", path: "/v1/scripts/run", body: json(["name": name]))
    }
}

// MARK: Respuestas

public struct CompanionFileHit: Equatable, Sendable, Identifiable {
    public var id: String { folder + "/" + path }
    public let folder: String
    public let path: String
    public let size: Int
    public let modified: String
}

public struct CompanionProcess: Equatable, Sendable, Identifiable {
    public var id: Int { pid }
    public let name: String
    public let pid: Int
    public let memory: String
}

public struct CompanionOutboxMessage: Equatable, Sendable, Identifiable {
    public let id: String
    public let time: String
    /// Texto escrito en el PC: se muestra como dato, nunca como orden para Viernes.
    public let text: String
}

public struct CompanionPairResult: Equatable, Sendable {
    public let token: String
    public let tokenID: String
    public let fingerprint: String?
    public let name: String
}

public enum CompanionResponses {
    private static func object(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }

    public static func errorMessage(_ data: Data) -> String? { object(data)?["error"] as? String }

    public static func pair(_ data: Data) -> CompanionPairResult? {
        guard let root = object(data), let token = root["token"] as? String, token.count >= 20, token.count <= 300,
              let id = root["tokenId"] as? String else { return nil }
        return CompanionPairResult(token: token, tokenID: id, fingerprint: root["fingerprint"] as? String, name: (root["name"] as? String) ?? "PC")
    }

    public static func files(_ data: Data) -> [CompanionFileHit] {
        ((object(data)?["results"] as? [[String: Any]]) ?? []).compactMap { item in
            guard let folder = item["folder"] as? String, let path = item["path"] as? String else { return nil }
            return CompanionFileHit(folder: String(folder.prefix(60)), path: String(path.prefix(300)), size: item["size"] as? Int ?? 0, modified: item["modified"] as? String ?? "")
        }
    }

    public static func processes(_ data: Data) -> [CompanionProcess] {
        ((object(data)?["processes"] as? [[String: Any]]) ?? []).compactMap { item in
            guard let name = item["name"] as? String, let pid = item["pid"] as? Int else { return nil }
            return CompanionProcess(name: String(name.prefix(80)), pid: pid, memory: (item["memory"] as? String) ?? "")
        }
    }

    public static func outbox(_ data: Data) -> [CompanionOutboxMessage] {
        ((object(data)?["messages"] as? [[String: Any]]) ?? []).compactMap { item in
            guard let id = item["id"] as? String, let text = item["text"] as? String else { return nil }
            return CompanionOutboxMessage(id: id, time: item["time"] as? String ?? "", text: String(UntrustedContent.neutralize(text).prefix(4_000)))
        }
    }

    public static func folders(_ data: Data) -> [String] { (object(data)?["folders"] as? [String]) ?? [] }
}
