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

/// Una frase dictada: el texto del reconocedor, su ficha de diagnóstico y, SOLO si la transcripción en la nube está activada
/// y consentida, el audio de la frase (WAV de 16 kHz en la carpeta temporal; quien lo reciba debe borrarlo).
struct ListenerOutcome {
    var text: String
    var record: RecognitionRecord
    var audioURL: URL?
}

private final class WeakListener: @unchecked Sendable {
    weak var value: SpeechListener?
}

/// Copia el audio de la frase a un WAV de 16 kHz mono (≈ 32 KB por segundo) para la transcripción en la nube.
/// Solo se crea cuando el usuario la activó y consintió, y únicamente en el modo de pulsar para hablar.
private final class AudioCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let outFormat: AVAudioFormat
    private var file: AVAudioFile?
    private var bytes = 0
    private var stopped = false
    let url: URL

    init?(inputFormat: AVAudioFormat) {
        guard let out = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: out) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("viernes-dictado-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true) else { return nil }
        self.converter = converter
        self.outFormat = out
        self.file = file
        self.url = url
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, let file = file, bytes < GroqWhisper.maxAudioBytes else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return }
        bytes += Int(out.frameLength) * 2
        try? file.write(from: out)
    }

    /// Cierra el archivo. Devuelve la ruta si se grabó algo.
    func finish() -> URL? {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        file = nil
        return bytes > 0 ? url : nil
    }

    /// Cierra y BORRA el archivo.
    func discard() {
        _ = finish()
        try? FileManager.default.removeItem(at: url)
    }

    /// Borra restos de capturas de sesiones anteriores (p. ej. si la app se cerró a mitad de una frase).
    static func purgeStale() {
        let directory = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("viernes-dictado-") { try? FileManager.default.removeItem(at: file) }
    }
}

/// Captura de micrófono + reconocimiento de voz (framework Speech, en el dispositivo siempre que sea posible).
/// El micrófono SOLO está abierto entre `start` y `stop`/fin de frase, y la UI muestra un indicador mientras tanto.
@MainActor
final class SpeechListener {
    enum Mode { case command, wakeWord }

    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFinal: ((ListenerOutcome) -> Void)?
    var onWake: ((WakeWordMatcher.Match) -> Void)?
    var onError: ((String) -> Void)?
    /// Ficha de diagnóstico de un fallo (no llega por `onFinal`).
    var onDiagnostic: ((RecognitionRecord) -> Void)?
    /// Una interrupción (llamada, Siri) terminó: la escucha pasiva puede volver.
    var onInterruptionEnded: (() -> Void)?

    // Ajustes que la app fija ANTES de `start`.
    var contextualStrings: [String] = []
    var endSilenceSeconds: Double = 1.8
    var preferBuiltInMic = false
    /// Guardar el audio de la frase para la transcripción en la nube (solo con consentimiento; solo modo de pulsar para hablar).
    var captureAudioForCloud = false

    private(set) var isRunning = false
    private(set) var mode: Mode = .command
    private(set) var usingOnDevice = true

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var detector = SilenceDetector()
    private var startedAt = Date()
    private var sessionStartedAt = Date()
    private var latestText = ""
    private var completed = false
    private var finishing = false
    private var finishTimeoutTask: Task<Void, Never>?
    private var rotationTask: Task<Void, Never>?
    private let matcher = WakeWordMatcher()
    private let box = WeakListener()
    private var observers: [NSObjectProtocol] = []

    /// Identifica la sesión de reconocimiento vigente: los callbacks tardíos de una sesión ya cerrada se ignoran.
    private var sessionID = 0
    private var tapInstalled = false
    private var currentLocaleID = "es-CO"
    private var recognizerLocaleID = "es-CO"
    private var allowServerFallback = false

    // Para la ficha de diagnóstico de cada frase.
    private var partialCount = 0
    private var lastConfidence: Double?
    private var lastPartialChange = Date.distantPast
    private var endReason: RecognitionRecord.EndReason?
    private var retryCount = 0
    private var interrupted = false
    private var startedFromWake = false
    private var inputDescription: String?
    private var capture: AudioCapture?

