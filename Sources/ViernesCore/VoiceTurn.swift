import Foundation

// Lógica PURA del motor de voz en tiempo real: turnos con identificador (para que nada de un turno anterior suene en el
// siguiente), colchón anti-cortes, decodificación del audio PCM y métricas. El audio, la red y los hilos viven en la app.

// MARK: Turnos

/// Contabilidad de UN turno de habla a la vez. Cada turno tiene un identificador creciente; cancelar lo invalida, de modo que
/// cualquier fragmento, audio o evento tardío de un turno anterior se reconoce como «viejo» y se descarta.
public struct VoiceTurnLedger: Sendable {
    public enum Acceptance: Equatable, Sendable {
        case accepted
        /// Ya se aceptó un fragmento con ese número (reintento, eco): no se vuelve a hablar.
        case duplicate
        /// Llegó con un número mayor al esperado (se saltó uno): no se habla fuera de orden.
        case outOfOrder
        /// Pertenece a un turno anterior o cancelado.
        case stale
        case cancelled
        /// El texto del turno ya se dio por terminado.
        case afterEnd
    }

    public private(set) var currentTurn: UInt64 = 0
    public private(set) var nextIndex = 0
    public private(set) var textEnded = true
    public private(set) var cancelled = false
    /// Lo enviado a la conexión vigente y lo que el sintetizador confirmó haber convertido en audio.
    private var tracker = SpokenTextTracker()
    /// Caracteres enviados al sintetizador (con el espacio final de cada fragmento).
    public var sentCharacters: Int { tracker.sentCharacters }
    /// Caracteres que el sintetizador confirmó haber convertido en audio (alineación de ElevenLabs).
    public var spokenCharacters: Int { tracker.spokenCharacters }

    public init() {}

    @discardableResult
    public mutating func beginTurn() -> UInt64 {
        currentTurn &+= 1
        nextIndex = 0
        textEnded = false
        cancelled = false
        tracker = SpokenTextTracker()
        return currentTurn
    }

    /// Tras un corte de conexión se abre otra: la contabilidad empieza de nuevo, con el texto pendiente como lo único enviado.
    public mutating func restartSession(carrying pending: String) {
        tracker = SpokenTextTracker()
        let text = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { tracker.append(text) }
    }

    public func isCurrent(_ turn: UInt64) -> Bool { turn == currentTurn && !cancelled }

    public mutating func accept(_ segment: SpeechSegment, turn: UInt64) -> Acceptance {
        guard turn == currentTurn else { return .stale }
        if cancelled { return .cancelled }
        if textEnded { return .afterEnd }
        if segment.index < nextIndex { return .duplicate }
        if segment.index > nextIndex { return .outOfOrder }
        nextIndex += 1
        tracker.append(segment.text)
        return .accepted
    }

    /// El texto del turno terminó (ya no llegarán más fragmentos). `false` si el turno no es el vigente.
    @discardableResult
    public mutating func endText(turn: UInt64) -> Bool {
        guard isCurrent(turn) else { return false }
        textEnded = true
        return true
    }

    /// Cancela el turno vigente. Los eventos que lleguen después con su identificador serán `stale`.
    public mutating func cancel() {
        cancelled = true
        textEnded = true
        currentTurn &+= 1
    }

    public mutating func recordSpoken(characters: Int, turn: UInt64) {
        guard isCurrent(turn) else { return }
        tracker.spoken(characters)
    }

    /// Texto enviado que todavía no se convirtió en audio (para retomarlo tras un corte de conexión sin repetir lo ya dicho).
    public func remainingText() -> String { tracker.remainingText() }
}

/// Lleva la cuenta del texto enviado a UNA conexión del sintetizador y de cuánto de él ya es audio, para poder retomar lo que
/// falte tras un corte sin repetir lo ya dicho.
public struct SpokenTextTracker: Sendable {
    private var texts: [String] = []
    public private(set) var sentCharacters = 0
    public private(set) var spokenCharacters = 0

