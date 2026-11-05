import Foundation
import ViernesCore

/// Cerebro en la nube: API de chat compatible con OpenAI (Groq, Gemini…) con la clave gratuita del usuario.
/// ⚠️ El texto de la conversación sale del iPhone hacia el proveedor. Por eso es opt-in y se explica en su pantalla.
final class CloudEngine: LanguageModelEngine, @unchecked Sendable {
    let descriptor: ModelDescriptor
    private let settings: CloudBrainSettings
    private let session: URLSession

    init(descriptor: ModelDescriptor, settings: CloudBrainSettings) {
        self.descriptor = descriptor
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
                        maxTokens: request.maxTokens, temperature: request.temperature)

                    let (bytes, response) = try await self.session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw EngineError.generationFailed("Respuesta no válida del proveedor.")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 2_000 { break }
                        }
                        throw EngineError.generationFailed(OpenAIChatProtocol.errorMessage(
                            status: http.statusCode, body: body, provider: self.preset.displayName, model: self.settings.model))
                    }
                    for try await line in bytes.lines {
                        switch OpenAIChatProtocol.parseStreamLine(line) {
                        case .delta(let text): continuation.yield(text)
                        case .done:
                            continuation.finish()
                            return
                        case .ignore: continue
                        }
                    }
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
