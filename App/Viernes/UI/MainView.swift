import SwiftUI
import PhotosUI
import ViernesCore

/// Ayudas SOLO para las pruebas y las capturas del CI (`--uitest`): permiten fijar un estado visual para fotografiarlo.
/// En el uso real no existen: el estado del núcleo sale siempre del funcionamiento verdadero de la app.
private enum QAOverrides {
    private static var active: Bool { ProcessInfo.processInfo.arguments.contains("--uitest") }

    static var coreState: CoreVisualState? {
        guard active else { return nil }
        let prefix = "--uitest-core-state="
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        switch String(argument.dropFirst(prefix.count)) {
        case "listening": return .listening
        case "thinking": return .thinking
        case "speaking": return .speaking
        case "executing": return .executing
        case "error": return .error
        case "offline": return .offline
        default: return .idle
        }
    }

    /// Abre una hoja al arrancar para fotografiarla (`--uitest-open=library` o `=attachment`).
    static var openSheet: String? {
        guard active else { return nil }
        let prefix = "--uitest-open="
        return ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var confirmation: ConfirmationCenter
    @EnvironmentObject var mailDrafts: MailDraftCenter
    @State private var sheet: Sheet?
    @State private var keyboardMode = false
    @FocusState private var inputFocused: Bool
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showCamera = false
    @State private var showScanner = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var detailID: IdentifiedUUID?

    enum Sheet: String, Identifiable {
        case settings, memory, history, library
        var id: String { rawValue }
    }

    /// Con mensajes en pantalla la conversación pasa a primer plano y el núcleo se compacta.
    private var inConversation: Bool { !model.messages.isEmpty || !model.streamingText.isEmpty }

    private var visualState: CoreVisualState {
        QAOverrides.coreState ?? CoreVisualState(core: model.displayState, executing: model.activeTool != nil)
    }

    var body: some View {
        ZStack {
            Theme.background
            VStack(spacing: 0) {
                header
                if inConversation { conversationLayout } else { homeLayout }
                controls
            }
            .padding(.horizontal, 18)

            if let banner = model.banner {
                VStack {
                    ChromePanel(tint: Theme.amber) {
                        Text(banner).font(Theme.body(13)).foregroundStyle(Theme.textPrimary)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { model.banner = nil }
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 54)
                .accessibilityIdentifier("banner")
            }
        }
        .task {
            // Solo pruebas/capturas: espera a que la semilla real de la biblioteca o de los adjuntos termine y abre la hoja pedida.
            guard let which = QAOverrides.openSheet else { return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if which == "library" { sheet = .library }
            if which == "attachment", let first = model.attachments.drafts.first(where: { $0.failureText == nil }) { detailID = IdentifiedUUID(id: first.id) }
        }
        .animation(.easeInOut(duration: 0.25), value: model.banner)
        .animation(.easeInOut(duration: 0.3), value: inConversation)
        // Una confirmación no puede presentarse encima de otra hoja: se cierra la que esté abierta.
        .onChange(of: confirmation.current) { _, request in if request != nil { sheet = nil } }
        .onChange(of: mailDrafts.current) { _, draft in if draft != nil { sheet = nil } }
        .sheet(item: $sheet) { which in
            NavigationStack {
                switch which {
                case .settings: SettingsView()
                case .memory: MemoryView()
                case .history: HistoryView(dismissAll: { sheet = nil })
                case .library: LibraryView()
                }
            }
            .environmentObject(model)
            .presentationBackground(Theme.ink)
        }
        .sheet(item: Binding(get: { confirmation.current.map(IdentifiedConfirmation.init) }, set: { _ in })) { item in
            ConfirmationSheet(request: item.request)
                .environmentObject(confirmation)
                .presentationDetents([.medium])
                .presentationBackground(Theme.ink)
                .interactiveDismissDisabled()
        }
        // Vista previa del correo: la herramienta compose_email espera a que el usuario abra Correo, copie o descarte.
        .sheet(item: Binding(get: { mailDrafts.current }, set: { _ in })) { draft in
            MailDraftSheet(draft: draft)
                .environmentObject(mailDrafts)
                .presentationDetents([.large])
                .presentationBackground(Theme.ink)
                .interactiveDismissDisabled()
        }
        // Adjuntos: fototeca, Archivos, cámara y escáner de documentos.
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoSelection,
                      maxSelectionCount: max(1, model.attachments.imageSlotsLeft), matching: .images)
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            photoSelection = []
            Task { await model.attachments.addPhotoItems(items) }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.attachments.addFiles(urls) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(isPresented: $showCamera) { model.attachments.addCameraImage($0) }.ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScannerView(isPresented: $showScanner) { model.attachments.addScan(pages: $0) }.ignoresSafeArea()
        }
        .sheet(item: $detailID) { item in
            AttachmentDetailSheet(center: model.attachments, id: item.id).environmentObject(model)
        }
    }

    /// Fuentes de adjuntos (las que el dispositivo no ofrece, como la cámara en el simulador, aparecen desactivadas y lo dicen).
    @ViewBuilder private var attachItems: some View {
        Button { showPhotoPicker = true } label: { Label("Foto de la fototeca", systemImage: "photo.on.rectangle") }
            .accessibilityIdentifier("attach-photo")
        Button { showCamera = true } label: {
            Label(AttachmentSources.cameraAvailable ? "Tomar una foto" : "Tomar una foto (sin cámara)", systemImage: "camera")
        }
        .disabled(!AttachmentSources.cameraAvailable)
        .accessibilityIdentifier("attach-camera")
        Button { showScanner = true } label: {
            Label(AttachmentSources.scannerAvailable ? "Escanear documento" : "Escanear documento (no disponible)", systemImage: "doc.viewfinder")
        }
        .disabled(!AttachmentSources.scannerAvailable)
        .accessibilityIdentifier("attach-scan")
        Button { showFileImporter = true } label: { Label("Archivo (PDF, Word, Excel, texto…)", systemImage: "folder") }
            .accessibilityIdentifier("attach-file")
    }

    // MARK: Cabecera (marca a la izquierda, engranaje a la derecha)

    private var header: some View {
        HStack(spacing: 12) {
            ViernesMark(size: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text("VIERNES")
                    .font(Theme.display(18, weight: .semibold)).tracking(6)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(inConversation ? "Conversación" : "Tu asistente personal")
                    .font(Theme.body(13)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if inConversation {
                Menu { moreItems } label: { Image(systemName: "ellipsis") }
                    .buttonStyle(ChromeIconButtonStyle(size: 40))
                    .accessibilityLabel("Más opciones").accessibilityIdentifier("open-more")
            }
            Button { sheet = .settings } label: { Image(systemName: "gearshape") }
                .buttonStyle(ChromeIconButtonStyle(size: 40))
                .accessibilityLabel("Configuración").accessibilityIdentifier("open-settings")
        }
        .padding(.top, 6)
    }

    /// Acciones secundarias, en un menú para que la pantalla principal quede limpia.
    @ViewBuilder private var moreItems: some View {
        Menu { attachItems } label: { Label("Adjuntar", systemImage: "paperclip") }
            .accessibilityIdentifier("attach-menu-more")
        Button { sheet = .memory } label: { Label("Memoria", systemImage: "brain.head.profile") }
            .accessibilityIdentifier("open-memory")
        Button { sheet = .library } label: { Label("Biblioteca", systemImage: "books.vertical") }
            .accessibilityIdentifier("open-library")
        Button { sheet = .history } label: { Label("Historial", systemImage: "clock.arrow.circlepath") }
            .accessibilityIdentifier("open-history")
        Button { model.newConversation() } label: { Label("Nueva conversación", systemImage: "square.and.pencil") }
            .accessibilityIdentifier("new-conversation")
        Button {
            model.typedDraft = "Pregúntale a Claude "
            keyboardMode = true
            inputFocused = true
        } label: { Label("Preguntar a Claude", systemImage: "sparkles") }
            .accessibilityIdentifier("menu-claude")
    }

    // MARK: Núcleo

    private func core(compact: Bool) -> some View {
        ViernesCoreVisual(state: visualState, level: model.audioLevel, pulse: model.speakPulse, reducedEffects: model.settings.reducedEffects)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: compact ? CGFloat(84) : CGFloat(380), maxHeight: compact ? CGFloat(84) : CGFloat.infinity)
            .contentShape(Circle())
            .onTapGesture { model.micTapped() }
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("core")
    }

    // MARK: Pantalla de inicio

    private var homeLayout: some View {
        VStack(spacing: 0) {
            core(compact: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 2)
            onlinePill.padding(.top, 2)
            headline.padding(.top, 14)
            enginePanel
            quickTiles.padding(.top, 18)
            Spacer(minLength: 6)
        }
    }

    private var onlinePill: some View {
        let online = model.isOnline
        let tint: Color = online ? Color(red: 0.30, green: 0.88, blue: 0.48) : Theme.amber
        return HStack(spacing: 7) {
            Circle().fill(tint).frame(width: 7, height: 7).shadow(color: tint.opacity(0.8), radius: 4)
            Text(online ? "En línea" : "Sin conexión · local").font(Theme.body(13, weight: .medium)).foregroundStyle(tint)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Capsule().fill(Theme.ink.opacity(0.7)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.55), lineWidth: 0.8))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("online-pill")
    }

    private var headlineTexts: (title: String, subtitle: String) {
        switch model.displayState {
        case .disconnected:
            return ("Sin cerebro activo", "Elige un cerebro en Configuración para empezar")
        case .listening:
            let heard = model.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            return ("Te escucho", heard.isEmpty ? "Habla con naturalidad" : heard)
        case .thinking:
            if let wait = model.engineWaitNote { return ("Esperando al proveedor…", wait) }
            if let note = model.busyNote { return (note, "") }
            if let tool = model.activeTool { return (ToolPhrases.running(tool), "") }
            return ("Pensando…", "")
        case .speaking:
            return ("Hablando", "Toca el núcleo para interrumpir")
        case .error:
            return ("Algo falló", "Revisa el mensaje e inténtalo de nuevo")
        case .idle:
            return ("¿En qué puedo ayudarte?", "Tu inteligencia, en tus manos")
        }
    }

    private var headline: some View {
        VStack(spacing: 6) {
            Text(headlineTexts.title)
                .font(Theme.display(26, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.75)
                .accessibilityIdentifier("headline")
            if !headlineTexts.subtitle.isEmpty {
                Text(headlineTexts.subtitle)
                    .font(Theme.body(16)).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center).lineLimit(2)
            }
            wakeIndicator
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder private var wakeIndicator: some View {
        if model.wakeWordActive {
            HStack(spacing: 6) {
                Circle().fill(Theme.alert).frame(width: 6, height: 6)
                Text("Micrófono abierto · esperando «Viernes»").font(Theme.mono(11))
            }
            .foregroundStyle(Theme.textSecondary)
            .accessibilityIdentifier("wake-indicator")
        }
    }

    @ViewBuilder private var enginePanel: some View {
        if case .downloading(let progress) = model.engineStatus {
            VStack(spacing: 4) {
                ProgressView(value: progress).tint(Theme.accent).frame(maxWidth: 220)
                Text("Descargando modelo \(Int(progress * 100)) %").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, 10)
        } else if case .loading = model.engineStatus {
            Text("Cargando modelo en memoria…").font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).padding(.top, 10)
        } else if !model.engineStatus.isReady {
            Button("Configurar cerebro") { sheet = .settings }
                .buttonStyle(ChromeButtonStyle(tint: Theme.amber))
                .accessibilityIdentifier("configure-model")
                .padding(.top, 10)
        }
    }

    /// Cuatro mosaicos como en la referencia. Solo capacidades que existen de verdad.
    private var quickTiles: some View {
        HStack(spacing: 12) {
            tile(icon: "calendar", title: "Mi día", id: "quick-today") { model.submit("¿Qué tengo hoy en mi agenda?") }
            tile(icon: "checkmark.circle", title: "Tareas", id: "quick-tasks") { model.submit("Lista mis recordatorios pendientes") }
            tile(icon: "cloud.sun", title: "Clima", id: "quick-weather") { model.submit("¿Qué clima hace hoy?") }
            Menu { moreItems } label: { tileLabel(icon: "square.grid.2x2", title: "Más") }
                .accessibilityLabel("Más").accessibilityIdentifier("quick-more")
        }
    }

    private func tileLabel(icon: String, title: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 22, weight: .light)).foregroundStyle(Theme.silver)
            Text(title).font(Theme.body(13, weight: .medium)).foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity).frame(height: 78)
        .chromeSurface(tint: Theme.accent, radius: 18)
    }

    private func tile(icon: String, title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { tileLabel(icon: icon, title: title) }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityIdentifier(id)
    }

    // MARK: Conversación

    private var conversationLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                core(compact: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headlineTexts.title)
                        .font(Theme.display(15, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    HStack(spacing: 6) {
                        Circle().fill(model.isOnline ? Color(red: 0.30, green: 0.88, blue: 0.48) : Theme.amber).frame(width: 6, height: 6)
                        Text(model.activeModel.isSystemModel ? "Apple Intelligence" : (model.activeModel.displayName.components(separatedBy: " (").first ?? ""))
                            .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    wakeIndicator
                    enginePanel
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            ConversationView()
                .frame(maxHeight: .infinity)
                .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.06)))
        }
    }

    // MARK: Controles

    private var controls: some View {
        VStack(spacing: 8) {
            if let pending = model.pendingTranscript { TranscriptReviewBar(pending: pending) }
            if !model.attachments.drafts.isEmpty {
                AttachmentStrip(center: model.attachments, library: model.libraryItems) { detailID = IdentifiedUUID(id: $0) }
            }
            if keyboardMode { inputBar }
            HStack(spacing: 10) {
                controlButton(icon: keyboardMode ? "keyboard.chevron.compact.down" : "keyboard", label: "Teclado", id: "toggle-keyboard") {
                    keyboardMode.toggle()
                    inputFocused = keyboardMode
                }
                VoiceDock()
                controlButton(icon: model.settings.voice.speakResponses ? "speaker.wave.2" : "speaker.slash", label: "Voz de respuesta", id: "toggle-speech") {
                    model.settings.voice.speakResponses.toggle()
                    if !model.settings.voice.speakResponses { model.interrupt() }
                }
            }
            Text(dockCaption)
                .font(Theme.body(13)).foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("state-label")
        }
        .padding(.top, 8).padding(.bottom, 8)
        .onChange(of: model.typedDraft) { _, new in if !new.isEmpty { keyboardMode = true } }
    }

    private var dockCaption: String {
        switch model.coreState {
        case .listening: return "Escuchando · toca para terminar"
        case .thinking: return "Toca para cancelar"
        case .speaking: return "Toca para interrumpir y hablar"
        default: return "Toca para hablar"
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Menu { attachItems } label: { Image(systemName: "paperclip") }
                .buttonStyle(ChromeIconButtonStyle(size: 44))
                .accessibilityLabel("Adjuntar").accessibilityIdentifier("attach-menu")
            TextField("Escribe o habla…", text: $model.typedDraft, axis: .vertical)
                .lineLimit(1...3)
                .focused($inputFocused)
                .textFieldStyle(.plain)
                .font(Theme.body(15))
                .padding(.horizontal, 16).padding(.vertical, 12)
                .chromeSurface(tint: Theme.accent, radius: 22)
                .foregroundStyle(Theme.textPrimary)
                .submitLabel(.send)
                .onSubmit { model.sendTyped() }
                .accessibilityIdentifier("text-input")
            Button { model.sendTyped() } label: { Image(systemName: "arrow.up") }
                .buttonStyle(ChromeIconButtonStyle(tint: Theme.accent, size: 44))
                .disabled(model.typedDraft.trimmingCharacters(in: .whitespaces).isEmpty && !model.attachments.hasReady)
                .accessibilityLabel("Enviar mensaje").accessibilityIdentifier("send-message")
        }
    }

    private func controlButton(icon: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .buttonStyle(ChromeIconButtonStyle(size: 42))
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
    }
}

struct IdentifiedUUID: Identifiable {
    let id: UUID
}

struct IdentifiedConfirmation: Identifiable {
    let request: ConfirmationRequest
    var id: String { request.tool + request.detail }
}
