import Foundation

public struct SpeechChunk: Equatable, Sendable {
    public let text: String
    /// Pausa a insertar DESPUÉS del fragmento (segundos, antes de escalar por el ajuste del usuario).
    public let pauseAfter: TimeInterval
}

/// Prepara texto de chat para ser hablado: sin markdown, sin emojis, sin URLs largas, por frases.
public enum SpeechText {
    public static func clean(_ text: String) -> String {
        var result = text

        // Enlaces markdown [texto](url) -> texto
        result = result.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        // URLs sueltas
        result = result.replacingOccurrences(of: "https?://\\S+", with: "un enlace", options: .regularExpression)
        // Bloques de código y código en línea
        result = result.replacingOccurrences(of: "```[\\s\\S]*?```", with: " (bloque de código omitido) ", options: .regularExpression)
        result = result.replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
        // Énfasis y encabezados
        result = result.replacingOccurrences(of: "(\\*\\*|__|\\*|_|~~)", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?m)^\\s{0,3}#{1,6}\\s*", with: "", options: .regularExpression)
        // Viñetas y numeraciones al inicio de línea -> pausa natural
        result = result.replacingOccurrences(of: "(?m)^\\s*([-•*]|\\d+[.)])\\s+", with: "", options: .regularExpression)
        // Emojis
        result = String(String.UnicodeScalarView(result.unicodeScalars.filter { !isEmoji($0) }))
        // Espacios
        result = result.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isEmoji(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isEmojiPresentation { return true }
        // Pictogramas con presentación de texto por defecto pero fuera de ASCII (☀, ✔, ❤...). Excluye dígitos, #, * y letras.
        return scalar.properties.isEmoji && scalar.value > 0x2000 && scalar.value != 0xFE0F
            || scalar.value == 0xFE0F || scalar.value == 0x200D
    }

    /// Divide en frases con pausas: coma/punto y coma corta, punto medio, salto de párrafo largo.
    public static func chunks(_ text: String, maxLength: Int = 220) -> [SpeechChunk] {
        let cleaned = clean(text)
        guard !cleaned.isEmpty else { return [] }
        var chunks: [SpeechChunk] = []
        let paragraphs = cleaned.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        for (index, paragraph) in paragraphs.enumerated() {
            let isLastParagraph = index == paragraphs.count - 1
            let sentences = splitSentences(paragraph)
            for (sentenceIndex, sentence) in sentences.enumerated() {
                let isLastSentence = sentenceIndex == sentences.count - 1
                let pieces = wrap(sentence, maxLength: maxLength)
                for (pieceIndex, piece) in pieces.enumerated() {
                    let pause: TimeInterval
                    if pieceIndex < pieces.count - 1 { pause = 0.22 }          // corte interno de una frase larga
                    else if isLastSentence { pause = isLastParagraph ? 0 : 0.55 }
                    else if piece.hasSuffix("?") || piece.hasSuffix("!") { pause = 0.30 }
                    else { pause = 0.22 }
                    chunks.append(SpeechChunk(text: piece, pauseAfter: pause))
                }
            }
        }
        return chunks
    }

    static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let terminators: Set<Character> = [".", "!", "?", "…", ";"]
        let characters = Array(text)
        for (i, char) in characters.enumerated() {
            current.append(char)
            guard terminators.contains(char) else { continue }
            // No cortar en decimales (3.14) ni abreviaturas de una letra ("p. ej." se acepta como corte, es aceptable).
            let next = i + 1 < characters.count ? characters[i + 1] : " "
            let previous = i > 0 ? characters[i - 1] : " "
            if char == ".", previous.isNumber, next.isNumber { continue }
            if next.isWhitespace || i + 1 == characters.count {
                let sentence = current.trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty { sentences.append(sentence) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { sentences.append(rest) }
        return sentences
    }

    /// Parte frases demasiado largas por comas, y en última instancia por palabras.
    static func wrap(_ sentence: String, maxLength: Int) -> [String] {
        guard sentence.count > maxLength else { return [sentence] }
        var pieces: [String] = []
        var current = ""
        for word in sentence.split(separator: " ", omittingEmptySubsequences: true) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count > maxLength, !current.isEmpty {
                pieces.append(current)
                current = String(word)
            } else {
                current = candidate
            }
            if current.hasSuffix(","), current.count > maxLength / 2 {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
