import AVFoundation
import ViernesCore

/// Voz de Viernes. Coordina CADA TURNO de habla, desde que el modelo empieza a escribir hasta que suena la última palabra:
///
/// - **Tiempo real (ElevenLabs por WebSocket)**: el texto se corta en unidades naturales (`SpeechSegmenter`) y se envía a la
///   conexión según se genera; el audio PCM llega por streaming y suena de forma continua (`RealtimePCMPlayer`). Se empieza a
///   hablar sin esperar al final de la respuesta.
/// - **Por frases (ElevenLabs por HTTP)**: el envío anterior, una petición por frase. Solo si el usuario apaga el tiempo real.
/// - **Voz del sistema (`AVSpeechSynthesizer`)**: sin red. También es el respaldo si la nube falla: lo que falte se dice con ella,
///   sin repetir lo ya dicho y sin solaparse.
///
/// Cada turno tiene un identificador (`VoiceTurnLedger`): interrumpir lo cancela y todo lo que llegue después de ese turno
/// (fragmentos, audio, eventos de red) se descarta. Mide cada turno (`VoiceTurnRecorder`) para saber DÓNDE se pierde el tiempo.
/// Para una voz del sistema más natural, descarga voces «Mejoradas» o «Premium» en Ajustes › Accesibilidad › Contenido hablado.
@MainActor
final class SpeechSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    var onStart: (() -> Void)?
    var onFinish: (() -> Void)?               // terminó el turno (habló todo o fue interrumpido)
    var onWord: (() -> Void)?                 // pulso: anima el núcleo
    /// La voz neuronal falló y se usó la del sistema (se avisa una vez por configuración).
    var onCloudError: ((String) -> Void)?
    /// Un turno terminó: sus métricas (para el informe de rendimiento de voz).
    var onTurnMetrics: ((VoiceTurnMetrics) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private let player = RealtimePCMPlayer()

    private enum Mode {
        case realtime, rest, system
        var label: String {
            switch self {
            case .realtime: return "tiempo real"
            case .rest: return "por frases (HTTP)"
            case .system: return "voz del sistema"
            }
        }
    }

    /// Un turno en curso. Es una clase para poder pasarla a las funciones sin copiar su estado.
    private final class Turn {
        let id: UInt64
        let mode: Mode
        let cloud: ElevenLabsSettings?
        let speed: Double
        var segmenter = SpeechSegmenter()
        var recorder: VoiceTurnRecorder
        var session: RealtimeTTSSession?
        var connection = 0
        var playerGeneration = 0
        var textEnded = false
        var sessionFinal = false
        var playerDrained = false
        var fellBack = false
        var reconnects = 0
        var speakingStarted = false
        var heldSystem: [SpeechChunk] = []
        init(id: UInt64, mode: Mode, cloud: ElevenLabsSettings?, speed: Double, recorder: VoiceTurnRecorder) {
            self.id = id
            self.mode = mode
            self.cloud = cloud
            self.speed = speed
            self.recorder = recorder
        }
    }

    private var turn: Turn?
    private var ledger = VoiceTurnLedger()
    private var lastPulse = Date.distantPast

    // Voz neuronal por frases (HTTP): cola de frases con un máximo de 2 descargas simultáneas (límite del plan gratuito).
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
    /// Frases vivas de la voz del sistema (encoladas o sonando). Los `didCancel` tardíos de frases ya descartadas por `stop()`
    /// se ignoran porque su identificador ya no está aquí.
    private var live = Set<ObjectIdentifier>()
    private(set) var isSpeaking = false
    /// Hay un turno en curso o frases encoladas o sonando (incluye el instante antes de que empiece la primera).
    var isBusy: Bool { turn != nil || isSpeaking || !live.isEmpty || !cloudJobs.isEmpty || cloudRunner != nil }
    private var settings: VoiceSettings = .default

    override init() {
        super.init()
        synthesizer.delegate = self
        wirePlayer()
        AudioSessionWatcher.shared.onEvent = { [weak self] event in self?.audioSessionEvent(event) }
    }

    private var uptime: Double { ProcessInfo.processInfo.systemUptime }

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

    // MARK: Ajustes

    func apply(_ settings: VoiceSettings) {
        self.settings = settings.sanitized()
        cloudSuspended = false
        cloudAnnounced = false
    }

    private var cloudActive: Bool {
        guard let cloud = settings.elevenLabs, cloud.isUsable, !cloudSuspended else { return false }
        return CloudKeyStore.hasKey(providerID: ElevenLabsProtocol.keyProviderID)
    }

    // MARK: Turnos

    /// Empieza un turno de habla. Si había uno en curso, se cancela sin avisar (el nuevo lo sustituye).
    func beginTurn() {
        if turn != nil || isBusy { cancelEverything(outcome: .cancelled, notify: false) }
        try? AudioSessionController.ensureConversationActive()      // una vez por turno, no por frase
        let id = ledger.beginTurn()
        var mode = Mode.system
        var cloud: ElevenLabsSettings?
        if cloudActive, let configured = settings.elevenLabs {
            cloud = configured
            mode = configured.realtimeEnabled ? .realtime : .rest
        }
        let recorder = VoiceTurnRecorder(turn: id, backend: mode.label, startedAt: uptime)
        let created = Turn(id: id, mode: mode, cloud: cloud, speed: ElevenLabsProtocol.speed(forRate: settings.rate), recorder: recorder)
        turn = created
        if mode == .realtime { created.playerGeneration = player.beginTurn() }
    }

    /// Texto nuevo del modelo (un delta). Se corta en fragmentos y se habla según se va completando.
    func feed(_ delta: String) {
        guard let current = turn, !current.textEnded, !delta.isEmpty else { return }
        current.recorder.firstToken(at: uptime)
        for segment in current.segmenter.feed(delta) { route(segment, in: current) }
    }

    /// El modelo terminó. `flush`: decir también lo que quede sin cerrar (falso si la respuesta falló).
    func endTurn(flush: Bool = true) {
        guard let current = turn, !current.textEnded else { return }
        if flush { for segment in current.segmenter.flush() { route(segment, in: current) } }
        current.textEnded = true
        _ = ledger.endText(turn: current.id)
        if current.mode == .realtime, !current.fellBack {
            if let session = current.session { session.finishText() } else { player.finishInput(generation: current.playerGeneration) }
        }
        completeIfDone(current)
    }

    /// Dice un texto completo (repetir una respuesta, muestras de voz): un turno de una sola vez.
    func enqueue(_ text: String) {
        beginTurn()
        feed(text)
        endTurn()
    }

    /// Interrumpe AL INSTANTE y descarta todo lo pendiente.
    func stop() {
        guard isBusy else { return }
        cancelEverything(outcome: .interrupted, notify: true)
    }

    // MARK: Encaminar fragmentos

    private func route(_ segment: SpeechSegment, in current: Turn) {
        switch ledger.accept(segment, turn: current.id) {
        case .accepted: break
        case .duplicate, .outOfOrder, .afterEnd:
            current.recorder.discarded()
            return
        case .stale, .cancelled:
            return
        }
        current.recorder.segmentReady(at: uptime, characters: segment.text.count)
        let chunk = SpeechChunk(text: segment.text, pauseAfter: segment.pauseAfter)
        switch current.mode {
        case .realtime:
            if current.fellBack { sendToSystem(chunk, in: current) } else { sendRealtime(chunk.text, in: current) }
        case .rest:
            if let cloud = current.cloud {
                cloudJobs.append(CloudJob(chunk: chunk, settings: cloud, speed: current.speed))
                prefetchCloud()
                startCloudRunner()
            }
        case .system:
            enqueueSystem([chunk])
        }
    }

    // MARK: Tiempo real (WebSocket)

    private func sendRealtime(_ text: String, in current: Turn) {
        if current.session == nil, !openSession(for: current) { return }
        current.session?.send(text: text)
    }

    /// Abre la conexión del turno. `false` si no se pudo (falta la clave o la voz): entonces se habla con la voz del sistema.
    @discardableResult
    private func openSession(for current: Turn) -> Bool {
        guard let cloud = current.cloud,
              let key = CloudKeyStore.read(providerID: ElevenLabsProtocol.keyProviderID),
              let url = ElevenLabsRealtime.websocketURL(voiceID: cloud.voiceID, modelID: cloud.modelID) else {
            fallBack(current, message: "Falta la clave o la voz de ElevenLabs. Revisa Voz y habla › Voz neuronal.", fatal: true)
            return false
        }
        current.connection += 1
        let connection = current.connection
        let turnID = current.id
        let generation = current.playerGeneration
        let player = self.player
        let session = RealtimeTTSSession(
            url: url, apiKey: key, initialMessage: ElevenLabsRealtime.initialMessage(speed: current.speed),
            onAudio: { data in player.append(data, generation: generation) },       // directo y en orden, sin pasar por el hilo principal
            onTerminal: { [weak self] terminal in
                Task { @MainActor in self?.sessionEnded(terminal, turnID: turnID, connection: connection) }
            })
        current.session = session
        session.start()
        return true
    }

    private func sessionEnded(_ terminal: RealtimeTTSSession.Terminal, turnID: UInt64, connection: Int) {
        guard let current = turn, current.id == turnID, current.connection == connection, ledger.isCurrent(turnID) else { return }
        switch terminal {
        case .final:
            current.sessionFinal = true
            player.finishInput(generation: current.playerGeneration)
        case .failure(let message, let fatal):
            current.recorder.connectionError()
            Diagnostics.shared.log("voz: la conexión de ElevenLabs falló (\(fatal ? "fatal" : "recuperable")): \(message)")
            recover(current, message: message, fatal: fatal)
        }
    }

    /// La conexión se cortó a medias: se reconecta UNA vez retomando solo lo que no se había dicho; si no, voz del sistema.
    private func recover(_ current: Turn, message: String, fatal: Bool) {
        let session = current.session
        // Sin la alineación del servidor no se sabe hasta dónde llegó el audio: antes que repetir lo dicho, se descarta lo
        // enviado y no resuelto (nunca se repite una frase).
        let knowsProgress = (session?.spokenCharacters ?? 0) > 0 || (session?.receivedAudioChunks ?? 0) == 0
        ledger.recordSpoken(characters: session?.spokenCharacters ?? 0, turn: current.id)
        let pending = knowsProgress ? ledger.remainingText() : ""
        if !knowsProgress { current.recorder.discarded() }
        session?.cancel()
        current.session = nil

        if !fatal, current.reconnects < 1 {
            current.reconnects += 1
            current.recorder.reconnected()
            ledger.restartSession(carrying: pending)
            if !pending.isEmpty {
                // La conexión nueva retoma lo pendiente; si el texto ya terminó, también se cierra.
                if openSession(for: current) {
                    current.session?.send(text: pending)
                    if current.textEnded { current.session?.finishText() }
                }
            } else if current.textEnded {
                player.finishInput(generation: current.playerGeneration)       // no queda nada por decir
            }
            // Sin nada pendiente y con el texto aún abierto, la conexión se abre con el próximo fragmento.
            return
        }
        fallBack(current, message: message, fatal: fatal, pending: pending)
    }

    /// Pasa el resto del turno a la voz del sistema. Lo que ya esté en el colchón de audio termina de sonar antes, para no solaparse.
    private func fallBack(_ current: Turn, message: String, fatal: Bool, pending: String? = nil) {
        guard !current.fellBack else { return }
        current.fellBack = true
        current.recorder.fellBack()
        if fatal { cloudSuspended = true }
        announceCloudProblem(message)
        current.session?.cancel()
        current.session = nil
        let tail = pending ?? ledger.remainingText()
        if !tail.isEmpty { current.heldSystem.append(contentsOf: SpeechText.chunks(tail)) }
        player.finishInput(generation: current.playerGeneration)           // deja sonar lo que ya llegó y avisa al vaciarse
        if current.playerDrained { releaseHeldSystem(current) }
    }

    private func sendToSystem(_ chunk: SpeechChunk, in current: Turn) {
        if current.playerDrained { enqueueSystem([chunk]) } else { current.heldSystem.append(chunk) }
    }

    private func releaseHeldSystem(_ current: Turn) {
        let held = current.heldSystem
        current.heldSystem = []
        if !held.isEmpty { enqueueSystem(held) }
        completeIfDone(current)
    }

    private func announceCloudProblem(_ message: String) {
        guard !cloudAnnounced else { return }
        cloudAnnounced = true
        onCloudError?(message)
    }

    // MARK: Reproductor (eventos de la cola de audio)

    private func wirePlayer() {
        player.onFirstAudio = { [weak self] generation, time in
            Task { @MainActor in self?.playerStarted(generation: generation, at: time) }
        }
        player.onGap = { [weak self] generation, milliseconds in
            Task { @MainActor in
                guard let self = self, let current = self.turn, current.playerGeneration == generation else { return }
                current.recorder.gap(ms: milliseconds)
            }
        }
        player.onScheduled = { [weak self] generation, bytes, milliseconds in
            Task { @MainActor in
                guard let self = self, let current = self.turn, current.playerGeneration == generation else { return }
                current.recorder.audioScheduled(bytes: bytes, durationMs: milliseconds)
            }
        }
        player.onDrained = { [weak self] generation in
            Task { @MainActor in self?.playerDrained(generation: generation) }
        }
        player.onPulse = { [weak self] in
            Task { @MainActor in self?.pulse() }
        }
        player.onEngineReset = { [weak self] generation in
            Task { @MainActor in
                guard let self = self, let current = self.turn, current.playerGeneration == generation else { return }
                Diagnostics.shared.log("voz: cambió la ruta de audio durante la voz; se corta el turno")
                self.cancelEverything(outcome: .interrupted, notify: true)
            }
        }
        player.onFailure = { [weak self] generation, reason in
            Task { @MainActor in
                guard let self = self, let current = self.turn, current.playerGeneration == generation else { return }
                Diagnostics.shared.log("voz: no arrancó el motor de audio: \(reason)")
                current.recorder.connectionError()
                self.fallBack(current, message: "No pude abrir el audio en tiempo real: hablo con la voz de Apple.", fatal: false, pending: nil)
            }
        }
    }

    private func playerStarted(generation: Int, at time: Double) {
        guard let current = turn, current.playerGeneration == generation, current.mode == .realtime else { return }
        current.recorder.firstAudio(at: time)
        markSpeaking(current)
    }

    private func playerDrained(generation: Int) {
        guard let current = turn, current.playerGeneration == generation, current.mode == .realtime else { return }
        current.playerDrained = true
        if current.fellBack { releaseHeldSystem(current) } else { completeIfDone(current) }
    }

    private func pulse() {
        let time = Date()
        guard time.timeIntervalSince(lastPulse) > 0.06 else { return }
        lastPulse = time
        onWord?()
    }

    private func markSpeaking(_ current: Turn) {
        current.speakingStarted = true
        if !isSpeaking {
            isSpeaking = true
            onStart?()
        }
    }

    // MARK: Fin y cancelación

    /// ¿Terminó el turno? Cuando el texto se acabó y el audio de todos los caminos ya sonó.
    private func completeIfDone(_ current: Turn) {
        guard turn === current, current.textEnded else { return }
        switch current.mode {
        case .realtime:
            guard current.playerDrained, current.heldSystem.isEmpty, live.isEmpty else { return }
            if !current.fellBack, current.session != nil, !current.sessionFinal { return }
        case .rest:
            guard cloudJobs.isEmpty, cloudRunner == nil, live.isEmpty else { return }
        case .system:
            guard live.isEmpty else { return }
        }
        finishTurn(current, outcome: .completed)
    }

    private func finishTurn(_ current: Turn, outcome: VoiceTurnMetrics.Outcome) {
        guard turn === current else { return }
        current.recorder.finish(at: uptime, outcome: outcome)
        let metrics = current.recorder.metrics
        let spoke = current.speakingStarted
        turn = nil
        isSpeaking = false
        onTurnMetrics?(metrics)
        if spoke { onFinish?() }
    }

    /// Corta todo (interrupción, turno nuevo, problema de audio): silencio inmediato y turno invalidado.
    private func cancelEverything(outcome: VoiceTurnMetrics.Outcome, notify: Bool) {
        let current = turn
        let wasSpeaking = isSpeaking || current != nil
        current?.recorder.interrupted(at: uptime)
        ledger.cancel()
        current?.session?.cancel()
        current?.session = nil
        player.stop()                                      // sincrónico: cuando vuelve, no suena nada de la nube
        stopCloud()
        live.removeAll()                                   // los callbacks de cancelación que lleguen después se ignorarán
        synthesizer.stopSpeaking(at: .immediate)
        current?.recorder.silenced(at: uptime)
        if let current = current {
            current.recorder.finish(at: uptime, outcome: outcome)
            onTurnMetrics?(current.recorder.metrics)
        }
        turn = nil
        isSpeaking = false
        if notify, wasSpeaking { onFinish?() }
    }

    /// Eventos del sistema de audio que afectan a lo que se está diciendo.
    private func audioSessionEvent(_ event: AudioSessionWatcher.Event) {
        switch event {
        case .interruptionBegan, .outputLost, .mediaServicesReset:
            guard isBusy else { return }
            Diagnostics.shared.log("voz: interrupción del sistema de audio (\(event)); se detiene la voz")
            stop()
        case .interruptionEnded, .routeChanged:
            break
        }
    }

    // MARK: Voz neuronal por frases (HTTP)

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
        announceCloudProblem(failure.message)
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
                if let current = turn {
                    current.recorder.firstAudio(at: uptime)
                    markSpeaking(current)
                } else if !isSpeaking { isSpeaking = true; onStart?() }
                cloudPlayer.onTick = { [weak self] in self?.pulse() }
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
        if let current = turn { completeIfDone(current) }
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
            guard self.live.contains(id) else { return }
            if let current = self.turn {
                current.recorder.firstAudio(at: self.uptime)
                self.markSpeaking(current)
            } else if !self.isSpeaking {
                self.isSpeaking = true
                self.onStart?()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in self.pulse() }
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
        if let current = turn { completeIfDone(current) }
    }
}
