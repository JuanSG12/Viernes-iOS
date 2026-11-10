import AVFoundation
import ViernesCore

/// Reproduce audio PCM (16 bits, 24 kHz, mono) que llega por trozos de forma CONTINUA: un único `AVAudioEngine` con un
/// `AVAudioPlayerNode` al que se le programan los trozos según llegan, con un colchón (`JitterBufferPolicy`) para que las llegadas
/// irregulares de la red no se oigan como cortes. Todo ocurre en una cola propia, fuera del hilo principal (la interfaz, que
/// dibuja el núcleo 3D a 60 fps, no puede retrasar el audio).
///
/// Cada turno tiene una «generación»: `stop()` o un turno nuevo la incrementan y todo lo que llegue con una generación vieja se
/// descarta, así nada de un turno anterior suena en el siguiente. Las llamadas a los `on…` ocurren en la cola del reproductor.
final class RealtimePCMPlayer: @unchecked Sendable {
    /// (generación, instante en `systemUptime`) — sonó el primer audio del turno.
    var onFirstAudio: ((Int, Double) -> Void)?
    /// (generación, milisegundos) — el audio se acabó antes de que llegara más y volvió a sonar tras un silencio.
    var onGap: ((Int, Double) -> Void)?
    /// (generación, bytes, milisegundos) — se programó un trozo de audio.
    var onScheduled: ((Int, Int, Double) -> Void)?
    /// (generación) — todo el audio del turno terminó de sonar (o no había nada que sonar).
    var onDrained: ((Int) -> Void)?
    /// Pulso periódico mientras suena (anima el núcleo).
    var onPulse: (() -> Void)?
    /// (generación) — el sistema reconfiguró el audio (audífonos, ruta) y se perdió lo programado: hay que cortar el turno.
    var onEngineReset: ((Int) -> Void)?
    /// (generación, motivo) — no se pudo arrancar el motor de audio.
    var onFailure: ((Int, String) -> Void)?

    private let queue = DispatchQueue(label: "com.example.viernes.voice.player", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let sampleRate = ElevenLabsRealtime.sampleRate
    private let policy = JitterBufferPolicy()
    private var graphReady = false
    private var engineStartedAt = -100.0
    private var observer: NSObjectProtocol?

    // Estado del turno vigente: solo se toca dentro de `queue`.
    private var generation = 0
    private var decoder = PCMStreamDecoder()
    private var scheduledFrames = 0
    private var playedFrames = 0
    private var inputFinished = false
    private var started = false
    private var playing = false
    private var heldSince: Double?
    private var holdTimerArmed = false
    private var gapStartedAt: Double?
    private var drained = true
    private var pulsing = false

    init() {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: ElevenLabsRealtime.sampleRate, channels: 1, interleaved: false)!
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { self?.handleConfigurationChange() }
        }
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    // MARK: Control (se puede llamar desde cualquier hilo)

    /// Prepara un turno nuevo y devuelve su generación. El motor de audio arranca en la cola del reproductor.
    func beginTurn() -> Int {
        let gen: Int = queue.sync {
            generation += 1
            resetTurnState()
            drained = false
            return generation
        }
        queue.async { [weak self] in self?.startEngineIfNeeded(generation: gen) }
        return gen
    }

    func append(_ data: Data, generation gen: Int) {
        queue.async { [weak self] in self?.appendLocked(data, generation: gen) }
    }

    /// Ya no llegará más audio en este turno.
    func finishInput(generation gen: Int) {
        queue.async { [weak self] in
            guard let self = self, gen == self.generation, !self.inputFinished else { return }
            self.inputFinished = true
            self.evaluatePlayback()
            self.checkDrained()
        }
    }

    /// Corta el audio AL INSTANTE (no vuelve hasta que el nodo está parado) y descarta todo lo pendiente.
    func stop() {
        queue.sync {
            generation += 1
            node.stop()
            resetTurnState()
            drained = true
            scheduleIdleStop(afterGeneration: generation)
        }
    }

    var isActive: Bool { queue.sync { !drained } }

    // MARK: Interno (en `queue`)

    private func resetTurnState() {
        decoder.reset()
        scheduledFrames = 0
        playedFrames = 0
        inputFinished = false
        started = false
        playing = false
        heldSince = nil
        holdTimerArmed = false
        gapStartedAt = nil
        pulsing = false
    }

