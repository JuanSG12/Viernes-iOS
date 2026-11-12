import Foundation

// Gestión unificada de fallos de los proveedores en la nube (Groq, Gemini, OpenAI, Cerebras…).
// Cada motivo se distingue porque NO todos se tratan igual: esperar sirve para el límite por minuto, no para un saldo agotado ni
// para la cuota diaria; una clave o un modelo mal puestos se arreglan en Ajustes, no reintentando.

public enum ProviderFailureKind: String, Codable, Sendable, CaseIterable {
    case temporaryRateLimit     // 429 sin más datos
    case tokensPerMinute
    case requestsPerMinute
    case dailyQuota
    case insufficientCredit     // sin saldo / sin cuota de facturación
    case modelNotFound
    case invalidKey
    case authentication         // permiso, región o cuenta
    case unavailable            // 5xx
    case badRequest
    case other

    public var title: String {
        switch self {
        case .temporaryRateLimit: return "límite temporal"
        case .tokensPerMinute: return "tokens por minuto"
        case .requestsPerMinute: return "solicitudes por minuto"
        case .dailyQuota: return "cuota diaria agotada"
        case .insufficientCredit: return "sin crédito"
        case .modelNotFound: return "modelo inexistente"
        case .invalidKey: return "clave inválida"
        case .authentication: return "acceso denegado"
        case .unavailable: return "servicio no disponible"
        case .badRequest: return "petición rechazada"
        case .other: return "error"
        }
    }
}

public struct ProviderFailure: Equatable, Sendable {
    public var kind: ProviderFailureKind
    public var status: Int
    /// Espera que pidió el proveedor (cabecera `Retry-After`, `reset-*` o el texto del error), si la dijo.
    public var retryAfter: TimeInterval?
    /// Cifras reales del proveedor («límite 8000, usados 7243, pedidos 1984»), solo para informar.
    public var detail: String?
    public var providerMessage: String?

    public init(kind: ProviderFailureKind, status: Int, retryAfter: TimeInterval? = nil, detail: String? = nil, providerMessage: String? = nil) {
        self.kind = kind
        self.status = status
        self.retryAfter = retryAfter
        self.detail = detail
        self.providerMessage = providerMessage
    }

    /// Espera máxima que Viernes acepta hacer SOLA; más allá se informa.
    public static let maxAutomaticWait: TimeInterval = 30
    /// Reintentos automáticos por petición (nunca ilimitados).
    public static let maxRetries = 2

    /// Segundos a esperar antes de reintentar la MISMA petición, o `nil` si no conviene reintentar
    /// (facturación, cuota diaria, clave, modelo, petición mala, o una espera demasiado larga).
    public var automaticWait: TimeInterval? {
        switch kind {
        case .temporaryRateLimit, .tokensPerMinute, .requestsPerMinute:
            let wait: TimeInterval = retryAfter ?? 8
            return wait <= Self.maxAutomaticWait ? max(wait, 1) : nil
        case .unavailable:
            let wait: TimeInterval = retryAfter ?? 2
            return wait <= Self.maxAutomaticWait ? max(wait, 1) : nil
        default:
            return nil
        }
    }

    /// ¿Otro proveedor ya autorizado por el usuario podría resolver esto? Los errores de configuración (clave, modelo, petición)
    /// no se esquivan: se muestran para que se arreglen.
    public var allowsFailover: Bool {
        switch kind {
        case .temporaryRateLimit, .tokensPerMinute, .requestsPerMinute, .dailyQuota, .insufficientCredit, .unavailable: return true
        default: return false
        }
    }

    /// Texto breve del aviso mientras se espera (nunca dice «plan gratuito»: no sabemos qué plan tiene la cuenta).
    public func waitNotice(provider: String, seconds: TimeInterval, attempt: Int, of total: Int) -> String {
        let time = OpenAIChatProtocol.humanDuration(seconds)
        switch kind {
        case .tokensPerMinute: return "\(provider): límite de tokens por minuto. Reintento en \(time) (\(attempt) de \(total))…"
        case .requestsPerMinute: return "\(provider): límite de solicitudes por minuto. Reintento en \(time) (\(attempt) de \(total))…"
        case .unavailable: return "\(provider) no responde. Reintento en \(time) (\(attempt) de \(total))…"
        default: return "\(provider) pidió esperar \(time). Reintento en \(time) (\(attempt) de \(total))…"
        }
    }

