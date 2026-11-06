import Foundation
import ViernesCore

/// Transcripción opcional con Whisper de Groq. ⚠️ El AUDIO de la frase sale del teléfono hacia Groq: solo se llama si el usuario
/// lo activó y consintió de forma expresa (ver `SpeechSettings.cloudTranscription`). Nunca se envía audio a ElevenLabs ni a otro
/// servicio. El archivo temporal se borra siempre al terminar, haya salido bien o mal.
enum CloudTranscriber {
    struct Result {
        let text: String
        let seconds: Double
    }

    struct Failure: Error {
        let message: String
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral          // sin caché ni cookies en disco
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static func hasKey() -> Bool { CloudKeyStore.hasKey(providerID: CloudProviders.groq.id) }

    static func transcribe(fileURL: URL, terms: [String]) async -> Swift.Result<Result, Failure> {
        defer { try? FileManager.default.removeItem(at: fileURL) }
        guard let key = CloudKeyStore.read(providerID: CloudProviders.groq.id) else {
            return .failure(Failure(message: "Falta la clave de Groq. Guárdala en Ajustes › Cerebro en la nube."))
        }
        guard let audio = try? Data(contentsOf: fileURL), !audio.isEmpty else {
            return .failure(Failure(message: "No hubo audio que transcribir."))
        }
        guard audio.count <= GroqWhisper.maxAudioBytes else {
            return .failure(Failure(message: GroqWhisper.errorMessage(status: 413, body: "")))
        }
        guard let url = URL(string: GroqWhisper.endpoint) else { return .failure(Failure(message: "URL del proveedor no válida.")) }
        let boundary = "viernes-" + UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(GroqWhisper.contentType(boundary: boundary), forHTTPHeaderField: "Content-Type")
        request.httpBody = GroqWhisper.multipartBody(boundary: boundary, audio: audio, language: "es", prompt: GroqWhisper.prompt(from: terms))

        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(Failure(message: "Respuesta no válida de Groq.")) }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data.prefix(4_000), encoding: .utf8) ?? ""
                return .failure(Failure(message: GroqWhisper.errorMessage(status: http.statusCode, body: body, retryAfterHeader: http.value(forHTTPHeaderField: "retry-after"))))
            }
            guard let text = GroqWhisper.parseTranscript(data) else { return .failure(Failure(message: "Groq no devolvió texto.")) }
            return .success(Result(text: text, seconds: Date().timeIntervalSince(started)))
        } catch let error as URLError where error.code == .timedOut {
            return .failure(Failure(message: "Groq tardó demasiado en transcribir."))
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(error.code) {
            return .failure(Failure(message: "Sin conexión a internet para transcribir en la nube."))
        } catch {
            return .failure(Failure(message: "No pude transcribir en la nube: \(error.localizedDescription)"))
        }
    }
}
