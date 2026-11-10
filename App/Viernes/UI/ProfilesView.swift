import SwiftUI
import UniformTypeIdentifiers
import ViernesCore

private let avatarColors: [Color] = [
    Color(red: 1.0, green: 0.42, blue: 0.0), Color(red: 0.2, green: 0.6, blue: 0.9), Color(red: 0.3, green: 0.75, blue: 0.5),
    Color(red: 0.8, green: 0.4, blue: 0.8), Color(red: 0.9, green: 0.75, blue: 0.2), Color(red: 0.9, green: 0.35, blue: 0.4),
    Color(red: 0.4, green: 0.5, blue: 0.9), Color(red: 0.5, green: 0.8, blue: 0.8)
]

struct ProfileAvatar: View {
    let entry: ProfileEntry
    var size: CGFloat = 34
    var body: some View {
        Text(entry.initial)
            .font(Theme.body(size * 0.45, weight: .semibold))
            .foregroundStyle(.black)
            .frame(width: size, height: size)
            .background(Circle().fill(avatarColors[entry.colorIndex % avatarColors.count]))
            .accessibilityHidden(true)
    }
}

/// Pantalla que sustituye a la app cuando el perfil activo está protegido y aún no se confirmó la identidad.
struct LockedProfileView: View {
    @EnvironmentObject var host: ProfileHost
    @State private var tried = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(Theme.accent)
            Text("Perfil protegido").font(Theme.body(20, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text("«\(host.registry.active.displayName)» pide confirmar tu identidad (Face ID, Touch ID o el código del iPhone).")
                .font(.footnote).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            Button("Desbloquear") { Task { await host.unlock() } }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .accessibilityIdentifier("profile-unlock")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .task {
            guard !tried else { return }
            tried = true
            await host.unlock()
        }
    }
}

struct ProfilesView: View {
    @EnvironmentObject var host: ProfileHost
    @State private var showNew = false
    @State private var newName = ""
    @State private var showImporter = false
    @State private var importFile: URL?
    @State private var confirmEraseEverything = false