    /// Mensaje para el usuario, en español, sin jerga y sin la clave. Dice qué pasó y qué hacer.
    public func userMessage(provider: String, model: String) -> String {
        let figures: String = detail.map { " (\($0))" } ?? ""
        let renewal: String = retryAfter.map { " Se renueva en ≈ \(OpenAIChatProtocol.humanDuration($0))." } ?? ""
        switch kind {
        case .insufficientCredit:
            return "\(provider) informa que la cuenta no tiene crédito ni cuota de facturación disponible\(figures). Esperar no lo arregla: revisa el plan y la facturación en la consola de \(provider) o usa otro proveedor. No se reintentó."
        case .dailyQuota:
            return "Se agotó la cuota DIARIA de \(provider)\(figures).\(renewal) No se reintentó: espera a que se renueve, usa otro proveedor autorizado o el modelo local."
        case .tokensPerMinute:
            let wait: String = retryAfter.map { " Espera ≈ \(OpenAIChatProtocol.humanDuration($0))." } ?? " Espera un minuto."
            return "\(provider) alcanzó el límite de TOKENS por minuto\(figures).\(wait) Cada mensaje envía instrucciones, historial y la respuesta reservada; los mensajes cortos gastan menos."
        case .requestsPerMinute:
            let wait: String = retryAfter.map { " Espera ≈ \(OpenAIChatProtocol.humanDuration($0))." } ?? " Espera un minuto."
            return "\(provider) alcanzó el límite de SOLICITUDES por minuto\(figures).\(wait)"
        case .temporaryRateLimit:
            let wait: String = retryAfter.map { " Espera ≈ \(OpenAIChatProtocol.humanDuration($0))." } ?? " Espera un momento."
            return "\(provider) limitó temporalmente las solicitudes\(figures).\(wait)"
        case .modelNotFound:
            return "\(provider) no tiene disponible el modelo «\(model)» con tu cuenta. Abre Ajustes › Cerebro en la nube › Probar conexión: lista los modelos reales y puedes elegir uno."
        case .invalidKey:
            return "\(provider) rechazó la clave (error \(status)). Revísala o pégala de nuevo en Ajustes › Cerebro en la nube."
        case .authentication:
            return "\(provider) negó el acceso (error \(status)): la clave no tiene permiso para este modelo o esta región, o la cuenta tiene un problema."
        case .unavailable:
            return "\(provider) no está disponible ahora mismo (error \(status)). Inténtalo en un momento."
        case .badRequest:
            let extra: String = providerMessage.map { ": \(String($0.prefix(160)))" } ?? "."
            return "\(provider) rechazó la petición (error \(status))\(extra)"
        case .other:
            let extra: String = providerMessage.map { ": \(String($0.prefix(160)))" } ?? "."
            return "\(provider) respondió con error \(status)\(extra)"
        }
    }
}

public enum ProviderFailureClassifier {
    /// Interpreta un error HTTP de cualquier proveedor. `headers` con claves en minúsculas. No inventa: si no reconoce el motivo,
    /// lo deja como límite temporal (429) o error genérico.
    public static func classify(status: Int, headers: [String: String], body: String) -> ProviderFailure {
        let parsed: ParsedBody = parse(body)
        let text: String = (parsed.message ?? body).lowercased()
        let code: String = parsed.code.lowercased()
        let type: String = parsed.type.lowercased()
        let googleStatus: String = parsed.googleStatus.uppercased()
        let detail: String? = figures(in: parsed.message ?? "")

        var kind: ProviderFailureKind
        switch status {
        case 401:
            kind = .invalidKey
        case 402:
            kind = .insufficientCredit
        case 403:
            kind = (text.contains("api key") || text.contains("api_key") || code.contains("invalid_api_key")) ? .invalidKey : .authentication
        case 404:
            kind = .modelNotFound
        case 400:
            if text.contains("api key not valid") || text.contains("api_key_invalid") || code.contains("invalid_api_key") { kind = .invalidKey }
            else if code.contains("model_not_found") { kind = .modelNotFound }
            else { kind = .badRequest }
        case 408:
            kind = .unavailable
        case 429:
            kind = classifyQuota(text: text, code: code, type: type, googleStatus: googleStatus, quotaIDs: parsed.quotaIDs, retry: parsed.retryDelay)
        case 500...599:
            kind = .unavailable
        default:
            if code.contains("insufficient_quota") { kind = .insufficientCredit }
            else if code.contains("model_not_found") { kind = .modelNotFound }
            else { kind = .other }
        }
        // Algunos proveedores devuelven el motivo de cuota con otro código HTTP (p. ej. 403 con «insufficient_quota»).
        if status != 429, status != 402, code.contains("insufficient_quota") || type.contains("insufficient_quota") { kind = .insufficientCredit }

        let retry: TimeInterval? = retryAfter(kind: kind, headers: headers, message: parsed.message, retryDelay: parsed.retryDelay)
        return ProviderFailure(kind: kind, status: status, retryAfter: retry, detail: detail, providerMessage: parsed.message.map { String($0.prefix(300)) })
    }

