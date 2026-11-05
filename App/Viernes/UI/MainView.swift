import SwiftUI
import ViernesCore

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var confirmation: ConfirmationCenter
    @State private var sheet: Sheet?
    @State private var keyboardMode = false
    @FocusState private var inputFocused: Bool

    enum Sheet: String, Identifiable {
        case settings, memory, history
        var id: String { rawValue }
    }

    /// Con mensajes en pantalla la conversación pasa a primer plano y el núcleo se compacta.
    private var inConversation: Bool { !model.messages.isEmpty || !model.streamingText.isEmpty }

    var body: some View {
        ZStack {
            Theme.background
            VStack(spacing: 0) {
                header
                statusChips.padding(.top, 10)
                if inConversation { conversationLayout } else { homeLayout }
                controls
            }
            .padding(.horizontal, 16)

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
        .animation(.easeInOut(duration: 0.25), value: model.banner)
        .animation(.easeInOut(duration: 0.3), value: inConversation)
        // Una confirmación no puede presentarse encima de otra hoja: se cierra la que esté abierta.
        .onChange(of: confirmation.current) { _, request in if request != nil { sheet = nil } }
        .sheet(item: $sheet) { which in
            NavigationStack {
                switch which {
                case .settings: SettingsView()
                case .memory: MemoryView()
                case .history: HistoryView(dismissAll: { sheet = nil })
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
    }

    // MARK: Cabecera

    private var header: some View {
        HStack(spacing: 12) {
            ViernesMark(size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("VIERNES")
                    .font(Theme.display(16, weight: .semibold)).tracking(4)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("Tu asistente personal")
                    .font(Theme.body(12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                Button { sheet = .history } label: { Image(systemName: "clock.arrow.circlepath") }
                    .accessibilityLabel("Historial").accessibilityIdentifier("open-history")
                Button { sheet = .memory } label: { Image(systemName: "brain.head.profile") }
                    .accessibilityLabel("Memoria").accessibilityIdentifier("open-memory")
                Button { model.newConversation() } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("Nueva conversación").accessibilityIdentifier("new-conversation")
                Button { sheet = .settings } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Configuración").accessibilityIdentifier("open-settings")
            }
            .buttonStyle(ChromeIconButtonStyle(size: 34))
        }
        .padding(.top, 6)
    }

    private var statusChips: some View {
        HStack(spacing: 8) {
            chip(icon: "cpu", text: model.activeModel.isSystemModel ? "Apple Intelligence" : (model.activeModel.displayName.components(separatedBy: " (").first ?? ""),
                 tint: model.engineStatus.isReady ? Theme.accent : Theme.amber)
            chip(icon: model.isOnline ? "wifi" : "wifi.slash", text: model.isOnline ? "En línea" : "Sin conexión · local",
                 tint: model.isOnline ? Theme.textSecondary : Theme.amber)
            if model.settings.claude.mode != .disabled {
                chip(icon: "arrow.up.forward.app", text: "Claude: \(model.settings.claude.mode == .openApp ? "abrir app" : "Atajo")", tint: Theme.silver)
            }
        }
        .lineLimit(1)
    }

    private func chip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .font(Theme.mono(11))
        .foregroundStyle(tint)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(Theme.carbon.opacity(0.7)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.7))
    }

    // MARK: Núcleo

    private func core(compact: Bool) -> some View {
        ChromeCoreView(state: model.displayState, level: model.audioLevel, pulse: model.speakPulse,
                       acting: model.activeTool != nil, reducedEffects: model.settings.reducedEffects)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: compact ? CGFloat(96) : CGFloat(340), maxHeight: compact ? CGFloat(96) : CGFloat.infinity)
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
                .padding(.vertical, 6)
            headline
            enginePanel
            quickActions.padding(.top, 14)
            Spacer(minLength: 8)
        }
    }

    private var headlineTexts: (title: String, subtitle: String) {
        switch model.displayState {
        case .disconnected:
            return ("Sin cerebro activo", "Elige un cerebro en Configuración para empezar")
        case .listening:
            let heard = model.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            return ("Te escucho", heard.isEmpty ? "Habla con naturalidad" : heard)
        case .thinking:
            if let tool = model.activeTool { return (ToolPhrases.running(tool), "") }
            return ("Pensando…", "")
        case .speaking:
            return ("Hablando", "Toca el núcleo para interrumpir")
        case .error:
            return ("Algo falló", "Revisa el mensaje e inténtalo de nuevo")
        case .idle:
            return ("¿En qué puedo ayudarte?", greeting)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Buenos días"
        case 12..<19: return "Buenas tardes"
        default: return "Buenas noches"
        }
    }

    private var headline: some View {
        VStack(spacing: 6) {
            Text(model.displayState.title.uppercased())
                .font(Theme.mono(11, weight: .semibold)).tracking(3)
                .foregroundStyle(Theme.color(for: model.displayState))
                .accessibilityIdentifier("state-label")
            Text(headlineTexts.title)
                .font(Theme.display(24, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
                .accessibilityIdentifier("headline")
            if !headlineTexts.subtitle.isEmpty {
                Text(headlineTexts.subtitle)
                    .font(Theme.body(15)).foregroundStyle(Theme.textSecondary)
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

    /// Accesos rápidos: solo capacidades que existen de verdad.
    private var quickActions: some View {
        HStack(spacing: 10) {
            quickAction(icon: "checklist", title: "Tareas", id: "quick-tasks") { model.submit("Lista mis recordatorios pendientes") }
            quickAction(icon: "cloud.sun", title: "Clima", id: "quick-weather") { model.submit("¿Qué clima hace hoy?") }
            quickAction(icon: "sparkles", title: "Claude", id: "quick-claude") {
                model.typedDraft = "Pregúntale a Claude "
                keyboardMode = true
                inputFocused = true
            }
            quickAction(icon: "brain.head.profile", title: "Memoria", id: "quick-memory") { sheet = .memory }
        }
    }

    private func quickAction(icon: String, title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 20, weight: .regular)).foregroundStyle(Theme.accent)
                Text(title).font(Theme.body(12, weight: .medium)).foregroundStyle(Theme.textPrimary)
            }
            .frame(maxWidth: .infinity).frame(height: 64)
            .chromeSurface(tint: Theme.accent, radius: 16)
        }
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
                    Text(model.displayState.title.uppercased())
                        .font(Theme.mono(11, weight: .semibold)).tracking(3)
                        .foregroundStyle(Theme.color(for: model.displayState))
                        .accessibilityIdentifier("state-label")
                    Text(headlineTexts.title)
                        .font(Theme.display(15, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
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
        VStack(spacing: 10) {
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
                .font(Theme.mono(10)).tracking(2)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 8).padding(.bottom, 8)
        .onChange(of: model.typedDraft) { _, new in if !new.isEmpty { keyboardMode = true } }
    }

    private var dockCaption: String {
        switch model.coreState {
        case .listening: return "ESCUCHANDO · TOCA PARA TERMINAR"
        case .thinking: return "TOCA PARA CANCELAR"
        case .speaking: return "TOCA PARA INTERRUMPIR"
        default: return "TOCA PARA HABLAR"
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Escribe a Viernes…", text: $model.typedDraft, axis: .vertical)
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
                .disabled(model.typedDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Enviar mensaje").accessibilityIdentifier("send-message")
        }
    }

    private func controlButton(icon: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .buttonStyle(ChromeIconButtonStyle(size: 46))
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
    }
}

struct IdentifiedConfirmation: Identifiable {
    let request: ConfirmationRequest
    var id: String { request.tool + request.detail }
}
