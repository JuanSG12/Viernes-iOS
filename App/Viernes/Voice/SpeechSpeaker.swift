import AVFoundation
import ViernesCore

/// Síntesis de voz con AVSpeechSynthesizer: voces locales del sistema (sin red), cola por frases, pausas e interrupción.
/// Para una voz más natural, el usuario descarga voces «Mejoradas» o «Premium» en Ajustes › Accesibilidad › Contenido hablado › Voces.
@MainActor
final class SpeechSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    var onStart: (() -> Void)?
    var onFinish: (() -> Void)?               // se vació la cola (terminó de hablar o fue interrumpida)
    var onWord: (() -> Void)?                 // pulso por palabra: anima el núcleo
    /// La voz neuronal falló y se usó la del sistema (se avisa una vez por configuración).
    var onCloudError: ((String) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()

    // Voz neuronal (ElevenLabs): cola de frases con un máximo de 2 descargas simultáneas (límite del plan gratuito).
    private struct CloudJob {
        let id = UUID()
        let chunk: SpeechChunk
        let settings: ElevenLabsSettings
        let speed: Double
    }
    private let cloudPlayer = CloudAudioPlayer()
    private var cloudJobs: [CloudJob] = []
    private var cloudFetches: [UUID: Task<Result<Data, ElevenLabsClient.Failure>, Never>] = [:]
    private var cloudRunner: Task<Void, Never>?
    private var cloudRunnerToken: UUID?
    private var cloudSuspended = false
    private var cloudAnnounced = false
    /// Frases vivas (encoladas o sonando). Los `didCancel` tardíos de frases ya descartadas por `stop()` se ignoran
    /// porque su identificador ya no está aquí.
    private var live = Set<ObjectIdentifier>()
    private(set) var isSpeaking = false
    /// Hay frases encoladas o sonando (incluye el instante antes de que empiece la primera).
    var isBusy: Bool { isSpeaking || !live.isEmpty || !cloudJobs.isEmpty || cloudRunner != nil }
    private var settings: VoiceSettings = .default

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: Voces

    static func availableVoices() -> [VoiceDescriptor] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            let quality: VoiceDescriptor.Quality
            switch voice.quality {
            case .premium: quality = .premium
            case .enhanced: quality = .enhanced
            default: quality = .standard
            }
            let gender: VoiceDescriptor.Gender
            switch voice.gender {
            case .female: gender = .female
            case .male: gender = .male
            default: gender = .unspecified
            }
            return VoiceDescriptor(identifier: voice.identifier, name: voice.name, language: voice.language, quality: quality, gender: gender)
        }
    }

    static func rankedSpanishVoices(preferredLanguage: String = "es-CO") -> [VoiceDescriptor] {
        VoiceRanker.rank(availableVoices(), preferredLanguage: preferredLanguage)
    }

    static func resolveVoice(identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier = identifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) { return voice }
        if let best = VoiceRanker.best(availableVoices()), let voice = AVSpeechSynthesisVoice(identifier: best.identifier) { return voice }
        return AVSpeechSynthesisVoice(language: "es-MX")
    }

    // MARK: Reproducción

    func apply(_ settings: VoiceSettings) {
        self.settings = settings.sanitized()
        cloudSuspended = false
        cloudAnnounced = false
    }

    private var cloudActive: Bool {
        guard let cloud = settings.elevenLabs, cloud.isUsable, !cloudSuspended else { return false }
        return CloudKeyStore.hasKey(providerID: ElevenLabsProtocol.keyProviderID)
    }

    /// Encola una frase (usado por la respuesta en streaming) o un texto completo.
    func enqueue(_ text: String) {
        let chunks = SpeechText.chunks(text)
        guard !chunks.isEmpty else { return }
        try? AudioSessionController.activateForConversation()
        if cloudActive, let cloud = settings.elevenLabs {
            let speed = ElevenLabsProtocol.speed(forRate: settings.rate)
            for chunk in chunks { cloudJobs.append(CloudJob(chunk: chunk, settings: cloud, speed: speed)) }
            prefetchCloud()
            startCloudRunner()
            return
        }
        enqueueSystem(chunks)
    }

    // MARK: Voz neuronal

    private func prefetchCloud() {
        guard !cloudSuspended else { return }
        for job in cloudJobs.prefix(2) where cloudFetches[job.id] == nil {
            let text = job.chunk.text, settings = job.settings, speed = job.speed
            cloudFetches[job.id] = Task { await ElevenLabsClient.synthesize(text: text, settings: settings, speed: speed) }
        }
    }

    private func startCloudRunner() {
        guard cloudRunner == nil else { return }
        let token = UUID()
        cloudRunnerToken = token
        cloudRunner = Task { [weak self] in await self?.runCloudQueue(token: token) }
    }

    private func handleCloudFailure(_ failure: ElevenLabsClient.Failure) {
        if failure.fatal { cloudSuspended = true }
        if !cloudAnnounced {
            cloudAnnounced = true
            onCloudError?(failure.message)
        }
    }

    private func runCloudQueue(token: UUID) async {
        while !Task.isCancelled, let job = cloudJobs.first {
            prefetchCloud()
            var audio: Data?
            if let fetch = cloudFetches[job.id] {
                switch await fetch.value {
                case .success(let data): audio = data
                case .failure(let failure): if !Task.isCancelled { handleCloudFailure(failure) }
                }
            }
            if Task.isCancelled { break }
            if cloudJobs.first?.id == job.id { cloudJobs.removeFirst() }
            cloudFetches[job.id] = nil

            if let audio = audio {
                if !isSpeaking { isSpeaking = true; onStart?() }
                cloudPlayer.onTick = { [weak self] in self?.onWord?() }
                _ = await cloudPlayer.play(audio, volume: settings.volume)
                if Task.isCancelled { break }
                let pause = job.chunk.pauseAfter * settings.pauseScale
                if pause > 0 { try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
            } else {
                // Respaldo: voz del sistema para esta frase, esperando a que termine para conservar el orden.
                enqueueSystem([job.chunk])
                while !live.isEmpty, !Task.isCancelled { try? await Task.sleep(nanoseconds: 100_000_000) }
            }
        }
        guard cloudRunnerToken == token else { return }       // stop() ya limpió y quizá arrancó otra cola
        cloudRunner = nil
        cloudRunnerToken = nil
        if isSpeaking, live.isEmpty, cloudJobs.isEmpty {
            isSpeaking = false
            onFinish?()
        }
    }

    private func stopCloud() {
        cloudRunner?.cancel()
        cloudRunner = nil
        cloudRunnerToken = nil
        for fetch in cloudFetches.values { fetch.cancel() }
        cloudFetches.removeAll()
        cloudJobs.removeAll()
        cloudPlayer.stop()
    }

    // MARK: Voz del sistema

    private func enqueueSystem(_ chunks: [SpeechChunk]) {
        let voice = Self.resolveVoice(identifier: settings.voiceIdentifier)
        for chunk in chunks {
            let utterance = AVSpeechUtterance(string: chunk.text)
            utterance.voice = voice
            utterance.rate = settings.rate
            utterance.volume = settings.volume
            utterance.pitchMultiplier = settings.pitch
            utterance.preUtteranceDelay = 0
            utterance.postUtteranceDelay = chunk.pauseAfter * settings.pauseScale
            live.insert(ObjectIdentifier(utterance))
            synthesizer.speak(utterance)
        }
    }

    /// Interrumpe al instante y vacía la cola.
    func stop() {
        guard synthesizer.isSpeaking || !live.isEmpty || !cloudJobs.isEmpty || cloudRunner != nil else { return }
        stopCloud()
        live.removeAll()                       // los callbacks de cancelación que lleguen después se ignorarán
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        onFinish?()
    }

    /// Reproduce una muestra con los ajustes dados (pantalla de voces).
    func preview(identifier: String?, settings: VoiceSettings) {
        stop()
        let original = self.settings
        var temp = settings
        temp.voiceIdentifier = identifier
        apply(temp)
        enqueue("Hola. Soy Viernes. Así sueno con esta configuración.")
        // La frase ya tomó sus ajustes al encolarse: se restauran los reales para que una muestra no los deje cambiados.
        self.settings = original
    }

    // MARK: AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.live.contains(id), !self.isSpeaking else { return }
            self.isSpeaking = true
            self.onStart?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onWord?() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }

    private func utteranceEnded(_ id: ObjectIdentifier) {
        guard live.remove(id) != nil else { return }      // ya descartada por stop(): no cuenta
        if live.isEmpty, isSpeaking {
            isSpeaking = false
            onFinish?()
        }
    }
}
