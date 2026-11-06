import SwiftUI
import UIKit

struct PermissionsView: View {
    @EnvironmentObject var model: AppModel
    @State private var calendarReport: String?
    @State private var checking = false
    @State private var showLog = false

    private struct Item: Identifiable {
        let id: String
        let icon: String
        let title: String
        let why: String
        let state: PermissionState
        let request: (() async -> Void)?
    }

    private var calendarWhy: String {
        switch Permissions.calendar {
        case .writeOnly:
            return "Ahora mismo solo puede AÑADIR eventos. Para que lea tu agenda, activa «Permitir que Viernes lea mi calendario» en Privacidad y concede «Acceso completo»."
        case .granted:
            return "Acceso completo: puede añadir y, si lo activas en Privacidad, leer tus eventos."
        default:
            return "Para añadir eventos y, si activas la lectura en Privacidad, leer tu agenda. Se solicita la primera vez que lo usas."
        }
    }

    private var items: [Item] {
        _ = model.permissionTick
        return [
            Item(id: "mic", icon: "mic", title: "Micrófono", why: "Para oírte cuando tú la activas. Nunca se usa en segundo plano.", state: Permissions.microphone,
                 request: { _ = await Permissions.requestMicrophone() }),
            Item(id: "speech", icon: "waveform", title: "Reconocimiento de voz", why: "Para convertir tu voz en texto, en el dispositivo siempre que sea posible.", state: Permissions.speech,
                 request: { _ = await Permissions.requestSpeech() }),
            Item(id: "reminders", icon: "checklist", title: "Recordatorios", why: "Para crear, listar y completar recordatorios cuando lo pidas. Se solicita la primera vez que lo usas.", state: Permissions.reminders, request: nil),
            Item(id: "calendar", icon: "calendar", title: "Calendario", why: calendarWhy, state: Permissions.calendar, request: nil),
            Item(id: "contacts", icon: "person.crop.circle", title: "Contactos (opcional)", why: "Solo si activas «Permitir que Viernes lea mis contactos» en Privacidad, para buscar el correo o teléfono de alguien. Se solicita la primera vez que lo usas.", state: Permissions.contacts, request: nil)
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
                        Image(systemName: item.icon).foregroundStyle(Theme.accent).frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(item.title).foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text(item.state.label).font(.caption)
                                    .foregroundStyle(item.state.isGranted ? Theme.accent : (item.state == .notDetermined ? Theme.textSecondary : Theme.amber))
                            }
                            Text(item.why).font(.caption).foregroundStyle(Theme.textSecondary)
                            if item.state == .notDetermined, let request = item.request {
                                Button("Conceder") { Task { await request(); model.permissionTick += 1 } }.buttonStyle(ChromeButtonStyle())
                            } else if item.state == .denied || item.state == .restricted {
                                Button("Abrir Ajustes de iOS") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                                    .buttonStyle(ChromeButtonStyle(tint: Theme.amber))
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("permission-\(item.id)")
                }
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section {
                Button(checking ? "Comprobando…" : "Comprobar acceso al calendario") {
                    checking = true
                    Task {
                        calendarReport = await model.diagnoseCalendar()
                        checking = false
                    }
                }
                .buttonStyle(ChromeButtonStyle())
                .disabled(checking)
                .accessibilityIdentifier("calendar-diagnosis")
                if let calendarReport {
                    Text(calendarReport).font(Theme.mono(11)).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                    Button("Abrir Ajustes de iOS") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                        .buttonStyle(ChromeButtonStyle(tint: Theme.amber))
                }
                DisclosureGroup("Registro técnico (solo en este iPhone)", isExpanded: $showLog) {
                    let lines = Diagnostics.shared.recent.suffix(25)
                    if lines.isEmpty {
                        Text("Sin entradas todavía.").font(.caption).foregroundStyle(Theme.textSecondary)
                    } else {
                        Text(lines.joined(separator: "\n")).font(Theme.mono(10)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                        Button("Copiar") { UIPasteboard.general.string = Diagnostics.shared.recent.joined(separator: "\n") }
                            .buttonStyle(ChromeButtonStyle())
                    }
                }
                .font(.footnote).foregroundStyle(Theme.textSecondary)
            } header: { Text("Diagnóstico") } footer: {
                Text("Pide el acceso completo al calendario si hace falta y muestra lo que iOS le deja ver a Viernes: estado real, calendarios y eventos de los próximos 7 días (solo cantidades). El registro no guarda el contenido de tus eventos, contactos ni mensajes.")
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("No usa") {
                Text("Ubicación, fotos, cámara, Bluetooth ni notificaciones. Tampoco modos de ejecución en segundo plano.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))
        }
        .chromeList()
        .navigationTitle("Permisos")
        .navigationBarTitleDisplayMode(.inline)
    }
}