    // MARK: Cuota (429)

    private static func classifyQuota(text: String, code: String, type: String, googleStatus: String, quotaIDs: [String], retry: TimeInterval?) -> ProviderFailureKind {
        // Google dice EXACTAMENTE qué cuota se pasó (quotaId): es lo más fiable.
        for id in quotaIDs {
            let lowered: String = id.lowercased()
            if lowered.contains("perday") { return .dailyQuota }
            if lowered.contains("perminute") { return lowered.contains("token") ? .tokensPerMinute : .requestsPerMinute }
        }
        if code.contains("insufficient_quota") || type.contains("insufficient_quota") || code.contains("billing_hard_limit")
            || code.contains("billing_not_active") || text.contains("insufficient credit") || text.contains("insufficient balance")
            || text.contains("add credits") || text.contains("out of credits") || text.contains("no credits") {
            return .insufficientCredit
        }
        if text.contains("per day") || text.contains("(tpd)") || text.contains("(rpd)") || text.contains("daily") { return .dailyQuota }
        if text.contains("tokens per minute") || text.contains("(tpm)") { return .tokensPerMinute }
        if text.contains("requests per minute") || text.contains("(rpm)") { return .requestsPerMinute }
        if let retry = retry, retry > 600 { return .dailyQuota }
        return .temporaryRateLimit
    }

    // MARK: Tiempos

    private static func retryAfter(kind: ProviderFailureKind, headers: [String: String], message: String?, retryDelay: TimeInterval?) -> TimeInterval? {
        if let header = headers["retry-after"]?.trimmingCharacters(in: .whitespaces), let seconds = Double(header), seconds >= 0 { return seconds }
        if let delay = retryDelay { return delay }
        if let message = message {
            for marker in ["try again in ", "retry in ", "retry after "] {
                if let range = message.range(of: marker, options: .caseInsensitive), let value = OpenAIChatProtocol.parseDuration(String(message[range.upperBound...])) {
                    return value
                }
            }
        }
        // Cabeceras de reinicio (x-ratelimit-reset-*): solo la que corresponde al motivo.
        let tokens: TimeInterval? = headers["x-ratelimit-reset-tokens"].flatMap { OpenAIChatProtocol.parseDuration($0) }
        let requests: TimeInterval? = headers["x-ratelimit-reset-requests"].flatMap { OpenAIChatProtocol.parseDuration($0) }
        switch kind {
        case .tokensPerMinute: return tokens
        case .requestsPerMinute: return requests
        case .dailyQuota, .temporaryRateLimit:
            let known: [TimeInterval] = [tokens, requests].compactMap { $0 }
            return known.min()
        default: return nil
        }
    }

    // MARK: Cuerpo del error

    private struct ParsedBody {
        var message: String?
        var code: String = ""
        var type: String = ""
        var googleStatus: String = ""
        var quotaIDs: [String] = []
        var retryDelay: TimeInterval?
    }

    private static func parse(_ body: String) -> ParsedBody {
        var result = ParsedBody()
        guard let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return result }
        var root: [String: Any]?
        if let dict = json as? [String: Any] { root = dict } else if let array = json as? [[String: Any]] { root = array.first }
        guard let object = root else { return result }

