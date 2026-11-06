import Foundation

// Lógica PURA (sin micrófono ni red) del dictado: ajustes, corrección de lo transcrito, aprendizaje de correcciones,
// historial de reconocimiento para diagnóstico y política de errores. El micrófono y el reconocedor viven en la app.

/// Una corrección aprendida de lo que el usuario editó: «kisame guy» → «Kisameyguy».
public struct LearnedCorrection: Codable, Equatable, Sendable {
    public var heard: String
    public var meant: String
    public init(heard: String, meant: String) {
        self.heard = heard
        self.meant = meant
    }
}

public struct SpeechSettings: Codable, Equatable, Sendable {
    /// Qué pasa con lo transcrito antes de enviarlo al cerebro.
    public enum ReviewMode: String, Codable, Sendable, CaseIterable {
        /// Se envía en cuanto termina de hablar.
        case off
        /// Se muestra unos segundos con «Editar» y «Cancelar», y se envía solo.
        case brief
        /// No se envía hasta que el usuario toque «Enviar».
        case always
    }

    public var review: ReviewMode
    /// Silencio (en segundos) que cierra la frase. Más alto = tolera pausas al pensar o al dictar un correo.
    public var endSilenceSeconds: Double
    /// Nombres y términos frecuentes: sesgan el reconocedor y corrigen lo transcrito.
    public var glossary: [String]
    public var learned: [LearnedCorrection]
    public var autoCorrect: Bool
    /// Guarda en el teléfono el historial técnico de reconocimiento (sin audio).
    public var keepHistory: Bool
    /// Transcribir con Groq Whisper (el AUDIO sale del teléfono hacia Groq). Apagado por defecto y solo válido con consentimiento.
    public var cloudTranscription: Bool
    public var cloudConsentAt: Date?

    public static let `default` = SpeechSettings(review: .brief, endSilenceSeconds: 1.8, glossary: [], learned: [], autoCorrect: true,
                                                 keepHistory: true, cloudTranscription: false, cloudConsentAt: nil)

    public static let maxGlossary = 60
    public static let maxLearned = 80

    public init(review: ReviewMode, endSilenceSeconds: Double, glossary: [String], learned: [LearnedCorrection], autoCorrect: Bool,
                keepHistory: Bool, cloudTranscription: Bool, cloudConsentAt: Date?) {
        self.review = review
        self.endSilenceSeconds = endSilenceSeconds
        self.glossary = glossary
        self.learned = learned
        self.autoCorrect = autoCorrect
        self.keepHistory = keepHistory
        self.cloudTranscription = cloudTranscription
        self.cloudConsentAt = cloudConsentAt
    }

    public func sanitized() -> SpeechSettings {
        var copy = self
        copy.endSilenceSeconds = min(max(endSilenceSeconds, 0.8), 3.5)
        var seen = Set<String>()
        copy.glossary = glossary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 40 && seen.insert(TextNormalizer.fold($0)).inserted }
        if copy.glossary.count > Self.maxGlossary { copy.glossary = Array(copy.glossary.prefix(Self.maxGlossary)) }
        copy.learned = Array(learned.filter { !$0.heard.isEmpty && !$0.meant.isEmpty }.suffix(Self.maxLearned))
        // El audio nunca sale sin consentimiento expreso y fechado.
        if cloudConsentAt == nil { copy.cloudTranscription = false }
        return copy
    }

    /// Frases para sesgar al reconocedor (`contextualStrings`): glosario + lo aprendido + la palabra de activación.
    public func contextualStrings(extra: [String] = []) -> [String] {
        var seen = Set<String>()
        let all = ["Viernes"] + glossary + learned.map(\.meant) + extra
        return all.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 60 && seen.insert(TextNormalizer.fold($0)).inserted }
            .prefix(100).map { $0 }
    }
}

public struct TranscriptCorrection: Equatable, Sendable {
    public var text: String
    /// Cada cambio aplicado, para el historial de diagnóstico («kisame guy → Kisameyguy»).
    public var changes: [String]
}

/// Corrige lo que el reconocedor escribió ANTES de enviarlo al cerebro: correos dictados, correcciones aprendidas y nombres del glosario.
/// Es deliberadamente conservador: solo toca palabras casi iguales a un término del glosario y nunca palabras vacías del español.
public enum TranscriptCorrector {
    private struct Piece {
        var lead: String
        var core: String
        var trail: String
        var text: String { lead + core + trail }
    }