    private func startEngineIfNeeded(generation gen: Int) {
        guard gen == generation else { return }
        if !graphReady {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            graphReady = true
        }
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
                engineStartedAt = now
            } catch {
                drained = true
                onFailure?(gen, error.localizedDescription)
            }
        }
    }

    private func appendLocked(_ data: Data, generation gen: Int) {
        guard gen == generation, !drained, !inputFinished else { return }
        let samples = decoder.decode(data)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        let frames = samples.count
        scheduledFrames += frames
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.queue.async { self?.bufferPlayed(frames: frames, generation: gen) }
        }
        onScheduled?(gen, data.count, PCMStreamDecoder.milliseconds(frames: frames, sampleRate: sampleRate))
        evaluatePlayback()
    }

    private func bufferedMs() -> Double {
        PCMStreamDecoder.milliseconds(frames: scheduledFrames - playedFrames, sampleRate: sampleRate)
    }

    /// ¿Ya hay colchón suficiente para sonar (o reanudar)?
    private func evaluatePlayback() {
        guard !playing else { return }
        let frames = scheduledFrames - playedFrames
        let time = now
        if heldSince == nil, frames > 0 { heldSince = time }
        let heldMs = heldSince.map { (time - $0) * 1_000 } ?? 0
        if policy.shouldPlay(bufferedMs: bufferedMs(), wasPlaying: started, inputFinished: inputFinished, heldMs: heldMs) {
            startPlayback(at: time)
        } else if frames > 0, !holdTimerArmed {
            // Si el flujo se estanca con poco audio, pasado el máximo se suena lo que haya.
            holdTimerArmed = true
            let gen = generation
            queue.asyncAfter(deadline: .now() + policy.maxHoldMs / 1_000 + 0.02) { [weak self] in
                guard let self = self, gen == self.generation else { return }
                self.holdTimerArmed = false
                self.evaluatePlayback()
            }
        }
    }

    private func startPlayback(at time: Double) {
        node.play()
        playing = true
        heldSince = nil
        let gen = generation
        if let gapStart = gapStartedAt {
            gapStartedAt = nil
            onGap?(gen, (time - gapStart) * 1_000)
        }
        if !started {
            started = true
            onFirstAudio?(gen, time)
        }
        startPulsing(generation: gen)
    }

    private func startPulsing(generation gen: Int) {
        guard !pulsing else { return }
        pulsing = true
        pulseTick(generation: gen)
    }

    private func pulseTick(generation gen: Int) {
        guard gen == generation, playing else { pulsing = false; return }
        onPulse?()
        queue.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.pulseTick(generation: gen) }
    }

    private func bufferPlayed(frames: Int, generation gen: Int) {
        guard gen == generation else { return }
        playedFrames += frames
        guard playedFrames >= scheduledFrames else { return }
        if inputFinished {
            checkDrained()
        } else if playing {
            // Se acabó el audio programado y todavía llegará más: se pausa hasta tener colchón y se anota el hueco.
            node.pause()
            playing = false
            heldSince = nil
            gapStartedAt = now
        }
    }

    private func checkDrained() {
        guard inputFinished, playedFrames >= scheduledFrames, !drained else { return }
        drained = true
        playing = false
        node.stop()
        let gen = generation
        onDrained?(gen)
        scheduleIdleStop(afterGeneration: gen)
    }

    /// Libera el motor de audio si pasan unos segundos sin hablar.
    private func scheduleIdleStop(afterGeneration gen: Int) {
        queue.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self = self, gen == self.generation, self.drained, self.engine.isRunning else { return }
            self.engine.stop()
        }
    }

    private func handleConfigurationChange() {
        // Justo al arrancar el motor el sistema puede avisar de un ajuste normal: solo se asegura de que siga en marcha.
        if now - engineStartedAt < 0.6 {
            if !engine.isRunning { try? engine.start() }
            return
        }
        // El motor se detiene solo al cambiar la ruta (audífonos). Si había un turno sonando se pierde lo programado: se corta.
        let gen = generation
        let wasActive = !drained
        node.stop()
        resetTurnState()
        drained = true
        generation += 1
        if wasActive { onEngineReset?(gen) }
    }
}
