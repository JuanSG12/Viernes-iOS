import AVFoundation
import ViernesCore

/// Cliente de ElevenLabs (voz neuronal). ⚠️ Cada frase hablada SALE del teléfono hacia ElevenLabs.
/// La clave vive solo en el Llavero. Cualquier fallo se resuelve hablando con la voz del sistema.
enum ElevenLabsClient {
    struct Failure: Error {
        let message: String
        /// Problema de configuración (clave, plan, voz): no tiene sentido reintentar en esta sesión.
        let fatal: Bool
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private static func authorized(_ url: URL, method: String) -> URLRequest? {
        guard let key = CloudKeyStore.read(providerID: ElevenLabsProtocol.keyProviderID) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        return request
    }

    private static func failure(for error: Error) -> Failure {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return Failure(message: "Sin conexión: hablo con la voz de Apple.", fatal: false)
            case .timedOut:
                return Failure(message: "ElevenLabs tardó demasiado: hablo con la voz de Apple.", fatal: false)
            case .cancelled:
                return Failure(message: "Cancelado.", fatal: false)
            default: break
            }
        }
        return Failure(message: "Error de red con ElevenLabs: \(error.localizedDescription)", fatal: false)
    }

    private static func httpFailure(status: Int, data: Data) -> Failure {
        let body = String(data: data.prefix(2_000), encoding: .utf8) ?? ""
        return Failure(message: ElevenLabsProtocol.errorMessage(status: status, body: body), fatal: [401, 402, 403, 404, 422].contains(status))
    }

    static func synthesize(text: String, settings: ElevenLabsSettings, speed: Double) async -> Result<Data, Failure> {
        guard let url = ElevenLabsProtocol.speechURL(voiceID: settings.voiceID),
              var request = authorized(url, method: "POST") else {
            return .failure(Failure(message: "Falta la clave o la voz de ElevenLabs. Revisa Voz y habla › Voz neuronal.", fatal: true))
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        do {
            request.httpBody = try ElevenLabsProtocol.requestBody(text: text, modelID: settings.modelID, speed: speed)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(Failure(message: "Respuesta no válida de ElevenLabs.", fatal: false)) }
            guard (200..<300).contains(http.statusCode) else { return .failure(httpFailure(status: http.statusCode, data: data)) }
            guard !data.isEmpty, (http.value(forHTTPHeaderField: "Content-Type") ?? "audio").lowercased().contains("audio") else {
                return .failure(Failure(message: "ElevenLabs no devolvió audio.", fatal: false))
            }
            return .success(data)
        } catch {
            return .failure(failure(for: error))
        }
    }

    static func fetchVoices() async -> Result<[CloudVoiceInfo], Failure> {
        guard let url = ElevenLabsProtocol.voicesURL, let request = authorized(url, method: "GET") else {
            return .failure(Failure(message: "Primero guarda tu clave de ElevenLabs.", fatal: true))
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(Failure(message: "Respuesta no válida de ElevenLabs.", fatal: false)) }
            guard (200..<300).contains(http.statusCode) else { return .failure(httpFailure(status: http.statusCode, data: data)) }
            return .success(ElevenLabsProtocol.parseVoices(data))
        } catch {
            return .failure(failure(for: error))
        }
    }
}

/// Reproduce un audio (mp3) y avisa al terminar. Emite un pulso periódico para animar el núcleo mientras suena.
@MainActor
final class CloudAudioPlayer: NSObject, AVAudioPlayerDelegate {
    var onTick: (() -> Void)?
    private var player: AVAudioPlayer?
    private var playerID: ObjectIdentifier?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timer: Timer?

    func play(_ data: Data, volume: Float) async -> Bool {
        guard let player = try? AVAudioPlayer(data: data) else { return false }
        player.delegate = self
        player.volume = volume
        guard player.prepareToPlay(), player.play() else { return false }
        self.player = player
        self.playerID = ObjectIdentifier(player)
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick?() }
        }
        return await withCheckedContinuation { continuation in self.continuation = continuation }
    }

    func stop() {
        player?.stop()
        finish(false)
    }

    private func finish(_ success: Bool) {
        timer?.invalidate()
        timer = nil
        player = nil
        playerID = nil
        let pending = continuation
        continuation = nil
        pending?.resume(returning: success)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in if self.playerID == id { self.finish(flag) } }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in if self.playerID == id { self.finish(false) } }
    }
}
