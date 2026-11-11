import SwiftUI
import ViernesCore

struct MemoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var editing: MemoryItem?
    @State private var adding = false
    @State private var confirmDeleteAll = false
    @State private var entityToDelete: MemoryEntity?

    private var filtered: [MemoryItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return model.memoryItems }
        let ids = Set(MemoryRetriever.rank(query: query, items: model.memoryItems, limit: 50).map(\.item.id))
        return model.memoryItems.filter { ids.contains($0.id) || TextNormalizer.fold($0.text).contains(TextNormalizer.fold(query)) }
    }

    /// Línea de detalle de un recuerdo (en pasos simples: una sola expresión larga no la compila Swift a tiempo).
    private static func detailLine(for item: MemoryItem) -> String {
        var line: String = item.kind.displayName
        line += " · "
        line += item.updatedAt.formatted(date: .abbreviated, time: .omitted)
        if let relations: String = MemoryRelations.summary(of: item) {
            line += " · "
            line += relations
        }
        if let expires: Date = item.expiresAt {
            line += " · caduca "
            line += expires.formatted(date: .abbreviated, time: .omitted)
        }
        return line
    }

    var body: some View {
        Group {
            if model.settings.requireBiometricsForMemory && !model.memoryUnlocked {
                locked
            } else {
                content
            }
        }
        .navigationTitle("Memoria")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
        .task { await model.reloadMemory(); if model.settings.requireBiometricsForMemory && !model.memoryUnlocked { await model.unlockMemory() } }
        .onDisappear { if model.settings.requireBiometricsForMemory { model.memoryUnlocked = false } }
    }

    private var locked: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.amber)
            Text("La memoria está protegida").foregroundStyle(Theme.textPrimary)
            Button("Desbloquear con Face ID") { Task { await model.unlockMemory() } }.buttonStyle(ChromeButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private var content: some View {
        List {
            if !model.settings.memory.enabled {
                Section {
                    Label("La memoria está desactivada. Viernes no guardará nada nuevo ni usará recuerdos. Actívala en Configuración › Privacidad.", systemImage: "pause.circle")
                        .font(.footnote).foregroundStyle(Theme.amber)
                }.listRowBackground(Color.clear)
            }
            if !model.pendingMemories.isEmpty {
                Section("Sugerencias por aprobar") {
                    ForEach(model.pendingMemories) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.text)
                            Text(item.kind.displayName).font(.caption).foregroundStyle(Theme.textSecondary)
                            HStack {
                                Button("Guardar") { model.approveMemory(item) }.buttonStyle(ChromeButtonStyle())
                                Button("Descartar") { model.deleteMemory(item) }.buttonStyle(ChromeButtonStyle(tint: Theme.amber))
                            }
                        }
                        .listRowBackground(Theme.carbon.opacity(0.5))
                    }
                }
            }
            let entities = MemoryGraph.entities(model.memoryItems)
            if !entities.isEmpty {
                Section("Personas y proyectos") {
                    ForEach(entities) { entity in
                        Button { query = entity.name } label: {
                            Label("\(entity.name) · \(entity.count) recuerdo\(entity.count == 1 ? "" : "s")",
                                  systemImage: entity.kind == .person ? "person" : "folder")
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { entityToDelete = entity } label: { Label("Borrar todo", systemImage: "trash") }
                        }
                        .accessibilityIdentifier("memory-entity")
                    }
                    ForEach(MemoryGraph.links(model.memoryItems)) { link in
                        Label("\(link.person) ↔ \(link.project) (\(link.count))", systemImage: "link").font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                    Text("Toca un nombre para ver sus recuerdos; desliza para borrar todo lo de esa persona o proyecto.").font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                .listRowBackground(Theme.carbon.opacity(0.5))
            }
            let expired = MemoryExpiry.expired(model.memoryItems)
            if !expired.isEmpty {
                Section {
                    Button("Borrar \(expired.count) recuerdo\(expired.count == 1 ? "" : "s") caducado\(expired.count == 1 ? "" : "s")", role: .destructive) { model.deleteMemories(expired) }
                }
                .listRowBackground(Theme.carbon.opacity(0.5))
            }
            Section("Recuerdos (\(model.memoryItems.count))") {
                if filtered.isEmpty {
                    Text(model.memoryItems.isEmpty ? "Aún no hay recuerdos. Dile «recuerda que…» o añade uno con +." : "Sin resultados.")
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(filtered) { item in
                    Button { editing = item } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                if item.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(Theme.accent) }
                                Text(item.text).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.leading)
                            }
                            Text(Self.detailLine(for: item))
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .listRowBackground(Theme.carbon.opacity(0.5))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { model.deleteMemory(item) } label: { Label("Borrar", systemImage: "trash") }
                    }
                    .swipeActions(edge: .leading) {
                        Button { var copy = item; copy.pinned.toggle(); model.updateMemory(copy) } label: { Label(item.pinned ? "Desfijar" : "Fijar", systemImage: "pin") }
                            .tint(Theme.steel)
                    }
                }
            }
            if model.unreadableMemoryCount > 0 {
                Section {
                    Label("\(model.unreadableMemoryCount) recuerdo(s) no se pueden descifrar (clave de cifrado distinta). Puedes borrar todo desde Privacidad.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(Theme.alert)
                }.listRowBackground(Color.clear)
            }
        }
        .chromeList()
        .searchable(text: $query, prompt: "Buscar recuerdos")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Añadir recuerdo") }
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) { confirmDeleteAll = true } label: { Image(systemName: "trash") }
                    .disabled(model.memoryItems.isEmpty && model.pendingMemories.isEmpty).accessibilityLabel("Borrar toda la memoria")
            }
        }
        .sheet(item: $editing) { item in NavigationStack { MemoryEditor(item: item) }.environmentObject(model).presentationBackground(Theme.ink) }
        .sheet(isPresented: $adding) { NavigationStack { MemoryEditor(item: nil) }.environmentObject(model).presentationBackground(Theme.ink) }
        .confirmationDialog("¿Borrar lo relacionado?", isPresented: Binding(get: { entityToDelete != nil }, set: { if !$0 { entityToDelete = nil } }), titleVisibility: .visible,
                            presenting: entityToDelete) { entity in
            Button("Borrar los recuerdos de «\(entity.name)»", role: .destructive) {
                model.deleteMemories(MemoryGraph.related(to: entity.name, in: model.memoryItems))
            }
        } message: { entity in Text("Se eliminan \(entity.count) recuerdo(s) relacionados con «\(entity.name)». No se puede deshacer.") }
        .confirmationDialog("¿Borrar toda la memoria?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Borrar todo", role: .destructive) { model.deleteAllMemory() }
        } message: { Text("Se eliminarán todos los recuerdos y sugerencias. No se puede deshacer.") }
    }
}

