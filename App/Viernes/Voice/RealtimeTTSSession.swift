import Foundation
import ViernesCore

/// Una conexión WebSocket al Text-to-Speech de ElevenLabs para UN turno de habla: se le envía el texto por fragmentos mientras el
/// modelo escribe y devuelve audio PCM por streaming. ⚠️ El texto que Viernes dice SALE del teléfono hacia ElevenLabs (nunca el audio
/// del micrófono). La clave va solo en la cabecera `xi-api-key`; vive en el Llavero.
///
/// El audio se entrega por `onAudio` EN ORDEN y sin saltar de hilo (la recepción es secuencial); los hitos poco frecuentes
/// (`final`, fallo) van por `onTerminal`, una sola vez. `cancel()` cierra sin avisar.
final class RealtimeTTSSession: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum Terminal {
        case final
        case failure(message: String, fatal: Bool)
    }

    private let url: URL
    private let apiKey: String
    private let initialMessage: String
    private let onAudio: (Data) -> Void
    private let onTerminal: (Terminal) -> Void

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var finished = false
    private var spoken = 0
    private var audioChunks = 0

    init(url: URL, apiKey: String, initialMessage: String, onAudio: @escaping (Data) -> Void, onTerminal: @escaping (Terminal) -> Void) {
        self.url = url
        self.apiKey = apiKey
        self.initialMessage = initialMessage
        self.onAudio = onAudio
        self.onTerminal = onTerminal
        super.init()
    }

    /// Caracteres del texto de entrada que ya son audio (según la alineación que devuelve el servidor).
    var spokenCharacters: Int { lock.withLock { spoken } }
    /// Trozos de audio recibidos (0 = todavía no sonó nada de esta conexión).
    var receivedAudioChunks: Int { lock.withLock { audioChunks } }

    func start() {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 15
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        lock.withLock {
            self.session = session
            self.task = task
        }
        task.resume()
        task.send(.string(initialMessage)) { [weak self] error in
            if let error = error { self?.fail(error) }
        }
        receiveNext()
    }

    func send(text: String) {
        guard let task = lock.withLock({ finished ? nil : self.task }) else { return }
        task.send(.string(ElevenLabsRealtime.textMessage(text))) { [weak self] error in
            if let error = error { self?.fail(error) }
        }
    }

    /// Ya no habrá más texto: el servidor genera lo que quede, manda `isFinal` y cierra.
    func finishText() {
        guard let task = lock.withLock({ finished ? nil : self.task }) else { return }
        task.send(.string(ElevenLabsRealtime.closeMessage)) { [weak self] error in
            if let error = error { self?.fail(error) }
        }
    }

    /// Cierra la conexión sin avisar (interrupción del usuario, turno nuevo).
    func cancel() {
        _ = markFinished()
        teardown()
    }

    // MARK: Interno

    private func receiveNext() {
        guard let task = lock.withLock({ finished ? nil : self.task }) else { return }
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.fail(error)
            case .success(let message):
                switch message {
                case .string(let text): self.handle(text)
                case .data(let data): if let text = String(data: data, encoding: .utf8) { self.handle(text) }
                @unknown default: break
                }
                self.receiveNext()
            }
        }
    }

    private func handle(_ text: String) {
        switch ElevenLabsRealtime.parse(text) {
        case .audio(let data, let characters):
            let active: Bool = lock.withLock {
                if finished { return false }
                audioChunks += 1
                spoken += characters
                return true
            }
            if active { onAudio(data) }
        case .final:
            if markFinished() {
                onTerminal(.final)
                teardown()
            }
        case .error(let message, let fatal):
            if markFinished() {
                onTerminal(.failure(message: message, fatal: fatal))
                teardown()
            }
        case .ignore:
            break
        }
    }

    private func fail(_ error: Error) {
        guard markFinished() else { return }
        var message = "Se cortó la conexión con ElevenLabs."
        var fatal = false
        if let response = lock.withLock({ task?.response }) as? HTTPURLResponse, !(200..<300).contains(response.statusCode), response.statusCode != 101 {
            let failure = ElevenLabsRealtime.handshakeFailure(status: response.statusCode)
            message = failure.message
            fatal = failure.fatal
        } else if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: message = "Sin conexión: hablo con la voz de Apple."
            case .timedOut: message = "ElevenLabs tardó demasiado: hablo con la voz de Apple."
            default: break
            }
        }
        onTerminal(.failure(message: message, fatal: fatal))
        teardown()
    }

    /// `true` solo la primera vez: el evento terminal se entrega una única vez.
    private func markFinished() -> Bool {
        lock.withLock {
            if finished { return false }
            finished = true
            return true
        }
    }

    private func teardown() {
        let (task, session): (URLSessionWebSocketTask?, URLSession?) = lock.withLock {
            let pair = (self.task, self.session)
            self.task = nil
            self.session = nil
            return pair
        }
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        // Un cierre sin `isFinal` es un corte: se avisa una vez (si ya se entregó el final o se canceló, no pasa nada).
        if markFinished() {
            onTerminal(.failure(message: "ElevenLabs cerró la conexión antes de terminar.", fatal: false))
            teardown()
        }
    }
}
