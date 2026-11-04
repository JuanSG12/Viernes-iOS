import AVFoundation
import ViernesCore

/// Síntesis de voz con AVSpeechSynthesizer: voces locales del sistema (sin red), cola por frases, pausas e interrupción.
/// Para una voz más natural, el usuario descarga voces «Mejoradas» o «Premium» en Ajustes › Accesibilidad › Contenido hablado › Voces.
@MainActor
final class SpeechSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    var onStart: (() -> Void)?
    var onFinish: (() -> Void)?               // se vació la cola (terminó de hablar o fue interrumpida)
    var onWord: (() -> Void)?                 // pulso por palabra: anima el núcleo

    private let synthesizer = AVSpeechSynthesizer()
    /// Frases vivas (encoladas o sonando). Los `didCancel` tardíos de frases ya descartadas por `stop()` se ignoran
    /// porque su identificador ya no está aquí.
    private var live = Set<ObjectIdentifier>()
    private(set) var isSpeaking = false
    /// Hay frases encoladas o sonando (incluye el instante antes de que empiece la primera).
    var isBusy: Bool { isSpeaking || !live.isEmpty }
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

    func apply(_ settings: VoiceSettings) { self.settings = settings.sanitized() }

    /// Encola una frase (usado por la respuesta en streaming) o un texto completo.
    func enqueue(_ text: String) {
        let chunks = SpeechText.chunks(text)
        guard !chunks.isEmpty else { return }
        try? AudioSessionController.activateForConversation()
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
        guard synthesizer.isSpeaking || !live.isEmpty else { return }
        live.removeAll()                       // los callbacks de cancelación que lleguen después se ignorarán
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        onFinish?()
    }

    /// Reproduce una muestra con los ajustes dados (pantalla de voces).
    func preview(identifier: String?, settings: VoiceSettings) {
        stop()
        var temp = settings
        temp.voiceIdentifier = identifier
        apply(temp)
        enqueue("Hola. Soy Viernes. Así sueno con esta configuración.")
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
