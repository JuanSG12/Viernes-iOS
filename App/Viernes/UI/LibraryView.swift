import SwiftUI
import ViernesCore

private let libraryErrorColor = Color(red: 1.0, green: 0.38, blue: 0.34)

/// Biblioteca de conocimiento personal: documentos, imágenes con texto y notas guardados para consultarlos en cualquier conversación.
/// Guarda el TEXTO extraído (cifrado, en el iPhone), no el archivo original. Es distinta de la memoria personal.
struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Scope: Hashable { case all, unfiled, collection(UUID) }

    @State private var query = ""
    @State private var hits: [KnowledgeHit] = []
    @State private var scope: Scope = .all
    @State private var showImporter = false
    @State private var showNote = false
    @State private var showCollections = false
    @State private var itemToDelete: KnowledgeItem?

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var visibleItems: [KnowledgeItem] {
        switch scope {
        case .all: return model.libraryItems
        case .unfiled: return model.libraryItems.filter { $0.collectionID == nil }
        case .collection(let id):
            let ids = Self.descendants(of: id, in: model.libraryCollections)
            return model.libraryItems.filter { $0.collectionID.map { ids.contains($0) } ?? false }
        }
    }

    static func descendants(of id: UUID, in collections: [KnowledgeCollection]) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var changed = true
        while changed {
            changed = false
            for collection in collections {
                if let parent = collection.parentID, result.contains(parent), !result.contains(collection.id) {
                    result.insert(collection.id)
                    changed = true
                }
            }
        }
        return result
    }

    private var searchFilter: KnowledgeFilter {
        switch scope {
        case .all: return .all
        case .unfiled: return KnowledgeFilter(itemIDs: Set(model.libraryItems.filter { $0.collectionID == nil }.map { $0.id }))
        case .collection(let id): return KnowledgeFilter(collectionID: id)
        }
    }

    private var scopeTitle: String {
        switch scope {
        case .all: return "Todo"
        case .unfiled: return "Sin carpeta"
        case .collection(let id): return model.libraryCollections.first { $0.id == id }?.name ?? "Todo"
        }
    }

    var body: some View {
        List {
            if let notice = model.libraryNotice {
                Section {
                    Text(notice).font(.footnote).foregroundStyle(Theme.textPrimary).accessibilityIdentifier("library-notice")
                    Button("Entendido") { model.libraryNotice = nil }
                }
                .listRowBackground(Theme.carbon.opacity(0.5))
            }
            if !trimmedQuery.isEmpty {
                searchSection
            } else if model.libraryItems.isEmpty {
                emptyState
            } else {
                itemsSection
            }
        }
        .chromeList()
        .navigationTitle("Biblioteca")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Buscar en mis documentos")
        .task(id: "\(trimmedQuery)|\(scopeTitle)|\(model.libraryItems.map { "\($0.id)\($0.title)" }.joined())") { await runSearch() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showImporter = true } label: { Label("Añadir archivo…", systemImage: "doc.badge.plus") }.accessibilityIdentifier("library-add-file")
                    Button { showNote = true } label: { Label("Nueva nota", systemImage: "note.text.badge.plus") }.accessibilityIdentifier("library-add-note")
                    Button { showCollections = true } label: { Label("Proyectos y carpetas", systemImage: "folder.badge.gearshape") }.accessibilityIdentifier("library-collections")
                } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Añadir a la biblioteca").accessibilityIdentifier("library-add")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Mostrar", selection: $scope) {
                        Text("Todo").tag(Scope.all)
                        Text("Sin carpeta").tag(Scope.unfiled)
                        ForEach(model.libraryCollections) { collection in
                            Text("\(collection.kind.displayName): \(collection.name)").tag(Scope.collection(collection.id))
                        }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    .accessibilityLabel("Filtrar por proyecto o carpeta").accessibilityIdentifier("library-filter")
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                let target: UUID? = { if case .collection(let id) = scope { return id } else { return nil } }()
                model.importToLibrary(urls: urls, collectionID: target)
            }
        }
        .sheet(isPresented: $showNote) {
            NavigationStack { NoteEditorView() }.environmentObject(model).presentationBackground(Theme.ink)
        }
        .sheet(isPresented: $showCollections) {
            NavigationStack { CollectionsView() }.environmentObject(model).presentationBackground(Theme.ink)
        }
        .confirmationDialog("¿Eliminar de la biblioteca?", isPresented: Binding(get: { itemToDelete != nil }, set: { if !$0 { itemToDelete = nil } }),
                            titleVisibility: .visible, presenting: itemToDelete) { item in
            Button("Eliminar «\(item.title)»", role: .destructive) { model.deleteLibraryItem(item.id) }
        } message: { _ in
            Text("Se borra su texto, su índice y sus fragmentos. No se puede deshacer.")
        }
        .accessibilityIdentifier("library")
    }

    private var emptyState: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "books.vertical").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.silver)
                Text("Tu biblioteca está vacía").font(.system(size: 18, weight: .light)).foregroundStyle(Theme.textPrimary)
                Text("Guarda documentos, imágenes con texto y notas para que Viernes pueda consultarlos en cualquier conversación, citando el documento y la página. Se guarda el texto extraído (no el archivo original), cifrado en tu iPhone. Puedes añadirlos con «+» o desde un adjunto con «Guardar en la biblioteca».")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .padding(.vertical, 6)
            .accessibilityIdentifier("library-empty")
        }
        .listRowBackground(Theme.carbon.opacity(0.5))
    }

    private var itemsSection: some View {
        Section("\(scopeTitle) · \(visibleItems.count)") {
            ForEach(visibleItems) { item in
                NavigationLink { LibraryItemView(id: item.id) } label: { LibraryRow(item: item) }
                    .swipeActions { Button("Eliminar", role: .destructive) { itemToDelete = item } }
                    .accessibilityIdentifier("library-item")
            }
        }
        .listRowBackground(Theme.carbon.opacity(0.5))
    }

    private var searchSection: some View {
        Section(hits.isEmpty ? "Sin resultados" : "Resultados · \(hits.count)") {
            if hits.isEmpty {
                Text("No encontré fragmentos relevantes en «\(scopeTitle)». Prueba con otras palabras (la búsqueda ignora tildes y plurales) o con una fecha como «15 de marzo de 2023».")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                NavigationLink { LibraryItemView(id: hit.itemID) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(hit.title).font(Theme.body(14, weight: .medium)).foregroundStyle(Theme.textPrimary)
                            if !hit.reference.isEmpty { Text(hit.reference).font(Theme.mono(10)).foregroundStyle(Theme.accent) }
                        }
                        Text(String(hit.text.prefix(200))).font(.footnote).foregroundStyle(Theme.textSecondary).lineLimit(4)
                    }
                }
                .accessibilityIdentifier("library-hit")
            }
        }
        .listRowBackground(Theme.carbon.opacity(0.5))
    }

    private func runSearch() async {
        guard !trimmedQuery.isEmpty else { hits = []; return }
        try? await Task.sleep(nanoseconds: 250_000_000)           // espera a que termine de escribir (la tarea anterior se cancela sola)
        if Task.isCancelled { return }
        hits = await model.knowledge.search(trimmedQuery, filter: searchFilter, limit: 20, onlyRelevant: true)
    }
}

