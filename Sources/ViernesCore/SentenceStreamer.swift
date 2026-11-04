import Foundation

/// Corta el texto que llega en deltas en frases completas, para empezar a hablar antes de que termine la respuesta.
public struct SentenceStreamer: Sendable {
    private var buffer: [Character] = []
    public init() {}

    /// Devuelve las frases que quedaron completas con este fragmento.
    public mutating func feed(_ delta: String) -> [String] {
        buffer.append(contentsOf: delta)
        var sentences: [String] = []
        var start = 0
        var i = 0
        while i < buffer.count {
            let char = buffer[i]
            var isBoundary = false
            if char == "\n" {
                isBoundary = true
            } else if ".!?…;".contains(char) {
                let next: Character? = i + 1 < buffer.count ? buffer[i + 1] : nil
                let previous: Character? = i > 0 ? buffer[i - 1] : nil
                // Se necesita ver el carácter siguiente para no cortar "3.14" ni al final del fragmento.
                if let next = next, next.isWhitespace {
                    isBoundary = !(char == "." && (previous?.isNumber ?? false) && next.isNumber)
                }
            }
            if isBoundary {
                let sentence = String(buffer[start...i]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { sentences.append(sentence) }
                start = i + 1
            }
            i += 1
        }
        buffer = Array(buffer[start...])
        return sentences
    }

    /// Al terminar el flujo: lo que quede es la última frase.
    public mutating func flush() -> String? {
        let rest = String(buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        buffer.removeAll()
        return rest.isEmpty ? nil : rest
    }
}