    var body: some View {
        List {
            if let notice = host.notice {
                Section {
                    Text(notice).font(.footnote).foregroundStyle(Theme.textPrimary).accessibilityIdentifier("profile-notice")
                    Button("Entendido") { host.notice = nil }.font(.footnote)
                }
                .listRowBackground(Theme.carbon.opacity(0.5))
            }

            Section("Perfiles en este iPhone") {
                ForEach(host.registry.entries) { entry in
                    NavigationLink { ProfileDetailView(id: entry.id) } label: {
                        HStack(spacing: 12) {
                            ProfileAvatar(entry: entry)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.displayName).foregroundStyle(Theme.textPrimary)
                                Text(entry.id == host.registry.activeID ? "Activo" : "Toca para ver o cambiar")
                                    .font(.caption).foregroundStyle(entry.id == host.registry.activeID ? Theme.accent : Theme.textSecondary)
                            }
                            Spacer()
                            if entry.isProtected { Image(systemName: "lock.fill").foregroundStyle(Theme.textSecondary) }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(entry.displayName), \(entry.id == host.registry.activeID ? "activo" : "inactivo")\(entry.isProtected ? ", protegido" : "")")
                    }
                    .accessibilityIdentifier("profile-row")
                }
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section {
                Button { newName = ""; showNew = true } label: { Label("Nuevo perfil", systemImage: "person.badge.plus") }
                    .disabled(host.registry.entries.count >= ProfileRegistry.maxProfiles)
                    .accessibilityIdentifier("profile-new")
                Button { showImporter = true } label: { Label("Importar un perfil desde un archivo…", systemImage: "square.and.arrow.down") }
                    .accessibilityIdentifier("profile-import")
                Text("Hasta \(ProfileRegistry.maxProfiles) perfiles. Importar crea un perfil NUEVO: nunca mezcla ni pisa uno existente.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Qué separa un perfil") {
                Text("Cada perfil tiene SU memoria, SUS documentos, SUS conversaciones, SUS ajustes y personalidad, SUS claves de API y SU clave de cifrado, en almacenes distintos. Con la clave de un perfil no se puede abrir nada de otro. Cambiar de perfil descarta de la memoria todo lo del anterior.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                Text("Lo que NO se separa: los modelos descargados (son del iPhone) y lo que iOS guarda fuera de Viernes (calendario, contactos, recordatorios): cada perfil puede o no leerlo según su propio permiso. Los perfiles no sustituyen a las cuentas de usuario de iOS.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Borrar") {
                Button("Borrar TODOS los perfiles y sus datos", role: .destructive) { confirmEraseEverything = true }
                    .accessibilityIdentifier("profile-erase-everything")
            }
            .listRowBackground(Theme.carbon.opacity(0.5))
        }
        .chromeList()
        .navigationTitle("Perfiles")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Nuevo perfil", isPresented: $showNew) {
            TextField("Nombre", text: $newName)
            Button("Crear") { host.createProfile(name: newName) }
            Button("Crear y entrar") {
                if let entry = host.createProfile(name: newName) { Task { await host.switchTo(entry.id) } }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Empieza vacío: sin recuerdos, documentos ni claves.")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { importFile = url }
        }
        .sheet(item: Binding(get: { importFile.map(ImportTarget.init) }, set: { if $0 == nil { importFile = nil } })) { target in
            ImportProfileSheet(file: target.url)
        }
        .confirmationDialog("¿Borrar todos los perfiles?", isPresented: $confirmEraseEverything, titleVisibility: .visible) {
            Button("Borrar todo y empezar de cero", role: .destructive) { host.eraseEverything() }
        } message: {
            Text("Se eliminan los recuerdos, documentos, conversaciones, ajustes y claves de TODOS los perfiles. Los modelos descargados no se tocan. No se puede deshacer.")
        }
    }
}

private struct ImportTarget: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ProfileDetailView: View {
    let id: UUID
    @EnvironmentObject var host: ProfileHost
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmDelete = false
    @State private var showExport = false

    private var entry: ProfileEntry? { host.registry.entry(id: id) }
    private var isActive: Bool { id == host.registry.activeID }

    var body: some View {
        List {
            if let entry = entry {
                Section("Nombre") {
                    HStack {
                        ProfileAvatar(entry: entry)
                        TextField("Nombre del perfil", text: $name)
                            .onSubmit { host.renameProfile(id, to: name) }
                            .accessibilityIdentifier("profile-name")
                    }
                    Button("Guardar nombre") { host.renameProfile(id, to: name) }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines) == entry.displayName)
                }
                .listRowBackground(Theme.carbon.opacity(0.5))

                Section("Uso") {
                    if isActive {
                        Label("Este es el perfil activo", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                        NavigationLink { PersonalityView().environmentObject(host.model) } label: {
                            Label("Personalidad, idioma y autonomía", systemImage: "theatermasks")
                        }
                        .accessibilityIdentifier("profile-personality")
                    } else {
                        Button { Task { if await host.switchTo(id) { dismiss() } } } label: {
                            Label("Cambiar a este perfil", systemImage: "arrow.left.arrow.right")
                        }
                        .accessibilityIdentifier("profile-switch")
                    }
                    Toggle(isOn: Binding(get: { entry.isProtected }, set: { value in Task { await host.setProtected(id, value) } })) {
                        Label("Proteger con Face ID o código", systemImage: "lock")
                    }
                    .accessibilityIdentifier("profile-protect")
                    Text("Un perfil protegido pide confirmar tu identidad al entrar en él (al cambiar de perfil y al abrir la app).")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                .listRowBackground(Theme.carbon.opacity(0.5))

                if isActive {
                    Section("Datos de este perfil") {
                        LabeledContent("Recuerdos", value: "\(host.model.memoryItems.count)")
                        LabeledContent("Elementos de la biblioteca", value: "\(host.model.libraryItems.count)")
                        LabeledContent("Conversaciones guardadas", value: "\(host.model.history.count)")
                        Button { showExport = true } label: { Label("Exportar este perfil…", systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("profile-export")
                    }
                    .listRowBackground(Theme.carbon.opacity(0.5))
                }

                Section("Eliminar") {
                    Button("Eliminar este perfil y todos sus datos", role: .destructive) { confirmDelete = true }
                        .disabled(host.registry.entries.count <= 1)
                        .accessibilityIdentifier("profile-delete")
                    if host.registry.entries.count <= 1 {
                        Text("Es el único perfil: crea otro primero, o usa «Borrar todos los perfiles».")
                            .font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                }
                .listRowBackground(Theme.carbon.opacity(0.5))
            } else {
                Text("Este perfil ya no existe.").foregroundStyle(Theme.textSecondary)
            }
        }
        .chromeList()
        .navigationTitle(entry?.displayName ?? "Perfil")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = entry?.displayName ?? "" }
        .confirmationDialog("¿Eliminar el perfil?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Eliminar «\(entry?.displayName ?? "")» y sus datos", role: .destructive) {
                Task { if await host.deleteProfile(id) { dismiss() } }
            }
        } message: {
            Text("Se borran sus recuerdos, documentos, conversaciones, ajustes, claves de API y su clave de cifrado. Los demás perfiles no se tocan. No se puede deshacer.")
        }
        .sheet(isPresented: $showExport) { ExportProfileSheet() }
    }
}

struct ExportProfileSheet: View {
    @EnvironmentObject var host: ProfileHost
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var includeVectors = false
    @State private var working = false
    @State private var exported: URL?
    @State private var failure: String?

    private var mismatch: Bool { !passphrase.isEmpty && passphrase != confirmation }

    var body: some View {
        NavigationStack {
            List {
                Section("Contenido") {
                    Text("Ajustes y personalidad, recuerdos, biblioteca (texto y referencias) y conversaciones de «\(host.registry.active.displayName)». NO incluye claves de API ni la clave de cifrado: esas no salen del Llavero de este iPhone.")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                    Toggle("Incluir vectores de significado (archivo mucho más grande)", isOn: $includeVectors)
                }
                .listRowBackground(Theme.carbon.opacity(0.5))

                Section("Contraseña (recomendada)") {
                    SecureField("Contraseña", text: $passphrase).accessibilityIdentifier("export-passphrase")
                    SecureField("Repite la contraseña", text: $confirmation)
                    if mismatch { Text("Las contraseñas no coinciden.").font(.footnote).foregroundStyle(.red) }
                    Text(passphrase.isEmpty
                         ? "Sin contraseña, el archivo contiene tus datos personales EN CLARO: quien lo abra los lee."
                         : "El archivo se cifra con tu contraseña (PBKDF2 + AES-256). Si la olvidas, no se puede recuperar: no hay puerta trasera.")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                .listRowBackground(Theme.carbon.opacity(0.5))

                Section {
                    if let exported = exported {
                        ShareLink(item: exported) { Label("Compartir o guardar el archivo", systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("export-share")
                        Text("El archivo está en la carpeta temporal del iPhone y se borra al abrir la app de nuevo.")
                            .font(.footnote).foregroundStyle(Theme.textSecondary)
                    } else {
                        Button(working ? "Creando…" : "Crear archivo") { create() }
                            .disabled(working || mismatch)
                            .accessibilityIdentifier("export-create")
                    }
                    if let failure = failure { Text(failure).font(.footnote).foregroundStyle(.red) }
                }
                .listRowBackground(Theme.carbon.opacity(0.5))
            }
            .chromeList()
            .navigationTitle("Exportar perfil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
        }
    }

    private func create() {
        working = true
        failure = nil
        let secret = passphrase
        Task {
            defer { working = false }
            do {
                exported = try await host.exportActiveProfile(includeVectors: includeVectors, passphrase: secret.isEmpty ? nil : secret)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

struct ImportProfileSheet: View {
    let file: URL
    @EnvironmentObject var host: ProfileHost
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var pendingMemories = true
    @State private var trustPersonalization = false
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Archivo") {
                    Text(file.lastPathComponent).font(Theme.mono(11)).foregroundStyle(Theme.textPrimary)
                    SecureField("Contraseña (solo si el archivo está cifrado)", text: $passphrase)
                }
                .listRowBackground(Theme.carbon.opacity(0.5))

                Section("Seguridad de lo importado") {
                    Toggle("Dejar los recuerdos pendientes de aprobar", isOn: $pendingMemories)
                    Text("Los recuerdos pendientes no se le dan al modelo hasta que los apruebes en Memoria. Un archivo ajeno o manipulado podría traer textos pensados para dirigir al asistente.")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                    Toggle("Confiar en las instrucciones personales y la pronunciación del archivo", isOn: $trustPersonalization)
                    Text("Apagado: se importan sin ellas. Siempre quedan apagados los permisos de calendario y contactos, la escucha por voz, el dictado en servidores, la voz en la nube y el envío de adjuntos sin preguntar, y la configuración de Claude vuelve a la de fábrica: lo activas tú en el perfil nuevo.")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                .listRowBackground(Theme.carbon.opacity(0.5))

                Section {
                    Button(working ? "Importando…" : "Importar como perfil nuevo") { runImport() }
                        .disabled(working)
                        .accessibilityIdentifier("import-run")
                    if let failure = failure { Text(failure).font(.footnote).foregroundStyle(.red) }
                }
                .listRowBackground(Theme.carbon.opacity(0.5))
            }
            .chromeList()
            .navigationTitle("Importar perfil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }
    }

    private func runImport() {
        working = true
        failure = nil
        let options = RestoreOptions(memoriesAsPending: pendingMemories, trustPersonalization: trustPersonalization)
        let secret = passphrase
        Task {
            defer { working = false }
            do {
                _ = try await host.importProfile(from: file, passphrase: secret.isEmpty ? nil : secret, options: options)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
