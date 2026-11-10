import SwiftUI
import UIKit
import ViernesCore

/// Informe de rendimiento de la voz: cuánto tarda en empezar a hablar y dónde se pierde el tiempo (modelo, red, reproducción).
/// Lo medido es de ESTE iPhone y de las últimas respuestas; no es una promesa de latencia. Solo tiempos y conteos, nunca el texto.
struct VoicePerformanceView: View {
    @ObservedObject var metrics: VoiceMetricsStore
    @State private var confirmClear = false

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_CO")
        formatter.dateFormat = "d MMM HH:mm:ss"
        return formatter
    }()

    var body: some View {
        List {
            Section {
                Text(metrics.report)
                    .font(Theme.mono(11)).foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("voice-report")
            } header: { Text("Resumen") } footer: {
                Text("«Hasta el primer audio» incluye lo que tarda el modelo en escribir la primera frase. Un «corte inesperado» es un silencio entre dos trozos de audio porque el siguiente no había llegado todavía.")
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section {
                if metrics.turns.isEmpty {
                    Text("Todavía no hay respuestas habladas. Pídele algo a Viernes con la voz activada.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                ForEach(metrics.turns.reversed()) { turn in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(Self.formatter.string(from: turn.date)) · \(turn.backend) · \(label(turn.outcome))")
                            .font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
                        Text("token \(ms(turn.firstTokenMs)) · fragmento +\(ms(turn.firstSegmentMs)) · audio \(ms(turn.firstAudioMs))")
                            .font(Theme.mono(11)).foregroundStyle(Theme.textPrimary)
                        Text("cortes \(turn.gapsMs.count) (\(ms(turn.gapsMs.isEmpty ? nil : turn.totalGapMs))) · descartados \(turn.discardedSegments) · errores \(turn.connectionErrors) · reconexiones \(turn.reconnects)" + (turn.fellBackToSystemVoice ? " · pasó a la voz de Apple" : ""))
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                        if let silence = turn.silenceAfterInterruptMs {
                            Text("interrumpida: silencio en \(ms(silence))").font(.caption).foregroundStyle(Theme.amber)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: { Text("Últimas respuestas") }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section {
                Button("Copiar informe") { UIPasteboard.general.string = metrics.report }
                    .disabled(metrics.turns.isEmpty)
                Button("Borrar métricas", role: .destructive) { confirmClear = true }
                    .disabled(metrics.turns.isEmpty)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))
        }
        .chromeList()
        .navigationTitle("Rendimiento de la voz")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("¿Borrar las métricas de voz?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Borrar", role: .destructive) { metrics.clear() }
        }
    }

    private func ms(_ value: Double?) -> String {
        guard let value = value else { return "—" }
        return String(format: "%.0f ms", value)
    }

    private func label(_ outcome: VoiceTurnMetrics.Outcome) -> String {
        switch outcome {
        case .running: return "en curso"
        case .completed: return "terminó"
        case .interrupted: return "interrumpida"
        case .failed: return "falló"
        case .cancelled: return "sustituida"
        }
    }
}
