import Foundation

/// Detección de fin de frase por energía de audio (VAD sencillo y determinista).
/// Se alimenta con niveles RMS en dBFS; no toca el micrófono por sí mismo, así que es 100 % comprobable con pruebas.
public struct SilenceDetector: Sendable {
    public struct Configuration: Sendable {
        public var absoluteSpeechThresholdDB: Float = -42
        public var marginOverNoiseDB: Float = 9
        public var endSilence: TimeInterval = 1.3          // silencio tras hablar que cierra la frase
        public var minSpeech: TimeInterval = 0.25          // hablar menos que esto se ignora como ruido
        public var noSpeechTimeout: TimeInterval = 7       // nadie habló
        public var maxDuration: TimeInterval = 40          // tope de una frase
        public init() {}
    }

    public enum Decision: Equatable, Sendable {
        case keepListening
        case endOfUtterance
        case noSpeech
        case maxDurationReached
    }

    private let config: Configuration
    private var noiseFloorDB: Float = -60
    private var startTime: TimeInterval?
    private var speechStart: TimeInterval?
    private var accumulatedSpeech: TimeInterval = 0
    private var lastSpeech: TimeInterval?
    private var lastSampleTime: TimeInterval?

    public init(configuration: Configuration = Configuration()) { config = configuration }

    public var hasDetectedSpeech: Bool { accumulatedSpeech >= config.minSpeech }

    public mutating func process(levelDB: Float, at time: TimeInterval) -> Decision {
        if startTime == nil { startTime = time }
        let delta = lastSampleTime.map { max(0, time - $0) } ?? 0
        lastSampleTime = time

        let threshold = max(config.absoluteSpeechThresholdDB, noiseFloorDB + config.marginOverNoiseDB)
        let isSpeech = levelDB > threshold
        if isSpeech {
            if speechStart == nil { speechStart = time }
            accumulatedSpeech += delta
            lastSpeech = time
        } else {
            // El suelo de ruido solo se adapta con audio que no es voz.
            noiseFloorDB = noiseFloorDB * 0.95 + levelDB * 0.05
        }

        let elapsed = time - (startTime ?? time)
        if elapsed >= config.maxDuration { return .maxDurationReached }
        if hasDetectedSpeech, let last = lastSpeech, time - last >= config.endSilence { return .endOfUtterance }
        if !hasDetectedSpeech, elapsed >= config.noSpeechTimeout { return .noSpeech }
        return .keepListening
    }

    public mutating func reset() {
        noiseFloorDB = -60
        startTime = nil
        speechStart = nil
        accumulatedSpeech = 0
        lastSpeech = nil
        lastSampleTime = nil
    }
}