    private static let punctuation = CharacterSet(charactersIn: ",.;:!?¡¿\"'()«»")

    private static func pieces(_ text: String) -> [Piece] {
        text.split(whereSeparator: { $0.isWhitespace }).map { raw in
            let word = String(raw)
            var scalars = Array(word.unicodeScalars)
            var lead = ""
            var trail = ""
            while let first = scalars.first, punctuation.contains(first), scalars.count > 1 { lead.unicodeScalars.append(first); scalars.removeFirst() }
            while let last = scalars.last, punctuation.contains(last), scalars.count > 1 { trail = String(last) + trail; scalars.removeLast() }
            var core = ""
            core.unicodeScalars.append(contentsOf: scalars)
            return Piece(lead: lead, core: core, trail: trail)
        }
    }

    private static func join(_ pieces: [Piece]) -> String { pieces.map(\.text).joined(separator: " ") }

    public static func apply(_ transcript: String, glossary: [String], learned: [LearnedCorrection]) -> TranscriptCorrection {
        var changes: [String] = []
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return TranscriptCorrection(text: text, changes: []) }

        let emails = SpokenText.normalizeEmails(in: text)
        if emails != text {
            changes.append("correo dictado → dirección escrita")
            text = emails
        }

        var words = pieces(text)

        // 1) Correcciones aprendidas: la secuencia exacta de palabras (sin tildes ni mayúsculas) se cambia por lo que el usuario quiso.
        for rule in learned {
            let heard = pieces(rule.heard).map { TextNormalizer.fold($0.core) }
            guard !heard.isEmpty, heard.count <= words.count else { continue }
            var index = 0
            while index + heard.count <= words.count {
                let window = words[index..<(index + heard.count)].map { TextNormalizer.fold($0.core) }
                if window == heard {
                    let first = words[index], last = words[index + heard.count - 1]
                    let replacement = pieces(rule.meant)
                    if replacement.map(\.core).joined(separator: " ") != words[index..<(index + heard.count)].map(\.core).joined(separator: " ") {
                        changes.append("\(rule.heard) → \(rule.meant)")
                    }
                    words.replaceSubrange(index..<(index + heard.count), with: [Piece(lead: first.lead, core: rule.meant, trail: last.trail)])
                }
                index += 1
            }
        }

        // 2) Glosario: palabra casi igual a un término, o dos palabras seguidas que juntas lo forman.
        for term in glossary {
            let termWords = pieces(term).map(\.core)
            guard !termWords.isEmpty else { continue }
            let folded = termWords.map(TextNormalizer.fold)
            var index = 0
            while index < words.count {
                if let length = matchLength(words, at: index, term: term, termWords: termWords, folded: folded) {
                    let first = words[index], last = words[index + length - 1]
                    let before = words[index..<(index + length)].map(\.core).joined(separator: " ")
                    if before != term {
                        changes.append("\(before) → \(term)")
                        words.replaceSubrange(index..<(index + length), with: [Piece(lead: first.lead, core: term, trail: last.trail)])
                    }
                }
                index += 1
            }
        }
        return TranscriptCorrection(text: join(words), changes: changes)
    }

    /// Cuántas palabras de `words` desde `index` corresponden al término (0 si ninguna), o `nil`.
    private static func matchLength(_ words: [Piece], at index: Int, term: String, termWords: [String], folded: [String]) -> Int? {
        // a) Mismo número de palabras que el término, cada una igual o casi igual.
        if index + termWords.count <= words.count {
            var all = true
            for offset in 0..<termWords.count where !wordMatches(words[index + offset].core, folded[offset]) { all = false; break }
            if all { return termWords.count }
        }
        // b) Un término de UNA palabra partido en dos por el reconocedor («kisame guy» → «Kisameyguy»).
        if termWords.count == 1, index + 2 <= words.count {
            let joined = TextNormalizer.fold(words[index].core + words[index + 1].core)
            let target = folded[0]
            if target.count >= 6, !TextNormalizer.stopwords.contains(TextNormalizer.fold(words[index].core)),
               joined == target || (target.count >= 8 && TextNormalizer.editDistance(joined, target) <= 1) {
                return 2
            }
        }
        return nil
    }

    private static func wordMatches(_ word: String, _ foldedTerm: String) -> Bool {
        let foldedWord = TextNormalizer.fold(word)
        guard foldedWord.count >= 3, !TextNormalizer.stopwords.contains(foldedWord) else { return false }
        if foldedWord == foldedTerm { return true }
        // Casi igual: solo términos de 6 o más letras, misma inicial y una sola letra de diferencia.
        guard foldedTerm.count >= 6, foldedWord.first == foldedTerm.first else { return false }
        guard TextNormalizer.editDistance(foldedWord, foldedTerm) <= 1 else { return false }
        // Pero NO si la diferencia es la última letra: «Daniela» no es «Daniel», «Mariana» no es «Mariano», «esposa» no es «esposo».
        if foldedWord.hasPrefix(foldedTerm) || foldedTerm.hasPrefix(foldedWord) { return false }
        if foldedWord.count == foldedTerm.count, foldedWord.dropLast() == foldedTerm.dropLast() { return false }
        return true
    }
}

