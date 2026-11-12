import Foundation
import ViernesCore

/// Cerebro en la nube: API de chat compatible con OpenAI (Groq, OpenAI, Cerebras…) con la clave del usuario.
/// (Gemini usa su API nativa: ver `GeminiEngine`.)
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
    /// Avisos de espera para la pantalla (p. ej. «Groq: límite de tokens por minuto. Reintento en 6 s»). `nil` = ya no hay espera.
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
                    // ¿Está el proveedor en pausa por fallos que esperar no arregla? Se dice, sin enviar nada.
                    try ProviderHTTP.checkBreaker(providerID: self.preset.id, providerName: self.preset.displayName)
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
                    // Tope de salida: el del tipo de petición (ahorro de tokens) o, si no, el margen de siempre para razonamiento oculto.
                    let maxTokens: Int = request.outputBudget ?? max(request.maxTokens, OpenAIChatProtocol.minimumCloudTokens)
                    urlRequest.httpBody = try OpenAIChatProtocol.requestBody(
                        model: self.settings.model, system: request.system, turns: request.turns,
                        maxTokens: maxTokens, temperature: request.temperature,
                        includeUsage: self.preset.streamUsage)

                    // Apertura con reintentos acotados: solo los límites por minuto y los fallos breves se esperan; el saldo agotado,
                    // la cuota diaria, la clave o el modelo se informan tal cual (con las cifras del proveedor) y NO se reintentan.
                    let settingsCopy: CloudBrainSettings = self.settings
                    let opened = try await ProviderHTTP.open(
                        session: self.session, request: urlRequest, providerID: self.preset.id, providerName: self.preset.displayName,
                        model: self.settings.model, onStatus: self.onStatus,
                        rescue: { body in
                            // El mismo «tool_use_failed» también puede llegar como error HTTP 400: se rescata igual.
                            guard let failed = OpenAIChatProtocol.failedGeneration(inBody: body) else { return [] }
                            return ToolCallRecovery.extract(from: failed)
                        },
                        enrich: { failure, message in
                            guard failure.kind == .modelNotFound,
                                  let listing = try? await CloudConnectionTester.listModels(settings: settingsCopy), !listing.ids.isEmpty else { return message }
                            return message + " Modelos disponibles con tu clave: " + listing.ids.prefix(8).joined(separator: ", ") + "."
                        })
                    let bytes: URLSession.AsyncBytes
                    switch opened {
                    case .rescued(let calls):
                        for call in calls { continuation.yield("\(Persona.toolOpen)\(call)\(Persona.toolClose)\n") }
                        continuation.finish()
                        return
                    case .stream(let stream, let limits):
                        // Lo que el proveedor informe sobre sus límites (si no informa nada, no se muestra nada).
                        if let limits = limits { self.usage?.limits(self.preset.id, limits) }
                        bytes = stream
                    }
                    ProviderHealth.breaker.recordSuccess(self.preset.id)
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
                } catch let error as ProviderFailureError {
                    continuation.finish(throwing: error)
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

/// Comprueba la clave y lista los modelos REALES de la cuenta (los nombres y límites cambian con el tiempo y Google retira modelos).
/// Para Gemini usa su API nativa y solo muestra los que admiten `generateContent`.
enum CloudConnectionTester {
    struct Report {
        let ok: Bool
        let message: String
        var models: [String] = []
        var suggestedLight: String?
        var suggestedStrong: String?
    }

    struct Listing {
        let ids: [String]
        let suggestedLight: String?
        let suggestedStrong: String?
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }

    private static func failure(_ http: HTTPURLResponse, data: Data, preset: CloudProviderPreset, model: String) -> ProviderFailureError {
        let body: String = String(data: data.prefix(4_000), encoding: .utf8) ?? ""
        let classified: ProviderFailure = ProviderFailureClassifier.classify(status: http.statusCode, headers: ProviderHTTP.lowercased(http), body: body)
        return ProviderFailureError(failure: classified, message: classified.userMessage(provider: preset.displayName, model: model))
    }

    /// Modelos de conversación disponibles con la clave guardada. Lanza `ProviderFailureError` si el proveedor lo rechaza.
    static func listModels(settings raw: CloudBrainSettings) async throws -> Listing {
        let settings = raw.sanitized()
        let preset = settings.preset
        guard let key = CloudKeyStore.read(providerID: preset.id) else {
            throw EngineError.notReady("Primero guarda la clave de \(preset.displayName).")
        }
        let session = makeSession()
        if preset.id == CloudProviders.gemini.id {
            var all: [GeminiModelInfo] = []
            var token: String?
            for _ in 0..<4 {
                guard let url = GeminiProtocol.modelsURL(pageToken: token) else { break }
                var request = URLRequest(url: url)
                request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw EngineError.generationFailed("Respuesta no válida.") }
                guard (200..<300).contains(http.statusCode) else { throw failure(http, data: data, preset: preset, model: settings.model) }
                let page = GeminiModels.parseList(data)
                all.append(contentsOf: page.models)
                token = page.nextPageToken
                if token == nil { break }
            }
            let chat: [GeminiModelInfo] = GeminiModels.chatModels(all)
            return Listing(ids: chat.map(\.id), suggestedLight: GeminiModels.suggest(.light, from: all), suggestedStrong: GeminiModels.suggest(.strong, from: all))
        }
        guard let url = OpenAIChatProtocol.endpoint(preset, path: "models") else {
            throw EngineError.generationFailed("URL del proveedor no válida.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EngineError.generationFailed("Respuesta no válida.") }
        guard (200..<300).contains(http.statusCode) else { throw failure(http, data: data, preset: preset, model: settings.model) }
        return Listing(ids: CloudModelFilter.chatCandidates(OpenAIChatProtocol.parseModelIDs(data)), suggestedLight: nil, suggestedStrong: nil)
    }

    static func test(_ raw: CloudBrainSettings) async -> Report {
        let settings = raw.sanitized()
        let preset = settings.preset
        guard CloudKeyStore.hasKey(providerID: preset.id) else {
            return Report(ok: false, message: "Primero guarda la clave de \(preset.displayName).")
        }
        do {
            let listing = try await listModels(settings: settings)
            ProviderHealth.breaker.reset(preset.id)               // la clave funciona: se levanta una pausa anterior
            if listing.ids.isEmpty {
                return Report(ok: true, message: "Clave aceptada, pero el proveedor no listó modelos de conversación. Prueba a conversar.")
            }
            if listing.ids.contains(settings.model) {
                return Report(ok: true, message: "Conexión correcta. El modelo «\(settings.model)» está disponible (\(listing.ids.count) modelos de conversación).",
                              models: listing.ids, suggestedLight: listing.suggestedLight, suggestedStrong: listing.suggestedStrong)
            }
            return Report(ok: false,
                          message: "La clave funciona, pero el modelo «\(settings.model)» NO está disponible con tu cuenta. Estos sí lo están (toca uno para elegirlo):",
                          models: listing.ids, suggestedLight: listing.suggestedLight, suggestedStrong: listing.suggestedStrong)
        } catch let error as ProviderFailureError {
            return Report(ok: false, message: error.message)
        } catch let error as EngineError {
            return Report(ok: false, message: error.localizedDescription)
        } catch let error as URLError {
            return Report(ok: false, message: CloudEngine.describe(error))
        } catch {
            return Report(ok: false, message: error.localizedDescription)
        }
    }
}