        if let message = object["error"] as? String {
            result.message = message
            return result
        }
        let error: [String: Any] = (object["error"] as? [String: Any]) ?? object      // Cerebras y otros: el error va en la raíz
        result.message = error["message"] as? String
        result.code = stringValue(error["code"])
        result.type = stringValue(error["type"])
        result.googleStatus = stringValue(error["status"])
        if let details = error["details"] as? [[String: Any]] {
            for detail in details {
                if let violations = detail["violations"] as? [[String: Any]] {
                    for violation in violations {
                        if let id = violation["quotaId"] as? String { result.quotaIDs.append(id) }
                    }
                }
                if let delay = detail["retryDelay"] as? String, let seconds = OpenAIChatProtocol.parseDuration(delay) { result.retryDelay = seconds }
            }
        }
        return result
    }

    private static func stringValue(_ any: Any?) -> String {
        if let text = any as? String { return text }
        if let number = any as? Int { return String(number) }
        return ""
    }

    /// «Limit 8000, Used 7243, Requested 1984» → «límite 8000, usados 7243, pedidos 1984».
    private static func figures(in message: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "Limit\\s+(\\d+),\\s*Used\\s+(\\d+),\\s*Requested\\s+(\\d+)") else { return nil }
        let ns = message as NSString
        guard let match = regex.firstMatch(in: message, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges == 4 else { return nil }
        return "límite \(ns.substring(with: match.range(at: 1))), usados \(ns.substring(with: match.range(at: 2))), pedidos \(ns.substring(with: match.range(at: 3)))"
    }
}

/// Interruptor de seguridad («circuit breaker») por proveedor: tras un fallo que esperar no arregla (cuota diaria, sin crédito, clave)
/// o tras fallos repetidos del servicio, Viernes deja de insistir un tiempo y lo dice, en vez de golpear al proveedor en cada mensaje.
public final class ProviderCircuitBreaker: @unchecked Sendable {
    public struct Status: Equatable, Sendable {
        public var providerID: String
        public var isOpen: Bool
        public var openUntil: Date?
        public var kind: ProviderFailureKind?
        public var consecutiveFailures: Int
        public var lastMessage: String?
    }

    private struct State {
        var failures = 0
        var openUntil: Date?
        var kind: ProviderFailureKind?
        var message: String?
    }

    private let lock = NSLock()
    private var states: [String: State] = [:]

    public init() {}

    public func status(_ providerID: String, now: Date = Date()) -> Status {
        lock.lock()
        defer { lock.unlock() }
        let state: State = states[providerID] ?? State()
        let open: Bool = (state.openUntil.map { $0 > now }) ?? false
        return Status(providerID: providerID, isOpen: open, openUntil: open ? state.openUntil : nil, kind: state.kind,
                      consecutiveFailures: state.failures, lastMessage: state.message)
    }

    public func allows(_ providerID: String, now: Date = Date()) -> Bool { !status(providerID, now: now).isOpen }

    public func recordSuccess(_ providerID: String) {
        lock.lock()
        states[providerID] = State()
        lock.unlock()
    }

    public func reset(_ providerID: String) { recordSuccess(providerID) }

    /// Anota un fallo DEFINITIVO de una petición (después de agotar sus reintentos) y abre el interruptor si corresponde.
    public func recordFailure(_ providerID: String, failure: ProviderFailure, message: String? = nil, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var state: State = states[providerID] ?? State()
        state.failures += 1
        state.kind = failure.kind
        state.message = message
        switch failure.kind {
        case .dailyQuota:
            state.openUntil = now.addingTimeInterval(min(failure.retryAfter ?? 3_600, 86_400))
        case .insufficientCredit, .invalidKey, .authentication:
            state.openUntil = now.addingTimeInterval(900)
        case .tokensPerMinute, .requestsPerMinute, .temporaryRateLimit:
            state.openUntil = now.addingTimeInterval(min(max(failure.retryAfter ?? 20, 5), 120))
        case .unavailable:
            if state.failures >= 2 {
                let steps: Double = Double(min(state.failures - 2, 4))
                state.openUntil = now.addingTimeInterval(min(30 * pow(2, steps), 600))
            }
        case .modelNotFound, .badRequest, .other:
            state.failures = max(0, state.failures - 1)        // errores de configuración: no cuentan como proveedor caído
        }
        states[providerID] = state
    }

    /// Texto para avisar de que el proveedor está en pausa.
    public func pauseMessage(provider: String, status: Status, now: Date = Date()) -> String {
        let remaining: TimeInterval = max(1, (status.openUntil ?? now).timeIntervalSince(now))
        let reason: String = status.kind?.title ?? "fallos repetidos"
        return "\(provider) está en pausa (\(reason)) durante ≈ \(OpenAIChatProtocol.humanDuration(remaining)) para no insistir en vano. Puedes usar otro proveedor autorizado o el modelo local, o pulsar «Reintentar ahora» en Ajustes › Consumo y presupuesto."
    }
}
