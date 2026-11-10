import Foundation
import ViernesCore

/// Métricas de los últimos turnos de voz (en memoria, solo en este iPhone). Alimentan el informe de rendimiento de voz.
/// Guardan tiempos, conteos y el tipo de voz; nunca el texto que se dijo.
@MainActor
final class VoiceMetricsStore: ObservableObject {
    @Published private(set) var turns: [VoiceTurnMetrics] = []
    private static let capacity = 50

    func add(_ metrics: VoiceTurnMetrics) {
        // Un turno que no llegó a decir nada (respuesta vacía) no aporta datos.
        guard metrics.segments > 0 || metrics.firstAudioMs != nil || metrics.connectionErrors > 0 else { return }
        turns.append(metrics)
        if turns.count > Self.capacity { turns.removeFirst(turns.count - Self.capacity) }
        Diagnostics.shared.log("voz: turno \(metrics.turn) [\(metrics.backend)] token \(Self.format(metrics.firstTokenMs)), audio \(Self.format(metrics.firstAudioMs)), cortes \(metrics.gapsMs.count), \(metrics.outcome.rawValue)")
    }

    func clear() { turns.removeAll() }

    var report: String { VoiceMetricsReport.summary(turns) }

    private static func format(_ value: Double?) -> String {
        guard let value = value else { return "—" }
        return String(format: "%.0f ms", value)
    }
}
