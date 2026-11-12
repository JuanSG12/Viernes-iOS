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

/// Lo que se envió al cerebro por voz: el texto final, lo que se entendió antes de corregirlo y la ficha de diagnóstico.
struct VoiceSubmission: Equatable {
    let text: String
    let heard: String
    let recordID: UUID
}

/// Una frase dictada que el usuario puede revisar y corregir antes de que llegue al cerebro.
struct PendingTranscript: Identifiable, Equatable {
    let id = UUID()
    var text: String
    let recordID: UUID
    /// Lo que se entendió ANTES de la corrección automática y de cualquier edición: base para aprender de las correcciones.
    let heard: String
    /// Se enviará sola al terminar la cuenta atrás; editar el texto la cancela.
    var autoSend: Bool
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
    /// Espera impuesta por el proveedor del cerebro en la nube (p. ej. «Groq pidió esperar 6 s»); nil si no hay.
    @Published var engineWaitNote: String?
    /// Lo que Viernes entendió por voz, esperando a que el usuario lo revise antes de enviarlo (ver `SpeechSettings.review`).
    @Published var pendingTranscript: PendingTranscript?
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
    /// Vista previa de borradores de correo (la herramienta compose_email espera a que el usuario decida).
    let mailDrafts = MailDraftCenter()
    /// Perfil al que pertenece este modelo: sus ajustes, su clave de cifrado, sus almacenes y sus claves de API son solo suyos.
    /// Cambiar de perfil crea un `AppModel` nuevo (ver `ProfileHost`): no queda nada del anterior en memoria.
    let profileEntry: ProfileEntry
    let profileLayout: ProfileStorageLayout
    /// Historial local de reconocimiento de voz, para diagnóstico.
    let recognition: RecognitionHistory
    /// Consumo de los proveedores en la nube de este perfil: historial cifrado, presupuesto y límites informados.
    let usage: UsageStore
    /// Historial de misiones del agente de este perfil (cifrado).
    let missionLog: MissionLog
    /// Historial de investigaciones web de este perfil (cifrado).
    let researchLog: ResearchLog
    @Published var missionStates: [MissionState] = []
    /// Métricas de los últimos turnos de voz (informe de rendimiento).
    let voiceMetrics = VoiceMetricsStore()
    /// Adjuntos del mensaje en preparación (fototeca, cámara, escáner, Archivos) con su estado real de lectura.
    let attachments = AttachmentCenter()
    /// Biblioteca de conocimiento personal (documentos, imÃ¡genes, notas): almacÃ©n y Ã­ndice APARTE de la memoria.
    let knowledge: KnowledgeEngine
    private let knowledgeStore: SwiftDataKnowledgeStore
    @Published var libraryItems: [KnowledgeItem] = []
    @Published var libraryCollections: [KnowledgeCollection] = []
    /// Resultado de la Ãºltima acciÃ³n de la biblioteca (guardado, duplicado, error), para mostrarlo.
    @Published var libraryNotice: String?
    private let claude = ClaudeCoordinator()
    /// Ejecutor de herramientas del dispositivo (también lo usa la pantalla de Permisos para el diagnóstico del calendario).
    private let tools: DeviceToolExecutor
    private let listener = SpeechListener()
    private let speaker = SpeechSpeaker()
    private let memoryStore: SwiftDataMemoryStore
    private let conversations: ConversationRepository
    private let conversation: ConversationEngine
    private var engine: LanguageModelEngine
    private let settingsStore: SettingsStore
    private let monitor = NWPathMonitor()
    private var memoryWarningObserver: NSObjectProtocol?

    private var generationTask: Task<Void, Never>?
    /// Transcripción en la nube / corrección en curso (se cancela como cualquier otra generación).
    private var transcribeTask: Task<Void, Never>?
    private var pendingTask: Task<Void, Never>?
    /// Última frase enviada por voz (para el botón «corregir» y para aprender de las correcciones).
    private var lastVoiceSubmission: VoiceSubmission?
    private var correctionBase: VoiceSubmission?
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

