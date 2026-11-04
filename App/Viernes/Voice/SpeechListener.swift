import AVFoundation
import Speech
import ViernesCore

enum ListenerFailure: LocalizedError {
    case permissionDenied
    case recognizerUnavailable
    case onDeviceModelMissing(locale: String)
    case audio(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Faltan permisos de micrófono o reconocimiento de voz. Actívalos en Ajustes › Viernes."
        case .recognizerUnavailable:
            return "El reconocimiento de voz no está disponible ahora mismo."
        case .onDeviceModelMissing(let locale):
            return "No hay reconocimiento de voz en el dispositivo para \(locale). Descarga el idioma en Ajustes › General › Teclado › Dictado, o permite el reconocimiento de Apple por internet en Viernes › Voz."
        case .audio(let detail):
            return "Problema de audio: \(detail)"
        }
    }
}

private final class WeakListener: @unchecked Sendable {
    weak var value: SpeechListener?
}

/// Captura de micrófono + reconocimiento de voz (framework Speech, en el dispositivo siempre que sea posible).
/// El micrófono SOLO está abierto entre `start` y `stop`/fin de frase, y la UI muestra un indicador mientras tanto.
@MainActor
final class SpeechListener {
    enum Mode { case command, wakeWord }

    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFinal: ((String) -> Void)?
    var onWake: ((WakeWordMatcher.Match) -> Void)?
    var onError: ((String) -> Void)?

    private(set) var isRunning = false
    private(set) var mode: Mode = .command
    private(set) var usingOnDevice = true

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var detector = SilenceDetector()
    private var startedAt = Date()
    private var latestText = ""
    private var completed = false
    private var finishing = false
    private var finishTimeoutTask: Task<Void, Never>?
    private var rotationTask: Task<Void, Never>?
    private let matcher = WakeWordMatcher()
    private let box = WeakListener()

    /// Identifica la sesión de reconocimiento vigente: los callbacks tardíos de una sesión ya cerrada se ignoran.
    private var sessionID = 0
    private var tapInstalled = false
    private var currentLocaleID = "es-CO"
    private var allowServerFallback = false

    init() { box.value = self }

    // MARK: Control

