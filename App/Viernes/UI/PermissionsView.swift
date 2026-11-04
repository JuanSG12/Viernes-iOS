import SwiftUI
import UIKit

struct PermissionsView: View {
    @EnvironmentObject var model: AppModel

    private struct Item: Identifiable {
        let id: String
        let icon: String
        let title: String
        let why: String
        let state: PermissionState
        let request: (() async -> Void)?
    }

    private var items: [Item] {
        _ = model.permissionTick
        return [
            Item(id: "mic", icon: "mic", title: "Micrófono", why: "Para oírte cuando tú la activas. Nunca se usa en segundo plano.", state: Permissions.microphone,
                 request: { _ = await Permissions.requestMicrophone() }),
            Item(id: "speech", icon: "waveform", title: "Reconocimiento de voz", why: "Para convertir tu voz en texto, en el dispositivo siempre que sea posible.", state: Permissions.speech,
                 request: { _ = await Permissions.requestSpeech() }),
            Item(id: "reminders", icon: "checklist", title: "Recordatorios", why: "Para crear, listar y completar recordatorios cuando lo pidas y confirmes. Se solicita la primera vez que lo usas.", state: Permissions.reminders, request: nil),
            Item(id: "calendar", icon: "calendar", title: "Calendario (solo añadir)", why: "Para añadir eventos que confirmes. Viernes no lee tu calendario. Se solicita la primera vez que lo usas.", state: Permissions.calendar, request: nil)
        ]
    }

    var body: some View {
        List {
            Section {
                Text("Viernes pide cada permiso solo cuando lo necesita y explica para qué. Puedes revocarlos en cualquier momento desde los Ajustes de iOS.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }.listRowBackground(Color.clear)

            Section {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.icon).foregroundStyle(Theme.cyan).frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(item.title).foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text(item.state.label).font(.caption)
                                    .foregroundStyle(item.state.isGranted ? Theme.cyan : (item.state == .notDetermined ? Theme.textSecondary : Theme.amber))
                            }
                            Text(item.why).font(.caption).foregroundStyle(Theme.textSecondary)
                            if item.state == .notDetermined, let request = item.request {
                                Button("Conceder") { Task { await request(); model.permissionTick += 1 } }.buttonStyle(HoloButtonStyle())
                            } else if item.state == .denied || item.state == .restricted {
                                Button("Abrir Ajustes de iOS") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                                    .buttonStyle(HoloButtonStyle(tint: Theme.amber))
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("permission-\(item.id)")
                }
            }
            .listRowBackground(Theme.deep.opacity(0.5))

            Section("No usa") {
                Text("Ubicación, contactos, fotos, cámara, Bluetooth ni notificaciones. Tampoco modos de ejecución en segundo plano.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.deep.opacity(0.5))
        }
        .holoList()
        .navigationTitle("Permisos")
        .navigationBarTitleDisplayMode(.inline)
    }
}
