import Foundation

/// Un fragmento listo para hablar: texto ya limpio (sin markdown ni emojis) y numerado dentro de su turno.
public struct SpeechSegment: Equatable, Sendable {
    public let index: Int
    public let text: String
    /// Pausa sugerida DESPUÉS del fragmento para la voz del sistema (la voz neuronal ya trae su propia entonación).
    public let pauseAfter: TimeInterval

    public init(index: Int, text: String, pauseAfter: TimeInterval) {
        self.index = index
        self.text = text
        self.pauseAfter = pauseAfter
    }
}

/// Corta el texto que llega por deltas en unidades lingüísticas naturales para empezar a hablar cuanto antes:
/// - el PRIMER fragmento sale en cuanto hay una cláusula completa (coma, punto y coma, dos puntos) o una frase corta;
/// - los siguientes salen por frases (unidas hasta un mínimo de caracteres para no hablar «Sí.» suelto);
/// - nunca corta en decimales («3,14»), iniciales («J. Pérez»), abreviaturas («Dr.»), «p. m.» ni marcadores de lista («1.»);
/// - una frase interminable se parte en una coma o espacio cerca del máximo.
/// El resultado NO depende de cómo lleguen los deltas: alimentar de golpe o carácter a carácter da los mismos fragmentos
/// (solo se decide cuando ya se ve el carácter que sigue). Es puro y comprobable.
public struct SpeechSegmenter: Sendable {
    public struct Policy: Equatable, Sendable {
        /// Caracteres visibles mínimos del primer fragmento al cortar por frase.
        public var firstMinChars = 8
        /// Caracteres visibles mínimos del primer fragmento al cortar por cláusula (coma, «;», «:»).
        public var firstClauseChars = 42
        /// Caracteres visibles mínimos de los fragmentos siguientes al cortar por frase.
        public var minChars = 40
        /// Longitud máxima de un fragmento.
        public var maxChars = 220
        public init() {}
    }

    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…"]
    private static let clauseMarks: Set<Character> = [",", ";", ":", "—", "–"]
    private static let abbreviations: Set<String> = ["sr", "sra", "srta", "dr", "dra", "ing", "lic", "prof", "pag", "vs", "aprox", "num", "av", "tel", "ej", "cap", "art", "dpto", "col"]

    public let policy: Policy
    private var buffer: [Character] = []
    private var emitted = 0

    public init(policy: Policy = Policy()) { self.policy = policy }

    public var emittedCount: Int { emitted }

    public mutating func feed(_ delta: String) -> [SpeechSegment] {
        buffer.append(contentsOf: delta)
        return drain(final: false)
    }

    /// Al terminar el texto: lo que quede es el último fragmento.
    public mutating func flush() -> [SpeechSegment] { drain(final: true) }

    // MARK: Interno

    private mutating func drain(final: Bool) -> [SpeechSegment] {
        var out: [SpeechSegment] = []
        while let cut = nextCut(final: final) {
            let piece = String(buffer[..<cut.end])
            buffer.removeFirst(cut.end)
            let cleaned = SpeechText.clean(piece)
            if !cleaned.isEmpty {
                out.append(SpeechSegment(index: emitted, text: cleaned, pauseAfter: cut.pause))
                emitted += 1
            }
        }
        return out
    }

    private func visibleCount(upTo end: Int) -> Int {
        var count = 0
        for index in 0..<min(end, buffer.count) where !buffer[index].isWhitespace { count += 1 }
        return count
    }

    /// Palabra alfanumérica que termina justo antes de `index` (sin el punto).
    private func wordBefore(_ index: Int) -> (word: String, startsLine: Bool) {
        var start = index
        while start > 0, buffer[start - 1].isLetter || buffer[start - 1].isNumber { start -= 1 }
        let word = String(buffer[start..<index])
        let startsLine = start == 0 || buffer[start - 1] == "\n"
        return (word, startsLine)
    }

    private func nextCut(final: Bool) -> (end: Int, pause: TimeInterval)? {
        let n = buffer.count
        if n == 0 { return nil }
        let need = emitted == 0 ? policy.firstMinChars : policy.minChars
        var i = 0
        scan: while i < n {
            // Un corte más allá del máximo no vale: lo decide la regla de frase interminable (y así el resultado no depende
            // de cómo lleguen los deltas).
            if i >= policy.maxChars { break scan }
            let c = buffer[i]
            if c == "\n" { return (i + 1, 0.55) }

            if Self.sentenceEnds.contains(c) {
                var j = i
                while j + 1 < n, Self.sentenceEnds.contains(buffer[j + 1]) { j += 1 }
                if j + 1 > policy.maxChars { break scan }
                guard j + 1 < n else { break scan }                    // falta ver qué sigue
                guard buffer[j + 1].isWhitespace else { i = j + 1; continue scan }       // «3.14», «a.m», «www.»
                var k = j + 1
                while k < n, buffer[k].isWhitespace, buffer[k] != "\n" { k += 1 }
                if k >= n { break scan }                              // falta ver el siguiente carácter visible
                var isBoundary = true
                if buffer[k] != "\n" {
                    if c == "." {
                        let (word, startsLine) = wordBefore(i)
                        let folded = TextNormalizer.fold(word)
                        if j == i, Self.abbreviations.contains(folded) { isBoundary = false }
                        if j == i, word.count == 1, word.first?.isLetter == true { isBoundary = false }          // inicial: «J. Pérez»
                        if j == i, !word.isEmpty, word.allSatisfy({ $0.isNumber }), startsLine { isBoundary = false }   // «1. Primero»
                        if buffer[k].isLowercase { isBoundary = false }                                           // «etc. y luego», «p. m.»
                    }
                }
                if isBoundary, visibleCount(upTo: j + 1) >= need {
                    let pause: TimeInterval = (c == "?" || c == "!") ? 0.30 : 0.22
                    return (j + 1, pause)
                }
                i = j + 1
                continue scan
            }

            if emitted == 0, Self.clauseMarks.contains(c) {
                guard i + 1 < n else { break scan }
                if buffer[i + 1].isWhitespace, visibleCount(upTo: i + 1) >= policy.firstClauseChars { return (i + 1, 0.12) }
            }
            i += 1
        }

        // Frase interminable: se parte en una cláusula o espacio cercano al máximo.
        if n > policy.maxChars {
            let low = policy.maxChars / 2
            var position = policy.maxChars - 1
            while position >= low {
                if Self.clauseMarks.contains(buffer[position]), buffer[position + 1].isWhitespace { return (position + 1, 0.15) }
                position -= 1
            }
            position = policy.maxChars
            while position >= low {
                if buffer[position].isWhitespace { return (position + 1, 0.15) }
                position -= 1
            }
            return (policy.maxChars, 0.15)
        }
        return final ? (n, 0) : nil
    }
}
