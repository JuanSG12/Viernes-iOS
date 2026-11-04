import SwiftUI
import ViernesCore

struct VoicePickerView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section("Ajustes de habla") {
                Toggle("Hablar las respuestas", isOn: $model.settings.voice.speakResponses)
                slider("Velocidad", value: Binding(get: { Double(model.settings.voice.rate) }, set: { model.settings.voice.rate = Float($0) }), range: 0.3...0.65, format: "%.2f")
                slider("Volumen", value: Binding(get: { Double(model.settings.voice.volume) }, set: { model.settings.voice.volume = Float($0) }), range: 0...1, format: "%.0f%%", scale: 100)
                slider("Tono", value: Binding(get: { Double(model.settings.voice.pitch) }, set: { model.settings.voice.pitch = Float($0) }), range: 0.7...1.3, format: "%.2f")
                slider("Pausas entre frases", value: $model.settings.voice.pauseScale, range: 0...2.5, format: "×%.1f")
                Button("Escuchar muestra") { model.previewVoice(identifier: model.settings.voice.voiceIdentifier) }
                    .buttonStyle(HoloButtonStyle()).accessibilityIdentifier("voice-preview")
                Button("Detener") { model.interrupt() }.buttonStyle(HoloButtonStyle(tint: Theme.amber))
            }
            .listRowBackground(Theme.deep.opacity(0.5))

            Section {
                Button { model.settings.voice.voiceIdentifier = nil } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Automática (recomendada)").foregroundStyle(Theme.textPrimary)
                            Text("Elige la mejor voz femenina en español disponible: calidad Premium > Mejorada > Estándar, colombiano > latino > España.")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        if model.settings.voice.voiceIdentifier == nil { Image(systemName: "checkmark").foregroundStyle(Theme.cyan) }
                    }
                }
                ForEach(model.voices) { voice in
                    Button { model.settings.voice.voiceIdentifier = voice.identifier; model.previewVoice(identifier: voice.identifier) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(voice.name).foregroundStyle(Theme.textPrimary)
                                Text("\(voice.language) · \(voice.quality.displayName)\(VoiceRanker.isRoboticOrNovelty(voice) ? " · suena robótica" : "")")
                                    .font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if model.settings.voice.voiceIdentifier == voice.identifier { Image(systemName: "checkmark").foregroundStyle(Theme.cyan) }
                        }
                    }
                }
                if model.voices.isEmpty {
                    Text("No se encontraron voces en español en este dispositivo.").foregroundStyle(Theme.amber)
                }
            } header: { Text("Voz") } footer: {
                Text("Para una voz más natural, descarga una voz «Mejorada» o «Premium» de español en Ajustes › Accesibilidad › Contenido hablado › Voces › Español. Las voces se procesan en el dispositivo, sin internet.")
            }
            .listRowBackground(Theme.deep.opacity(0.5))
        }
        .holoList()
        .navigationTitle("Voz y habla")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.interrupt() }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String, scale: Double = 1) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(String(format: format, value.wrappedValue * scale)).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Slider(value: value, in: range)
        }
    }
}