/// Aprende de lo que el usuario corrige: compara lo oído con lo editado y devuelve los cambios pequeños y claros.
public enum TranscriptDiff {
    public static func corrections(heard: String, edited: String) -> [LearnedCorrection] {
        func words(_ text: String) -> [String] {
            text.split(whereSeparator: { $0.isWhitespace }).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?¡¿\"'()«»")) }
                .filter { !$0.isEmpty }
        }
        let a = words(heard), b = words(edited)
        guard !a.isEmpty, !b.isEmpty, a.count <= 60, b.count <= 60 else { return [] }
        let fa = a.map(TextNormalizer.fold), fb = b.map(TextNormalizer.fold)

        // Subsecuencia común más larga (LCS) sobre las palabras plegadas.
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = fa[i] == fb[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var result: [LearnedCorrection] = []
        var i = 0, j = 0
        var heardSpan: [String] = [], meantSpan: [String] = []
        func flush() {
            defer { heardSpan = []; meantSpan = [] }
            guard !heardSpan.isEmpty, !meantSpan.isEmpty, heardSpan.count <= 3, meantSpan.count <= 3 else { return }
            let heardText = heardSpan.joined(separator: " "), meantText = meantSpan.joined(separator: " ")
            guard heardText != meantText else { return }
            result.append(LearnedCorrection(heard: heardText, meant: meantText))
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, fa[i] == fb[j] {
                // Palabra igual: si solo cambió la escritura (mayúsculas, tildes), también cuenta como corrección de una palabra.
                flush()
                if a[i] != b[j] { result.append(LearnedCorrection(heard: a[i], meant: b[j])) }
                i += 1; j += 1
            } else if j >= b.count || (i < a.count && table[i + 1][j] >= table[i][j + 1]) {
                heardSpan.append(a[i]); i += 1
            } else {
                meantSpan.append(b[j]); j += 1
            }
        }
        flush()
        return result
    }

    /// Añade correcciones nuevas a las ya aprendidas (sin duplicados; las más recientes al final).
    public static func merge(_ new: [LearnedCorrection], into existing: [LearnedCorrection]) -> [LearnedCorrection] {
        var list = existing
        for item in new {
            list.removeAll { TextNormalizer.fold($0.heard) == TextNormalizer.fold(item.heard) }
            list.append(item)
        }
        return Array(list.suffix(SpeechSettings.maxLearned))
    }
}

// MARK: Historial de reconocimiento (diagnóstico local)

public enum TranscriptVote: String, Codable, Sendable { case local, cloud, neither }

/// Una frase dictada y lo que pasó con ella. Texto, nunca audio. Sirve para saber si el fallo está en la captura,
/// en el reconocimiento o en el procesamiento posterior, y para comparar el reconocimiento local con Whisper sin suponer.
public struct RecognitionRecord: Codable, Equatable, Identifiable, Sendable {
    public enum EndReason: String, Codable, Sendable {
        case silence          // el detector de silencio cerró la frase
        case userTap          // el usuario tocó para terminar
        case maxDuration
        case noSpeech         // nadie habló
        case recognizerFinal  // el reconocedor entregó su resultado final
        case error
    }