    public init() {}

    /// Registra un texto enviado (la API pide un espacio final por mensaje, que también cuenta).
    public mutating func append(_ text: String) {
        texts.append(text)
        sentCharacters += text.count + 1
    }

    public mutating func spoken(_ characters: Int) {
        guard characters > 0 else { return }
        spokenCharacters = min(spokenCharacters + characters, sentCharacters)
    }

    /// Si el corte cae a media palabra, se retoma en la siguiente palabra.
    public func remainingText() -> String {
        let characters = Array(texts.map { $0 + " " }.joined())
        let cut = min(spokenCharacters, characters.count)
        var start = cut
        if cut > 0, cut < characters.count, !characters[cut - 1].isWhitespace, !characters[cut].isWhitespace {
            while start < characters.count, !characters[start].isWhitespace { start += 1 }
        }
        return String(characters[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: Colchón anti-cortes

/// Decide cuándo empezar (o reanudar) la reproducción de audio que llega por trozos. Empezar con un poco de audio ya guardado
/// evita los cortes por llegadas irregulares; tras quedarse sin audio se espera un colchón menor antes de seguir.
public struct JitterBufferPolicy: Equatable, Sendable {
    /// Milisegundos de audio que deben haber llegado para EMPEZAR a sonar.
    public var startMs: Double = 250
    /// Milisegundos de audio para REANUDAR tras quedarse sin audio.
    public var rebufferMs: Double = 150
    /// Si el flujo se estanca, tras esperar esto se suena lo que haya (mejor un trozo corto que un silencio eterno).
    public var maxHoldMs: Double = 1_200

    public init() {}

    public func shouldPlay(bufferedMs: Double, wasPlaying: Bool, inputFinished: Bool, heldMs: Double) -> Bool {
        guard bufferedMs > 0 else { return false }
        if inputFinished { return true }
        if bufferedMs >= (wasPlaying ? rebufferMs : startMs) { return true }
        return heldMs >= maxHoldMs
    }
}

// MARK: Audio PCM

/// Convierte el audio PCM de 16 bits little-endian que llega por trozos arbitrarios en muestras decimales (-1…1).
/// Un trozo puede terminar en medio de una muestra: el byte sobrante se guarda para el siguiente.
public struct PCMStreamDecoder: Sendable {
    private var leftover: UInt8?

    public init() {}

    public mutating func decode(_ data: Data) -> [Float] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count + 1)
        if let pending = leftover { bytes.append(pending); leftover = nil }
        bytes.append(contentsOf: data)
        if bytes.count % 2 == 1 { leftover = bytes.removeLast() }
        var samples = [Float]()
        samples.reserveCapacity(bytes.count / 2)
        var index = 0
        while index + 1 < bytes.count {
            let value = Int16(bitPattern: UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
            samples.append(Float(value) / 32_768)
            index += 2
        }
        return samples
    }

    public mutating func reset() { leftover = nil }

    public static func milliseconds(frames: Int, sampleRate: Double) -> Double {
        guard sampleRate > 0 else { return 0 }
        return Double(frames) / sampleRate * 1_000
    }
}

// MARK: Métricas

/// Lo ocurrido en UN turno de habla, con tiempos en milisegundos desde que se pidió hablar. Todo se mide con un reloj
/// monótono inyectado: en el teléfono es el reloj del sistema y en las pruebas uno falso, así las pruebas son reproducibles.
public struct VoiceTurnMetrics: Codable, Equatable, Identifiable, Sendable {
    public enum Outcome: String, Codable, Sendable { case running, completed, interrupted, failed, cancelled }

    public var turn: UInt64
    public var id: UInt64 { turn }
    /// «tiempo real» (WebSocket), «por frases» (HTTP) o «voz del sistema».
    public var backend: String
    public var date: Date
    public var startedAt: Double
    /// Desde el envío del mensaje hasta el primer fragmento de texto del modelo.
    public var firstTokenMs: Double?
    /// Desde el primer token hasta tener el primer fragmento listo para hablar.
    public var firstSegmentMs: Double?
    /// Desde el envío hasta el primer audio audible.
    public var firstAudioMs: Double?
    public var segments = 0
    public var charactersSent = 0
    public var audioBytes = 0
    /// Silencios inesperados entre audio y audio (el colchón se vació antes de que llegara más).
    public var gapsMs: [Double] = []
    /// Tiempo entre el fin de una frase y el inicio de la siguiente, según el sintetizador del sistema (incluye las pausas configuradas).
    /// `nil` = ese modo no lo mide (el tiempo real mide los cortes en `gapsMs`). Opcional para no invalidar métricas guardadas antes.
    public var silencesBetweenSegmentsMs: [Double]?
    public var discardedSegments = 0
    public var connectionErrors = 0
    public var reconnects = 0
    public var fellBackToSystemVoice = false
    public var interruptedAtMs: Double?
    /// Desde la orden de interrumpir hasta el silencio real.
    public var silenceAfterInterruptMs: Double?
    /// Audio que llegó a sonar (suma de lo programado).
    public var playbackMs: Double = 0
    public var endedAtMs: Double?
    public var outcome: Outcome = .running
    public var note: String?

    public init(turn: UInt64, backend: String, date: Date = Date(), startedAt: Double) {
        self.turn = turn
        self.backend = backend
        self.date = date
        self.startedAt = startedAt
    }

    public var totalGapMs: Double { gapsMs.reduce(0, +) }
}

/// Anota los hitos de un turno. Estructura de valor: el dueño la guarda y la modifica.
public struct VoiceTurnRecorder: Sendable {
    public private(set) var metrics: VoiceTurnMetrics
    private var firstTokenAt: Double?

    public init(turn: UInt64, backend: String, startedAt: Double, date: Date = Date()) {
        metrics = VoiceTurnMetrics(turn: turn, backend: backend, date: date, startedAt: startedAt)
    }

    private func ms(_ at: Double) -> Double { max(0, (at - metrics.startedAt) * 1_000) }

    public mutating func firstToken(at: Double) {
        guard metrics.firstTokenMs == nil else { return }
        metrics.firstTokenMs = ms(at)
        firstTokenAt = at
    }

    public mutating func segmentReady(at: Double, characters: Int) {
        metrics.segments += 1
        metrics.charactersSent += characters
        if metrics.firstSegmentMs == nil, let tokenAt = firstTokenAt { metrics.firstSegmentMs = max(0, (at - tokenAt) * 1_000) }
    }

    public mutating func firstAudio(at: Double) {
        guard metrics.firstAudioMs == nil else { return }
        metrics.firstAudioMs = ms(at)
    }

    public mutating func audioScheduled(bytes: Int, durationMs: Double) {
        metrics.audioBytes += bytes
        metrics.playbackMs += durationMs
    }

    public mutating func gap(ms value: Double) { if value > 0 { metrics.gapsMs.append(value) } }
    public mutating func segmentSilence(ms value: Double) {
        guard value >= 0 else { return }
        metrics.silencesBetweenSegmentsMs = (metrics.silencesBetweenSegmentsMs ?? []) + [value]
    }
    public mutating func discarded() { metrics.discardedSegments += 1 }
    public mutating func connectionError() { metrics.connectionErrors += 1 }
    public mutating func reconnected() { metrics.reconnects += 1 }
    public mutating func fellBack() { metrics.fellBackToSystemVoice = true }

    public mutating func interrupted(at: Double) {
        guard metrics.interruptedAtMs == nil else { return }
        metrics.interruptedAtMs = ms(at)
    }

    public mutating func silenced(at: Double) {
        guard let interruptedMs = metrics.interruptedAtMs else { return }
        metrics.silenceAfterInterruptMs = max(0, ms(at) - interruptedMs)
    }

    public mutating func finish(at: Double, outcome: VoiceTurnMetrics.Outcome, note: String? = nil) {
        guard metrics.outcome == .running else { return }
        metrics.endedAtMs = ms(at)
        metrics.outcome = outcome
        if let note = note { metrics.note = note }
    }
}

public enum VoiceMetricsReport {
    /// Percentil por interpolación del más cercano (p entre 0 y 1). `nil` si no hay datos.
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = min(max(p, 0), 1) * Double(sorted.count - 1)
        return sorted[Int(rank.rounded())]
    }

    private static func format(_ value: Double?) -> String {
        guard let value = value else { return "—" }
        return value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
    }

    /// Informe de rendimiento en texto, apto para copiar. No promete nada: solo cuenta lo medido.
    public static func summary(_ turns: [VoiceTurnMetrics]) -> String {
        guard !turns.isEmpty else { return "Sin turnos de voz registrados todavía." }
        var lines: [String] = ["Turnos de voz registrados: \(turns.count)"]
        for backend in Array(Set(turns.map(\.backend))).sorted() {
            let group = turns.filter { $0.backend == backend }
            func column(_ keyPath: KeyPath<VoiceTurnMetrics, Double?>) -> [Double] { group.compactMap { $0[keyPath: keyPath] } }
            lines.append("")
            lines.append("== \(backend) (\(group.count) turnos)")
            lines.append("  hasta el primer token:  mediana \(format(percentile(column(\.firstTokenMs), 0.5)))  ·  p95 \(format(percentile(column(\.firstTokenMs), 0.95)))")
            lines.append("  hasta el primer audio:  mediana \(format(percentile(column(\.firstAudioMs), 0.5)))  ·  p95 \(format(percentile(column(\.firstAudioMs), 0.95)))")
            lines.append("  del token al primer fragmento: mediana \(format(percentile(column(\.firstSegmentMs), 0.5)))")
            let gaps = group.flatMap(\.gapsMs)
            lines.append("  cortes inesperados: \(gaps.count) en total (mayor \(format(gaps.max())), suma \(format(gaps.isEmpty ? nil : gaps.reduce(0, +))))")
            lines.append("  tiempo total de la respuesta: mediana \(format(percentile(column(\.endedAtMs), 0.5)))  ·  p95 \(format(percentile(column(\.endedAtMs), 0.95)))")
            let silences = group.compactMap(\.silencesBetweenSegmentsMs).flatMap { $0 }
            if group.contains(where: { $0.silencesBetweenSegmentsMs != nil }) {
                lines.append("  silencios entre frases (sintetizador del sistema): \(silences.count) · mediana \(format(percentile(silences, 0.5))) · mayor \(format(silences.max()))")
            }
            let audioBytes = group.reduce(0) { $0 + $1.audioBytes }
            if audioBytes > 0 { lines.append("  audio recibido: \(audioBytes / 1_024) KB") }
            lines.append("  interrupciones: \(group.filter { $0.interruptedAtMs != nil }.count)  ·  hasta el silencio: mediana \(format(percentile(column(\.silenceAfterInterruptMs), 0.5)))")
            lines.append("  fragmentos descartados: \(group.reduce(0) { $0 + $1.discardedSegments })  ·  errores de conexión: \(group.reduce(0) { $0 + $1.connectionErrors })  ·  reconexiones: \(group.reduce(0) { $0 + $1.reconnects })  ·  respaldos a voz del sistema: \(group.filter(\.fellBackToSystemVoice).count)")
            lines.append("  audio reproducido: \(format(group.reduce(0) { $0 + $1.playbackMs }))  ·  caracteres enviados: \(group.reduce(0) { $0 + $1.charactersSent })")
        }
        return lines.joined(separator: "\n")
    }
}
