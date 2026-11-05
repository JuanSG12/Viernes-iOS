import SwiftUI
import ViernesCore

struct ElevenLabsVoiceView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    @State private var keyInput = ""
    @State private var hasKey = false
    @State private var keyError: String?
    @State private var loading = false
    @State private var voices: [CloudVoiceInfo] = []
    @State private var message: String?

    private var cloud: ElevenLabsSettings { model.settings.voice.elevenLabs ?? .default }

    var body: some View {
        List {
            Section {
                Text("Las voces del iPhone suenan a robot. ElevenLabs genera voces neuronales mucho más humanas, con una clave gratuita tuya. Es opcional: si falla, Viernes habla con la voz de Apple.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                Label("Cada frase que Viernes diga se envía a ElevenLabs para convertirla en audio. El plan gratuito tiene una cuota mensual de caracteres limitada (consúltala en tu cuenta) y no está pensado para uso comercial. Tu micrófono y tu audio NO se envían.", systemImage: "exclamationmark.shield")
                    .font(.caption).foregroundStyle(Theme.amber)
            }
            .listRowBackground(Color.clear)

            Section {
                if hasKey { Label("Clave guardada en el Llavero de este iPhone", systemImage: "checkmark.seal").foregroundStyle(Theme.accent) }
                SecureField(hasKey ? "Pegar una clave nueva" : "Pega aquí tu clave de ElevenLabs", text: $keyInput)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("eleven-key")
                Button("Guardar clave") { saveKey() }
                    .buttonStyle(ChromeButtonStyle())
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let keyError { Text(keyError).font(.caption).foregroundStyle(Theme.alert) }
                Button("Conseguir una clave gratuita") {
                    if let url = URL(string: ElevenLabsProtocol.keyPageURL) { openURL(url) }
                }.buttonStyle(ChromeButtonStyle())
                if hasKey {
                    Button("Quitar la clave", role: .destructive) {
                        CloudKeyStore.delete(providerID: ElevenLabsProtocol.keyProviderID)
                        hasKey = false
                        voices = []
                        update { $0.enabled = false }
                    }
                }
            } header: { Text("Clave") } footer: {
                Text("Solo se guarda en el Llavero (no sale del iPhone ni entra en copias) y solo se envía a ElevenLabs. Al crearla, si puedes, déjala solo con permisos de texto a voz y lectura de voces.")
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section {
                Button(loading ? "Cargando…" : "Cargar mis voces") { loadVoices() }
                    .buttonStyle(ChromeButtonStyle())
                    .disabled(loading || !hasKey)
                    .accessibilityIdentifier("eleven-load")
                if let message { Text(message).font(.caption).foregroundStyle(Theme.amber) }
                if cloud.hasVoice {
                    Label("Voz elegida: \(cloud.voiceName.isEmpty ? cloud.voiceID : cloud.voiceName)", systemImage: "person.wave.2")
                        .foregroundStyle(Theme.accent)
                }
                ForEach(voices) { voice in
                    Button {
                        update { $0.voiceID = voice.id; $0.voiceName = voice.name }
                        model.previewCloudVoice()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(voice.name).foregroundStyle(Theme.textPrimary)
                                if !voice.detail.isEmpty || !voice.category.isEmpty {
                                    Text([voice.detail, voice.category].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(Theme.textSecondary)
                                }
                            }
                            Spacer()
                            if cloud.voiceID == voice.id { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                }
            } header: { Text("Voz") } footer: {
                Text("Si una voz da error de plan, elige otra de las predefinidas. Para que suene en español natural, prueba varias: el acento depende de la voz y del modelo.")
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section {
                Toggle("Usar la voz de ElevenLabs", isOn: Binding(get: { cloud.enabled }, set: { value in update { $0.enabled = value } }))
                    .disabled(!hasKey || !cloud.hasVoice)
                    .accessibilityIdentifier("eleven-enabled")
                Button("Escuchar muestra") { model.previewCloudVoice() }
                    .buttonStyle(ChromeButtonStyle())
                    .disabled(!hasKey || !cloud.hasVoice)
                Button("Detener") { model.interrupt() }.buttonStyle(ChromeButtonStyle(tint: Theme.amber))
                if !hasKey || !cloud.hasVoice {
                    Text("Guarda la clave y elige una voz para poder activarla.").font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            .listRowBackground(Theme.carbon.opacity(0.5))
        }
        .chromeList()
        .navigationTitle("Voz neuronal")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { hasKey = CloudKeyStore.hasKey(providerID: ElevenLabsProtocol.keyProviderID) }
        .onDisappear { model.interrupt() }
    }

    private func update(_ change: (inout ElevenLabsSettings) -> Void) {
        var next = cloud
        change(&next)
        model.settings.voice.elevenLabs = next
    }

    private func saveKey() {
        do {
            if try CloudKeyStore.save(keyInput, providerID: ElevenLabsProtocol.keyProviderID) {
                keyInput = ""
                keyError = nil
                hasKey = true
                message = nil
            } else {
                keyError = "Eso no parece una clave: debe ser una sola línea de letras, números y guiones bajos, sin espacios."
            }
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func loadVoices() {
        loading = true
        message = nil
        Task {
            let result = await ElevenLabsClient.fetchVoices()
            await MainActor.run {
                loading = false
                switch result {
                case .success(let list):
                    voices = list
                    if list.isEmpty { message = "La clave funciona, pero no hay voces en la lista. Revisa los permisos de la clave («voices_read»)." }
                case .failure(let failure):
                    message = failure.message
                }
            }
        }
    }
}
