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

    var body: some View {
        ZStack {
            Theme.background
            VStack(spacing: 0) {
                topBar
                statusChips.padding(.top, 6)
                Spacer(minLength: 8)
                core
                stateLabel
                Spacer(minLength: 8)
                transcriptArea
                controls
            }
            .padding(.horizontal, 16)

            if let banner = model.banner {
                VStack {
                    GlassPanel(tint: Theme.amber) {
                        Text(banner).font(.footnote).foregroundStyle(Theme.textPrimary)
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
            .presentationBackground(Theme.abyss)
        }
        .sheet(item: Binding(get: { confirmation.current.map(IdentifiedConfirmation.init) }, set: { _ in })) { item in
            ConfirmationSheet(request: item.request)
                .environmentObject(confirmation)
                .presentationDetents([.medium])
                .presentationBackground(Theme.abyss)
                .interactiveDismissDisabled()
        }
    }

    // MARK: Piezas

    private var topBar: some View {
        HStack {
            Button { sheet = .history } label: { Image(systemName: "clock.arrow.circlepath") }
                .accessibilityLabel("Historial").accessibilityIdentifier("open-history")
            Button { sheet = .memory } label: { Image(systemName: "brain.head.profile") }
                .accessibilityLabel("Memoria").accessibilityIdentifier("open-memory")
            Spacer()
            Text("VIERNES").font(.system(size: 15, weight: .light, design: .default)).tracking(8).foregroundStyle(Theme.textPrimary)
            Spacer()
            Button { model.newConversation() } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel("Nueva conversación").accessibilityIdentifier("new-conversation")
            Button { sheet = .settings } label: { Image(systemName: "slider.horizontal.3") }
                .accessibilityLabel("Configuración").accessibilityIdentifier("open-settings")
        }
        .font(.system(size: 18, weight: .light))
        .foregroundStyle(Theme.cyan)
        .padding(.top, 6)
    }

    private var statusChips: some View {
        HStack(spacing: 8) {
            chip(icon: "cpu", text: model.activeModel.isSystemModel ? "Apple Intelligence" : model.activeModel.displayName.components(separatedBy: " (").first ?? "", tint: model.engineStatus.isReady ? Theme.cyan : Theme.amber)
            chip(icon: model.isOnline ? "wifi" : "wifi.slash", text: model.isOnline ? "En línea" : "Sin conexión · local", tint: model.isOnline ? Theme.textSecondary : Theme.amber)
            if model.settings.claude.mode != .disabled {
                chip(icon: "arrow.up.forward.app", text: "Claude: \(model.settings.claude.mode == .openApp ? "abrir app" : "Atajo")", tint: Theme.ice)
            }
        }
        .lineLimit(1)
    }

    private func chip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(tint.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.6))
    }

    private var core: some View {
        HoloCoreView(state: model.displayState, level: model.audioLevel, pulse: model.speakPulse, reducedEffects: model.settings.reducedEffects)
            .frame(maxWidth: 320, maxHeight: 320)
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Circle())
            .onTapGesture { model.micTapped() }
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("core")
    }

    private var stateLabel: some View {
        VStack(spacing: 4) {
            Text(model.displayState.title.uppercased())
                .font(.system(size: 13, weight: .medium, design: .monospaced)).tracking(4)
                .foregroundStyle(Theme.color(for: model.displayState))
                .accessibilityIdentifier("state-label")
            if model.wakeWordActive {
                HStack(spacing: 6) {
                    Circle().fill(Theme.alert).frame(width: 6, height: 6)
                    Text("Micrófono abierto · esperando «Viernes»").font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("wake-indicator")
            }
            if case .downloading(let progress) = model.engineStatus {
                ProgressView(value: progress).tint(Theme.cyan).frame(maxWidth: 200)
                Text("Descargando modelo \(Int(progress * 100)) %").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
            } else if case .loading = model.engineStatus {
                Text("Cargando modelo en memoria…").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
            } else if !model.engineStatus.isReady {
                Button("Configurar modelo") { sheet = .settings }.buttonStyle(HoloButtonStyle(tint: Theme.amber))
                    .accessibilityIdentifier("configure-model")
            }
        }
    }

    private var transcriptArea: some View {
        ConversationView()
            .frame(maxHeight: 230)
            .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.12)))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if keyboardMode {
                HStack(spacing: 8) {
                    TextField("Escribe a Viernes…", text: $model.typedDraft, axis: .vertical)
                        .lineLimit(1...3)
                        .focused($inputFocused)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Theme.deep.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.cyan.opacity(0.4), lineWidth: 0.8))
                        .foregroundStyle(Theme.textPrimary)
                        .submitLabel(.send)
                        .onSubmit { model.sendTyped() }
                        .accessibilityIdentifier("text-input")
                    Button { model.sendTyped() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)) }
                        .foregroundStyle(Theme.cyan)
                        .disabled(model.typedDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel("Enviar").accessibilityIdentifier("send")
                }
            }
            HStack(spacing: 28) {
                controlButton(icon: keyboardMode ? "keyboard.chevron.compact.down" : "keyboard", label: "Teclado", id: "toggle-keyboard") {
                    keyboardMode.toggle()
                    inputFocused = keyboardMode
                }
                micButton
                controlButton(icon: model.settings.voice.speakResponses ? "speaker.wave.2" : "speaker.slash", label: "Voz de respuesta", id: "toggle-speech") {
                    model.settings.voice.speakResponses.toggle()
                    if !model.settings.voice.speakResponses { model.interrupt() }
                }
            }
        }
        .padding(.bottom, 10)
        .onChange(of: model.typedDraft) { _, new in if !new.isEmpty { keyboardMode = true } }
    }

    private var micButton: some View {
        Button { model.micTapped() } label: {
            ZStack {
                Circle().fill(Theme.color(for: model.coreState).opacity(0.14)).frame(width: 74, height: 74)
                Circle().strokeBorder(Theme.color(for: model.coreState), lineWidth: 1.4).frame(width: 74, height: 74)
                Image(systemName: micIcon).font(.system(size: 28, weight: .light)).foregroundStyle(Theme.color(for: model.coreState))
            }
        }
        .accessibilityLabel(micLabel)
        .accessibilityIdentifier("mic")
    }

    private var micIcon: String {
        switch model.coreState {
        case .listening: return "stop.fill"
        case .speaking: return "hand.raised.fill"
        case .thinking: return "xmark"
        default: return "mic"
        }
    }

    private var micLabel: String {
        switch model.coreState {
        case .listening: return "Terminar de hablar"
        case .speaking: return "Interrumpir"
        case .thinking: return "Cancelar"
        default: return "Hablar con Viernes"
        }
    }

    private func controlButton(icon: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 20, weight: .light)).foregroundStyle(Theme.cyan)
                .frame(width: 48, height: 48)
                .background(Theme.cyan.opacity(0.08), in: Circle())
                .overlay(Circle().strokeBorder(Theme.cyan.opacity(0.3), lineWidth: 0.8))
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

struct IdentifiedConfirmation: Identifiable {
    let request: ConfirmationRequest
    var id: String { request.tool + request.detail }
}