    public var id: UUID
    public var date: Date
    public var locale: String
    public var onDevice: Bool
    public var mode: String                 // «botón» o «palabra»
    public var duration: Double
    public var endReason: EndReason
    public var partialCount: Int
    public var raw: String                  // lo que entregó el reconocedor
    public var corrected: String?           // tras la corrección automática, si cambió algo
    public var confidence: Double?          // media de confianza de los segmentos (en el dispositivo suele ser 0 = sin dato)
    public var error: String?
    public var retried: Bool
    public var cloudText: String?           // lo que devolvió Whisper, si estaba activado
    public var cloudSeconds: Double?
    public var cloudError: String?
    public var edited: String?              // lo que el usuario dejó tras editar
    public var vote: TranscriptVote?

    public init(id: UUID = UUID(), date: Date = Date(), locale: String, onDevice: Bool, mode: String, duration: Double,
                endReason: EndReason, partialCount: Int, raw: String, corrected: String? = nil, confidence: Double? = nil,
                error: String? = nil, retried: Bool = false, cloudText: String? = nil, cloudSeconds: Double? = nil,
                cloudError: String? = nil, edited: String? = nil, vote: TranscriptVote? = nil) {
        self.id = id
        self.date = date
        self.locale = locale
        self.onDevice = onDevice
        self.mode = mode
        self.duration = duration
        self.endReason = endReason
        self.partialCount = partialCount
        self.raw = raw
        self.corrected = corrected
        self.confidence = confidence
        self.error = error
        self.retried = retried
        self.cloudText = cloudText
        self.cloudSeconds = cloudSeconds
        self.cloudError = cloudError
        self.edited = edited
        self.vote = vote
    }

    /// Lo que finalmente se mostró al cerebro como petición (la edición manual manda sobre la corrección automática).
    public var finalText: String { edited ?? corrected ?? raw }
}

public struct RecognitionStats: Equatable, Sendable {
    public var total = 0
    public var empty = 0
    public var withError = 0
    public var retried = 0
    public var edited = 0
    public var autoCorrected = 0
    public var localVotes = 0
    public var cloudVotes = 0
    public var neitherVotes = 0
    public var cloudCompared = 0

    public var votesCast: Int { localVotes + cloudVotes + neitherVotes }

    public static func summarize(_ records: [RecognitionRecord]) -> RecognitionStats {
        var stats = RecognitionStats()
        for record in records {
            stats.total += 1
            if record.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { stats.empty += 1 }
            if record.error != nil { stats.withError += 1 }
            if record.retried { stats.retried += 1 }
            if let edited = record.edited, edited != (record.corrected ?? record.raw) { stats.edited += 1 }
            if record.corrected != nil, record.corrected != record.raw { stats.autoCorrected += 1 }
            if record.cloudText != nil { stats.cloudCompared += 1 }
            switch record.vote {
            case .local?: stats.localVotes += 1
            case .cloud?: stats.cloudVotes += 1
            case .neither?: stats.neitherVotes += 1
            case nil: break
            }
        }
        return stats
    }
}

/// Qué hacer ante un error del reconocedor de Apple. Los códigos salen de lo observado por desarrolladores y de la documentación
/// pública; cualquier código desconocido se trata como recuperable UNA vez y queda en el historial con su dominio y código.
public enum SpeechErrorPolicy {
    public enum Action: Equatable, Sendable {
        /// «No se oyó voz» o cancelado: no es un fallo.
        case benign
        /// Reintentar una vez con un reconocedor nuevo.
        case retry
        /// No se puede reintentar: se explica qué hacer.
        case fatal(String)
    }

    public static func classify(domain: String, code: Int, hasText: Bool) -> Action {
        if code == 1110 || code == 301 { return .benign }
        if hasText { return .benign }                                  // ya hay texto: se usa lo transcrito
        if domain == "kLSRErrorDomain", code == 102 {
            return .fatal("Falta el modelo de dictado en español en este iPhone. Descárgalo en Ajustes › General › Teclado › Dictado, o permite el reconocimiento de Apple por internet en Viernes › Escucha.")
        }
        if domain == "kLSRErrorDomain", code == 201 {
            return .fatal("El dictado está desactivado en iOS. Actívalo en Ajustes › General › Teclado › Activar dictado.")
        }
        return .retry
    }

    public static func describe(domain: String, code: Int, message: String) -> String {
        "\(message) (\(domain) \(code))"
    }
}
