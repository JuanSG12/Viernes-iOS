import SwiftUI
import ViernesCore

struct PrivacyView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmErase = false

    var body: some View {
        List {
            Section {
                Text("Todo se guarda cifrado en este iPhone (AES-256, clave en el Llavero que no sale del dispositivo). Viernes no tiene servidor propio, cuentas ni analítica. Lo único que sale del dispositivo es lo que tú pidas explícitamente: descargar un modelo, abrir un enlace, o enviar una pregunta a Claude.")
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
            .listRowBackground(Theme.deep.opacity(0.5))

            Section("Historial de conversaciones") {
                Picker("Guardar transcripciones", selection: $model.settings.transcriptRetention) {
                    ForEach(TranscriptRetention.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text("Al reducir el plazo, lo más antiguo se borra de inmediato.").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.deep.opacity(0.5))

            Section("Protección") {
                Toggle("Pedir Face ID para ver la Memoria", isOn: $model.settings.requireBiometricsForMemory)
                    .disabled(!Permissions.biometricsAvailable)
                if !Permissions.biometricsAvailable {
                    Text("Este dispositivo no tiene Face ID, Touch ID ni código configurado.").font(.caption).foregroundStyle(Theme.amber)
                }
            }
            .listRowBackground(Theme.deep.opacity(0.5))

            Section("Audio") {
                Label("El audio se transcribe en el dispositivo y no se guarda.", systemImage: "waveform.badge.mic")
                Label(model.settings.allowServerRecognition ? "Reconocimiento por internet de Apple PERMITIDO si falta el modelo local." : "Reconocimiento por internet de Apple desactivado.", systemImage: "network")
                    .foregroundStyle(model.settings.allowServerRecognition ? Theme.amber : Theme.textPrimary)
            }
            .font(.footnote)
            .listRowBackground(Theme.deep.opacity(0.5))

            Section("Borrar") {
                Button("Borrar todos los datos de Viernes", role: .destructive) { confirmErase = true }
                    .accessibilityIdentifier("erase-all")
            }
            .listRowBackground(Theme.deep.opacity(0.5))
        }
        .holoList()
        .navigationTitle("Privacidad")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("¿Borrar todo?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Borrar memoria, historial y ajustes", role: .destructive) { model.eraseAllData() }
        } message: { Text("Se eliminan recuerdos, conversaciones, ajustes y la clave de cifrado. Los modelos descargados no se tocan. No se puede deshacer.") }
    }
}
