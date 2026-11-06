import SwiftUI
import ViernesCore

struct PrivacyView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmErase = false

    var body: some View {
        List {
            Section {
                Text("Todo se guarda cifrado en este iPhone (AES-256, clave en el Llavero que no sale del dispositivo). Viernes no tiene servidor propio, cuentas ni analítica. Lo único que sale del dispositivo es lo que tú pidas o actives explícitamente: descargar un modelo, abrir un enlace, enviar una pregunta a Claude, consultar el clima de una ciudad (solo su nombre, a Open-Meteo) usar el cerebro en la nube (opcional: tus mensajes van al proveedor que elijas) o la voz neuronal de ElevenLabs (opcional: el texto que Viernes dice va a ElevenLabs; tu audio no).")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }.listRowBackground(Color.clear)

            Section("Qué puede recordar Viernes") {
                Toggle("Memoria activada", isOn: $model.settings.memory.enabled).accessibilityIdentifier("memory-enabled")
                Group {
                    Toggle("Preferencias", isOn: $model.settings.memory.allowPreferences)
                    Toggle("Proyectos", isOn: $model.settings.memory.allowProjects)
                    Toggle("Datos personales que yo pida guardar", isOn: $model.settings.memory.allowFacts)
                    Toggle("Resúmenes de conversaciones", isOn: $model.settings.memory.allowSummaries)
                }
                .disabled(!model.settings.memory.enabled)
                Toggle("Permitir que Viernes proponga recuerdos", isOn: $model.settings.memory.autoSuggest)
                    .disabled(!model.settings.memory.enabled)
                Text("Nunca se guarda algo automáticamente: solo cuando dices «recuerda que…», lo añades tú, o apruebas una sugerencia. Contraseñas, tarjetas, claves y documentos de identidad se rechazan siempre.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section {
                Toggle("Permitir que Viernes lea mi calendario", isOn: Binding(
                    get: { model.settings.calendarReadEnabled }, set: { model.settings.calendarRead = $0 }))
                    .accessibilityIdentifier("calendar-read")
                Toggle("Permitir que Viernes lea mis contactos", isOn: Binding(
                    get: { model.settings.contactsReadEnabled }, set: { model.settings.contactsRead = $0 }))
                    .accessibilityIdentifier("contacts-read")
            } header: { Text("Datos de tu iPhone") } footer: {
                Text("Apagado por defecto. Por defecto Viernes solo puede AÑADIR eventos. Si lo activas, podrá leer tu agenda o buscar contactos cuando se lo pidas, sin preguntarte cada vez: este interruptor es tu autorización (iOS además pide su propio permiso la primera vez). Lo que lea se entrega al cerebro activo: con el cerebro en la nube, también sale del teléfono. Si no quieres eso, déjalo apagado.")
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Historial de conversaciones") {
                Picker("Guardar transcripciones", selection: $model.settings.transcriptRetention) {
                    ForEach(TranscriptRetention.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text("Al reducir el plazo, lo más antiguo se borra de inmediato.").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Protección") {
                Toggle("Pedir Face ID para ver la Memoria", isOn: $model.settings.requireBiometricsForMemory)
                    .disabled(!Permissions.biometricsAvailable)
                if !Permissions.biometricsAvailable {
                    Text("Este dispositivo no tiene Face ID, Touch ID ni código configurado.").font(.caption).foregroundStyle(Theme.amber)
                }
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Audio") {
                Label("El audio se transcribe en el dispositivo y no se guarda.", systemImage: "waveform.badge.mic")
                Label(model.settings.allowServerRecognition ? "Reconocimiento por internet de Apple PERMITIDO si falta el modelo local." : "Reconocimiento por internet de Apple desactivado.", systemImage: "network")
                    .foregroundStyle(model.settings.allowServerRecognition ? Theme.amber : Theme.textPrimary)
            }
            .font(.footnote)
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Borrar") {
                Button("Borrar todos los datos de Viernes", role: .destructive) { confirmErase = true }
                    .accessibilityIdentifier("erase-all")
            }
            .listRowBackground(Theme.carbon.opacity(0.5))
        }
        .chromeList()
        .navigationTitle("Privacidad")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("¿Borrar todo?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Borrar memoria, historial y ajustes", role: .destructive) { model.eraseAllData() }
        } message: { Text("Se eliminan recuerdos, conversaciones, ajustes y la clave de cifrado. Los modelos descargados no se tocan. No se puede deshacer.") }
    }
}
