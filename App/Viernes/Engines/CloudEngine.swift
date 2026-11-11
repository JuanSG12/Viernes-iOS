import Foundation
import ViernesCore

/// Cerebro en la nube: API de chat compatible con OpenAI (Groq, Gemini…) con la clave gratuita del usuario.
/// ⚠️ El texto de la conversación sale del iPhone hacia el proveedor. Por eso es opt-in y se explica en su pantalla.
/// Lo que el motor en la nube necesita del consumo del perfil: permiso previo (autorización y presupuesto), anotar lo gastado y lo que
/// informó el proveedor sobre sus límites.
struct UsageHooks: @unchecked Sendable {
    var gate: @Sendable (_ providerID: String, _ model: String) -> UsageGateDecision
    var record: @Sendable (_ providerID: String, _ model: String, _ usage: TokenUsage) -> Void
    var limits: @Sendable (_ providerID: String, _ snapshot: ProviderLimitsSnapshot) -> Void
    var warn: @Sendable (String) -> Void
}

final class CloudEngine: LanguageModelEngine, EngineStatusReporting, @unchecked Sendable {
    let descriptor: ModelDescriptor
    private let settings: CloudBrainSettings
    private let session: URLSession
    private let usage: UsageHooks?
    /// Avisos de espera para la pantalla (p. ej. «Groq pidió esperar 6 s»). `nil` = ya no hay espera.
    var onStatus: (@Sendable (String?) -> Void)?

    init(descriptor: ModelDescriptor, settings: CloudBrainSettings, usage: UsageHooks? = nil) {
        self.descriptor = descriptor
        self.usage = usage
        self.settings = settings.sanitized()
        let configuration = URLSessionConfiguration.ephemeral          // sin caché ni cookies en disco
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    private var preset: CloudProviderPreset { settings.preset }

    private var missingKeyReason: String {
        "Falta la clave de \(preset.displayName). Ve a Ajustes › Cerebro en la nube y pégala."
    }

    func availability() async -> EngineAvailability {
        CloudKeyStore.hasKey(providerID: preset.id) ? .ready : .unavailable(reason: missingKeyReason)
    }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard CloudKeyStore.hasKey(providerID: preset.id) else { throw EngineError.notReady(missingKeyReason) }
        progress(1)
    }

    func unload() async {}

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Antes de cualquier cosa: ¿está autorizado el proveedor y cabe en el presupuesto? Si no, no sale nada de la app.
                    if let hooks = self.usage {
                        switch hooks.gate(self.preset.id, self.settings.model) {
                        case .block(let reason): throw EngineError.generationFailed(reason)
                        case .warn(let text): hooks.warn(text)
                        case .allow: break
                        }
                    }
                    guard let key = CloudKeyStore.read(providerID: self.preset.id) else {
                        throw EngineError.notReady(self.missingKeyReason)
                    }
                    guard let url = OpenAIChatProtocol.endpoint(self.preset, path: "chat/completions") else {
                        throw EngineError.generationFailed("URL del proveedor no válida.")
                    }
                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlRequest.httpBody = try OpenAIChatProtocol.requestBody(
                        model: self.settings.model, system: request.system, turns: request.turns,
                        maxTokens: max(request.maxTokens, OpenAIChatProtocol.minimumCloudTokens), temperature: request.temperature,
                        includeUsage: self.preset.streamUsage)

