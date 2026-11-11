import SwiftUI
import UIKit
import ViernesCore

/// Banco de medición de la voz: mismas frases, mismas condiciones, un resultado por modo. Los números son de ESTE iPhone, de esta red
/// y de este momento; no hay ganador automático.
struct VoiceBenchView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: Set<VoiceBenchBackend> = [.system]

    private func available(_ backend: VoiceBenchBackend) -> Bool { backend.settings(base: model.settings.voice) != nil }

    private var report: String {
        let device = "\(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)"
        return VoiceBenchReport.text(runs: model.voiceBenchRuns, device: device)
    }

    var body: some View {
        List {
            Section("Qué mide") {
                Text("Dice \(VoiceBenchPhrases.all.count) frases fijas (\(VoiceBenchPhrases.totalCharacters) caracteres) con cada modo que elijas y anota: tiempo hasta el primer audio, tiempo total, cortes o silencios entre frases, errores, audio recibido y variación de memoria. Hazlo con la pantalla encendida y el volumen subido; repítelo varias veces y en distintas redes antes de concluir.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Modos") {
                ForEach(VoiceBenchBackend.allCases) { backend in
                    Toggle(isOn: Binding(get: { selected.contains(backend) },
                                         set: { value in if value { selected.insert(backend) } else { selected.remove(backend) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(backend.label).foregroundStyle(Theme.textPrimary)
                            if !available(backend) {
                                Text("No disponible: elige una voz y guarda la clave en Ajustes › Voz › ElevenLabs.").font(.caption2).foregroundStyle(Theme.textSecondary)
                            } else if backend.usesCloud {
                                Text("Gasta ≈ \(VoiceBenchPhrases.totalCharacters) caracteres de tu plan de ElevenLabs.").font(.caption2).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    .disabled(!available(backend) || model.voiceBenchRunning)
                }
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section {
                if model.voiceBenchRunning {
                    Button("Cancelar medición", role: .destructive) { model.cancelVoiceBench() }
                } else {
                    Button("Empezar medición") { model.startVoiceBench(VoiceBenchBackend.allCases.filter { selected.contains($0) && available($0) }) }
                        .disabled(selected.filter { available($0) }.isEmpty)
                        .accessibilityIdentifier("voice-bench-start")
                }
                if let status = model.voiceBenchStatus {
                    Text(status).font(.footnote).foregroundStyle(Theme.textPrimary).accessibilityIdentifier("voice-bench-status")
                }
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Resultados") {
                Text(report)
                    .font(Theme.mono(11)).foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("voice-bench-report")
                Button("Copiar resultados") { UIPasteboard.general.string = report }
                    .disabled(model.voiceBenchRuns.isEmpty)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))
        }
        .chromeList()
        .navigationTitle("Banco de medición")
        .navigationBarTitleDisplayMode(.inline)
    }
}