/// Fila de la biblioteca con el estado REAL del procesamiento.
struct LibraryRow: View {
    let item: KnowledgeItem

    var body: some View {
        HStack(spacing: 12) {
            if let data = item.thumbnail, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill().frame(width: 38, height: 38).clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: item.fileKind?.symbolName ?? item.kind.symbolName).foregroundStyle(Theme.accent).frame(width: 38, height: 38)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(Theme.body(14, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                if !item.tags.isEmpty {
                    Text(item.tags.map { "#\($0)" }.joined(separator: " ")).font(Theme.mono(10)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            LibraryStatusBadge(status: item.status)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(LibraryStatusBadge.text(item.status))")
    }

    private var subtitle: String {
        var parts = [item.kind.displayName]
        if let pages = item.pageCount { parts.append("\(pages) \(pages == 1 ? "pág." : "págs.")") }
        parts.append(item.importedAt.formatted(date: .abbreviated, time: .omitted))
        if item.recognizedByOCR { parts.append("OCR") }
        return parts.joined(separator: " · ")
    }
}

struct LibraryStatusBadge: View {
    let status: KnowledgeStatus

    static func text(_ status: KnowledgeStatus) -> String {
        switch status {
        case .queued: return "en cola"
        case .processing: return "procesando"
        case .indexed: return "indexado"
        case .failed: return "error"
        }
    }

    var body: some View {
        switch status {
        case .queued, .processing:
            HStack(spacing: 4) { ProgressView().scaleEffect(0.6); Text("Procesando").font(Theme.mono(9)).foregroundStyle(Theme.textSecondary) }
        case .indexed:
            HStack(spacing: 4) { Image(systemName: "checkmark.seal.fill").font(.system(size: 11)); Text("Indexado").font(Theme.mono(9)) }
                .foregroundStyle(Theme.accent)
        case .failed:
            HStack(spacing: 4) { Image(systemName: "xmark.octagon.fill").font(.system(size: 11)); Text("Error").font(Theme.mono(9)) }
                .foregroundStyle(libraryErrorColor)
        }
    }
}

/// Detalle de un elemento: datos, organización (título, etiquetas, carpeta), fragmentos guardados y borrado.
struct LibraryItemView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var title = ""
    @State private var tagsText = ""
    @State private var fragments: [(reference: String, text: String)] = []
    @State private var confirmDelete = false
    @State private var loaded = false

    private var item: KnowledgeItem? { model.libraryItems.first { $0.id == id } }

    var body: some View {
        Group {
            if let item = item { content(item) } else { Text("Este elemento ya no está en la biblioteca.").foregroundStyle(Theme.textSecondary) }
        }
        .navigationTitle("Elemento")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded, let item = item else { return }
            loaded = true
            title = item.title
            tagsText = item.tags.joined(separator: ", ")
            fragments = await model.knowledge.fragments(of: id)
        }
    }

    private func content(_ item: KnowledgeItem) -> some View {
        List {
            Section("Estado") {
                HStack { LibraryStatusBadge(status: item.status); Spacer() }
                if case .failed(let reason) = item.status { Text(reason).font(.footnote).foregroundStyle(libraryErrorColor).accessibilityIdentifier("library-item-error") }
                ForEach(item.warnings, id: \.self) { Text("• \($0)").font(.footnote).foregroundStyle(Theme.textSecondary) }
                if item.truncated { Text("• Es muy grande: solo se guardó una parte del texto.").font(.footnote).foregroundStyle(Theme.textSecondary) }
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Datos") {
                LabeledContent("Tipo", value: item.kind.displayName + (item.fileKind.map { " · \($0.displayName)" } ?? ""))
                LabeledContent("Origen", value: item.sourceName)
                LabeledContent("Guardado", value: item.importedAt.formatted(date: .abbreviated, time: .shortened))
                if let pages = item.pageCount { LabeledContent("Páginas", value: "\(pages)") }
                LabeledContent("Texto", value: "\(item.characterCount) caracteres en \(item.chunkCount) fragmentos")
                LabeledContent("Identificador", value: String(item.contentHash.prefix(12)))
                LabeledContent("Búsqueda por significado", value: item.embedderID == nil ? "no (solo texto)" : (item.embedderID?.hasPrefix("nl-") == true ? "sí (modelo del sistema)" : "básica (palabras y raíces)"))
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Organización") {
                TextField("Título", text: $title)
                    .onSubmit { Task { try? await model.knowledge.rename(id, to: title) } }
                    .accessibilityIdentifier("library-item-title")
                TextField("Etiquetas separadas por comas", text: $tagsText)
                    .textInputAutocapitalization(.never)
                    .onSubmit { Task { try? await model.knowledge.setTags(id, tagsText.components(separatedBy: ",")) } }
                Picker("Carpeta", selection: Binding(get: { item.collectionID }, set: { target in Task { try? await model.knowledge.move(id, to: target) } })) {
                    Text("Sin carpeta").tag(UUID?.none)
                    ForEach(model.libraryCollections) { Text("\($0.kind.displayName): \($0.name)").tag(Optional($0.id)) }
                }
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            if !fragments.isEmpty {
                Section("Fragmentos guardados (\(fragments.count))") {
                    ForEach(Array(fragments.prefix(8).enumerated()), id: \.offset) { _, fragment in
                        VStack(alignment: .leading, spacing: 3) {
                            if !fragment.reference.isEmpty { Text(fragment.reference).font(Theme.mono(10)).foregroundStyle(Theme.accent) }
                            Text(String(fragment.text.prefix(240))).font(.footnote).foregroundStyle(Theme.textPrimary)
                        }
                    }
                    if fragments.count > 8 { Text("…y \(fragments.count - 8) fragmentos más").font(.footnote).foregroundStyle(Theme.textSecondary) }
                }
                .listRowBackground(Theme.carbon.opacity(0.5))
            }

            Section {
                Button("Eliminar de la biblioteca", role: .destructive) { confirmDelete = true }.accessibilityIdentifier("library-item-delete")
            }
            .listRowBackground(Theme.carbon.opacity(0.5))
        }
        .chromeList()
        .confirmationDialog("¿Eliminar «\(item.title)»?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Eliminar", role: .destructive) { model.deleteLibraryItem(id); dismiss() }
        } message: { Text("Se borra su texto, su índice y sus fragmentos. Dejará de aparecer en las búsquedas.") }
    }
}

/// Nueva nota o texto escrito por el usuario.
struct NoteEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var kind: KnowledgeKind = .note
    @State private var collectionID: UUID?
    @State private var tagsText = ""
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                TextField("Título (opcional)", text: $title).accessibilityIdentifier("note-title")
                TextEditor(text: $text).frame(minHeight: 160).accessibilityIdentifier("note-text")
            }
            Section {
                Picker("Tipo", selection: $kind) {
                    Text("Nota").tag(KnowledgeKind.note)
                    Text("Texto").tag(KnowledgeKind.text)
                }
                Picker("Carpeta", selection: $collectionID) {
                    Text("Sin carpeta").tag(UUID?.none)
                    ForEach(model.libraryCollections) { Text("\($0.kind.displayName): \($0.name)").tag(Optional($0.id)) }
                }
                TextField("Etiquetas separadas por comas", text: $tagsText).textInputAutocapitalization(.never)
            }
            if let message = message { Section { Text(message).font(.footnote).foregroundStyle(Theme.textSecondary) } }
        }
        .navigationTitle("Nueva nota")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Guardando…" : "Guardar") { save() }
                    .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("note-save")
            }
        }
    }

    private func save() {
        saving = true
        Task {
            let outcome = await model.addLibraryNote(title: title, text: text, kind: kind, collectionID: collectionID,
                                                     tags: tagsText.components(separatedBy: ","))
            saving = false
            switch outcome {
            case .saved: dismiss()
            case .duplicate(let existing, let reason): message = "Ya lo tenías: \(reason.explanation) que «\(existing.title)»."
            case .failed(let reason): message = reason
            }
        }
    }
}