    /// Sin `entry`, usa el perfil heredado (los almacenamientos y las claves de siempre).
    init(container: ModelContainer, knowledgeContainer: ModelContainer,
         entry: ProfileEntry = ProfileEntry(displayName: "Principal", isLegacy: true), defaults: UserDefaults = .standard) {
        let layout = ProfileStorageLayout(entry: entry)
        let vault = Vault(layout: layout)
        profileEntry = entry
        profileLayout = layout
        let store = SettingsStore(defaults: defaults, layout: layout)
        settingsStore = store
        var loaded = store.load().sanitized()
        if CommandLine.arguments.contains("--uitest") {
            loaded = .default
            loaded.onboardingCompleted = CommandLine.arguments.contains("--uitest-skip-onboarding")
        }
        settings = loaded
        let initial = ModelCatalog.descriptor(id: loaded.selectedModelID ?? "") ?? ModelCatalog.all[0]
        activeModel = initial
        engine = UnavailableEngine(descriptor: initial, reason: "Aún no se ha cargado ningún modelo.")
        let memory = SwiftDataMemoryStore(modelContainer: container)
        memory.use(vault: vault)
        memoryStore = memory
        let repository = ConversationRepository(modelContainer: container)
        repository.use(vault: vault)
        conversations = repository
        let libraryStore = SwiftDataKnowledgeStore(modelContainer: knowledgeContainer)
        libraryStore.use(vault: vault)
        knowledgeStore = libraryStore
        recognition = RecognitionHistory(vault: vault, fileName: layout.recognitionHistoryPath)
        let usageStore = UsageStore(vault: vault, path: layout.usageHistoryPath)
        usageStore.settings = loaded.usageSettings
        usage = usageStore
        let missions = MissionLog(vault: vault, path: layout.missionsPath)
        missionLog = missions
        let research = ResearchLog(vault: vault, path: layout.researchPath)
        researchLog = research
        let library = KnowledgeEngine(store: libraryStore, embedder: LibraryEmbedder.make())
        knowledge = library
        let executor = DeviceToolExecutor(claude: claude, mailDrafts: mailDrafts, ledger: EventLedger(defaults: defaults, key: layout.createdEventsKey))
        tools = executor
        executor.contactsReadSetting = loaded.contactsRead
        executor.defaultRegion = loaded.profileSettings.region
        executor.researchLog = research
        executor.webProvider = loaded.webSettings.provider
        executor.webLanguage = loaded.profileSettings.responseLanguage
        conversation = ConversationEngine(engine: engine, memory: memory, executor: executor, confirmer: confirmation,
                                          config: ConversationConfig(memoryPolicy: loaded.memory, claudeMode: loaded.claude.mode,
                                                                     calendarReadEnabled: loaded.calendarReadEnabled,
                                                                     contactsReadEnabled: loaded.contactsReadEnabled,
                                                                     libraryEnabled: loaded.attachmentSettings.libraryOn,
                                                                     askBeforeCloudLibrary: loaded.attachmentSettings.askBeforeCloud,
                                                                     profile: loaded.profileSettings, webResearchEnabled: Self.webEnabled(loaded),
                                                                     optimizeTokens: loaded.tokenSaverEnabled),
                                          knowledge: library, missions: missions)
        wireServices()
        speaker.pronunciation = loaded.profileSettings.personality.pronunciation
        memoryUnlocked = !loaded.requireBiometricsForMemory      // con Face ID exigido, la memoria arranca BLOQUEADA
        // Enrutador de inteligencia: solo actúa si el usuario lo activó (por defecto está apagado y se usa el cerebro elegido).
        Task { [weak self] in
            await self?.conversation.setRouteProvider({ [weak self] kind in await self?.routedEngine(for: kind) })
        }
    }

    // MARK: Arranque

    /// Pide acceso completo al calendario y devuelve un informe REAL de lo que iOS permite ver (pantalla de Permisos).
    func diagnoseCalendar() async -> String {
        let report = await tools.calendarDiagnosis()
        permissionTick += 1
        return report
    }

