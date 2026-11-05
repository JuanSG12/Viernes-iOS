import SwiftUI
import SwiftData
import Network
import UIKit
import ViernesCore

enum CoreState: Equatable {
    case idle, listening, thinking, speaking, error, disconnected

    var title: String {
        switch self {
        case .idle: return "En espera"
        case .listening: return "Escuchando"
        case .thinking: return "Pensando"
        case .speaking: return "Hablando"
        case .error: return "Error"
        case .disconnected: return "Sin cerebro"
        }
    }
}

enum EngineStatus: Equatable {
    case notLoaded
    case downloading(Double)
    case loading
    case ready
    case unavailable(String)
    case failed(String)

    var isReady: Bool { self == .ready }
}

/// Estado y orquestación de toda la app. Una sola fuente de verdad para las pantallas.
@MainActor
final class AppModel: ObservableObject {
    // MARK: Estado de UI
    @Published var coreState: CoreState = .idle
    @Published var messages: [ChatMessage] = []
    @Published var streamingText = ""
    @Published var liveTranscript = ""
    @Published var liveActions: [ActionRecord] = []
    /// Herramienta que se está ejecutando de verdad (nil si ninguna). Alimenta la animación y el texto de estado.
    @Published var activeTool: String?
    @Published var audioLevel: Float = 0
    @Published var speakPulse = Date.distantPast
    @Published var engineStatus: EngineStatus = .notLoaded
    @Published var banner: String?
    @Published var isOnline = true
    @Published var typedDraft = ""
    @Published var wakeWordActive = false
    @Published var memoryItems: [MemoryItem] = []
    @Published var pendingMemories: [MemoryItem] = []
    @Published var unreadableMemoryCount = 0
    @Published var history: [ConversationSnapshot] = []
    @Published var voices: [VoiceDescriptor] = []
    @Published var permissionTick = 0
    @Published var memoryUnlocked = true
    @Published var busyNote: String?
    @Published private(set) var activeModel: ModelDescriptor
    @Published var settings: AppSettings {
        didSet { if settings != oldValue { settingsChanged(from: oldValue) } }
    }

    /// No hay una respuesta generándose (los botones de repetir/copiar solo aparecen entonces).
    var generationIdle: Bool { generationTask == nil }

    /// El núcleo muestra «Sin cerebro» cuando no hay motor utilizable y no está ocupado con otra cosa.
    var displayState: CoreState {
        if coreState == .idle && !engineStatus.isReady { return .disconnected }
        return coreState
    }

    // MARK: Servicios
    let confirmation = ConfirmationCenter()
    private let claude = ClaudeCoordinator()
    private let listener = SpeechListener()
    private let speaker = SpeechSpeaker()
    private let memoryStore: SwiftDataMemoryStore
    private let conversations: ConversationRepository
    private let conversation: ConversationEngine
    private var engine: LanguageModelEngine
    private let settingsStore = SettingsStore()
    private let monitor = NWPathMonitor()

    private var generationTask: Task<Void, Never>?
    private var generationID = 0            // un Task cancelado que termina tarde no debe tocar al nuevo
    private var loadTask: Task<Void, Never>?
    private var bootstrapped = false
    private var sceneActive = true
    private var wakeTriggered = false
    private var retriedAfterWake = false
    private var currentConversationID = UUID()
    private var conversationStartedAt = Date()
    private var bannerTask: Task<Void, Never>?
    private let wakeMatcher = WakeWordMatcher()

