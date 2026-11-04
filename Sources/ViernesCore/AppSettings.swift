import Foundation

public struct VoiceSettings: Codable, Equatable, Sendable {
    /// `nil` = elegir automáticamente la mejor voz española disponible.
    public var voiceIdentifier: String?
    /// 0.0…1.0 en la escala de AVSpeechUtterance (0.5 = velocidad por defecto del sistema).
    public var rate: Float
    public var volume: Float
    public var pitch: Float               // 0.5…2.0
    /// Multiplicador de las pausas entre frases (0 = sin pausas).
    public var pauseScale: Double
    public var speakResponses: Bool

    public static let `default` = VoiceSettings(voiceIdentifier: nil, rate: 0.5, volume: 1.0, pitch: 0.95, pauseScale: 1.0, speakResponses: true)

    public init(voiceIdentifier: String?, rate: Float, volume: Float, pitch: Float, pauseScale: Double, speakResponses: Bool) {
        self.voiceIdentifier = voiceIdentifier
        self.rate = rate
        self.volume = volume
        self.pitch = pitch
        self.pauseScale = pauseScale
        self.speakResponses = speakResponses
    }

    public func sanitized() -> VoiceSettings {
        var copy = self
        copy.rate = min(max(rate, 0.3), 0.65)
        copy.volume = min(max(volume, 0), 1)
        copy.pitch = min(max(pitch, 0.5), 2)
        copy.pauseScale = min(max(pauseScale, 0), 3)
        return copy
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var selectedModelID: String?
    public var claude: ClaudeBridgeConfig
    public var voice: VoiceSettings
    public var memory: MemoryPolicy
    public var transcriptRetention: TranscriptRetention
    /// Escucha activa por palabra "Viernes" SOLO con la app en primer plano. Apagada por defecto.
    public var wakeWordEnabled: Bool
    /// Tras responder, vuelve a escuchar sola (conversación manos libres). Apagado por defecto.
    public var continuousConversation: Bool
    public var recognitionLocale: String
    /// Permite que el dictado use los servidores de Apple si el idioma no está disponible en el dispositivo.
    /// Apagado por defecto: sin esto, el audio NUNCA sale del teléfono.
    public var allowServerRecognition: Bool
    public var requireBiometricsForMemory: Bool
    public var reducedEffects: Bool
    public var hapticsEnabled: Bool
    public var onboardingCompleted: Bool

    public static let `default` = AppSettings(
        selectedModelID: nil, claude: ClaudeBridgeConfig(), voice: .default, memory: .default,
        transcriptRetention: .days7, wakeWordEnabled: false, continuousConversation: false,
        recognitionLocale: "es-CO", allowServerRecognition: false, requireBiometricsForMemory: false,
        reducedEffects: false, hapticsEnabled: true, onboardingCompleted: false
    )

    public init(selectedModelID: String?, claude: ClaudeBridgeConfig, voice: VoiceSettings, memory: MemoryPolicy,
                transcriptRetention: TranscriptRetention, wakeWordEnabled: Bool, continuousConversation: Bool,
                recognitionLocale: String, allowServerRecognition: Bool, requireBiometricsForMemory: Bool,
                reducedEffects: Bool, hapticsEnabled: Bool, onboardingCompleted: Bool) {
        self.allowServerRecognition = allowServerRecognition
        self.selectedModelID = selectedModelID
        self.claude = claude
        self.voice = voice
        self.memory = memory
        self.transcriptRetention = transcriptRetention
        self.wakeWordEnabled = wakeWordEnabled
        self.continuousConversation = continuousConversation
        self.recognitionLocale = recognitionLocale
        self.requireBiometricsForMemory = requireBiometricsForMemory
        self.reducedEffects = reducedEffects
        self.hapticsEnabled = hapticsEnabled
        self.onboardingCompleted = onboardingCompleted
    }

    public func sanitized() -> AppSettings {
        var copy = self
        copy.voice = voice.sanitized()
        if let id = selectedModelID, ModelCatalog.descriptor(id: id) == nil { copy.selectedModelID = nil }
        if claude.shortcutName.trimmingCharacters(in: .whitespaces).isEmpty { copy.claude.shortcutName = ClaudeBridgeConfig().shortcutName }
        return copy
    }
}
