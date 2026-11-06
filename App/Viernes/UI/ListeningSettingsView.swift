import SwiftUI
import UIKit
import ViernesCore

struct ListeningSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var askCloudConsent = false

    /// Enlaza un campo de `SpeechSettings` (guardado como opcional en los ajustes para no romper ajustes antiguos).
    private func speech<T>(_ keyPath: WritableKeyPath<SpeechSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings.speechSettings[keyPath: keyPath] },
            set: { value in
                var current = model.settings.speechSettings
                current[keyPath: keyPath] = value
                model.settings.speech = current
            })
    }

    private var cloudBinding: Binding<Bool> {
        Binding(
            get: { model.settings.speechSettings.cloudTranscription },
            set: { on in
                if on {
                    askCloudConsent = true
                } else {
                    var current = model.settings.speechSettings
                    current.cloudTranscription = false
                    current.cloudConsentAt = nil          // al apagarlo se retira el consentimiento: volver a activarlo lo pide de nuevo
                    model.settings.speech = current
                }
            })
    }

    var body: some View {
        List {
            Section {
                Toggle("Escuchar la palabra «Viernes»", isOn: $model.settings.wakeWordEnabled)
                    .accessibilityIdentifier("wake-toggle")
                Text("Solo funciona MIENTRAS la app está abierta y en pantalla. El micrófono permanece abierto en ese modo y la app lo indica con un punto rojo. iOS no permite a una app de terceros escuchar con la app cerrada o el teléfono bloqueado, y Viernes no lo intenta. Para activarla en esos casos usa Siri: «Oye Siri, abre Viernes» o «Habla con Viernes». Consume más batería mientras está activa.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            } header: { Text("Palabra de activación") }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section {
                Toggle("Conversación continua", isOn: $model.settings.continuousConversation)
                Text("Al terminar de hablar, Viernes vuelve a escucharte sola. Apágalo para controlar tú cada turno.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            } header: { Text("Manos libres") }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section {
                Picker("Idioma", selection: $model.settings.recognitionLocale) {
                    Text("Español (Colombia)").tag("es-CO")
                    Text("Español (México)").tag("es-MX")
                    Text("Español (EE. UU.)").tag("es-US")
                    Text("Español (España)").tag("es-ES")
                }
                Toggle("Permitir reconocimiento de Apple por internet", isOn: $model.settings.allowServerRecognition)
                    .accessibilityIdentifier("server-recognition-toggle")
                Text("Apagado (recomendado): Viernes solo transcribe EN el dispositivo y el audio nunca sale del teléfono. Si tu iPhone no tiene el dictado del idioma elegido descargado, verás un aviso; descárgalo en Ajustes › General › Teclado › Dictado. Si lo enciendes, cuando no haya modelo local Apple podrá procesar tu audio en sus servidores.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Toggle("Usar el micrófono del iPhone con audífonos Bluetooth", isOn: speech(\.preferBuiltInMic))
                Text("El micrófono de unos audífonos Bluetooth tiene mucha menos calidad y es una causa frecuente de mala transcripción. Con esto activado, Viernes oye por el micrófono del iPhone aunque los audífonos estén conectados.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            } header: { Text("Reconocimiento de voz") }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section {
                Picker("Antes de enviar", selection: speech(\.review)) {
                    Text("Enviar de inmediato").tag(SpeechSettings.ReviewMode.off)
                    Text("Mostrar 2,5 s para corregir").tag(SpeechSettings.ReviewMode.brief)
                    Text("Pedir confirmación siempre").tag(SpeechSettings.ReviewMode.always)
                }
                .accessibilityIdentifier("review-mode")
                Text("Lo que Viernes entendió aparece en pantalla antes de llegar al cerebro: puedes tocarlo para corregirlo, enviarlo ya o descartarlo. En «Mostrar 2,5 s» se envía solo si no lo tocas. Tras enviarlo, un lápiz junto a tu mensaje permite corregirlo y reenviarlo.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pausa para cerrar la frase: \(String(format: "%.1f", model.settings.speechSettings.endSilenceSeconds)) s")
                    Slider(value: speech(\.endSilenceSeconds), in: 0.8...3.0, step: 0.1)
                        .tint(Theme.accent)
                        .accessibilityIdentifier("end-silence")
                }
                Text("Cuánto silencio hace falta para dar por terminada tu frase. Súbela si te corta cuando haces pausas (por ejemplo al dictar un correo); bájala si quieres respuestas más rápidas.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            } header: { Text("Revisar lo que dices") }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section {
                Toggle("Corregir y aprender de mis correcciones", isOn: speech(\.autoCorrect))
                NavigationLink {
                    GlossaryView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nombres y términos").foregroundStyle(Theme.textPrimary)
                        Text("\(model.settings.speechSettings.glossary.count) nombres · \(model.settings.speechSettings.learned.count) correcciones aprendidas")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                .accessibilityIdentifier("glossary-link")
                Text("Los nombres de tu lista se le dan al reconocedor para que los prefiera, y lo transcrito se corrige antes de enviarlo (por ejemplo «kisame guy» → «Kisameyguy», o un correo dictado «juan arroba gmail punto com» → juan@gmail.com). Es deliberadamente prudente: solo toca palabras casi iguales a un nombre de tu lista.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            } header: { Text("Nombres y correcciones") }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section {
                Toggle("Transcribir con Groq Whisper (envía el audio)", isOn: cloudBinding)
                    .disabled(!CloudTranscriber.hasKey() && !model.settings.speechSettings.cloudTranscription)
                    .accessibilityIdentifier("cloud-transcription-toggle")
                if !CloudTranscriber.hasKey() {
                    Text("Primero guarda tu clave de Groq en Cerebro en la nube.").font(.caption).foregroundStyle(Theme.amber)
                }
                Text("Apagado por defecto. Si lo activas, el AUDIO de lo que dictes tocando el micrófono se envía a Groq para transcribirlo con Whisper (con la misma clave gratuita; se aplican sus límites). No se envía audio de la escucha «Viernes», ni a ElevenLabs ni a nadie más, y el archivo se borra del teléfono al terminar. La transcripción del iPhone sigue funcionando siempre y es la que se usa si la nube falla. No se ha comprobado que Whisper sea mejor en tu voz: el diagnóstico guarda las dos versiones para que lo compares.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            } header: { Text("Transcripción en la nube (opcional)") }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section {
                Toggle("Guardar el historial de reconocimiento", isOn: speech(\.keepHistory))
                NavigationLink {
                    RecognitionHistoryView(history: model.recognition)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Diagnóstico del reconocimiento").foregroundStyle(Theme.textPrimary)
                        Text("\(model.recognition.records.count) frases registradas").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                .accessibilityIdentifier("recognition-history-link")
            } header: { Text("Diagnóstico") } footer: {
                Text("Guarda solo texto (nunca audio), cifrado en este iPhone, para saber si un error viene de la captura, del reconocimiento o del procesamiento posterior.")
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Siempre disponible") {
                Label("Botón del micrófono y toque sobre el núcleo", systemImage: "mic")
                Label("Teclado para escribir sin voz", systemImage: "keyboard")
            }
            .foregroundStyle(Theme.textPrimary)
            .listRowBackground(Theme.carbon.opacity(0.5))
        }
        .chromeList()
        .navigationTitle("Escucha y activación")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("¿Enviar tu audio a Groq?", isPresented: $askCloudConsent, titleVisibility: .visible) {
            Button("Sí, enviar el audio de mis dictados") {
                var current = model.settings.speechSettings
                current.cloudConsentAt = Date()
                current.cloudTranscription = true
                model.settings.speech = current
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("El audio de lo que dictes con el botón saldrá del iPhone hacia Groq (EE. UU.) para transcribirlo. Puedes apagarlo cuando quieras.")
        }
    }
}

/// Nombres propios y términos frecuentes (para el reconocedor y para la corrección) y lo aprendido de las ediciones del usuario.
struct GlossaryView: View {
    @EnvironmentObject var model: AppModel
    @State private var newTerm = ""

    private var speech: SpeechSettings { model.settings.speechSettings }

    private func update(_ change: (inout SpeechSettings) -> Void) {
        var current = model.settings.speechSettings
        change(&current)
        model.settings.speech = current.sanitized()
    }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Un nombre o término (p. ej. Wendy Ramírez)", text: $newTerm)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("glossary-field")
                    Button("Añadir") {
                        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !term.isEmpty else { return }
                        update { $0.glossary.append(term) }
                        newTerm = ""
                    }
                    .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || speech.glossary.count >= SpeechSettings.maxGlossary)
                    .accessibilityIdentifier("glossary-add")
                }
                ForEach(speech.glossary, id: \.self) { term in Text(term).foregroundStyle(Theme.textPrimary) }
                    .onDelete { offsets in update { $0.glossary.remove(atOffsets: offsets) } }
            } header: { Text("Nombres y términos") } footer: {
                Text("Hasta \(SpeechSettings.maxGlossary). Personas, empresas, lugares o palabras que sueles decir y que se transcriben mal.")
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section {
                if speech.learned.isEmpty {
                    Text("Todavía nada. Cuando corrijas una frase dictada, Viernes apunta aquí lo que cambiaste.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                ForEach(Array(speech.learned.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text("«\(item.heard)»").foregroundStyle(Theme.textSecondary)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(Theme.accent)
                        Text("«\(item.meant)»").foregroundStyle(Theme.textPrimary)
                    }
                }
                .onDelete { offsets in update { $0.learned.remove(atOffsets: offsets) } }
            } header: { Text("Aprendido de tus correcciones") } footer: {
                Text("Desliza para quitar lo que no quieras que se repita.")
            }
            .listRowBackground(Theme.carbon.opacity(0.5))
        }
        .chromeList()
        .navigationTitle("Nombres y términos")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Historial de reconocimiento: qué entregó el reconocedor, qué se corrigió, qué editó el usuario y, si estaba activada, qué dijo
/// Whisper. Con él se separa si un fallo viene de la captura (entrada de audio, silencio), del reconocimiento (texto) o del procesamiento
/// posterior (corrección, cerebro). También permite comparar el reconocimiento local con Whisper con datos propios, sin suponer.
struct RecognitionHistoryView: View {
    @ObservedObject var history: RecognitionHistory
    @EnvironmentObject var model: AppModel
    @State private var confirmClear = false

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_CO")
        formatter.dateFormat = "d MMM HH:mm:ss"
        return formatter
    }()

    var body: some View {
        let stats = history.stats
        List {
            Section {
                row("Frases registradas", "\(stats.total)")
                row("Sin texto (nadie habló o no se captó)", "\(stats.empty)")
                row("Con error del reconocedor", "\(stats.withError)")
                row("Reiniciadas automáticamente", "\(stats.retried)")
                row("Corregidas solas", "\(stats.autoCorrected)")
                row("Editadas por ti", "\(stats.edited)")
                if stats.cloudCompared > 0 {
                    row("Comparadas con Whisper", "\(stats.cloudCompared)")
                    row("Votos: iPhone / Whisper / ninguna", "\(stats.localVotes) / \(stats.cloudVotes) / \(stats.neitherVotes)")
                }
            } header: { Text("Resumen") } footer: {
                if stats.cloudCompared > 0 {
                    Text(comparisonText(stats)).font(.footnote)
                } else {
                    Text("Para comparar con Whisper, actívalo en Escucha y activación y vota qué versión acertó en cada frase.")
                }
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section {
                if history.records.isEmpty {
                    Text("Sin frases todavía.").font(.caption).foregroundStyle(Theme.textSecondary)
                }
                ForEach(history.records.reversed()) { record in
                    recordView(record)
                }
            } header: { Text("Últimas frases") }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section {
                Button("Copiar informe") { UIPasteboard.general.string = history.report() }
                    .disabled(history.records.isEmpty)
                Button("Borrar historial", role: .destructive) { confirmClear = true }
                    .disabled(history.records.isEmpty)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))
        }
        .chromeList()
        .navigationTitle("Diagnóstico de voz")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("¿Borrar el historial de reconocimiento?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Borrar", role: .destructive) { history.clear() }
        }
    }

    private func comparisonText(_ stats: RecognitionStats) -> String {
        guard stats.votesCast >= 5 else {
            return "Faltan votos para sacar conclusiones (hay \(stats.votesCast); con menos de 5 no se afirma nada sobre cuál transcribe mejor)."
        }
        if stats.cloudVotes > stats.localVotes { return "En TUS votos, Whisper acertó más veces que el reconocimiento del iPhone (\(stats.cloudVotes) frente a \(stats.localVotes)). Es una muestra pequeña y personal." }
        if stats.localVotes > stats.cloudVotes { return "En TUS votos, el reconocimiento del iPhone acertó más veces que Whisper (\(stats.localVotes) frente a \(stats.cloudVotes)). Es una muestra pequeña y personal." }
        return "En TUS votos, hay empate entre el iPhone y Whisper. Es una muestra pequeña y personal."
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title).font(.callout); Spacer(); Text(value).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary) }
            .foregroundStyle(Theme.textPrimary)
    }

    @ViewBuilder private func recordView(_ record: RecognitionRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(Self.formatter.string(from: record.date)) · \(record.mode) · \(record.onDevice ? "en el dispositivo" : "Apple por internet") · \(String(format: "%.1f", record.duration)) s · \(label(record.endReason))")
                .font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
            if let input = record.input { Text("Entrada: \(input)").font(Theme.mono(10)).foregroundStyle(Theme.textSecondary) }
            line("Oído", record.raw.isEmpty ? "(nada)" : record.raw)
            if let corrected = record.corrected, corrected != record.raw { line("Corregido", corrected) }
            if let cloud = record.cloudText { line("Whisper", cloud) }
            if let error = record.cloudError { line("Whisper falló", error) }
            if let edited = record.edited { line("Tú dejaste", edited) }
            if let error = record.error { line("Error", error) }
            if record.retried { Text("Se reinició el reconocimiento una vez.").font(.caption).foregroundStyle(Theme.amber) }
            if record.interrupted { Text("Hubo una interrupción del audio (llamada, Siri o cambio de audífonos).").font(.caption).foregroundStyle(Theme.amber) }
            if record.cloudText != nil {
                HStack(spacing: 8) {
                    Text("¿Cuál acertó?").font(.caption).foregroundStyle(Theme.textSecondary)
                    voteButton("iPhone", .local, record)
                    voteButton("Whisper", .cloud, record)
                    voteButton("Ninguna", .neither, record)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func line(_ title: String, _ value: String) -> some View {
        (Text(title + ": ").font(.caption).foregroundColor(Theme.accent) + Text(value).font(.callout).foregroundColor(Theme.textPrimary))
            .textSelection(.enabled)
    }

    private func voteButton(_ title: String, _ vote: TranscriptVote, _ record: RecognitionRecord) -> some View {
        Button(title) { model.vote(record.vote == vote ? nil : vote, for: record.id) }
            .buttonStyle(ChromeButtonStyle(tint: record.vote == vote ? Theme.accent : Theme.chrome))
    }

    private func label(_ reason: RecognitionRecord.EndReason) -> String {
        switch reason {
        case .silence: return "terminó por silencio"
        case .userTap: return "la cerraste tú"
        case .maxDuration: return "duración máxima"
        case .noSpeech: return "no se oyó voz"
        case .recognizerFinal: return "resultado final"
        case .error: return "error"
        }
    }
}
