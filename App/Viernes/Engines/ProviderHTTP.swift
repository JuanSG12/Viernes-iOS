import Foundation
import ViernesCore

/// Fallo de un proveedor con su motivo real (cuota diaria, saldo, límite por minuto…). Lo usan los motores y el cambio de proveedor.
struct ProviderFailureError: LocalizedError {
    let failure: ProviderFailure
    let message: String
    var errorDescription: String? { "Falló la generación: \(message)" }
}

/// Interruptor de seguridad compartido por todos los motores de la nube.
enum ProviderHealth {
    static let breaker = ProviderCircuitBreaker()
}

/// Apertura de la conexión con un proveedor: reintentos ACOTADOS solo para lo que esperar arregla, y un fallo claro para el resto.
enum ProviderHTTP {
    enum Opened {
        case stream(URLSession.AsyncBytes, limits: ProviderLimitsSnapshot?)
        case rescued([String])
    }

    static func lowercased(_ http: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let name = key as? String, let text = value as? String { result[name.lowercased()] = text }
        }
        return result
    }

    /// Falla de inmediato (sin enviar nada) si el proveedor está en pausa por el interruptor de seguridad.
    static func checkBreaker(providerID: String, providerName: String) throws {
        let status = ProviderHealth.breaker.status(providerID)
        guard status.isOpen else { return }
        let failure = ProviderFailure(kind: status.kind ?? .unavailable, status: 0)
        throw ProviderFailureError(failure: failure, message: ProviderHealth.breaker.pauseMessage(provider: providerName, status: status))
    }

    /// `rescue`: recibe el cuerpo de un 400 y devuelve llamadas a herramientas recuperables (Groq «tool_use_failed»).
    /// `enrich`: permite añadir información real al mensaje de un fallo (p. ej. los modelos disponibles si el modelo no existe).
    static func open(session: URLSession, request: URLRequest, providerID: String, providerName: String, model: String,
                     onStatus: (@Sendable (String?) -> Void)?,
                     rescue: ((String) -> [String])? = nil,
                     enrich: ((ProviderFailure, String) async -> String)? = nil) async throws -> Opened {
        var retries = 0
        while true {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw EngineError.generationFailed("Respuesta no válida del proveedor.")
            }
            let headers: [String: String] = lowercased(http)
            if (200..<300).contains(http.statusCode) {
                let snapshot = ProviderLimitsSnapshot.from(headers: headers)
                return .stream(bytes, limits: snapshot.isEmpty ? nil : snapshot)
            }
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 8_000 { break }
            }
            if http.statusCode == 400, let rescue = rescue {
                let calls: [String] = rescue(body)
                if !calls.isEmpty { return .rescued(calls) }
            }
            let failure: ProviderFailure = ProviderFailureClassifier.classify(status: http.statusCode, headers: headers, body: body)
            let wait: String = failure.retryAfter.map { String($0) } ?? "?"
            Diagnostics.shared.log("\(providerName): \(failure.kind.rawValue) (HTTP \(http.statusCode)), espera \(wait) s, \(failure.detail ?? "sin cifras"), intento \(retries + 1)")
            if retries < ProviderFailure.maxRetries, let seconds = failure.automaticWait {
                retries += 1
                onStatus?(failure.waitNotice(provider: providerName, seconds: seconds, attempt: retries, of: ProviderFailure.maxRetries))
                try await Task.sleep(nanoseconds: UInt64((seconds + 0.4) * 1_000_000_000))
                onStatus?(nil)
                continue
            }
            onStatus?(nil)
            var message: String = failure.userMessage(provider: providerName, model: model)
            if let enrich = enrich { message = await enrich(failure, message) }
            ProviderHealth.breaker.recordFailure(providerID, failure: failure, message: message)
            throw ProviderFailureError(failure: failure, message: message)
        }
    }
}
