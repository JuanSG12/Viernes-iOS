import SwiftUI
import ViernesCore

/// Ajustes de adjuntos: privacidad del envío a la nube, modelo de visión y la matriz de capacidades por cerebro.
struct AttachmentSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var visionDraft = ""
    @State private var checking = false
    @State private var checkResult: String?

    private var askBinding: Binding<Bool> {
        Binding(get: { model.settings.attachmentSettings.askBeforeCloud },
                set: { value in
                    var current = model.settings.attachmentSettings
                    current.askBeforeCloud = value
                    model.settings.attachments = current
                })
    }

    private var libraryBinding: Binding<Bool> {
        Binding(get: { model.settings.attachmentSettings.libraryOn },
                set: { value in
                    var current = model.settings.attachmentSettings
                    current.libraryEnabled = value
                    model.settings.attachments = current
                })
    }

    @State private var confirmEraseLibrary = false

    private var groqVisionModel: String {
        CapabilityMatrix.visionModel(providerID: CloudProviders.groq.id, chatModel: model.settings.cloudBrain.model,
                                     overrides: model.settings.attachmentSettings.visionModels)
    }

    var body: some View {
        List {
            Section("Privacidad") {
                Toggle("Preguntar antes de enviar adjuntos a la nube", isOn: askBinding)
                    .accessibilityIdentifier("attachments-ask-toggle")
                Text("Los documentos se leen en el teléfono. Solo su texto (o las imágenes) sale hacia un proveedor si usas un cerebro en la nube, y por defecto Viernes te lo pregunta antes, diciendo qué sale y adónde. Nunca cambia a otro proveedor sin tu permiso.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Biblioteca") {
                Toggle("Consultar mi biblioteca en las conversaciones", isOn: libraryBinding)
                    .accessibilityIdentifier("library-enabled-toggle")
                Text("\(model.libraryItems.count) elementos guardados. Cuando preguntas por tus documentos («mi contrato», «mis notas»…), Viernes busca fragmentos EN EL TELÉFONO y se los da al modelo con su documento y página. Con un cerebro en la nube te pregunta antes de enviarle esos fragmentos (si no desactivaste la pregunta arriba).")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                Button("Borrar toda la biblioteca", role: .destructive) { confirmEraseLibrary = true }
                    .disabled(model.libraryItems.isEmpty && model.libraryCollections.isEmpty)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Modelo de visión de Groq") {
                TextField(CapabilityMatrix.groqDefaultVisionModel, text: $visionDraft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit(saveVision)
                    .accessibilityIdentifier("attachments-vision-model")
                HStack {
                    Button("Guardar", action: saveVision)
                    Spacer()
                    Button("Restablecer") { visionDraft = ""; saveVision() }
                }
                Button(checking ? "Comprobando…" : "Comprobar que existe en mi cuenta") { check() }
                    .disabled(checking)
                if let checkResult = checkResult {
                    Text(checkResult).font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                Text("El modelo de texto de Groq (gpt-oss) no lee imágenes. Para leerlas, Groq ofrece un modelo de visión en vista previa que puede cambiar de nombre: aquí puedes ajustarlo. Gemini lee imágenes con su propio modelo.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Qué puede leer cada cerebro") {
                ForEach(profiles) { profile in CapabilityCard(profile: profile, isCurrent: profile.id == model.currentBrainProfile.id) }
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Formatos y límites") {
                Text("Leo: \(FileSniffer.supportedDescription). El tipo se comprueba por el CONTENIDO del archivo, no por su extensión.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                Text("Hasta \(AttachmentLimits.maxAttachmentsPerMessage) archivos por mensaje (\(AttachmentLimits.maxImagesPerMessage) imágenes), \(AttachmentLimits.maxDocumentBytes / 1_048_576) MB por documento y \(AttachmentLimits.maxImageSourceBytes / 1_048_576) MB por imagen. Las imágenes se reducen antes de enviarse. Los PDF escaneados se leen con OCR en el teléfono (hasta \(AttachmentLimits.maxOCRPages) páginas).")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                Text("Los archivos adjuntos son información, no órdenes: ninguna instrucción dentro de un archivo puede ejecutar acciones, y con archivos en la conversación hasta crear un recordatorio pide tu confirmación.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))
        }
        .chromeList()
        .navigationTitle("Adjuntos y visión")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("¿Borrar toda la biblioteca?", isPresented: $confirmEraseLibrary, titleVisibility: .visible) {
            Button("Borrar documentos, notas, carpetas e índice", role: .destructive) { model.deleteAllLibrary() }
        } message: {
            Text("Se borra todo el texto guardado. Tu memoria personal no se toca. No se puede deshacer.")
        }
        .onAppear { visionDraft = model.settings.attachmentSettings.visionModels[CloudProviders.groq.id] ?? "" }
    }

    /// Los cerebros que Viernes puede usar, con lo que cada uno lee.
    private var profiles: [BrainProfile] {
        var list: [BrainProfile] = [model.currentBrainProfile]
        let overrides = model.settings.attachmentSettings.visionModels
        let groqChat = CapabilityMatrix.chatProfile(descriptor: ModelCatalog.cloudDescriptor, cloud: .default, overrides: overrides)
        let geminiChat = CapabilityMatrix.chatProfile(
            descriptor: ModelCatalog.cloudDescriptor,
            cloud: CloudBrainSettings(providerID: CloudProviders.gemini.id, model: CloudProviders.gemini.defaultModel), overrides: overrides)
        if let vision = CapabilityMatrix.visionProfile(providerID: CloudProviders.groq.id, chatModel: CloudProviders.groq.defaultModel, overrides: overrides) {
            list.append(contentsOf: [groqChat, vision])
        } else {
            list.append(groqChat)
        }
        list.append(geminiChat)
        for descriptor in [ModelCatalog.all[0], ModelCatalog.all[1]] {
            list.append(CapabilityMatrix.chatProfile(descriptor: descriptor, cloud: .default))
        }
        var seen = Set<String>()
        return list.filter { seen.insert($0.id).inserted }
    }

    private func saveVision() {
        let cleaned = visionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var current = model.settings.attachmentSettings
        if cleaned.isEmpty || cleaned == CapabilityMatrix.groqDefaultVisionModel {
            current.visionModels.removeValue(forKey: CloudProviders.groq.id)
        } else {
            current.visionModels[CloudProviders.groq.id] = cleaned
        }
        model.settings.attachments = current.sanitized()
        visionDraft = model.settings.attachmentSettings.visionModels[CloudProviders.groq.id] ?? ""
    }

    /// Pide a Groq la lista de modelos de la cuenta y comprueba que el de visión está. Solo se ejecuta cuando el usuario lo pide.
    private func check() {
        checking = true
        checkResult = nil
        let target = groqVisionModel
        Task {
            defer { checking = false }
            guard let key = CloudKeyStore.read(providerID: CloudProviders.groq.id) else {
                checkResult = "Primero guarda la clave de Groq en Ajustes › Cerebro en la nube."
                return
            }
            guard let url = OpenAIChatProtocol.endpoint(CloudProviders.groq, path: "models") else { return }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            do {
                let (data, response) = try await URLSession(configuration: configuration).data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    checkResult = "Groq no aceptó la consulta (revisa la clave en Cerebro en la nube)."
                    return
                }
                let ids = OpenAIChatProtocol.parseModelIDs(data)
                if ids.contains(target) {
                    checkResult = "«\(target)» aparece en tu cuenta de Groq. (Que aparezca no garantiza que lea imágenes: eso lo documenta Groq.)"
                } else {
                    let similar = ids.filter { $0.lowercased().contains("qwen") || $0.lowercased().contains("llama-4") || $0.lowercased().contains("vision") }
                    checkResult = "«\(target)» NO aparece en tu cuenta. " + (similar.isEmpty ? "Revisa la documentación de visión de Groq." : "Parecidos: \(similar.prefix(6).joined(separator: ", ")).")
                }
            } catch {
                checkResult = "No pude consultar a Groq: \(error.localizedDescription)"
            }
        }
    }
}

/// Una tarjeta de la matriz de capacidades de un cerebro.
private struct CapabilityCard: View {
    let profile: BrainProfile
    let isCurrent: Bool

    private func mark(_ value: Bool) -> String { value ? "✓" : "✗" }

    var body: some View {
        let caps = profile.capabilities
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(profile.displayName).font(Theme.body(14, weight: .medium)).foregroundStyle(Theme.textPrimary)
                if isCurrent { Text("ACTIVO").font(Theme.mono(9)).foregroundStyle(Theme.accent) }
                Spacer()
                Text(profile.isCloud ? "nube" : "en el teléfono").font(Theme.mono(9)).foregroundStyle(Theme.textSecondary)
            }
            Text("Texto \(mark(caps.text))  ·  Imagen \(mark(caps.imageInput))\(caps.imageInput ? " (≤\(caps.maxImages))" : "")  ·  PDF \(mark(caps.pdfNative))  ·  Audio \(mark(caps.audioInput))  ·  Herramientas \(mark(caps.tools))  ·  Streaming \(mark(caps.streaming))")
                .font(Theme.mono(10)).foregroundStyle(Theme.textPrimary)
            Text("Contexto: \(caps.contextTokens.map { "\($0) tokens" } ?? "sin dato verificado") · texto de archivos por petición: ≈\(caps.excerptBudgetChars) caracteres")
                .font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
            Text(caps.note).font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("capability-card")
    }
}