struct MemoryEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: MemoryItem?
    @State private var text = ""
    @State private var kind: MemoryKind = .fact
    @State private var pinned = false
    @State private var project = ""
    @State private var peopleText = ""
    @State private var expiry: Expiry = .never

    /// Cuánto dura un recuerdo. En un recuerdo existente, «Mantener» conserva su fecha actual.
    private enum Expiry: String, CaseIterable, Identifiable {
        case keep, never, week, month, year
        var id: String { rawValue }
        var label: String {
            switch self {
            case .keep: return "Mantener la fecha actual"
            case .never: return "No caduca"
            case .week: return "En 1 semana"
            case .month: return "En 1 mes"
            case .year: return "En 1 año"
            }
        }
        func date(from now: Date, current: Date?) -> Date? {
            switch self {
            case .keep: return current
            case .never: return nil
            case .week: return now.addingTimeInterval(7 * 86_400)
            case .month: return now.addingTimeInterval(30 * 86_400)
            case .year: return now.addingTimeInterval(365 * 86_400)
            }
        }
    }

    private var sensitive: Bool { SensitiveDataRedactor.scan(text).isSensitive }

    var body: some View {
        Form {
            Section("Recuerdo") {
                TextField("Texto", text: $text, axis: .vertical).lineLimit(2...8).accessibilityIdentifier("memory-text")
                Picker("Tipo", selection: $kind) {
                    ForEach(MemoryKind.allCases.filter { $0 != .summary || item?.kind == .summary }, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Fijar (siempre disponible)", isOn: $pinned)
            }
            Section("Contexto (opcional)") {
                TextField("Proyecto", text: $project).accessibilityIdentifier("memory-project")
                TextField("Personas (separadas por comas)", text: $peopleText).accessibilityIdentifier("memory-people")
                Picker("Caducidad", selection: $expiry) {
                    ForEach(Expiry.allCases.filter { $0 != .keep || item?.expiresAt != nil }) { Text($0.label).tag($0) }
                }
                Text("El proyecto y las personas ayudan a encontrar este recuerdo cuando hablas de ellos. Un recuerdo caducado deja de usarse y se borra solo.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            if sensitive {
                Section { Label("Parece contener datos sensibles (contraseña, tarjeta, documento o clave). Viernes no los guarda.", systemImage: "exclamationmark.shield").foregroundStyle(Theme.alert).font(.footnote) }
            }
        }
        .chromeList()
        .navigationTitle(item == nil ? "Nuevo recuerdo" : "Editar recuerdo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Guardar") { save() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sensitive)
                    .accessibilityIdentifier("memory-save")
            }
        }
        .onAppear {
            if let item = item {
                text = item.text; kind = item.kind; pinned = item.pinned
                project = item.project ?? ""
                peopleText = (item.people ?? []).joined(separator: ", ")
                expiry = item.expiresAt != nil ? .keep : .never
            }
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let relations = MemoryRelations.clean(project: project, people: MemoryRelations.parsePeople(peopleText))
        if var existing = item {
            existing.text = trimmed
            existing.kind = kind
            existing.pinned = pinned
            existing.project = relations.project
            existing.people = relations.people
            existing.expiresAt = expiry.date(from: Date(), current: existing.expiresAt)
            model.updateMemory(existing)
        } else {
            model.addMemory(text: trimmed, kind: kind, project: relations.project, people: relations.people ?? [],
                            expiresAt: expiry.date(from: Date(), current: nil))
        }
        dismiss()
    }
}
