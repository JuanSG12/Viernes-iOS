import Foundation

/// Banco de medición de la voz: las MISMAS frases, en las mismas condiciones, por cada modo de voz, para comparar con números del
/// propio iPhone y no con impresiones. Lo que se mide viene de `VoiceTurnMetrics` (el mismo registro de los turnos reales).
public enum VoiceBenchPhrases {
    /// Frases fijas en español colombiano: corta, con hora y nombres, con pregunta y signos, y larga con cifras. No cambian entre
    /// versiones para que las mediciones sean comparables.
    public static let all: [String] = [
        "Listo, ya lo hice.",
        "Mañana tienes una reunión a las nueve y media con el equipo de ventas, y después un almuerzo con Karen en el centro.",
        "¿Sabías que hoy llueve? Sí, es probable; lleva paraguas, por favor. Gracias por avisarme, nos vemos pronto.",
        "El portátil que te recomiendo cuesta dos millones ochocientos mil pesos, trae dieciséis gigas de memoria y un procesador rápido. Tiene buena batería, un teclado cómodo y sirve para programar durante todo el día sin calentarse, aunque la pantalla es un poco pequeña para mi gusto."
    ]

    public static var totalCharacters: Int { all.reduce(0) { $0 + $1.count } }
}

public struct VoiceBenchRun: Codable, Equatable, Sendable {
    public var backend: String
    public var phraseIndex: Int
    public var metrics: VoiceTurnMetrics
    /// Variación de la memoria residente de la app durante la frase, en MB (puede ser negativa; es ruidosa).
    public var memoryDeltaMB: Double?

    public init(backend: String, phraseIndex: Int, metrics: VoiceTurnMetrics, memoryDeltaMB: Double? = nil) {
        self.backend = backend
        self.phraseIndex = phraseIndex
        self.metrics = metrics
        self.memoryDeltaMB = memoryDeltaMB
    }
}

public enum VoiceBenchReport {
    /// Texto copiable con los resultados por modo. No elige un «ganador»: con pocas frases solo muestra los números y avisa de sus límites.
    public static func text(runs: [VoiceBenchRun], date: Date = Date(), device: String = "") -> String {
        guard !runs.isEmpty else { return "El banco todavía no ha medido nada." }
        var lines = ["Banco de medición de voz · \(VoiceBenchPhrases.all.count) frases fijas (\(VoiceBenchPhrases.totalCharacters) caracteres)" + (device.isEmpty ? "" : " · \(device)")]
        lines.append(VoiceMetricsReport.summary(runs.map(\.metrics)))
        var memory: [String] = []
        for backend in Array(Set(runs.map(\.backend))).sorted() {
            let deltas = runs.filter { $0.backend == backend }.compactMap(\.memoryDeltaMB)
            if let median = VoiceMetricsReport.percentile(deltas, 0.5) {
                memory.append("\(backend): mediana \(String(format: "%+.1f", median)) MB")
            }
        }
        if !memory.isEmpty { lines.append("\nVariación de memoria residente por frase: " + memory.joined(separator: " · ")) }
        let failed = runs.filter { $0.metrics.outcome != .completed }
        if !failed.isEmpty { lines.append("\nFrases que no terminaron bien: \(failed.count) de \(runs.count).") }
        lines.append("\nLímites: son \(runs.count) mediciones en esta red y este momento; la memoria es ruidosa; «cortes» solo los mide el modo en tiempo real y «silencios entre frases» solo la voz del sistema; el modo por frases (HTTP) no mide ninguno. Repite varias veces antes de concluir.")
        return lines.joined(separator: "\n")
    }
}