    init() {
        box.value = self
        AudioCapture.purgeStale()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in self?.handleInterruption(rawType: rawType) }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleConfigurationChange() }
        })
    }

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
        retryCount = 0
        try startSession(mode: mode, localeID: localeID, allowServerFallback: allowServerFallback)
    }

    private func startSession(mode: Mode, localeID: String, allowServerFallback: Bool) throws {
        guard Permissions.microphone == .granted, Permissions.speech == .granted else { throw ListenerFailure.permissionDenied }
        guard let (recognizer, onDevice) = Self.resolveRecognizer(preferred: localeID, allowServer: allowServerFallback) else {
            if SFSpeechRecognizer(locale: Locale(identifier: localeID)) == nil { throw ListenerFailure.recognizerUnavailable }
            throw ListenerFailure.onDeviceModelMissing(locale: localeID)
        }

        sessionID += 1
        let id = sessionID
        self.mode = mode
        self.currentLocaleID = localeID
        self.recognizerLocaleID = recognizer.locale.identifier
        self.allowServerFallback = allowServerFallback
        usingOnDevice = onDevice
        latestText = ""
        completed = false
        finishing = false
        detector = makeDetector()
        startedAt = Date()
        sessionStartedAt = Date()
        partialCount = 0
        lastConfidence = nil
        lastPartialChange = .distantPast
        endReason = nil
        interrupted = false
        if mode == .wakeWord { startedFromWake = true } else if retryCount == 0 { startedFromWake = false }

        do { try AudioSessionController.activateForConversation(preferBuiltInMic: preferBuiltInMic) } catch { throw ListenerFailure.audio(error.localizedDescription) }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDevice
        request.taskHint = .dictation
        request.addsPunctuation = mode == .command
        // Nombres y términos frecuentes: el reconocedor los prefiere cuando dudan dos palabras que suenan parecido.
        if !contextualStrings.isEmpty { request.contextualStrings = Array(contextualStrings.prefix(100)) }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ListenerFailure.audio("No hay micrófono disponible.") }
        inputDescription = describeInput(sampleRate: format.sampleRate)
        capture = (captureAudioForCloud && mode == .command && !startedFromWake) ? AudioCapture(inputFormat: format) : nil
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format,
                         block: Self.tapBlock(request: request, capture: capture, box: box, id: id))
        tapInstalled = true

        engine.prepare()
        do { try engine.start() } catch {
            removeTapIfInstalled()
            capture?.discard()
            capture = nil
            throw ListenerFailure.audio(error.localizedDescription)
        }
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(box, id: id))
        isRunning = true
        Diagnostics.shared.log("voz: escucha iniciada (\(mode == .command ? "botón" : "palabra"), \(recognizerLocaleID), \(onDevice ? "en el dispositivo" : "servidores de Apple"), entrada: \(inputDescription ?? "?"))")

        if mode == .wakeWord {
            // El reconocimiento continuo tiene límite de duración por petición: se reinicia en ventanas de 50 s.
            rotationTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 50_000_000_000)
                guard !Task.isCancelled else { return }
                self?.rotateWakeWord()
            }
        }
    }

    private func makeDetector() -> SilenceDetector {
        var configuration = SilenceDetector.Configuration()
        configuration.endSilence = min(max(endSilenceSeconds, 0.8), 3.5)
        return SilenceDetector(configuration: configuration)
    }

    private func describeInput(sampleRate: Double) -> String {
        let port = AVAudioSession.sharedInstance().currentRoute.inputs.first
        return "\(port?.portName ?? "?") (\(port?.portType.rawValue ?? "?")) \(Int(sampleRate)) Hz"
    }

    /// Detiene todo y libera el micrófono SIN disparar `onFinal`.
    func stop() {
        teardown()
        completed = true
    }

    /// Cierra la frase actual (p. ej. el usuario volvió a pulsar el botón): entrega lo transcrito hasta ahora.
    func finishNow() {
        guard isRunning, mode == .command, !finishing else { return }
        beginFinishing(reason: .userTap)
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
        capture?.discard()                    // si nadie lo reclamó, el audio se borra
        capture = nil
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
        detector = makeDetector()
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

    private func beginFinishing(reason: RecognitionRecord.EndReason) {
        finishing = true
        endReason = reason
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

    private func makeOutcome(text: String, reason: RecognitionRecord.EndReason, error: String? = nil) -> ListenerOutcome {
        let audio = capture?.finish()
        if text.isEmpty { capture?.discard() }
        capture = nil
        let record = RecognitionRecord(
            locale: recognizerLocaleID, onDevice: usingOnDevice, mode: startedFromWake ? "palabra" : "botón",
            duration: Date().timeIntervalSince(startedAt), endReason: reason, partialCount: partialCount, raw: text,
            confidence: lastConfidence, error: error, retried: retryCount > 0, input: inputDescription, interrupted: interrupted)
        return ListenerOutcome(text: text, record: record, audioURL: text.isEmpty ? nil : audio)
    }

    private func complete() {
        guard !completed else { return }
        completed = true
        let text = latestText.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = makeOutcome(text: text, reason: endReason ?? .recognizerFinal)
        teardown()
        onFinal?(outcome)
    }

    /// Un fallo que no se puede recuperar: se deja la ficha para el diagnóstico y se avisa al usuario.
    private func fail(_ message: String, detail: String) {
        completed = true
        let outcome = makeOutcome(text: "", reason: .error, error: detail)
        teardown()
        Diagnostics.shared.log("voz: error → \(detail)")
        onDiagnostic?(outcome.record)
        onError?(message)
    }

    /// El reconocedor falló sin haber entregado texto: se reabre UNA vez antes de molestar al usuario.
    private func retryRecognition(detail: String) {
        Diagnostics.shared.log("voz: error del reconocedor (\(detail)); reinicio el reconocimiento una vez")
        let locale = currentLocaleID, server = allowServerFallback, currentMode = mode
        let attempts = retryCount + 1
        teardown()
        completed = false
        retryCount = attempts
        do {
            try startSession(mode: currentMode, localeID: locale, allowServerFallback: server)
        } catch {
            fail(error.localizedDescription, detail: "reintento: \(error.localizedDescription)")
        }
    }

    // MARK: Interrupciones del audio

    private func handleInterruption(rawType: UInt?) {
        guard let rawType = rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            guard isRunning else { return }
            interrupted = true
            Diagnostics.shared.log("voz: interrupción del audio (llamada, Siri u otra app)")
            if mode == .command, !finishing {
                beginFinishing(reason: .silence)          // se usa lo transcrito hasta ahora
            } else if mode == .wakeWord {
                teardown()
                completed = true
            }
        case .ended:
            onInterruptionEnded?()
        @unknown default:
            break
        }
    }

    /// Cambió la ruta o el formato del audio (se conectaron o quitaron audífonos): el motor se detiene solo.
    private func handleConfigurationChange() {
        guard isRunning else { return }
        if Date().timeIntervalSince(sessionStartedAt) < 0.8 {
            // Aviso normal justo al arrancar (la sesión cambia de categoría): solo se asegura de que el motor siga en marcha.
            if !engine.isRunning { try? engine.start() }
            return
        }
        interrupted = true
        Diagnostics.shared.log("voz: cambió la configuración del audio (audífonos o ruta)")
        if mode == .command, !finishing {
            beginFinishing(reason: .silence)
        } else if mode == .wakeWord {
            rotateWakeWord()
        }
    }

    // MARK: Resultados

    fileprivate func handleLevel(id: Int, _ levelDB: Float) {
        guard id == sessionID, isRunning else { return }
        onLevel?(min(max((levelDB + 60) / 45, 0), 1))
        guard mode == .command, !finishing else { return }
        let time = Date().timeIntervalSince(startedAt)
        switch detector.process(levelDB: levelDB, at: time) {
        case .keepListening: break
        case .endOfUtterance:
            // Si el reconocedor aún está añadiendo palabras (va retrasado respecto al audio), se espera un poco más.
            if Date().timeIntervalSince(lastPartialChange) < 0.7 { break }
            beginFinishing(reason: .silence)
        case .maxDurationReached:
            beginFinishing(reason: .maxDuration)
        case .noSpeech:
            completed = true
            let outcome = makeOutcome(text: "", reason: .noSpeech)
            teardown()
            onFinal?(outcome)
        }
    }

    fileprivate func handleResult(id: Int, text: String?, isFinal: Bool, confidence: Double?, errorText: String?, errorDomain: String?, errorCode: Int?) {
        guard id == sessionID, isRunning || finishing else { return }
        if let text = text, !text.isEmpty {
            if text != latestText {
                partialCount += 1
                lastPartialChange = Date()
            }
            latestText = text
            lastConfidence = confidence
            onPartial?(text)
            if mode == .wakeWord, let match = matcher.match(in: text) {
                startedFromWake = true
                promoteToCommand()
                onWake?(match)
                return
            }
        }
        if mode == .command {
            if isFinal { complete(); return }
            if let errorText = errorText {
                let domain = errorDomain ?? ""
                let code = errorCode ?? 0
                switch SpeechErrorPolicy.classify(domain: domain, code: code, hasText: !latestText.isEmpty) {
                case .benign:
                    complete()
                case .retry:
                    if retryCount < 1, !finishing { retryRecognition(detail: SpeechErrorPolicy.describe(domain: domain, code: code, message: errorText)) }
                    else { fail(errorText, detail: SpeechErrorPolicy.describe(domain: domain, code: code, message: errorText)) }
                case .fatal(let message):
                    fail(message, detail: SpeechErrorPolicy.describe(domain: domain, code: code, message: errorText))
                }
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

    nonisolated private static func tapBlock(request: SFSpeechAudioBufferRecognitionRequest, capture: AudioCapture?, box: WeakListener, id: Int) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
            capture?.append(buffer)
            let level = levelDB(buffer)
            Task { @MainActor in box.value?.handleLevel(id: id, level) }
        }
    }

    nonisolated private static func resultHandler(_ box: WeakListener, id: Int) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let segments = result?.bestTranscription.segments ?? []
            let confidence: Double? = segments.isEmpty ? nil : Double(segments.map(\.confidence).reduce(0, +)) / Double(segments.count)
            let errorText = error?.localizedDescription
            let nsError = error as NSError?
            let errorDomain = nsError?.domain
            let errorCode = nsError?.code
            Task { @MainActor in
                box.value?.handleResult(id: id, text: text, isFinal: isFinal, confidence: confidence,
                                        errorText: errorText, errorDomain: errorDomain, errorCode: errorCode)
            }
        }
    }
}
