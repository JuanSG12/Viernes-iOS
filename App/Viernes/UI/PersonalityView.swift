import SwiftUI
import ViernesCore

/// Personalidad, idioma, autonomía y herramientas del PERFIL activo. Es solo estilo: no cambia las reglas de honestidad, de
/// herramientas ni de seguridad, y la autonomía nunca puede saltarse una confirmación.
struct PersonalityView: View {
    @EnvironmentObject var model: AppModel
    @State private var newWord = ""
    @State private var newSpoken = ""

    private func profile<T>(_ keyPath: WritableKeyPath<ProfileSettings, T>) -> Binding<T> {
        Binding(get: { model.settings.profileSettings[keyPath: keyPath] },
                set: { value in
                    var current = model.settings.profileSettings
                    current[keyPath: keyPath] = value
                    model.settings.profile = current
                })
    }

    private func personality<T>(_ keyPath: WritableKeyPath<PersonalityConfig, T>) -> Binding<T> {
        Binding(get: { model.settings.profileSettings.personality[keyPath: keyPath] },
                set: { value in
                    var current = model.settings.profileSettings
                    current.personality[keyPath: keyPath] = value
                    model.settings.profile = current
                })
    }

    private func toolBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { model.settings.profileSettings.isToolEnabled(name) },
                set: { enabled in
                    var current = model.settings.profileSettings
                    current.disabledTools.removeAll { $0 == name }
                    if !enabled { current.disabledTools.append(name) }
                    model.settings.profile = current
                })
    }

    private var preview: String {
        PersonalityPrompt.section(for: model.settings.profileSettings)
            ?? "Nada: con los valores por defecto el modelo recibe exactamente el mismo texto de siempre."
    }

    var body: some View {
        List {
            Section("Asistente") {
                TextField(ProfileSettings.defaultAssistantName, text: profile(\.assistantName))
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("personality-name")
                Picker("Idioma de respuesta", selection: profile(\.responseLanguage)) {
                    ForEach(ProfileLocales.languages) { Text($0.name.capitalized).tag($0.code) }
                }
                Picker("Región", selection: profile(\.region)) {
                    ForEach(ProfileLocales.regions) { Text($0.name).tag($0.code) }
                }
                Text("El nombre y el idioma cambian cómo se presenta y en qué idioma contesta. La palabra de activación sigue siendo «Viernes», y la voz y el idioma de dictado se eligen en Ajustes › Voz y Escucha.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Trato y estilo") {
                Picker("Trato", selection: personality(\.formality)) {
                    ForEach(PersonalityConfig.Formality.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented).accessibilityIdentifier("personality-formality")
                Picker("Naturalidad", selection: personality(\.naturalness)) {
                    ForEach(PersonalityConfig.Naturalness.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Longitud", selection: personality(\.length)) {
                    ForEach(PersonalityConfig.Length.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Estilo", selection: personality(\.style)) {
                    ForEach(PersonalityConfig.Style.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Autonomía") {
                Picker("Autonomía", selection: profile(\.autonomy)) {
                    ForEach(AutonomyLevel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented).accessibilityIdentifier("personality-autonomy")
                Text(model.settings.profileSettings.autonomy.summary).font(.footnote).foregroundStyle(Theme.textPrimary)
                Text("La autonomía solo puede pedir MÁS confirmaciones, nunca menos: borrar, enviar o abrir enlaces siempre se confirman, y con archivos adjuntos o documentos de la biblioteca en la conversación también las acciones reversibles.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Instrucciones personales") {
                TextEditor(text: personality(\.personalInstructions))
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .accessibilityIdentifier("personality-instructions")
                Text("\(model.settings.profileSettings.personality.personalInstructions.count) / \(PersonalityConfig.maxInstructionLength) caracteres. Escribe cómo quieres que te trate («háblame de forma pausada», «explícame con ejemplos»). Solo es estilo: no puede cambiar las reglas de honestidad ni de seguridad de Viernes, ni autorizar acciones.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Pronunciación") {
                ForEach(model.settings.profileSettings.personality.pronunciation) { hint in
                    HStack {
                        Text(hint.word).foregroundStyle(Theme.textPrimary)
                        Image(systemName: "arrow.right").foregroundStyle(Theme.textSecondary)
                        Text(hint.spoken).foregroundStyle(Theme.accent)
                    }
                }
                .onDelete { offsets in
                    var current = model.settings.profileSettings
                    current.personality.pronunciation.remove(atOffsets: offsets)
                    model.settings.profile = current
                }
                HStack {
                    TextField("Palabra", text: $newWord).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Se dice…", text: $newSpoken).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button("Añadir") { addHint() }
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty || newSpoken.trimmingCharacters(in: .whitespaces).isEmpty
                                  || model.settings.profileSettings.personality.pronunciation.count >= PersonalityConfig.maxHints)
                }
                Text("Cambia solo lo que se OYE (por ejemplo «ACME» → «ácme»); el texto en pantalla no cambia.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Herramientas de este perfil") {
                ForEach(ToolCatalog.all) { tool in
                    Toggle(isOn: toolBinding(tool.name)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.summary).font(.footnote).foregroundStyle(Theme.textPrimary)
                            Text(tool.name).font(Theme.mono(9)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                Text("Una herramienta apagada no se le ofrece al modelo ni se ejecuta, aunque la pida. Los permisos de iOS (calendario, contactos…) se siguen activando en Ajustes › Privacidad.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Lo que se le añade al modelo") {
                Text(preview)
                    .font(Theme.mono(10)).foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("personality-preview")
                Text("Este es el texto real que se agrega a las instrucciones del modelo con este perfil (después de neutralizar y acotar lo que escribiste).")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))
        }
        .chromeList()
        .navigationTitle("Personalidad")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addHint() {
        var current = model.settings.profileSettings
        current.personality.pronunciation.append(PronunciationHint(word: newWord, spoken: newSpoken))
        current.personality = current.personality.sanitized()
        model.settings.profile = current
        newWord = ""
        newSpoken = ""
    }
}