    /// SOLO para las capturas del CI (`--uitest --uitest-demo-weather`): una conversación de EJEMPLO, marcada «Vista de prueba»,
    /// para poder revisar el diseño de la tarjeta de clima. Nunca se usa fuera de las pruebas.
    private static func qaWeatherConversation() -> [ChatMessage] {
        let card = ToolCard(kind: .weather, fields: [
            "place": "Bogotá (Cundinamarca, Colombia)", "city": "Bogotá", "temp": "16", "feels": "15",
            "condition": "Parcialmente nublado", "symbol": "cloud.sun.fill", "humidity": "72", "wind": "8", "rain": "20",
            "tmax": "20", "tmin": "12", "tomorrowMax": "19", "tomorrowMin": "11", "tomorrowRain": "40"
        ])
        let record = ActionRecord(tool: "get_weather", summary: "Clima en Bogotá", outcome: .executed("Datos de ejemplo de la vista de prueba."), card: card)
        return [
            ChatMessage(role: .user, text: "¿Cuál es el clima en Bogotá hoy?"),
            ChatMessage(role: .assistant, text: "En Bogotá hoy se espera una temperatura entre 12 y 20 grados, con cielo parcialmente nublado y probabilidad de lluvia del 20 por ciento.",
                        actions: [record], engineName: "Vista de prueba")
        ]
    }

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        if CommandLine.arguments.contains("--uitest"), CommandLine.arguments.contains("--uitest-demo-weather") {
            messages = Self.qaWeatherConversation()
        }
        if CommandLine.arguments.contains("--uitest"), CommandLine.arguments.contains("--uitest-demo-attachments") {
            await seedQAAttachments()
        }
        // Los errores técnicos del motor van al registro local, nunca a la conversación.
        await conversation.setDiagnostics { Diagnostics.shared.log($0) }
        await conversation.recoverMissions()
        await reloadMissions()
        claude.config = settings.claude
        speaker.apply(settings.voice)
        voices = SpeechSpeaker.rankedSpanishVoices(preferredLanguage: settings.recognitionLocale)
        startConnectivityMonitor()
        memoryWarningObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleMemoryWarning() }
        }

        recognition.load(persist: shouldKeepRecognitionHistory)
        _ = try? await conversations.prune(retention: settings.transcriptRetention)
        await purgeExpiredMemories()
        await reloadMemory()
        await reloadHistory()
        await startLibrary()
        // Los documentos de ejemplo se siembran SOLO en el perfil principal: así las pruebas de UI pueden comprobar que otro perfil no los ve.
        if CommandLine.arguments.contains("--uitest"), CommandLine.arguments.contains("--uitest-demo-library"), profileEntry.isLegacy { await seedQALibrary() }
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
        listener.onFinal = { [weak self] outcome in self?.transcriptFinished(outcome) }
        listener.onWake = { [weak self] match in self?.wakeDetected(match) }
        listener.onError = { [weak self] message in self?.fail(message) }
        listener.onDiagnostic = { [weak self] record in self?.recognition.add(record) }
        listener.onInterruptionEnded = { [weak self] in self?.refreshWakeWord() }
        speaker.onStart = { [weak self] in if self?.coreState != .error { self?.coreState = .speaking } }
        speaker.onWord = { [weak self] in self?.speakPulse = Date() }
        speaker.onFinish = { [weak self] in self?.speechFinished() }
        speaker.onCloudError = { [weak self] message in self?.showBanner(message) }
        speaker.onTurnMetrics = { [weak self] metrics in self?.voiceMetrics.add(metrics) }
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

        if let real = EngineProvider.makeEngine(for: descriptor, cloud: settings.cloudBrain, usage: usageHooks) {
            engine = real
            // Si el proveedor pide esperar (límite del plan gratuito), la pantalla lo dice en vez de parecer colgada.
            if let reporting = real as? EngineStatusReporting {
                reporting.onStatus = { [weak self] text in Task { @MainActor in self?.engineWaitNote = text } }
            }
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
            // Nube: cada petición cuenta contra los tokens por minuto del plan gratuito (y una orden suele hacer dos peticiones),
            // así que el historial enviado se mantiene moderado.
            historyCharBudget: activeModel.isCloud ? 7_000 : (activeModel.isSystemModel ? 4_500 : 6_000),
            calendarReadEnabled: settings.calendarReadEnabled, contactsReadEnabled: settings.contactsReadEnabled,
            libraryEnabled: settings.attachmentSettings.libraryOn, askBeforeCloudLibrary: settings.attachmentSettings.askBeforeCloud,
            profile: settings.profileSettings, webResearchEnabled: Self.webEnabled(settings),
            optimizeTokens: settings.tokenSaverEnabled
        ))
    }

    /// La investigación web solo se ofrece con el interruptor encendido Y la clave del buscador guardada en el Llavero del perfil.
    static func webEnabled(_ settings: AppSettings) -> Bool {
        settings.webSettings.enabled && CloudKeyStore.hasKey(providerID: settings.webSettings.provider.keyProviderID)
    }

    /// Tras guardar o borrar la clave del buscador: vuelve a decidir si las herramientas web se ofrecen.
    func refreshWebResearch() { Task { await pushConversationConfig() } }

    // MARK: Ajustes

    private func settingsChanged(from old: AppSettings) {
        settingsStore.save(settings)
        if settings.voice != old.voice { speaker.apply(settings.voice) }
        if settings.claude != old.claude { claude.config = settings.claude }
        if settings.contactsRead != old.contactsRead { tools.contactsReadSetting = settings.contactsRead }
        if settings.usage != old.usage { usage.settings = settings.usageSettings }
        if settings.profile != old.profile { tools.defaultRegion = settings.profileSettings.region; tools.webLanguage = settings.profileSettings.responseLanguage }
        if settings.web != old.web { tools.webProvider = settings.webSettings.provider; Task { await pushConversationConfig() } }
        if settings.cloudBrain != old.cloudBrain { refreshCloudEngine() }
        if settings.tokenSaver != old.tokenSaver { Task { await pushConversationConfig() } }
        if settings.recognitionLocale != old.recognitionLocale {
            voices = SpeechSpeaker.rankedSpanishVoices(preferredLanguage: settings.recognitionLocale)
        }
        if settings.memory != old.memory || settings.claude.mode != old.claude.mode || settings.voice.speakResponses != old.voice.speakResponses
            || settings.calendarReadEnabled != old.calendarReadEnabled || settings.contactsReadEnabled != old.contactsReadEnabled
            || settings.attachments != old.attachments || settings.profile != old.profile {
            Task { await pushConversationConfig() }
        }
        if settings.profile != old.profile { speaker.pronunciation = settings.profileSettings.personality.pronunciation }
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
        if settings.speechSettings.keepHistory != old.speechSettings.keepHistory || settings.transcriptRetention != old.transcriptRetention {
            recognition.setPersist(shouldKeepRecognitionHistory)
        }
    }

    /// El historial de reconocimiento solo se guarda en disco si el usuario lo permite y no eligió conservar «nada».
    private var shouldKeepRecognitionHistory: Bool {
        settings.speechSettings.keepHistory && settings.transcriptRetention != .never
    }

    // MARK: Voz

    func micTapped() {
        haptic(.light)
        switch coreState {
        case .listening:
            if listener.mode == .command { listener.finishNow() } else { stopEverything() }
        case .speaking: interruptAndListen()
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
        if pendingTranscript != nil { discardPending() }        // volver a pulsar el micrófono = repetir la frase
        liveTranscript = ""
        wakeTriggered = false
        beginCommandListening()
    }

    /// Ajustes de dictado que el escucha necesita ANTES de abrir el micrófono. El audio solo se guarda para la nube en el modo de
    /// pulsar para hablar, y solo con la transcripción en la nube activada, consentida y con clave de Groq.
    private func configureListener(forWake: Bool) {
        let speech = settings.speechSettings
        listener.contextualStrings = speech.contextualStrings()
        listener.endSilenceSeconds = speech.endSilenceSeconds
        listener.preferBuiltInMic = speech.preferBuiltInMic
        listener.captureAudioForCloud = !forWake && speech.cloudTranscription && speech.cloudConsentAt != nil && CloudTranscriber.hasKey()
    }

    private func beginCommandListening() {
        configureListener(forWake: false)
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

    private func transcriptFinished(_ outcome: ListenerOutcome) {
        audioLevel = 0
        var text = outcome.text
        if wakeTriggered {
            text = wakeMatcher.match(in: outcome.text)?.trailingCommand ?? outcome.text
            wakeTriggered = false
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !retriedAfterWake {
                // Dijo solo «Viernes»: se vuelve a escuchar una vez para el comando (sin hablar encima).
                retriedAfterWake = true
                wakeTriggered = false
                discardAudio(outcome.audioURL)
                beginCommandListening()
                return
            }
        }
        liveTranscript = ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            discardAudio(outcome.audioURL)
            recognition.add(outcome.record)           // las frases vacías también sirven para diagnosticar la captura
            coreState = .idle
            refreshWakeWord()
            return
        }
        coreState = .thinking
        transcribeTask?.cancel()
        transcribeTask = Task { [weak self] in
            await self?.finalizeTranscript(text: trimmed, outcome: outcome)
        }
    }

    private func discardAudio(_ url: URL?) {
        if let url = url { try? FileManager.default.removeItem(at: url) }
    }

    /// Frase ya dicha → (transcripción en la nube, si está activada) → corrección automática → revisión → cerebro.
    private func finalizeTranscript(text original: String, outcome: ListenerOutcome) async {
        var text = original
        var record = outcome.record
        let speech = settings.speechSettings

        if let audio = outcome.audioURL {
            // El audio solo sale del teléfono con la transcripción en la nube activada y CONSENTIDA. Si algo de eso falta, se borra.
            if speech.cloudTranscription, speech.cloudConsentAt != nil, CloudTranscriber.hasKey() {
                coreState = .thinking
                busyNote = "Transcribiendo con Groq…"
                let result = await CloudTranscriber.transcribe(fileURL: audio, terms: speech.contextualStrings())
                busyNote = nil
                if Task.isCancelled { return }
                switch result {
                case .success(let cloud):
                    record.cloudText = cloud.text
                    record.cloudSeconds = cloud.seconds
                    text = cloud.text
                case .failure(let failure):
                    record.cloudError = failure.message
                    showBanner("\(failure.message) Uso la transcripción del iPhone.")
                }
            } else {
                discardAudio(audio)
            }
        }

        var shown = text
        if speech.autoCorrect {
            let fixed = TranscriptCorrector.apply(text, glossary: speech.glossary, learned: speech.learned)
            if fixed.text != text {
                record.corrected = fixed.text
                shown = fixed.text
                Diagnostics.shared.log("voz: corrección automática → \(fixed.changes.joined(separator: "; "))")
            }
        }
        recognition.add(record)

        switch speech.review {
        case .off:
            lastVoiceSubmission = VoiceSubmission(text: shown, heard: text, recordID: record.id)
            submit(shown)
        case .brief, .always:
            coreState = .idle
            wakeWordActive = false
            let pending = PendingTranscript(text: shown, recordID: record.id, heard: text, autoSend: speech.review == .brief)
            pendingTranscript = pending
            if pending.autoSend { schedulePendingAutoSend(pending.id) }
        }
    }

    // MARK: Revisión y corrección de lo dictado

    static let reviewSeconds: Double = 2.5

    private func schedulePendingAutoSend(_ id: UUID) {
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.reviewSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self = self, self.pendingTranscript?.id == id, self.pendingTranscript?.autoSend == true else { return }
            self.confirmPending()
        }
    }

    /// El usuario tocó «Enviar» (o terminó la cuenta atrás sin tocar nada).
    func confirmPending() {
        guard let pending = pendingTranscript else { return }
        pendingTask?.cancel()
        pendingTranscript = nil
        let text = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { refreshWakeWord(); return }
        learnFromEdit(heard: pending.heard, edited: text, recordID: pending.recordID)
        lastVoiceSubmission = VoiceSubmission(text: text, heard: pending.heard, recordID: pending.recordID)
        submit(text)
    }

    /// El usuario tocó el texto para corregirlo: se cancela el envío automático.
    func editPending(_ text: String) {
        guard var pending = pendingTranscript else { return }
        pending.text = text
        pending.autoSend = false
        pendingTranscript = pending
        pendingTask?.cancel()
    }

    func discardPending() {
        pendingTask?.cancel()
        pendingTranscript = nil
        refreshWakeWord()
    }

    /// Aprende de lo que el usuario corrigió (palabras pequeñas y claras) y lo apunta en el historial de diagnóstico.
    private func learnFromEdit(heard: String, edited: String, recordID: UUID) {
        guard edited != heard else { return }
        recognition.update(recordID) { $0.edited = edited }
        guard settings.speechSettings.autoCorrect else { return }
        let found = TranscriptDiff.corrections(heard: heard, edited: edited)
        guard !found.isEmpty else { return }
        var speech = settings.speechSettings
        speech.learned = TranscriptDiff.merge(found, into: speech.learned)
        settings.speech = speech
        showBanner("Aprendí: " + found.map { "«\($0.heard)» → «\($0.meant)»" }.joined(separator: ", ") + ". Puedes quitarlo en Escucha › Nombres y términos.")
    }

    /// Botón «corregir» de la última frase enviada: la vuelve a poner en el cuadro de texto para editarla y reenviarla.
    func correctLastMessage() {
        guard generationTask == nil, let last = messages.last(where: { $0.role == .user }) else { return }
        if let voice = lastVoiceSubmission, voice.text == last.text { correctionBase = voice } else { correctionBase = nil }
        typedDraft = last.text
    }

    /// Hay una frase enviada por voz que se puede corregir (el botón del lápiz solo aparece en ella).
    var lastVoiceMessageID: UUID? {
        guard let voice = lastVoiceSubmission, let last = messages.last(where: { $0.role == .user }), last.text == voice.text else { return nil }
        return last.id
    }

    /// Voto del usuario en la pantalla de diagnóstico: qué transcripción fue la buena (para comparar sin suponer).
    func vote(_ vote: TranscriptVote?, for recordID: UUID) {
        recognition.update(recordID) { $0.vote = vote }
    }

    func interrupt() {
        speaker.stop()
        cancelGeneration()
        coreState = .idle
        refreshWakeWord()
    }

    /// Tocar mientras Viernes habla: la corta al instante (y con ella la respuesta que siguiera generándose) y abre el micrófono
    /// para la nueva instrucción. Lo que quedara por decir de la respuesta anterior no se reproduce.
    func interruptAndListen() {
        speaker.stop()
        cancelGeneration()
        coreState = .idle
        Task { await startListening() }
    }

    private func stopEverything() {
        listener.stop()
        speaker.stop()
        cancelGeneration()
        pendingTask?.cancel()
        pendingTranscript = nil
        wakeWordActive = false
        audioLevel = 0
        liveTranscript = ""
        coreState = .idle
    }

    private func speechFinished() {
        if voiceBenchRunning { return }          // el banco de medición dice frases de prueba: no debe disparar la conversación manos libres
        if generationTask != nil { if coreState == .speaking { coreState = .thinking }; return }
        finishTurn()
    }

    private func finishTurn() {
        guard generationTask == nil, !speaker.isBusy, coreState != .listening, coreState != .error else { return }
        coreState = .idle
        if pendingTranscript != nil { return }          // el usuario está revisando lo que dijo
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
            && Permissions.microphone == .granted && Permissions.speech == .granted && pendingTranscript == nil
        if wanted, !listener.isRunning {
            configureListener(forWake: true)
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
        guard !text.isEmpty || attachments.hasReady else { return }
        typedDraft = ""
        if !text.isEmpty, let base = correctionBase {
            // Era la corrección de una frase dictada: se aprende lo que cambió y esta pasa a ser la frase vigente.
            correctionBase = nil
            learnFromEdit(heard: base.heard, edited: text, recordID: base.recordID)
            lastVoiceSubmission = VoiceSubmission(text: text, heard: base.heard, recordID: base.recordID)
        }
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
        if attachments.isProcessing {
            showBanner("Todavía estoy leyendo los adjuntos. Espera un momento.")
            return
        }
        let drafts = attachments.readyDrafts
        if listener.isRunning { listener.stop() }
        wakeWordActive = false
        let shown = (text.isEmpty && !drafts.isEmpty) ? "Resume y explica lo que adjunté." : text
        // Con adjuntos, el mensaje se añade a la conversación solo después de decidir a qué cerebro van (y de que el usuario lo autorice).
        if drafts.isEmpty { messages.append(ChatMessage(role: .user, text: shown)) }
        streamingText = ""
        liveActions = []
        coreState = .thinking
        generationID += 1
        let id = generationID
        generationTask = Task { [weak self] in
            await self?.runGeneration(shown, drafts: drafts)
            guard let self = self, self.generationID == id else { return }
            self.generationTask = nil
            self.engineWaitNote = nil
            self.finishTurn()
        }
    }

    // MARK: Adjuntos

    private struct PreparedAttachments {
        let bundle: AttachmentBundle
        let engine: LanguageModelEngine?
        let budget: Int
    }

    /// Perfil de capacidades del cerebro activo (qué puede leer de verdad).
    var currentBrainProfile: BrainProfile {
        CapabilityMatrix.chatProfile(descriptor: activeModel, cloud: settings.cloudBrain, overrides: settings.attachmentSettings.visionModels)
    }

    private func routingContext(current: BrainProfile) -> RoutingContext {
        RoutingContext(current: current,
                       providersWithKey: Set(CloudProviders.all.filter { CloudKeyStore.hasKey(providerID: $0.id) }.map { $0.id }),
                       cloud: settings.cloudBrain, visionOverrides: settings.attachmentSettings.visionModels,
                       online: isOnline, askBeforeCloud: settings.attachmentSettings.askBeforeCloud, canOCRLocally: true)
    }

    /// Decide a qué cerebro van los adjuntos (con permiso si algo sale del teléfono), lee con OCR local si se eligió,
    /// y arma el paquete que recibe el motor. `nil` = no se envía (el usuario no lo autorizó o no hay forma de leerlo).
    private func prepareAttachments(_ text: String, drafts: [DraftAttachment]) async -> PreparedAttachments? {
        let current = currentBrainProfile
        let summary = AttachmentSummary(imageNames: drafts.filter { $0.kind == .image }.map { $0.name },
                                        documentNames: drafts.filter { $0.kind != .image }.map { $0.name })
        let context = routingContext(current: current)
        var chosen: RoutePlan?
        switch AttachmentRouter.decide(summary, context: context) {
        case .send(let plan):
            chosen = plan
        case .askConsent(let consent):
            if await confirmation.confirm(ConfirmationRequest(tool: "attachments", title: consent.title, detail: consent.detail)) {
                chosen = consent.plan
            } else {
                showBanner("No envié los adjuntos. Siguen en tu mensaje por si cambias de idea.")
            }
        case .cannot(let block):
            chosen = await resolveBlockedRoute(block, context: context)
        }
        guard let plan = chosen, !Task.isCancelled else {
            if typedDraft.isEmpty { typedDraft = text }          // no se pierde lo que escribió o dijo
            return nil
        }
        Diagnostics.shared.log("adjuntos: \(summary.imageCount) imagen(es), \(summary.documentCount) documento(s) → \(plan.brain.id); sale del teléfono: \(plan.leavesDevice ? "sí" : "no")")

        var documents = drafts.compactMap { $0.document }
        var notes = plan.notes
        let images = plan.sendImages ? drafts.compactMap { $0.image } : []
        if plan.ocrImages {
            var readAny = false
            for draft in drafts where draft.kind == .image {
                guard let jpeg = draft.ocrSource else { continue }
                let recognized = await Task.detached(priority: .userInitiated) { () -> String in
                    (try? TextRecognizer.recognize(jpeg: jpeg)) ?? ""
                }.value
                if recognized.isEmpty {
                    notes.append("No encontré texto legible en «\(draft.name)».")
                } else {
                    readAny = true
                    documents.append(ExtractedDocument(name: draft.name, kind: .image, sections: [DocumentSection(text: recognized)],
                                                       recognizedByOCR: true, warnings: ["Texto reconocido por OCR en el teléfono: puede tener errores y no describe la imagen."]))
                }
            }
            if !readAny && documents.isEmpty {
                appendSystemNotice("No encontré texto legible en las imágenes, así que no hay nada que pueda leer sin un modelo con visión. Puedes usar Gemini o el modelo de visión de Groq (Ajustes › Adjuntos y visión).")
                if typedDraft.isEmpty { typedDraft = text }
                return nil
            }
        }
        let bundle = AttachmentBundle(refs: drafts.compactMap { $0.ref }, documents: documents, images: images, notes: notes)
        return PreparedAttachments(bundle: bundle, engine: makeOverrideEngine(for: plan.brain, current: current),
                                   budget: plan.brain.capabilities.excerptBudgetChars)
    }

    /// El cerebro actual no puede leer lo adjuntado: se explica y se OFRECE cada alternativa; el usuario autoriza o no (nunca se elige por él).
    private func resolveBlockedRoute(_ block: RouteBlock, context: RoutingContext) async -> RoutePlan? {
        for alternative in block.alternatives {
            switch alternative.action {
            case .useBrain, .localOCR:
                let approved = await confirmation.confirm(ConfirmationRequest(
                    tool: "attachments", title: alternative.label, detail: block.reason + "\n\n" + alternative.explanation))
                if approved, let plan = AttachmentRouter.plan(for: alternative, context: context) { return plan }
                if Task.isCancelled { return nil }
            case .removeImages, .configure:
                continue
            }
        }
        let others = block.alternatives.compactMap { alternative -> String? in
            switch alternative.action {
            case .configure, .removeImages: return alternative.label + ": " + alternative.explanation
            default: return nil
            }
        }
        appendSystemNotice(([block.reason + " No envié nada."] + others).joined(separator: " "))
        return nil
    }

    /// Última decisión del enrutador (para mostrarla en Ajustes › Enrutador).
    @Published var lastRouteNote: String?

    private func cloudDescriptor(providerID: String, model: String) -> ModelDescriptor {
        let preset = CloudProviders.preset(id: providerID)
        return ModelDescriptor(id: "route.\(providerID)", displayName: "\(preset.displayName) · \(model)", backend: .cloud, approxDownloadMB: 0,
                               minDeviceRAMGB: 0, license: "Términos del proveedor elegido", spanishQuality: 5,
                               notes: "Cerebro en la nube elegido por el enrutador para este mensaje.")
    }

    /// Elige el cerebro para una petición según su tipo, SOLO entre los proveedores con clave guardada que el usuario autorizó y que
    /// no están en pausa ni sin presupuesto. `nil` = usar el cerebro activo (enrutador apagado, o nada elegible, o va el modelo local).
    /// Con «cambiar si falla» encendido, los siguientes proveedores autorizados quedan de reserva (nunca con archivos o imágenes).
    @MainActor
    func routedEngine(for kind: RequestClass) -> LanguageModelEngine? {
        let routing = settings.routingSettings
        guard routing.enabled else { lastRouteNote = nil; return nil }
        let policies = settings.usageSettings
        var configured = Set<String>()
        var authorized = Set<String>()
        var healthy = Set<String>()
        for preset in CloudProviders.all {
            guard CloudKeyStore.hasKey(providerID: preset.id) else { continue }
            configured.insert(preset.id)
            if policies.policy(for: preset.id).authorized { authorized.insert(preset.id) }
            guard ProviderHealth.breaker.allows(preset.id) else { continue }
            if case .block = usage.gate(providerID: preset.id, model: routing.model(for: preset.id, tier: .light, selected: settings.cloudBrain)) { continue }
            healthy.insert(preset.id)
        }
        let inputs = RouteInputs(configured: configured, authorized: authorized, healthy: healthy,
                                 localReady: !activeModel.isCloud && engineStatus.isReady, selected: settings.cloudBrain)
        guard let decision = IntelligenceRouter.decide(kind: kind, settings: routing, inputs: inputs) else { lastRouteNote = nil; return nil }
        lastRouteNote = decision.reason
        guard case .cloud = decision.target else { return nil }
        var candidates: [FailoverEngine.Candidate] = []
        var targets: [RouteTarget] = [decision.target]
        targets.append(contentsOf: decision.fallbacks)
        for target in targets {
            guard case .cloud(let provider, let chosenModel) = target else { continue }
            let engine = EngineProvider.makeCloudEngine(descriptor: cloudDescriptor(providerID: provider, model: chosenModel),
                                                        settings: CloudBrainSettings(providerID: provider, model: chosenModel), usage: usageHooks)
            candidates.append(FailoverEngine.Candidate(engine: engine, label: CloudProviders.preset(id: provider).displayName))
        }
        guard !candidates.isEmpty else { return nil }
        let failover = FailoverEngine(candidates: candidates)
        failover.onStatus = { [weak self] text in Task { @MainActor in self?.engineWaitNote = text } }
        return failover
    }

    /// Cerebro en la nube distinto del activo, creado SOLO para este mensaje (el activo no cambia).
    private func makeOverrideEngine(for brain: BrainProfile, current: BrainProfile) -> LanguageModelEngine? {
        guard brain.id != current.id, brain.isCloud, let provider = brain.providerID, let model = brain.model else { return nil }
        let descriptor = ModelDescriptor(id: brain.id, displayName: brain.displayName, backend: .cloud, approxDownloadMB: 0, minDeviceRAMGB: 0,
                                         license: "Términos del proveedor elegido", spanishQuality: 5,
                                         notes: "Cerebro en la nube usado solo para este mensaje.")
        let engine = EngineProvider.makeCloudEngine(descriptor: descriptor, settings: CloudBrainSettings(providerID: provider, model: model), usage: usageHooks)
        (engine as? EngineStatusReporting)?.onStatus = { [weak self] text in Task { @MainActor in self?.engineWaitNote = text } }
        return engine
    }

    private func runGeneration(_ text: String, drafts: [DraftAttachment] = []) async {
        var bundle: AttachmentBundle?
        var override: LanguageModelEngine?
        var budget: Int?
        if !drafts.isEmpty {
            guard let prepared = await prepareAttachments(text, drafts: drafts) else { return }
            bundle = prepared.bundle
            override = prepared.engine
            budget = prepared.budget
            messages.append(ChatMessage(role: .user, text: text, attachments: prepared.bundle.refs))
            attachments.markSent()
        }
        let speak = settings.voice.speakResponses
        // Un turno de habla por respuesta: el texto se envía a la voz según se genera, sin esperar al final.
        if speak { speaker.beginTurn() }
        for await event in await conversation.send(text, attachments: bundle, engineOverride: override, excerptBudget: budget) {
            if Task.isCancelled { return }
            switch event {
            case .thinking:
                break
            case .toolStarted(let name):
                activeTool = name
            case .delta(let delta):
                streamingText += delta
                if speak { speaker.feed(delta) }
            case .action(let record):
                activeTool = nil
                liveActions.append(record)
            case .completed(let message):
                activeTool = nil
                if speak { speaker.endTurn() }
                messages.append(message)
                streamingText = ""
                liveActions = []
                await persistConversation()
            case .failed(let reason):
                activeTool = nil
                streamingText = ""
                if speak { speaker.endTurn(flush: false) }
                appendSystemNotice(reason)
                enterError()
            }
        }
    }

    func cancelGeneration() {
        generationID += 1
        speaker.stop()                      // si había un turno de habla abierto, se corta con la generación
        generationTask?.cancel()
        generationTask = nil
        transcribeTask?.cancel()
        transcribeTask = nil
        busyNote = nil
        engineWaitNote = nil
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
        attachments.purgeAll()
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
        attachments.purgeAll()           // el contenido de los archivos no se guarda en el historial
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

    func addMemory(text: String, kind: MemoryKind, project: String? = nil, people: [String] = [], expiresAt: Date? = nil) {
        Task {
            do { _ = try await memoryStore.remember(text: text, kind: kind, source: .userExplicit, policy: settings.memory,
                                                    project: project, people: people, expiresAt: expiresAt) }
            catch { showBanner(error.localizedDescription) }
            await reloadMemory()
        }
    }

    /// Borra varios recuerdos a la vez (todo lo de un proyecto o una persona, o lo caducado).
    func deleteMemories(_ items: [MemoryItem]) {
        Task {
            for item in items { try? await memoryStore.delete(id: item.id) }
            await reloadMemory()
        }
    }

    /// Lo caducado se borra al abrir la app: un recuerdo con fecha de caducidad vencida deja de existir.
    func purgeExpiredMemories() async {
        let all = (try? await memoryStore.all()) ?? []
        for item in MemoryExpiry.expired(all) { try? await memoryStore.delete(id: item.id) }
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
            try? await knowledge.deleteAll()
            try? Vault(layout: profileLayout).destroyKey()
            recognition.clear()
            tools.clearLedger()
            usage.clear()
            await missionLog.deleteAll()
            await researchLog.clear()
            missionStates = []
            CloudKeyStore.deleteAll()
            settingsStore.reset()
            attachments.purgeAll()
            messages = []
            settings = .default
            await conversation.resetConversation()
            await reloadLibrary()
            await reloadMemory()
            await reloadHistory()
            showBanner("Todos los datos locales de Viernes fueron eliminados.")
        }
    }

    // MARK: Misiones

    func reloadMissions() async { missionStates = await conversation.missionHistory() }

    /// Repite SOLO los pasos que no terminaron de una misión interrumpida o cancelada (con los mismos permisos y validaciones).
    func resumeMission(_ id: UUID) {
        guard let saved = missionStates.first(where: { $0.id == id }) else { return }
        Task {
            _ = await conversation.resumeMission(saved)
            await reloadMissions()
        }
    }

    func clearMissions() {
        Task {
            await missionLog.deleteAll()
            await reloadMissions()
        }
    }

    // MARK: Banco de medición de voz

    @Published var voiceBenchRuns: [VoiceBenchRun] = []
    @Published var voiceBenchStatus: String?
    @Published private(set) var voiceBenchRunning = false
    private var voiceBenchTask: Task<Void, Never>?

    /// Dice las mismas frases fijas por cada modo elegido y anota los tiempos reales de ESTE iPhone. Los modos en la nube gastan
    /// caracteres del plan de ElevenLabs. No toca la conversación ni la memoria.
    func startVoiceBench(_ backends: [VoiceBenchBackend]) {
        guard !voiceBenchRunning, !backends.isEmpty else { return }
        voiceBenchRunning = true
        voiceBenchRuns = []
        voiceBenchStatus = "Preparando…"
        stopEverything()
        let base = settings.voice
        voiceBenchTask = Task { await self.runVoiceBench(backends, base: base) }
    }

    func cancelVoiceBench() {
        voiceBenchTask?.cancel()
        speaker.stop()
    }

    private func runVoiceBench(_ backends: [VoiceBenchBackend], base: VoiceSettings) async {
        defer {
            speaker.stop()
            speaker.apply(settings.voice)
            voiceBenchRunning = false
            coreState = .idle
        }
        let phrases = VoiceBenchPhrases.all
        for backend in backends {
            guard let voice = backend.settings(base: base) else {
                voiceBenchStatus = "«\(backend.label)» no está disponible: falta elegir una voz o guardar la clave de ElevenLabs."
                continue
            }
            speaker.apply(voice)
            for (index, phrase) in phrases.enumerated() {
                if Task.isCancelled { voiceBenchStatus = "Medición cancelada."; return }
                voiceBenchStatus = "\(backend.label): frase \(index + 1) de \(phrases.count)…"
                let before = voiceMetrics.turns.count
                let memoryBefore = ResidentMemory.megabytes()
                speaker.enqueue(phrase)
                var waited = 0
                while voiceMetrics.turns.count == before, waited < 1_200, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waited += 1
                }
                guard voiceMetrics.turns.count > before, let metrics = voiceMetrics.turns.last else {
                    speaker.stop()
                    voiceBenchStatus = "\(backend.label): la frase \(index + 1) no terminó en 120 s y se omitió."
                    continue
                }
                let memoryAfter = ResidentMemory.megabytes()
                let delta = (memoryBefore != nil && memoryAfter != nil) ? memoryAfter! - memoryBefore! : nil
                voiceBenchRuns.append(VoiceBenchRun(backend: metrics.backend, phraseIndex: index, metrics: metrics, memoryDeltaMB: delta))
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        voiceBenchStatus = voiceBenchRuns.isEmpty ? "No se pudo medir nada." : "Medición terminada: \(voiceBenchRuns.count) frases."
    }

    // MARK: Perfil

    /// Apaga lo que este modelo tenía en marcha (escucha, voz, generación, red, adjuntos temporales) para que `ProfileHost` pueda
    /// sustituirlo por el de otro perfil. Después de esto el modelo no debe volver a usarse.
    func shutdown() {
        stopEverything()
        loadTask?.cancel()
        monitor.cancel()
        if let observer = memoryWarningObserver { NotificationCenter.default.removeObserver(observer) }
        memoryWarningObserver = nil
        attachments.purgeAll()
        let engineToUnload = engine
        Task { await engineToUnload.unload() }
    }

    /// Reúne los datos de ESTE perfil (ajustes, recuerdos, biblioteca y conversaciones; nunca claves) para exportarlos.
    func makeProfileBundle(includeVectors: Bool) async throws -> ProfileBundle {
        let snapshots = (try? await conversations.list()) ?? []
        let exported = snapshots.map {
            ExportedConversation(id: $0.id, title: $0.title, startedAt: $0.startedAt, updatedAt: $0.updatedAt, messages: $0.messages)
        }
        return try await ProfileBundleBuilder.make(profileName: profileEntry.displayName, createdAt: profileEntry.createdAt, settings: settings,
                                                   memory: memoryStore, knowledge: knowledgeStore, conversations: exported,
                                                   includeVectors: includeVectors)
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

    /// Lo que los motores en la nube necesitan del consumo de este perfil (ver `UsageHooks`).
    private var usageHooks: UsageHooks {
        let store = usage
        return UsageHooks(
            gate: { provider, model in store.gate(providerID: provider, model: model) },
            record: { provider, model, tokens in store.record(providerID: provider, model: model, usage: tokens) },
            limits: { provider, snapshot in store.setLimits(provider, snapshot) },
            warn: { [weak self] text in Task { @MainActor in self?.showUsageWarning(text) } })
    }

    private var lastUsageWarning = ""

    /// El aviso de consumo se muestra una vez por mensaje distinto, no en cada petición.
    private func showUsageWarning(_ text: String) {
        guard text != lastUsageWarning else { return }
        lastUsageWarning = text
        showBanner(text)
    }

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
