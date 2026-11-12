import Foundation
import ViernesCore

/// Cerebro Gemini con la API NATIVA de Google (`streamGenerateContent`): flujo de texto, imágenes como `inlineData`, consumo real
/// (`usageMetadata`) y errores clasificados. Las herramientas siguen el mismo protocolo de texto que el resto de motores, así que
/// funcionan igual con cualquier modelo (no se usa la «llamada a funciones» nativa de Gemini).
/// La clave va en la cabecera `x-goog-api-key`, nunca en la URL.
final class GeminiEngine: LanguageModelEngine, EngineStatusReporting, @unchecked Sendable {
    let descriptor: ModelDescriptor
    private let settings: CloudBrainSettings
    private let session: URLSession
    private let usage: UsageHooks?
    var onStatus: (@Sendable (String?) -> Void)?

    init(descriptor: ModelDescriptor, settings: CloudBrainSettings, usage: UsageHooks? = nil) {
        self.descriptor = descriptor
        self.usage = usage
        self.settings = settings.sanitized()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    private var preset: CloudProviderPreset { CloudProviders.gemini }

    private var missingKeyReason: String {
        "Falta la clave de Google Gemini. Ve a Ajustes › Cerebro en la nube y pégala."
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
                    if let hooks = self.usage {
                        switch hooks.gate(self.preset.id, self.settings.model) {
                        case .block(let reason): throw EngineError.generationFailed(reason)
                        case .warn(let text): hooks.warn(text)
                        case .allow: break
                        }
                    }
                    try ProviderHTTP.checkBreaker(providerID: self.preset.id, providerName: self.preset.displayName)
                    guard let key = CloudKeyStore.read(providerID: self.preset.id) else { throw EngineError.notReady(self.missingKeyReason) }
                    guard let url = GeminiProtocol.streamURL(model: self.settings.model) else {
                        throw EngineError.generationFailed("El nombre del modelo no es válido: «\(self.settings.model)».")
                    }
                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue(key, forHTTPHeaderField: "x-goog-api-key")
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    // Los modelos que «piensan» gastan salida antes de escribir: se deja un margen mínimo para no quedar en blanco.
                    let maxOutput: Int = max(request.outputBudget ?? request.maxTokens, 1_024)
                    urlRequest.httpBody = try GeminiProtocol.requestBody(system: request.system, turns: request.turns,
                                                                         maxOutputTokens: maxOutput, temperature: request.temperature)
                    let settingsCopy: CloudBrainSettings = self.settings
                    let opened = try await ProviderHTTP.open(
                        session: self.session, request: urlRequest, providerID: self.preset.id, providerName: self.preset.displayName,
                        model: self.settings.model, onStatus: self.onStatus,
                        enrich: { failure, message in
                            // Modelo inexistente: se muestran los que la clave SÍ puede usar (no se cambia de modelo en silencio).
                            guard failure.kind == .modelNotFound,
                                  let listing = try? await CloudConnectionTester.listModels(settings: settingsCopy), !listing.ids.isEmpty else { return message }
                            return message + " Modelos disponibles con tu clave: " + listing.ids.prefix(8).joined(separator: ", ") + "."
                        })
                    let bytes: URLSession.AsyncBytes
                    switch opened {
                    case .rescued:
                        throw EngineError.generationFailed("Respuesta no válida de Gemini.")
                    case .stream(let stream, let limits):
                        if let limits = limits { self.usage?.limits(self.preset.id, limits) }
                        bytes = stream
                    }
                    ProviderHealth.breaker.recordSuccess(self.preset.id)

                    var produced = ""
                    var finishReason: String?
                    var blockReason: String?
                    var reported: TokenUsage?
                    let inputCharacters: Int = request.system.count + request.turns.reduce(0) { $0 + $1.content.count }
                    func recordUsage() {
                        guard let hooks = self.usage else { return }
                        let tokens: TokenUsage = reported ?? TokenUsage(input: UsageEstimator.tokens(forCharacters: inputCharacters),
                                                                        output: UsageEstimator.tokens(forCharacters: produced.count), isEstimate: true)
                        hooks.record(self.preset.id, self.settings.model, tokens)
                    }
                    for try await line in bytes.lines {
                        guard let chunk = GeminiProtocol.parseStreamLine(line) else { continue }
                        if let errorBody = chunk.errorBody {
                            let failure: ProviderFailure = ProviderFailureClassifier.classify(status: 500, headers: [:], body: errorBody)
                            throw EngineError.generationFailed("Google Gemini: \(failure.providerMessage ?? "error durante la respuesta")")
                        }
                        if let usageNow = chunk.usage { reported = usageNow }
                        if let reason = chunk.finishReason { finishReason = reason }
                        if let block = chunk.blockReason { blockReason = block }
                        if !chunk.text.isEmpty {
                            produced += chunk.text
                            continuation.yield(chunk.text)
                        }
                    }
                    recordUsage()
                    if let problem = GeminiProtocol.validationError(producedText: !produced.isEmpty, finishReason: finishReason, blockReason: blockReason) {
                        throw EngineError.generationFailed(problem)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: EngineError.cancelled)
                } catch let error as ProviderFailureError {
                    continuation.finish(throwing: error)
                } catch let error as EngineError {
                    continuation.finish(throwing: error)
                } catch let error as URLError {
                    continuation.finish(throwing: EngineError.generationFailed(CloudEngine.describe(error)))
                } catch {
                    continuation.finish(throwing: EngineError.generationFailed(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
