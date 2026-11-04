import Foundation

/// Detecta la palabra de activación en transcripciones parciales del reconocedor.
/// Importante: esto solo funciona MIENTRAS la app está en primer plano y el modo "Escucha activa" está encendido.
/// iOS no permite a una app de terceros escuchar de forma continua con la app cerrada o el teléfono bloqueado.
public struct WakeWordMatcher: Sendable {
    public struct Match: Equatable, Sendable {
        /// Texto dicho después de la palabra de activación ("Viernes, abre Spotify" -> "abre Spotify").
        public let trailingCommand: String
    }

    public let wakeWord: String
    public let maxEditDistance: Int
    private let fillerPrefixes: Set<String> = ["oye", "ey", "hey", "hola", "ok", "okay"]

    public init(wakeWord: String = "viernes", maxEditDistance: Int = 1) {
        self.wakeWord = TextNormalizer.fold(wakeWord)
        self.maxEditDistance = maxEditDistance
    }

    public func match(in transcript: String) -> Match? {
        let words = transcript.split(whereSeparator: { $0.isWhitespace || ",.;:¡!¿?".contains($0) }).map(String.init)
        for (index, word) in words.enumerated() {
            let folded = TextNormalizer.fold(word)
            guard isWakeWord(folded) else { continue }
            // Solo en las primeras posiciones (con un posible "oye" delante) para no activarse en frases largas.
            let preceding = words[..<index].map(TextNormalizer.fold)
            guard preceding.count <= 1, preceding.allSatisfy({ fillerPrefixes.contains($0) }) else { continue }
            let trailing = words[(index + 1)...].joined(separator: " ")
            return Match(trailingCommand: trailing)
        }
        return nil
    }

    private func isWakeWord(_ folded: String) -> Bool {
        // Mínimo 7 letras: con distancia 1, palabras comunes como "vienes" activarían falsamente.
        guard folded.count >= 7 else { return false }
        return TextNormalizer.editDistance(folded, wakeWord) <= maxEditDistance
    }
}
