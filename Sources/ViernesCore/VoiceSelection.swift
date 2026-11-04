import Foundation

public struct VoiceDescriptor: Identifiable, Equatable, Sendable {
    public enum Quality: Int, Sendable, Comparable {
        case standard = 0, enhanced = 1, premium = 2
        public static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }
        public var displayName: String {
            switch self {
            case .standard: return "Estándar"
            case .enhanced: return "Mejorada"
            case .premium: return "Premium"
            }
        }
    }
    public enum Gender: Sendable { case female, male, unspecified }

    public let identifier: String
    public let name: String
    public let language: String          // BCP-47, p. ej. "es-CO"
    public let quality: Quality
    public let gender: Gender
    public var id: String { identifier }

    public init(identifier: String, name: String, language: String, quality: Quality, gender: Gender) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.quality = quality
        self.gender = gender
    }
}

/// Puntúa las voces de AVSpeechSynthesisVoice para elegir la más "elegante, madura y natural" disponible.
/// Criterios: español (colombiano > latino > España), femenina, calidad Premium > Mejorada > Estándar,
/// y se descartan voces "eloquence"/novedad (suenan robóticas). Es una heurística: el usuario siempre puede elegir.
public enum VoiceRanker {
    public static func isRoboticOrNovelty(_ voice: VoiceDescriptor) -> Bool {
        let id = voice.identifier.lowercased()
        return id.contains("eloquence") || id.contains("speech.synthesis.voice")
    }

    public static func score(_ voice: VoiceDescriptor, preferredLanguage: String = "es-CO") -> Int {
        let language = voice.language.replacingOccurrences(of: "_", with: "-")
        guard language.lowercased().hasPrefix("es") else { return Int.min }
        var score = 0
        if language.caseInsensitiveCompare(preferredLanguage) == .orderedSame { score += 40 }
        else if ["es-419", "es-MX", "es-US"].contains(where: { $0.caseInsensitiveCompare(language) == .orderedSame }) { score += 25 }
        else if language.caseInsensitiveCompare("es-ES") == .orderedSame { score += 10 }
        else { score += 15 }       // otras variantes latinoamericanas (es-AR, es-CL...)
        score += voice.quality.rawValue * 30
        if voice.gender == .female { score += 20 }
        if voice.gender == .male { score -= 5 }
        if isRoboticOrNovelty(voice) { score -= 200 }
        return score
    }

    public static func rank(_ voices: [VoiceDescriptor], preferredLanguage: String = "es-CO") -> [VoiceDescriptor] {
        voices.filter { score($0, preferredLanguage: preferredLanguage) > Int.min }
            .sorted {
                let a = score($0, preferredLanguage: preferredLanguage), b = score($1, preferredLanguage: preferredLanguage)
                return a == b ? $0.name < $1.name : a > b
            }
    }

    public static func best(_ voices: [VoiceDescriptor], preferredLanguage: String = "es-CO") -> VoiceDescriptor? {
        rank(voices, preferredLanguage: preferredLanguage).first
    }
}