    init(container: ModelContainer) {
        var loaded = settingsStore.load().sanitized()
        if CommandLine.arguments.contains("--uitest") {
            loaded = .default
            loaded.onboardingCompleted = CommandLine.arguments.contains("--uitest-skip-onboarding")
        }
        settings = loaded
        let initial = ModelCatalog.descriptor(id: loaded.selectedModelID ?? "") ?? ModelCatalog.all[0]
        activeModel = initial
        engine = UnavailableEngine(descriptor: initial, reason: "Aún no se ha cargado ningún modelo.")
        memoryStore = SwiftDataMemoryStore(modelContainer: container)
        conversations = ConversationRepository(modelContainer: container)
        let executor = DeviceToolExecutor(claude: claude)
        conversation = ConversationEngine(engine: engine, memory: memoryStore, executor: executor, confirmer: confirmation,
                                          config: ConversationConfig(memoryPolicy: loaded.memory, claudeMode: loaded.claude.mode))
        wireServices()
        memoryUnlocked = !loaded.requireBiometricsForMemory      // con Face ID exigido, la memoria arranca BLOQUEADA
    }

    // MARK: Arranque

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        claude.config = settings.claude
        speaker.apply(settings.voice)
        voices = SpeechSpeaker.rankedSpanishVoices(preferredLanguage: settings.recognitionLocale)
        startConnectivityMonitor()
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleMemoryWarning() }
        }

        _ = try? await conversations.prune(retention: settings.transcriptRetention)
        await reloadMemory()
        await reloadHistory()
        await activateModel(id: settings.selectedModelID ?? recommendedModelID())
        refreshWakeWord()
        // Al final: los comandos de Siri/Atajos encolados en un arranque en frío deben ver el modelo ya activado.
        IntentBridge.shared.onCommand = { [weak self] command in self?.handle(command) }
    }

    private func recommendedModelID() -> String {
        ModelRecommender.defaultModel(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            foundationAvailable: EngineProvider.isFoundationModelAvailable
        ).id
    }

    private func wireServices() {
        listener.onPartial = { [weak self] text in self?.liveTranscript = text }
        listener.onLevel = { [weak self] level in
            guard let self = self else { return }
            self.audioLevel = self.audioLevel * 0.6 + level * 0.4
        }
        listener.onFinal = { [weak self] text in self?.transcriptFinished(text) }
        listener.onWake = { [weak self] match in self?.wakeDetected(match) }
        listener.onError = { [weak self] message in self?.fail(message) }
        speaker.onStart = { [weak self] in if self?.coreState != .error { self?.coreState = .speaking } }
        speaker.onWord = { [weak self] in self?.speakPulse = Date() }
        speaker.onFinish = { [weak self] in self?.speechFinished() }
        speaker.onCloudError = { [weak self] message in self?.showBanner(message) }
        claude.onResult = { [weak self] prompt, answer in self?.claudeAnswered(prompt: prompt, answer: answer) }
        claude.onCancelled = { [weak self] in self?.showBanner("El Atajo de Claude no devolvió texto. Revisa la respuesta en la app de Claude.") }
    }

    // MARK: Modelos

    func activateModel(id: String) async {
        loadTask?.cancel()
        let descriptor = ModelCatalog.descriptor(id: id) ?? ModelCatalog.all[0]
        await engine.unload()
        activeModel = descriptor
        if settings.selectedModelID != descriptor.id { settings.selectedModelID = descriptor.id }

        if let real = EngineProvider.makeEngine(for: descriptor, cloud: settings.cloudBrain) {
            engine = real
        } else {
            var reason = "Este modelo no está disponible en esta compilación."
            if case .unavailable(let why) = EngineProvider.foundationModelsAvailability(), descriptor.isSystemModel { reason = why }
            engine = UnavailableEngine(descriptor: descriptor, reason: reason)
        }
        await conversation.setEngine(engine)
        await pushConversationConfig()

        switch await engine.availability() {
        case .ready: engineStatus = .ready
        case .unavailable(let reason): engineStatus = .unavailable(reason)
        case .needsDownload:
            engineStatus = .notLoaded
            // Un modelo ya descargado antes se recarga solo (desde la caché local, sin descargar de nuevo).
            if settingsStore.preparedModelIDs.contains(descriptor.id) { loadActiveModel() }
        }
    }

    /// Descarga (si hace falta) y carga el modelo activo. Lo dispara SIEMPRE el usuario la primera vez.
    func loadActiveModel() {
        guard !(loadTask != nil && engineStatus != .notLoaded) else { return }
        let target = engine
        engineStatus = .downloading(0)
        loadTask = Task { [weak self] in
            do {
                try await target.prepare { progress in
                    Task { @MainActor [weak self] in
                        guard let self = self, self.activeModel.id == target.descriptor.id else { return }
                        self.engineStatus = progress >= 1 ? .loading : .downloading(progress)
                    }
                }
                guard let self = self, self.activeModel.id == target.descriptor.id else { return }
                self.engineStatus = .ready
                self.settingsStore.markPrepared(target.descriptor.id)
                self.loadTask = nil
            } catch {
                // Una carga obsoleta (el usuario cambió de modelo) no debe pisar el estado del modelo vigente.
                guard let self = self, self.activeModel.id == target.descriptor.id, !Task.isCancelled else { return }
                self.engineStatus = .failed(error.localizedDescription)
                self.loadTask = nil
            }
        }
    }

    func unloadActiveModel() {
        Task {
            await engine.unload()
            if activeModel.usesLocalWeights { engineStatus = .notLoaded }
        }
    }

    /// Reconstruye el motor en la nube tras guardar/borrar la clave o cambiar de proveedor o modelo.
    func refreshCloudEngine() {
        guard activeModel.isCloud else { return }
        Task { await activateModel(id: ModelCatalog.cloudID) }
    }

    func deleteDownload(of model: ModelDescriptor) {
        guard case .mlx(let repo) = model.backend else { return }
        Task {
            if activeModel.id == model.id { await engine.unload(); engineStatus = .notLoaded }
            let removed = ModelStorage.deleteCachedModel(repo: repo)
            settingsStore.unmarkPrepared(model.id)
            showBanner(removed ? "Descarga de \(model.displayName) eliminada." : "No encontré archivos descargados de \(model.displayName).")
        }
    }

    func fit(for model: ModelDescriptor) -> ModelFit {
        ModelRecommender.fit(for: model, physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                             foundationAvailable: EngineProvider.isFoundationModelAvailable)
    }

    private func handleMemoryWarning() {
        guard activeModel.usesLocalWeights, engineStatus.isReady else { return }
        cancelGeneration()
        Task { await engine.unload() }
        engineStatus = .notLoaded
        showBanner("iOS pidió liberar memoria: descargué el modelo. Vuelve a cargarlo desde Ajustes › Modelo, o elige uno más ligero.")
    }

    private func pushConversationConfig() async {
        await conversation.updateConfig(ConversationConfig(
            memoryPolicy: settings.memory, claudeMode: settings.claude.mode, spokenOutput: settings.voice.speakResponses,
            historyCharBudget: activeModel.isCloud ? 14_000 : (activeModel.isSystemModel ? 4_500 : 6_000)
        ))
    }

    // MARK: Ajustes

    private func settingsChanged(from old: AppSettings) {
        settingsStore.save(settings)
        if settings.voice != old.voice { speaker.apply(settings.voice) }
        if settings.claude != old.claude { claude.config = settings.claude }
        if settings.cloudBrain != old.cloudBrain { refreshCloudEngine() }
        if settings.recognitionLocale != old.recognitionLocale {
            voices = SpeechSpeaker.rankedSpanishVoices(preferredLanguage: settings.recognitionLocale)
        }
        if settings.memory != old.memory || settings.claude.mode != old.claude.mode || settings.voice.speakResponses != old.voice.speakResponses {
            Task { await pushConversationConfig() }
        }
        if settings.transcriptRetention != old.transcriptRetention {
            Task { _ = try? await conversations.prune(retention: settings.transcriptRetention); await reloadHistory() }
        }
        if settings.wakeWordEnabled != old.wakeWordEnabled || settings.allowServerRecognition != old.allowServerRecognition {
            if listener.isRunning, listener.mode == .wakeWord { listener.stop(); wakeWordActive = false }
            if settings.wakeWordEnabled {
                // Pide (con explicación previa en la pantalla de ajustes) los permisos que la escucha necesita.
                Task { if await ensureVoicePermissions() { refreshWakeWord() } }
            } else {
                refreshWakeWord()
            }
        }
        if settings.requireBiometricsForMemory != old.requireBiometricsForMemory { memoryUnlocked = !settings.requireBiometricsForMemory }
    }

    // MARK: Voz

    func micTapped() {
        haptic(.light)
        switch coreState {
        case .listening:
            if listener.mode == .command { listener.finishNow() } else { stopEverything() }
        case .speaking: interrupt()
        case .thinking: cancelGeneration(); coreState = .idle
        default: Task { await startListening() }
        }
    }

    func startListening() async {
        guard await ensureVoicePermissions() else { return }
        guard engineStatus.isReady else {
            appendSystemNotice(notReadyExplanation())
            enterError()
            return
        }
        speaker.stop()
        cancelGeneration()
        if listener.isRunning { listener.stop() }
        liveTranscript = ""
        wakeTriggered = false
        beginCommandListening()
    }

    private func beginCommandListening() {
        do {
            try listener.start(mode: .command, localeID: settings.recognitionLocale, allowServerFallback: settings.allowServerRecognition)
            coreState = .listening
            wakeWordActive = false
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func ensureVoicePermissions() async -> Bool {
        if Permissions.microphone == .notDetermined { _ = await Permissions.requestMicrophone() }
        if Permissions.speech == .notDetermined { _ = await Permissions.requestSpeech() }
        permissionTick += 1
        guard Permissions.microphone == .granted, Permissions.speech == .granted else {
            fail(ListenerFailure.permissionDenied.localizedDescription)
            return false
        }
        return true
    }

    private func wakeDetected(_ match: WakeWordMatcher.Match) {
        haptic(.medium)
        wakeTriggered = true
        retriedAfterWake = false
        wakeWordActive = false
        speaker.stop()
        coreState = .listening
        liveTranscript = match.trailingCommand
    }

    private func transcriptFinished(_ rawText: String) {
        audioLevel = 0
        var text = rawText
        if wakeTriggered {
            text = wakeMatcher.match(in: rawText)?.trailingCommand ?? rawText
            wakeTriggered = false
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !retriedAfterWake {
                // Dijo solo «Viernes»: se vuelve a escuchar una vez para el comando (sin hablar encima).
                retriedAfterWake = true
                wakeTriggered = false
                beginCommandListening()
                return
            }
        }
        liveTranscript = ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            coreState = .idle
            refreshWakeWord()
        } else {
            submit(trimmed)
        }
    }

    func interrupt() {
        speaker.stop()
        cancelGeneration()
        coreState = .idle
        refreshWakeWord()
    }

    private func stopEverything() {
        listener.stop()
        speaker.stop()
        cancelGeneration()
        wakeWordActive = false
        audioLevel = 0
        liveTranscript = ""
        coreState = .idle
    }

    private func speechFinished() {
        if generationTask != nil { if coreState == .speaking { coreState = .thinking }; return }
        finishTurn()
    }

    private func finishTurn() {
        guard generationTask == nil, !speaker.isBusy, coreState != .listening, coreState != .error else { return }
        coreState = .idle
        if settings.continuousConversation, engineStatus.isReady, sceneActive {
            Task { await startListening() }
        } else {
            if !settings.wakeWordEnabled { AudioSessionController.deactivate() }      // devuelve el audio a otras apps
            refreshWakeWord()
        }
    }

    /// Escucha de la palabra «Viernes»: SOLO con la app en primer plano, ociosa y con el ajuste activado.
    func refreshWakeWord() {
        let wanted = settings.wakeWordEnabled && sceneActive && coreState == .idle && engineStatus.isReady
            && Permissions.microphone == .granted && Permissions.speech == .granted
        if wanted, !listener.isRunning {
            do {
                try listener.start(mode: .wakeWord, localeID: settings.recognitionLocale, allowServerFallback: settings.allowServerRecognition)
                wakeWordActive = true
            } catch {
                wakeWordActive = false
                showBanner(error.localizedDescription)
            }
        } else if !wanted, listener.isRunning, listener.mode == .wakeWord {
            listener.stop()
            wakeWordActive = false
        }
    }

    // MARK: Conversación

    func sendTyped() {
        let text = typedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typedDraft = ""
        submit(text)
    }

    func submit(_ text: String) {
        guard generationTask == nil else { showBanner("Estoy ocupada con la respuesta anterior."); return }
        guard engineStatus.isReady else {
            messages.append(ChatMessage(role: .user, text: text))
            appendSystemNotice(notReadyExplanation())
            enterError()
            return
        }
        if listener.isRunning { listener.stop() }
        wakeWordActive = false
        messages.append(ChatMessage(role: .user, text: text))
        streamingText = ""
        liveActions = []
        coreState = .thinking
        generationID += 1
        let id = generationID
        generationTask = Task { [weak self] in
            await self?.runGeneration(text)
            guard let self = self, self.generationID == id else { return }
            self.generationTask = nil
            self.finishTurn()
        }
    }

    private func runGeneration(_ text: String) async {
        var streamer = SentenceStreamer()
        let speak = settings.voice.speakResponses
        for await event in await conversation.send(text) {
            if Task.isCancelled { return }
            switch event {
            case .thinking:
                break
            case .toolStarted(let name):
                activeTool = name
            case .delta(let delta):
                streamingText += delta
                if speak { for sentence in streamer.feed(delta) { speaker.enqueue(sentence) } }
            case .action(let record):
                activeTool = nil
                liveActions.append(record)
            case .completed(let message):
                activeTool = nil
                if speak, let rest = streamer.flush() { speaker.enqueue(rest) }
                messages.append(message)
                streamingText = ""
                liveActions = []
                await persistConversation()
            case .failed(let reason):
                activeTool = nil
                streamingText = ""
                appendSystemNotice(reason)
                enterError()
            }
        }
    }

    func cancelGeneration() {
        generationID += 1
        generationTask?.cancel()
        generationTask = nil
        streamingText = ""
        liveActions = []
        activeTool = nil
    }

    /// Vuelve a decir en voz alta una respuesta ya escrita (botón de la conversación).
    func replay(_ text: String) {
        guard generationTask == nil, coreState == .idle || coreState == .speaking else { return }
        speaker.stop()
        speaker.enqueue(text)
    }

    private func notReadyExplanation() -> String {
        switch engineStatus {
        case .notLoaded:
            return activeModel.requiresDownload
                ? "Mi modelo local («\(activeModel.displayName)») aún no está descargado o cargado. Ve a Ajustes › Modelo y toca «Descargar y cargar» (≈\(activeModel.approxDownloadMB) MB, requiere internet solo esta vez)."
                : "El modelo no está cargado."
        case .downloading(let progress): return "Estoy descargando el modelo (\(Int(progress * 100)) %). Espera a que termine."
        case .loading: return "Estoy cargando el modelo en memoria. Un momento."
        case .unavailable(let reason), .failed(let reason): return "No puedo pensar ahora mismo: \(reason)"
        case .ready: return ""
        }
    }

    /// Mensajes del propio sistema (no del modelo): se etiquetan como «Sistema».
    func appendSystemNotice(_ text: String) {
        messages.append(ChatMessage(role: .assistant, text: text, engineName: "Sistema"))
    }

    private func claudeAnswered(prompt: String, answer: String) {
        let message = ChatMessage(role: .assistant, text: "Claude respondió (vía tu Atajo) a «\(prompt)»:\n\n\(answer)", engineName: "Claude (Atajo)")
        messages.append(message)
        Task { await conversation.append(message); await persistConversation() }
    }

    // MARK: Historial

    private func persistConversation() async {
        guard settings.transcriptRetention != .never, !messages.isEmpty else { return }
        let title = messages.first(where: { $0.role == .user })?.text.prefix(48).description ?? "Conversación"
        let snapshot = ConversationSnapshot(id: currentConversationID, title: title, startedAt: conversationStartedAt,
                                            updatedAt: Date(), messages: messages.filter { $0.engineName != "Sistema" })
        try? await conversations.save(snapshot)
        await reloadHistory()
    }

    func reloadHistory() async { history = (try? await conversations.list()) ?? [] }

    func newConversation() {
        let finished = messages.filter { $0.engineName != "Sistema" }
        stopEverything()
        messages = []
        currentConversationID = UUID()
        conversationStartedAt = Date()
        Task {
            if settings.memory.autoSuggest, settings.memory.enabled, finished.count >= 4 { await suggestMemories(from: finished) }
            await conversation.resetConversation()
        }
    }

    func resume(_ snapshot: ConversationSnapshot) {
        stopEverything()
        messages = snapshot.messages
        currentConversationID = snapshot.id
        conversationStartedAt = snapshot.startedAt
        Task { await conversation.restore(snapshot.messages) }
    }

    func deleteConversation(_ snapshot: ConversationSnapshot) {
        Task { try? await conversations.delete(id: snapshot.id); await reloadHistory() }
    }

    func deleteAllHistory() {
        Task { try? await conversations.deleteAll(); await reloadHistory() }
    }

    /// Resume una conversación guardada con el modelo local y la guarda como recuerdo (respeta la política y el filtro de datos sensibles).
    func saveSummaryToMemory(of snapshot: ConversationSnapshot) {
        guard engineStatus.isReady else { showBanner(notReadyExplanation()); return }
        busyNote = "Resumiendo…"
        Task {
            defer { busyNote = nil }
            do {
                let summary = try await ConversationSummarizer.summarize(snapshot.messages, using: engine)
                guard !summary.isEmpty else { showBanner("El modelo no produjo un resumen."); return }
                _ = try await memoryStore.remember(text: summary, kind: .summary, source: .summary, policy: settings.memory)
                await reloadMemory()
                showBanner("Resumen guardado en Memoria.")
            } catch {
                showBanner(error.localizedDescription)
            }
        }
    }

    private func suggestMemories(from finished: [ChatMessage]) async {
        guard engineStatus.isReady, let suggestions = try? await ConversationSummarizer.suggestMemories(from: finished, using: engine) else { return }
        for suggestion in suggestions {
            _ = try? await memoryStore.remember(text: suggestion.text, kind: suggestion.kind, source: .userApproved, policy: settings.memory, pending: true)
        }
        await reloadMemory()
    }

    // MARK: Memoria

    func reloadMemory() async {
        let all = (try? await memoryStore.all()) ?? []
        memoryItems = all.filter { !$0.isPending }.sorted { ($0.pinned ? 1 : 0, $0.updatedAt) > ($1.pinned ? 1 : 0, $1.updatedAt) }
        pendingMemories = all.filter(\.isPending).sorted { $0.createdAt > $1.createdAt }
        unreadableMemoryCount = await memoryStore.unreadableCount()
    }

    func addMemory(text: String, kind: MemoryKind) {
        Task {
            do { _ = try await memoryStore.remember(text: text, kind: kind, source: .userExplicit, policy: settings.memory) }
            catch { showBanner(error.localizedDescription) }
            await reloadMemory()
        }
    }

    func updateMemory(_ item: MemoryItem) {
        var edited = item
        edited.updatedAt = Date()
        Task {
            let scan = SensitiveDataRedactor.scan(edited.text)
            guard !scan.isSensitive else { showBanner(MemoryError.sensitiveContent(scan.findings).localizedDescription); return }
            try? await memoryStore.upsert(edited)
            await reloadMemory()
        }
    }

    func deleteMemory(_ item: MemoryItem) {
        Task { try? await memoryStore.delete(id: item.id); await reloadMemory() }
    }

    func approveMemory(_ item: MemoryItem) {
        var approved = item
        approved.isPending = false
        approved.updatedAt = Date()
        Task { try? await memoryStore.upsert(approved); await reloadMemory() }
    }

    func deleteAllMemory() {
        Task { try? await memoryStore.deleteAll(); await reloadMemory() }
    }

    func unlockMemory() async {
        guard settings.requireBiometricsForMemory else { memoryUnlocked = true; return }
        memoryUnlocked = await Permissions.authenticate(reason: "Ver y editar la memoria de Viernes")
    }

    /// Borra memoria, historial, ajustes y la clave de cifrado. No se puede deshacer.
    func eraseAllData() {
        stopEverything()
        Task {
            try? await memoryStore.deleteAll()
            try? await conversations.deleteAll()
            try? Vault().destroyKey()
            CloudKeyStore.deleteAll()
            settingsStore.reset()
            messages = []
            settings = .default
            await conversation.resetConversation()
            await reloadMemory()
            await reloadHistory()
            showBanner("Todos los datos locales de Viernes fueron eliminados.")
        }
    }

    // MARK: Entradas externas (Siri, enlaces)

    func handle(_ command: IntentCommand) {
        switch command {
        case .open: break
        case .listen: Task { await startListening() }
        case .ask(let text): submit(text)
        }
    }

    func handle(url: URL) {
        switch DeepLink.parse(url) {
        case .home, .unknown: break
        case .listen: Task { await startListening() }
        case .ask(let text): typedDraft = text        // un enlace externo solo precarga el texto: nada se envía sin que el usuario lo vea
        case let link: claude.handle(link)
        }
    }

    // MARK: Ciclo de vida

    func scenePhaseChanged(_ phase: ScenePhase) {
        sceneActive = phase == .active
        if phase == .active {
            permissionTick += 1
            refreshWakeWord()
        } else if phase == .inactive {
            // Alertas del sistema (permisos), Centro de control o Siri: la escena queda «inactiva» pero la app sigue viva.
            // Solo se suelta la escucha pasiva; NO se cancela la respuesta en curso.
            if listener.isRunning, listener.mode == .wakeWord { listener.stop(); wakeWordActive = false }
        } else {
            // Sin modos de fondo: el micrófono se suelta y la GPU no se usa (iOS mata apps que lanzan trabajo Metal en segundo plano).
            listener.stop()
            wakeWordActive = false
            audioLevel = 0
            speaker.stop()
            cancelGeneration()
            if coreState != .error { coreState = .idle }
        }
    }

    // MARK: Utilidades

    func showBanner(_ text: String) {
        banner = text
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    private func fail(_ message: String) {
        listener.stop()
        wakeWordActive = false
        audioLevel = 0
        showBanner(message)
        enterError()
    }

    /// El núcleo muestra el error unos segundos y vuelve a espera.
    private func enterError() {
        coreState = .error
        haptic(.error)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self?.coreState == .error { self?.coreState = .idle; self?.refreshWakeWord() }
        }
    }

    private func startConnectivityMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "viernes.connectivity"))
    }

    enum HapticKind { case light, medium, error }
    private func haptic(_ kind: HapticKind) {
        guard settings.hapticsEnabled else { return }
        switch kind {
        case .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    func previewVoice(identifier: String?) {
        speaker.preview(identifier: identifier, settings: settings.voice)
    }

    /// Muestra con la voz neuronal elegida, aunque el interruptor aún esté apagado (para probarla antes de activarla).
    func previewCloudVoice() {
        var voice = settings.voice
        var cloud = voice.elevenLabs ?? .default
        cloud.enabled = true
        voice.elevenLabs = cloud
        speaker.preview(identifier: voice.voiceIdentifier, settings: voice)
    }
}
