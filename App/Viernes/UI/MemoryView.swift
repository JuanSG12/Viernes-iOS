import SwiftUI
import ViernesCore

struct MemoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var editing: MemoryItem?
    @State private var adding = false
    @State private var confirmDeleteAll = false

    private var filtered: [MemoryItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return model.memoryItems }
        let ids = Set(MemoryRetriever.rank(query: query, items: model.memoryItems, limit: 50).map(\.item.id))
        return model.memoryItems.filter { ids.contains($0.id) || TextNormalizer.fold($0.text).contains(TextNormalizer.fold(query)) }
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
            Button("Desbloquear con Face ID") { Task { await model.unlockMemory() } }.buttonStyle(HoloButtonStyle())
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
                                Button("Guardar") { model.approveMemory(item) }.buttonStyle(HoloButtonStyle())
                                Button("Descartar") { model.deleteMemory(item) }.buttonStyle(HoloButtonStyle(tint: Theme.amber))
                            }
                        }
                        .listRowBackground(Theme.deep.opacity(0.5))
                    }
                }
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
                                if item.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(Theme.cyan) }
                                Text(item.text).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.leading)
                            }
                            Text("\(item.kind.displayName) · \(item.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .listRowBackground(Theme.deep.opacity(0.5))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { model.deleteMemory(item) } label: { Label("Borrar", systemImage: "trash") }
                    }
                    .swipeActions(edge: .leading) {
                        Button { var copy = item; copy.pinned.toggle(); model.updateMemory(copy) } label: { Label(item.pinned ? "Desfijar" : "Fijar", systemImage: "pin") }
                            .tint(Theme.blue)
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
        .holoList()
        .searchable(text: $query, prompt: "Buscar recuerdos")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Añadir recuerdo") }
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) { confirmDeleteAll = true } label: { Image(systemName: "trash") }
                    .disabled(model.memoryItems.isEmpty && model.pendingMemories.isEmpty).accessibilityLabel("Borrar toda la memoria")
            }
        }
        .sheet(item: $editing) { item in NavigationStack { MemoryEditor(item: item) }.environmentObject(model).presentationBackground(Theme.abyss) }
        .sheet(isPresented: $adding) { NavigationStack { MemoryEditor(item: nil) }.environmentObject(model).presentationBackground(Theme.abyss) }
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
            if sensitive {
                Section { Label("Parece contener datos sensibles (contraseña, tarjeta, documento o clave). Viernes no los guarda.", systemImage: "exclamationmark.shield").foregroundStyle(Theme.alert).font(.footnote) }
            }
        }
        .holoList()
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
            if let item = item { text = item.text; kind = item.kind; pinned = item.pinned }
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if var existing = item {
            existing.text = trimmed
            existing.kind = kind
            existing.pinned = pinned
            model.updateMemory(existing)
        } else {
            model.addMemory(text: trimmed, kind: kind)
        }
        dismiss()
    }
}