/// Proyectos, carpetas y colecciones (se pueden anidar al crearlas dentro de otra).
struct CollectionsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: KnowledgeCollection.Kind = .project
    @State private var parentID: UUID?
    @State private var message: String?

    var body: some View {
        List {
            Section("Nuevo") {
                TextField("Nombre", text: $name).accessibilityIdentifier("collection-name")
                Picker("Tipo", selection: $kind) {
                    ForEach(KnowledgeCollection.Kind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Dentro de", selection: $parentID) {
                    Text("Nivel superior").tag(UUID?.none)
                    ForEach(model.libraryCollections) { Text($0.name).tag(Optional($0.id)) }
                }
                Button("Crear") {
                    Task {
                        do {
                            try await model.knowledge.createCollection(name: name, kind: kind, parentID: parentID)
                            name = ""
                            message = nil
                            await model.reloadLibrary()
                        } catch { message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("collection-create")
                if let message = message { Text(message).font(.footnote).foregroundStyle(libraryErrorColor) }
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Existentes") {
                if model.libraryCollections.isEmpty { Text("Aún no hay ninguno.").font(.footnote).foregroundStyle(Theme.textSecondary) }
                ForEach(model.libraryCollections) { collection in
                    let count = model.libraryItems.filter { $0.collectionID == collection.id }.count
                    HStack {
                        Image(systemName: "folder").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading) {
                            Text(collection.name).foregroundStyle(Theme.textPrimary)
                            Text("\(collection.kind.displayName) · \(count) elementos").font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .swipeActions {
                        Button("Borrar", role: .destructive) {
                            Task { try? await model.knowledge.deleteCollection(collection.id); await model.reloadLibrary() }
                        }
                    }
                }
                Text("Al borrar un proyecto o carpeta, sus documentos NO se borran: pasan al nivel superior.").font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))
        }
        .chromeList()
        .navigationTitle("Proyectos y carpetas")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
    }
}