    /// Elige la variante de español con reconocimiento EN EL DISPOSITIVO; si ninguna lo tiene y el usuario lo permitió, usa servidores de Apple.
    static func resolveRecognizer(preferred: String, allowServer: Bool) -> (SFSpeechRecognizer, onDevice: Bool)? {
        let candidates = [preferred, "es-CO", "es-MX", "es-US", "es-419", "es-ES"]
        var seen = Set<String>()
        var fallback: SFSpeechRecognizer?
        for id in candidates where seen.insert(id).inserted {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)), recognizer.isAvailable else { continue }
            if recognizer.supportsOnDeviceRecognition { return (recognizer, true) }
            if fallback == nil { fallback = recognizer }
        }
        if allowServer, let fallback = fallback { return (fallback, false) }
        return nil
    }

    func start(mode: Mode, localeID: String, allowServerFallback: Bool) throws {
        guard !isRunning else { return }
        guard Permissions.microphone == .granted, Permissions.speech == .granted else { throw ListenerFailure.permissionDenied }
        guard let (recognizer, onDevice) = Self.resolveRecognizer(preferred: localeID, allowServer: allowServerFallback) else {
            if SFSpeechRecognizer(locale: Locale(identifier: localeID)) == nil { throw ListenerFailure.recognizerUnavailable }
            throw ListenerFailure.onDeviceModelMissing(locale: localeID)
        }

        sessionID += 1
        let id = sessionID
        self.mode = mode
        self.currentLocaleID = localeID
        self.allowServerFallback = allowServerFallback
        usingOnDevice = onDevice
        latestText = ""
        completed = false
        finishing = false
        detector = SilenceDetector()
        startedAt = Date()

        do { try AudioSessionController.activateForConversation() } catch { throw ListenerFailure.audio(error.localizedDescription) }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDevice
        request.taskHint = .dictation
        request.addsPunctuation = mode == .command
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ListenerFailure.audio("No hay micrófono disponible.") }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(request: request, box: box, id: id))
        tapInstalled = true

        engine.prepare()
        do { try engine.start() } catch {
            removeTapIfInstalled()
            throw ListenerFailure.audio(error.localizedDescription)
        }
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(box, id: id))
        isRunning = true

        if mode == .wakeWord {
            // El reconocimiento continuo tiene límite de duración por petición: se reinicia en ventanas de 50 s.
            rotationTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 50_000_000_000)
                guard !Task.isCancelled else { return }
                self?.rotateWakeWord()
            }
        }
    }

    /// Detiene todo y libera el micrófono SIN disparar `onFinal`.
    func stop() {
        teardown()
        completed = true
    }

    /// Cierra la frase actual (p. ej. el usuario volvió a pulsar el botón): entrega lo transcrito hasta ahora.
    func finishNow() {
        guard isRunning, mode == .command, !finishing else { return }
        beginFinishing()
    }

    // MARK: Internos

    private func teardown() {
        sessionID += 1                       // invalida cualquier callback pendiente de la sesión que se cierra
        finishTimeoutTask?.cancel()
        rotationTask?.cancel()
        finishTimeoutTask = nil
        rotationTask = nil
        if engine.isRunning { engine.stop() }
        removeTapIfInstalled()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRunning = false
        onLevel?(0)
    }

    /// Acceder a `engine.inputNode` sin haber pedido el micrófono puede disparar el aviso de permiso del sistema (y un error
    /// de audio en simuladores). Solo se toca si este objeto instaló antes un tap, es decir, si el usuario ya activó la escucha.
    private func removeTapIfInstalled() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    /// Al oír «Viernes» la MISMA sesión de reconocimiento pasa a modo comando: no se pierde lo que se diga a continuación.
    private func promoteToCommand() {
        rotationTask?.cancel()
        rotationTask = nil
        mode = .command
        detector = SilenceDetector()
        startedAt = Date()
    }

    private func rotateWakeWord() {
        guard isRunning, mode == .wakeWord else { return }
        let locale = currentLocaleID, server = allowServerFallback
        teardown()
        completed = false
        do { try start(mode: .wakeWord, localeID: locale, allowServerFallback: server) }
        catch { onError?(error.localizedDescription) }
    }

    private func beginFinishing() {
        finishing = true
        removeTapIfInstalled()
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        onLevel?(0)
        // Si el reconocedor no entrega resultado final a tiempo, se usa el último parcial.
        finishTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            self?.complete()
        }
    }

    private func complete() {
        guard !completed else { return }
        completed = true
        let text = latestText.trimmingCharacters(in: .whitespacesAndNewlines)
        teardown()
        onFinal?(text)
    }

    fileprivate func handleLevel(id: Int, _ levelDB: Float) {
        guard id == sessionID, isRunning else { return }
        onLevel?(min(max((levelDB + 60) / 45, 0), 1))
        guard mode == .command, !finishing else { return }
        let time = Date().timeIntervalSince(startedAt)
        switch detector.process(levelDB: levelDB, at: time) {
        case .keepListening: break
        case .endOfUtterance, .maxDurationReached: beginFinishing()
        case .noSpeech:
            completed = true
            teardown()
            onFinal?("")
        }
    }

    fileprivate func handleResult(id: Int, text: String?, isFinal: Bool, errorText: String?, errorCode: Int?) {
        guard id == sessionID, isRunning || finishing else { return }
        if let text = text, !text.isEmpty {
            latestText = text
            onPartial?(text)
            if mode == .wakeWord, let match = matcher.match(in: text) {
                promoteToCommand()
                onWake?(match)
                return
            }
        }
        if mode == .command {
            if isFinal { complete(); return }
            if let errorText = errorText {
                let benign = [1110, 301].contains(errorCode ?? 0)     // "no se detectó voz" / "cancelado"
                if !latestText.isEmpty || benign { complete() }
                else { completed = true; teardown(); onError?(errorText) }
            }
        } else if isFinal || errorText != nil {
            rotateWakeWord()           // la ventana terminó sola: se vuelve a abrir mientras el modo siga activo
        }
    }

    // MARK: Bloques fuera del actor (los llama el hilo de audio / el reconocedor)

    nonisolated private static func levelDB(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return -100 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return -100 }
        var sum: Float = 0
        for index in 0..<count { sum += channel[index] * channel[index] }
        let rms = (sum / Float(count)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -100
    }

    nonisolated private static func tapBlock(request: SFSpeechAudioBufferRecognitionRequest, box: WeakListener, id: Int) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
            let level = levelDB(buffer)
            Task { @MainActor in box.value?.handleLevel(id: id, level) }
        }
    }

    nonisolated private static func resultHandler(_ box: WeakListener, id: Int) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorText = error?.localizedDescription
            let errorCode = (error as NSError?)?.code
            Task { @MainActor in
                box.value?.handleResult(id: id, text: text, isFinal: isFinal, errorText: errorText, errorCode: errorCode)
            }
        }
    }
}