                    // Petición con reintentos: un 429 (límite del plan gratuito) con espera corta se espera y se reintenta,
                    // avisando en pantalla; un límite diario o una espera larga se informa tal cual, con las cifras del proveedor.
                    var rateLimitRetries = 0
                    var opened: URLSession.AsyncBytes?
                    while opened == nil {
                        let (bytes, response) = try await self.session.bytes(for: urlRequest)
                        guard let http = response as? HTTPURLResponse else {
                            throw EngineError.generationFailed("Respuesta no válida del proveedor.")
                        }
                        if (200..<300).contains(http.statusCode) {
                            // Lo que el proveedor informe sobre sus límites (si no informa nada, no se muestra nada).
                            var lowered: [String: String] = [:]
                            for (key, value) in http.allHeaderFields {
                                if let name = key as? String, let text = value as? String { lowered[name.lowercased()] = text }
                            }
                            let snapshot = ProviderLimitsSnapshot.from(headers: lowered)
                            if !snapshot.isEmpty { self.usage?.limits(self.preset.id, snapshot) }
                            opened = bytes
                            break
                        }
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 8_000 { break }
                        }
                        // El mismo «tool_use_failed» también puede llegar como error HTTP 400: se rescata igual.
                        if http.statusCode == 400, let failed = OpenAIChatProtocol.failedGeneration(inBody: body) {
                            let calls = ToolCallRecovery.extract(from: failed)
                            if !calls.isEmpty {
                                for call in calls { continuation.yield("\(Persona.toolOpen)\(call)\(Persona.toolClose)\n") }
                                continuation.finish()
                                return
                            }
                        }
                        if http.statusCode == 429 {
                            let limit = OpenAIChatProtocol.parseRateLimit(retryAfterHeader: http.value(forHTTPHeaderField: "retry-after"), body: body)
                            Diagnostics.shared.log("límite de \(self.preset.displayName): ventana \(limit.window.rawValue), espera \(limit.retryAfter.map { String($0) } ?? "?") s, \(limit.detail ?? "sin cifras"), intento \(rateLimitRetries + 1)")
                            if rateLimitRetries < OpenAIChatProtocol.maxRateLimitRetries, let wait = OpenAIChatProtocol.automaticWait(for: limit) {
                                rateLimitRetries += 1
                                self.onStatus?("\(self.preset.displayName) pidió esperar \(OpenAIChatProtocol.humanDuration(wait)) (límite del plan gratuito). Reintento solo…")
                                try await Task.sleep(nanoseconds: UInt64((wait + 0.4) * 1_000_000_000))
                                self.onStatus?(nil)
                                continue
                            }
                            self.onStatus?(nil)
                            throw EngineError.generationFailed(OpenAIChatProtocol.rateLimitMessage(limit, provider: self.preset.displayName))
                        }
                        throw EngineError.generationFailed(OpenAIChatProtocol.errorMessage(
                            status: http.statusCode, body: body, provider: self.preset.displayName, model: self.settings.model))
                    }
                    guard let bytes = opened else { throw EngineError.generationFailed("Respuesta no válida del proveedor.") }
                    var yielded = false
                    var finishReason: String?
                    var reported: TokenUsage?
                    var produced = ""
                    let inputCharacters = request.system.count + request.turns.reduce(0) { $0 + $1.content.count }
                    /// Anota el consumo: el que informó el proveedor o, si no informó, una estimación por el texto (marcada como tal).
                    func recordUsage() {
                        guard let hooks = self.usage else { return }
                        let tokens = reported ?? TokenUsage(input: UsageEstimator.tokens(forCharacters: inputCharacters),
                                                            output: UsageEstimator.tokens(forCharacters: produced.count), isEstimate: true)
                        hooks.record(self.preset.id, self.settings.model, tokens)
                    }
                    /// Respuesta sin una sola palabra porque el modelo agotó su límite pensando: se dice, en vez de dejarla vacía.
                    func finishStream() throws {
                        if !yielded, finishReason == "length" {
                            throw EngineError.generationFailed("El modelo agotó su espacio de respuesta antes de escribir. Inténtalo de nuevo con un mensaje más corto.")
                        }
                    }
                    for try await line in bytes.lines {
                        if let found = OpenAIChatProtocol.parseUsage(line) { reported = found }
                        switch OpenAIChatProtocol.parseStreamLine(line) {
                        case .delta(let text):
                            yielded = true
                            produced += text
                            continuation.yield(text)
                        case .finish(let reason):
                            finishReason = reason
                        case .providerError(let message, let failedGeneration):
                            // Groq corta con «tool_use_failed» cuando el modelo escribe una llamada a función a su manera.
                            // Lo que quiso escribir llega en `failed_generation`: se rescata como llamada válida.
                            if !yielded, let failed = failedGeneration {
                                let calls = ToolCallRecovery.extract(from: failed)
                                if !calls.isEmpty {
                                    for call in calls { continuation.yield("\(Persona.toolOpen)\(call)\(Persona.toolClose)\n") }
                                    recordUsage()
                                    continuation.finish()
                                    return
                                }
                            }
                            throw EngineError.generationFailed("\(self.preset.displayName): \(message)")
                        case .done:
                            try finishStream()
                            recordUsage()
                            continuation.finish()
                            return
                        case .ignore: continue
                        }
                    }
                    try finishStream()
                    recordUsage()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: EngineError.cancelled)
                } catch let error as EngineError {
                    continuation.finish(throwing: error)
                } catch let error as URLError {
                    continuation.finish(throwing: EngineError.generationFailed(Self.describe(error)))
                } catch {
                    continuation.finish(throwing: EngineError.generationFailed(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return "Sin conexión a internet. El cerebro en la nube la necesita; puedes cambiar al modelo local en Ajustes › Modelo local."
        case .timedOut:
            return "El proveedor tardó demasiado en responder. Inténtalo de nuevo."
        case .cancelled:
            return "Generación cancelada."
        default:
            return "Error de red: \(error.localizedDescription)"
        }
    }
}

/// Comprueba la clave y lista los modelos reales del proveedor (los nombres y límites gratuitos cambian con el tiempo).
enum CloudConnectionTester {
    struct Report { let ok: Bool; let message: String }

    static func test(_ raw: CloudBrainSettings) async -> Report {
        let settings = raw.sanitized()
        let preset = settings.preset
        guard let key = CloudKeyStore.read(providerID: preset.id) else {
            return Report(ok: false, message: "Primero guarda la clave de \(preset.displayName).")
        }
        guard let url = OpenAIChatProtocol.endpoint(preset, path: "models") else {
            return Report(ok: false, message: "URL del proveedor no válida.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        do {
            let (data, response) = try await URLSession(configuration: configuration).data(for: request)
            guard let http = response as? HTTPURLResponse else { return Report(ok: false, message: "Respuesta no válida.") }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data.prefix(2_000), encoding: .utf8) ?? ""
                return Report(ok: false, message: OpenAIChatProtocol.errorMessage(
                    status: http.statusCode, body: body, provider: preset.displayName, model: settings.model))
            }
            let ids = OpenAIChatProtocol.parseModelIDs(data)
            if ids.isEmpty { return Report(ok: true, message: "Clave aceptada, pero el proveedor no listó modelos. Prueba a conversar.") }
            if ids.contains(settings.model) {
                return Report(ok: true, message: "Conexión correcta. El modelo «\(settings.model)» está disponible (\(ids.count) modelos en total).")
            }
            let sample = ids.prefix(10).joined(separator: ", ")
            return Report(ok: false, message: "La clave funciona, pero el modelo «\(settings.model)» no aparece. Disponibles: \(sample). Escribe uno de ellos en «Modelo».")
        } catch let error as URLError {
            return Report(ok: false, message: CloudEngine.describe(error))
        } catch {
            return Report(ok: false, message: error.localizedDescription)
        }
    }
}
