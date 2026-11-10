import Foundation

public enum ConversationEvent: Sendable {
    case thinking
    case delta(String)                       // texto visible (sin etiquetas de herramienta ni <think>)
    case toolStarted(String)                 // una herramienta VA a ejecutarse (antes de confirmar/ejecutar); anima la UI
    case action(ActionRecord)                // acción realmente intentada, con su resultado
    case completed(ChatMessage)
    case failed(String)
}

public struct ConversationConfig: Sendable {
    public var memoryPolicy: MemoryPolicy
    public var claudeMode: ClaudeMode
    public var spokenOutput: Bool
    public var maxToolRounds: Int
    public var maxCallsPerRound: Int
    public var historyCharBudget: Int
    public var memoryContextLimit: Int
    public var timeZone: TimeZone
    /// Permisos de lectura que el usuario activó EXPRESAMENTE en Privacidad (apagados por defecto).
    public var calendarReadEnabled: Bool
    public var contactsReadEnabled: Bool

    /// 4 rondas = hasta 3 rondas de herramientas encadenadas (consultar → actuar → …) y una respuesta final.
    public init(memoryPolicy: MemoryPolicy = .default, claudeMode: ClaudeMode = .disabled, spokenOutput: Bool = true,
                maxToolRounds: Int = 4, maxCallsPerRound: Int = 3, historyCharBudget: Int = 6_000,
                memoryContextLimit: Int = 5, timeZone: TimeZone = .current,
                calendarReadEnabled: Bool = false, contactsReadEnabled: Bool = false) {
        self.calendarReadEnabled = calendarReadEnabled
        self.contactsReadEnabled = contactsReadEnabled
        self.memoryPolicy = memoryPolicy
        self.claudeMode = claudeMode
        self.spokenOutput = spokenOutput
        self.maxToolRounds = maxToolRounds
        self.maxCallsPerRound = maxCallsPerRound
        self.historyCharBudget = historyCharBudget
        self.memoryContextLimit = memoryContextLimit
        self.timeZone = timeZone
    }
}

/// Orquesta una conversación: memoria → prompt → motor local → herramientas validadas y confirmadas → respuesta.
/// Principio: lo que cuenta como "acción realizada" es el `ActionRecord`, no lo que el modelo diga.
public actor ConversationEngine {
    private var engine: LanguageModelEngine
    private let memory: MemoryStore
    private let executor: ToolExecutor?
    private let confirmer: ConfirmationProvider?
    private let clock: @Sendable () -> Date
    public private(set) var config: ConversationConfig
    private var history: [ChatMessage] = []
    private var activeDocuments: [ExtractedDocument] = []
    /// Avisos de posible inyección por documento (calculados una sola vez, al adjuntarlo).
    private var documentNotes: [String: String] = [:]
    private let maxStoredMessages = 60
    /// Destino de los diagnósticos técnicos (la app los guarda en un registro local). Nunca se muestran en la conversación.
    private var diagnosticsSink: (@Sendable (String) -> Void)?

    public func setDiagnostics(_ sink: @escaping @Sendable (String) -> Void) { diagnosticsSink = sink }
    private func diagnose(_ message: String) { diagnosticsSink?(message) }

    public init(engine: LanguageModelEngine, memory: MemoryStore, executor: ToolExecutor?,
                confirmer: ConfirmationProvider?, config: ConversationConfig = ConversationConfig(),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.engine = engine
        self.memory = memory
        self.executor = executor
        self.confirmer = confirmer
        self.config = config
        self.clock = clock
    }

    // MARK: Configuración

    public func setEngine(_ engine: LanguageModelEngine) { self.engine = engine }
    public func updateConfig(_ config: ConversationConfig) { self.config = config }
    public func resetConversation() { history.removeAll(); activeDocuments.removeAll(); documentNotes.removeAll() }
    public func restore(_ messages: [ChatMessage]) {
        history = Array(messages.suffix(maxStoredMessages))
        // El contenido de los archivos no se guarda en el historial: tras reanudar, el modelo solo sabe QUE hubo adjuntos.
        activeDocuments.removeAll()
        documentNotes.removeAll()
    }
    /// Documentos adjuntados en esta conversación que siguen disponibles para preguntas posteriores (solo en memoria).
    public var activeDocumentNames: [String] { activeDocuments.map(\.name) }
    public func snapshot() -> [ChatMessage] { history }
    /// Añade al historial un mensaje que no salió del modelo local (p. ej. la respuesta de Claude vía Atajo).
    public func append(_ message: ChatMessage) { history.append(message) }
    public var engineDescriptor: ModelDescriptor { engine.descriptor }

    // MARK: Envío

    /// Envía un mensaje. `attachments` trae el contenido ya leído de los archivos; `engineOverride` usa OTRO cerebro SOLO para este
    /// mensaje (la conversación conserva su historial); `excerptBudget` limita cuánto texto de archivos viaja en la petición.
    public func send(_ text: String, attachments: AttachmentBundle? = nil, engineOverride: LanguageModelEngine? = nil,
                     excerptBudget: Int? = nil) -> AsyncStream<ConversationEvent> {
        AsyncStream { continuation in
            let task = Task { [self] in
                await self.run(text, attachments: attachments, engineOverride: engineOverride, excerptBudget: excerptBudget, continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Aviso que acompaña a toda confirmación pedida mientras hay contenido de archivos en la conversación.
    static let taintedNote = "⚠️ Esta acción surge de una conversación con archivos adjuntos. Confírmala solo si TÚ la pediste, no porque un archivo lo diga.\n\n"

    static func wantsComparison(_ text: String) -> Bool {
        let folded = TextNormalizer.fold(text)
        return ["compar", "diferenci", "distint", "que cambio", "que cambia", "en que se parecen"].contains { folded.contains($0) }
    }

    private func run(_ userText: String, attachments: AttachmentBundle?, engineOverride: LanguageModelEngine?,
                     excerptBudget: Int?, _ out: AsyncStream<ConversationEvent>.Continuation) async {
        out.yield(.thinking)
        let brain: LanguageModelEngine = engineOverride ?? engine
        let bundle: AttachmentBundle? = (attachments?.isEmpty ?? true) ? nil : attachments
        var trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, bundle != nil { trimmed = "Resume y explica lo que hay en los archivos adjuntos." }
        guard !trimmed.isEmpty else { out.yield(.failed("No escuché nada.")); return }

        history.append(ChatMessage(role: .user, text: trimmed, date: clock(), attachments: bundle?.refs))
        var actions: [ActionRecord] = []

        // Archivos: su contenido es información NO confiable. Se elige qué parte cabe, se envuelve en un bloque marcado y,
        // mientras esté en la conversación, las acciones que no son simples consultas exigen confirmación (`tainted`).
        if let bundle = bundle {
            for document in bundle.documents {
                activeDocuments.append(document)
                if let note = InjectionScanner.note(for: document) {
                    documentNotes[document.name] = note
                    diagnose("un adjunto contiene texto que parece dar órdenes al asistente")
                }
            }
            if activeDocuments.count > AttachmentLimits.maxActiveDocuments {
                activeDocuments.removeFirst(activeDocuments.count - AttachmentLimits.maxActiveDocuments)
            }
        }
        let asksToCompare = Self.wantsComparison(trimmed)
        var candidateDocuments: [ExtractedDocument] = []
        if asksToCompare, activeDocuments.count >= 2 {
            candidateDocuments = Array(activeDocuments.suffix(2))
        } else if let bundle = bundle, !bundle.documents.isEmpty {
            candidateDocuments = bundle.documents
        } else if ExcerptSelector.isRelevant(query: trimmed, documents: activeDocuments) {
            candidateDocuments = activeDocuments
        }
        let images = bundle?.images ?? []
        var untrustedBlock: String?
        if !candidateDocuments.isEmpty || !images.isEmpty {
            let selection = candidateDocuments.isEmpty
                ? ExcerptSelection.empty
                : ExcerptSelector.select(documents: candidateDocuments, query: trimmed, budget: excerptBudget ?? 5_000)
            var notes = bundle?.notes ?? []
            for document in candidateDocuments { if let note = documentNotes[document.name] { notes.append(note) } }
            let comparison = (asksToCompare && candidateDocuments.count >= 2) ? DocumentComparator.summary(of: candidateDocuments) : nil
            untrustedBlock = UntrustedContent.block(selection: selection, documents: candidateDocuments, notes: notes,
                                                    comparison: comparison, imageNames: images.map { $0.name })
        }
        let tainted = untrustedBlock != nil
        var firstUserSuffix = ""

        // 1) Orden explícita de memoria ("recuerda que…"): el usuario lo pidió con palabras.
        if let command = MemoryCommand.parse(trimmed) {
            let record = await handleMemoryCommand(command)
            actions.append(record)
            out.yield(.action(record))
            firstUserSuffix = "\n\n" + Persona.wrapResults([Self.describe(record)])
        }

        // 2) Contexto de memoria local para este mensaje.
        var contextMemories: [MemoryItem] = []
        if config.memoryPolicy.enabled, let all = try? await memory.all() {
            contextMemories = MemoryRetriever.context(query: trimmed, items: all, limit: config.memoryContextLimit, now: clock())
        }

        var baseSystem = Persona.systemPrompt(PersonaContext(
            now: clock(), timeZone: config.timeZone, engine: brain.descriptor, memories: contextMemories,
            tools: availableTools(), claudeMode: config.claudeMode, spokenOutput: config.spokenOutput
        ))
        if tainted { baseSystem += "\n\n" + UntrustedContent.systemRules }
        var system = baseSystem

        // El bloque de archivos ocupa parte de la petición: se recorta el historial para no pasarse del límite del proveedor.
        let historyBudget = max(1_500, config.historyCharBudget - (untrustedBlock?.count ?? 0))
        var turns = Self.turns(from: Array(history.dropLast()), budget: historyBudget)
        var userContent = trimmed + firstUserSuffix
        if let block = untrustedBlock { userContent = block + "\n\nPetición del usuario: " + userContent }
        turns.append(ChatTurn(role: .user, content: userContent, images: images))

        var displayText = ""
        var emptyRetries = 0
        /// Llamadas ya ejecutadas en este mensaje: una llamada «rescatada» de un texto no se repite si el modelo la copia de vuelta.
        var executedCalls = Set<String>()
        let maxRounds = max(1, config.maxToolRounds)
        var round = -1
        while true {
            round += 1
            if round >= maxRounds { break }
            if Task.isCancelled { return }
            let filter = StreamingTagFilter(specs: [
                .init(open: Persona.toolOpen, close: Persona.toolClose, capture: true),
                .init(open: "<think>", close: "</think>", capture: false),
                .init(open: Persona.resultOpen, close: Persona.resultClose, capture: false)
            ])
            let leakGuard = LeakGuard()
            var roundVisible = ""
            var rawRound = ""          // salida cruda del modelo (para rescatar llamadas en otro formato y para diagnosticar)

            do {
                let request = GenerationRequest(system: system, turns: turns)
                for try await delta in brain.generate(request) {
                    if Task.isCancelled { return }
                    if rawRound.utf8.count < 20_000 { rawRound += delta }
                    var piece = leakGuard.feed(filter.feed(delta))
                    if roundVisible.isEmpty { piece = String(piece.drop(while: { $0.isWhitespace })) }
                    if !piece.isEmpty {
                        if roundVisible.isEmpty, !displayText.isEmpty { out.yield(.delta("\n\n")); displayText += "\n\n" }
                        roundVisible += piece
                        displayText += piece
                        out.yield(.delta(piece))
                    }
                }
                var tail = leakGuard.feed(filter.finish()) + leakGuard.finish()
                if roundVisible.isEmpty { tail = String(tail.drop(while: { $0.isWhitespace })) }
                if !tail.isEmpty { roundVisible += tail; displayText += tail; out.yield(.delta(tail)) }
            } catch is CancellationError {
                return
            } catch {
                diagnose("motor: \(error.localizedDescription)")
                out.yield(.failed(error.localizedDescription))
                return
            }

            var toolContents = filter.captured.filter { $0.open == Persona.toolOpen }.map(\.content)
            if toolContents.isEmpty && filter.unterminatedBlocks == 0 {
                // Sin etiquetas <tool>: el modelo pudo escribir la llamada en su formato nativo (JSON suelto, <function=…>).
                let rescued = ToolCallRecovery.extract(from: rawRound).filter { !executedCalls.contains($0) }
                if !rescued.isEmpty {
                    diagnose("llamada recuperada de un formato no estándar: \(String(rescued[0].prefix(120)))")
                    toolContents = rescued
                } else if roundVisible.isEmpty && emptyRetries < Self.maxEmptyRetries {
                    // Respuesta vacía (solo razonamiento, o el proveedor cortó): se vuelve a pedir en vez de mostrar un error.
                    emptyRetries += 1
                    diagnose("respuesta vacía del modelo (reintento \(emptyRetries)); salida cruda: «\(String(rawRound.prefix(160)))»")
                    system = baseSystem + "\n\n" + Persona.emptyReplyNote
                    round -= 1
                    continue
                }
            }
            system = baseSystem
            if toolContents.isEmpty && filter.unterminatedBlocks == 0 { break }

            let executedBlocks = Array(toolContents.prefix(config.maxCallsPerRound))
            var records: [ActionRecord] = await executeRound(executedBlocks, tainted: tainted, out)
            if Task.isCancelled { return }
            for content in executedBlocks {
                if let call = ToolCallParser.parse(content) { executedCalls.insert(ToolCallRecovery.canonicalJSON(call)) }
            }
            if toolContents.isEmpty && filter.unterminatedBlocks > 0 && roundVisible.isEmpty {
                diagnose("respuesta del modelo truncada dentro de una llamada de herramienta")
                records.append(ActionRecord(tool: "desconocida", summary: "Respuesta truncada",
                                            outcome: .failed("La respuesta del modelo se cortó."), date: clock(), showToUser: false))
            }
            for record in records { out.yield(.action(record)) }
            actions.append(contentsOf: records)

            if records.isEmpty || round == maxRounds - 1 { break }

            // Siguiente ronda: el modelo ve su propia llamada y el resultado REAL.
            let rawAssistant = ([roundVisible] + executedBlocks.map { "\(Persona.toolOpen)\($0)\(Persona.toolClose)" })
                .filter { !$0.isEmpty }.joined(separator: "\n")
            turns.append(ChatTurn(role: .assistant, content: rawAssistant))
            turns.append(ChatTurn(role: .user, content: Persona.wrapResults(records.map(Self.describe))))
        }

        var finalText = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if finalText.isEmpty {
            if actions.isEmpty {
                diagnose("sin texto ni acciones tras \(emptyRetries) reintento(s)")
                out.yield(.failed(Self.emptyReplyFailure))
                return
            }
            if !actions.contains(where: { $0.isVisible }) {
                // Todo lo intentado quedó oculto (p. ej. datos que faltaban): nunca se deja una burbuja en blanco.
                finalText = Self.couldNotCompleteText
                out.yield(.delta(finalText))
            }
        }
        let message = ChatMessage(role: .assistant, text: finalText, date: clock(), actions: actions, engineName: brain.descriptor.displayName)
        history.append(message)
        if history.count > maxStoredMessages { history.removeFirst(history.count - maxStoredMessages) }
        out.yield(.completed(message))
    }

    // MARK: Respuestas vacías

    /// Veces que se vuelve a pedir una respuesta vacía antes de rendirse (sirve también tras ejecutar una herramienta).
    static let maxEmptyRetries = 2
    static let emptyReplyFailure = "El modelo no devolvió texto tras reintentarlo. Prueba de nuevo o cambia de modelo."
    static let couldNotCompleteText = "No logré completar eso con los datos que tengo. Dime qué quieres hacer con un poco más de detalle (qué, cuándo, con quién) y lo intento de nuevo."

    // MARK: Ejecución de una ronda de herramientas

    /// Fallos que pueden ser pasajeros (red): se reintenta UNA vez. Un «ciudad no encontrada» no se reintenta.
    static func isTransientFailure(_ reason: String) -> Bool {
        let folded = reason.lowercased()
        return ["sin conexión", "no respondió", "tiempo de espera", "timed out", "tardó demasiado"].contains { folded.contains($0) }
    }

    /// Herramientas que se pueden lanzar a la vez sin riesgo: seguras, sin estado en el motor y con ejecutor del dispositivo.
    private func isParallelSafe(_ call: ToolCall) -> Bool {
        guard let definition = ToolCatalog.definition(named: call.name) else { return false }
        return definition.risk == .safe && !ToolCatalog.memoryToolNames.contains(call.name)
    }

    /// Ejecuta las llamadas de una ronda. Las seguras e independientes corren en paralelo; las sensibles (con confirmación)
    /// y las de memoria van una a una y en orden. Devuelve los registros en el orden original de las llamadas.
    private func executeRound(_ blocks: [String], tainted: Bool, _ out: AsyncStream<ConversationEvent>.Continuation) async -> [ActionRecord] {
        var parsed: [(index: Int, call: ToolCall)] = []
        var slots: [ActionRecord?] = Array(repeating: nil, count: blocks.count)
        for (index, block) in blocks.enumerated() {
            if let call = ToolCallParser.parse(block) {
                parsed.append((index, call))
            } else {
                diagnose("llamada de herramienta malformada: \(String(block.prefix(120)))")
                slots[index] = ActionRecord(tool: "desconocida", summary: "Llamada de herramienta malformada",
                                            outcome: .failed("El formato de la llamada no era válido."), date: clock(), showToUser: false)
            }
        }

        let parallel = parsed.filter { isParallelSafe($0.call) }
        if parallel.count > 1 {
            for item in parallel { out.yield(.toolStarted(item.call.name)) }
            await withTaskGroup(of: (Int, ActionRecord).self) { group in
                for item in parallel {
                    group.addTask { [self] in (item.index, await self.performWithRetry(item.call, tainted: tainted)) }
                }
                for await (index, record) in group { slots[index] = record }
            }
        }
        let parallelIndexes = Set(parallel.count > 1 ? parallel.map { $0.index } : [])
        for item in parsed where !parallelIndexes.contains(item.index) {
            if Task.isCancelled { break }
            out.yield(.toolStarted(item.call.name))
            slots[item.index] = await performWithRetry(item.call, tainted: tainted)
        }
        return slots.compactMap { $0 }
    }

    private func performWithRetry(_ call: ToolCall, tainted: Bool) async -> ActionRecord {
        var record = await perform(call, tainted: tainted)
        if case .failed(let reason) = record.outcome, Self.isTransientFailure(reason), isParallelSafe(call), !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !Task.isCancelled { record = await perform(call, tainted: tainted) }
        }
        return record
    }

    // MARK: Herramientas

    func availableTools() -> [ToolDefinition] {
        ToolCatalog.all.filter { tool in
            if tool.name == "ask_claude" { return config.claudeMode != .disabled }
            if ToolCatalog.calendarReadTools.contains(tool.name) { return config.calendarReadEnabled && executor != nil }
            if tool.name == "find_contact" { return config.contactsReadEnabled && executor != nil }
            if ToolCatalog.memoryToolNames.contains(tool.name) { return config.memoryPolicy.enabled }
            return executor != nil
        }
    }

    private func perform(_ call: ToolCall, tainted: Bool = false) async -> ActionRecord {
        var validated: ToolCall
        do {
            validated = try ToolValidator.validate(call, timeZone: config.timeZone)
        } catch {
            // Error técnico que el modelo puede corregir solo: queda en diagnósticos y no se enseña al usuario.
            diagnose("validación de \(call.name): \(error.localizedDescription)")
            return ActionRecord(tool: call.name, summary: call.name, outcome: .failed(error.localizedDescription), date: clock(), showToUser: false)
        }
        guard availableTools().contains(where: { $0.name == validated.name }) else {
            diagnose("herramienta no disponible: \(validated.name)")
            let reason: String
            switch validated.name {
            case "list_events", "update_event", "delete_event":
                reason = "El usuario no ha activado la lectura del calendario (sin ella no puedo consultar ni modificar eventos). Dile que puede activarla en Configuración › Privacidad › «Permitir que Viernes lea mi calendario»."
            case "find_contact": reason = "El usuario no ha activado la lectura de contactos. Dile que puede activarla en Configuración › Privacidad › «Permitir que Viernes lea mis contactos»."
            case "ask_claude": reason = "La integración con Claude está desactivada. Dile que puede activarla en Configuración › Claude."
            default: reason = "Esa herramienta no está disponible o está desactivada."
            }
            return ActionRecord(tool: validated.name, summary: validated.name, outcome: .failed(reason), date: clock(), showToUser: false)
        }
        let definition = ToolCatalog.definition(named: validated.name)!
        var summary = Self.summary(for: validated, timeZone: config.timeZone)

        // Editar o borrar algo que YA existe: primero se localiza el objeto real (identificador de EventKit verificado). Si hay
        // ambigüedad o no existe, no se ejecuta ni se pide confirmar nada; y la confirmación muestra el objeto exacto.
        if ToolCatalog.resolvedTools.contains(validated.name), let executor = executor,
           let resolution = await executor.resolve(validated) {
            switch resolution {
            case .blocked(let reason, let askUser):
                diagnose("\(validated.name) no continuó: \(String(reason.prefix(160)))")
                return ActionRecord(tool: validated.name, summary: summary, outcome: .failed(reason), date: clock(), showToUser: !askUser)
            case .ready(let pinned, let detail):
                validated = pinned
                summary = detail
            }
        }

        // Con contenido de archivos en la conversación, cualquier acción que no sea una consulta sin efectos exige confirmación:
        // un archivo no puede autorizar nada (ni siquiera crear un recordatorio o preparar un borrador).
        if definition.risk.requiresConfirmation || (tainted && definition.risk != .safe) {
            guard let confirmer = confirmer else {
                return ActionRecord(tool: validated.name, summary: summary, outcome: .failed("No hay forma de pedir confirmación."), date: clock())
            }
            let approved = await confirmer.confirm(ConfirmationRequest(
                tool: validated.name, title: Self.confirmationTitle(validated.name),
                detail: (tainted ? Self.taintedNote : "") + summary))
            guard approved else {
                return ActionRecord(tool: validated.name, summary: summary, outcome: .declined, date: clock())
            }
        }

        let outcome: ToolOutcome
        if ToolCatalog.memoryToolNames.contains(validated.name) {
            outcome = await performMemoryTool(validated)
        } else if let executor = executor {
            outcome = await executor.execute(validated)
        } else {
            outcome = .failure("Herramienta no disponible.")
        }
        switch outcome {
        case .success(let text):
            return ActionRecord(tool: validated.name, summary: summary, outcome: .executed(text), date: clock())
        case .card(let text, let card):
            return ActionRecord(tool: validated.name, summary: summary, outcome: .executed(text), date: clock(), card: card)
        case .failure(let reason):
            diagnose("fallo de \(validated.name): \(String(reason.prefix(200)))")
            return ActionRecord(tool: validated.name, summary: summary, outcome: .failed(reason), date: clock())
        }
    }

    private func performMemoryTool(_ call: ToolCall) async -> ToolOutcome {
        switch call.name {
        case "save_memory":
            let text = call.args["text"] ?? ""
            let kind = call.args["kind"].flatMap(MemoryKind.init(rawValue:)) ?? MemoryCommand.classify(text)
            do {
                let item = try await memory.remember(text: text, kind: kind, source: .userExplicit, policy: config.memoryPolicy, now: clock())
                return .success("Guardado en memoria local: «\(item.text)»")
            } catch { return .failure(error.localizedDescription) }
        case "search_memory":
            do {
                let hits = try await memory.search(call.args["query"] ?? "", limit: 5, now: clock())
                if hits.isEmpty { return .success("No hay recuerdos que coincidan.") }
                return .success(hits.map { "• \($0.item.text)" }.joined(separator: "\n"))
            } catch { return .failure(error.localizedDescription) }
        case "forget_memory":
            return await forget(query: call.args["query"] ?? "", alreadyConfirmed: true)
        default:
            return .failure("Herramienta de memoria desconocida.")
        }
    }

    private func forget(query: String, alreadyConfirmed: Bool) async -> ToolOutcome {
        guard let best = try? await memory.search(query, limit: 1, now: clock()).first else {
            return .failure("No encontré ningún recuerdo que coincida con «\(query)».")
        }
        if !alreadyConfirmed {
            guard let confirmer = confirmer,
                  await confirmer.confirm(ConfirmationRequest(tool: "forget_memory", title: "Olvidar recuerdo", detail: best.item.text))
            else { return .failure("Eliminación cancelada.") }
        }
        do {
            try await memory.delete(id: best.item.id)
            return .success("Eliminado de la memoria: «\(best.item.text)»")
        } catch { return .failure(error.localizedDescription) }
    }

    private func handleMemoryCommand(_ command: MemoryCommand) async -> ActionRecord {
        switch command {
        case .remember(let text):
            let kind = MemoryCommand.classify(text)
            do {
                let item = try await memory.remember(text: text, kind: kind, source: .userExplicit, policy: config.memoryPolicy, now: clock())
                return ActionRecord(tool: "save_memory", summary: "Recordar: \(text)", outcome: .executed("Guardado en memoria local: «\(item.text)»"), date: clock())
            } catch {
                return ActionRecord(tool: "save_memory", summary: "Recordar: \(text)", outcome: .failed(error.localizedDescription), date: clock())
            }
        case .forget(let query):
            let outcome = await forget(query: query, alreadyConfirmed: false)
            switch outcome {
            case .success(let text), .card(let text, _):
                return ActionRecord(tool: "forget_memory", summary: "Olvidar: \(query)", outcome: .executed(text), date: clock())
            case .failure(let reason):
                return ActionRecord(tool: "forget_memory", summary: "Olvidar: \(query)", outcome: .failed(reason), date: clock())
            }
        }
    }

    // MARK: Utilidades puras (también usadas en pruebas)

    static func describe(_ record: ActionRecord) -> String {
        switch record.outcome {
        case .executed(let text): return "- \(record.tool): ÉXITO. \(text)"
        case .declined: return "- \(record.tool): RECHAZADA por el usuario. No se ejecutó."
        case .failed(let reason): return "- \(record.tool): FALLÓ. \(reason) No se ejecutó."
        }
    }

    static func confirmationTitle(_ tool: String) -> String {
        switch tool {
        case "open_url": return "Abrir enlace"
        case "create_reminder": return "Crear recordatorio"
        case "complete_reminder": return "Completar recordatorio"
        case "create_event": return "Crear evento"
        case "update_event": return "Modificar evento"
        case "delete_event": return "Eliminar evento"
        case "run_shortcut": return "Ejecutar Atajo"
        case "ask_claude": return "Enviar a Claude"
        case "list_events": return "Leer tu calendario"
        case "find_contact": return "Buscar en tus contactos"
        case "compose_email": return "Preparar borrador de correo"
        case "compose_message": return "Preparar borrador de mensaje"
        case "call_phone": return "Abrir el marcador"
        case "save_memory": return "Guardar en memoria"
        case "forget_memory": return "Olvidar recuerdo"
        default: return "Confirmar acción"
        }
    }

    /// «2026-11-06T15:45» → «vie 6 nov, 15:45» (si no se puede interpretar, se deja tal cual).
    static func friendlyDate(_ iso: String?, timeZone: TimeZone) -> String {
        guard let iso = iso else { return "" }
        guard let date = DateParsing.parse(iso, timeZone: timeZone) else { return iso }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_CO")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE d MMM, HH:mm"
        return formatter.string(from: date)
    }

    static func summary(for call: ToolCall, timeZone: TimeZone = .current) -> String {
        let a = call.args
        switch call.name {
        case "update_event", "delete_event":
            var pieces: [String] = []
            if let title = a["title"] { pieces.append("«\(title)»") }
            if let date = a["date"] { pieces.append("del día \(date)") }
            if let time = a["time"] { pieces.append("de las \(time)") }
            if a["just_created"] == "true" { pieces.append("el que acabo de crear") }
            let target = pieces.joined(separator: " ")
            let verb = call.name == "delete_event" ? "Eliminar evento" : "Modificar evento"
            return verb + (target.isEmpty ? "" : " " + target)
        case "open_app": return "Abrir \(a["app"] ?? "app")"
        case "open_url": return a["url"] ?? ""
        case "create_reminder": return "«\(a["title"] ?? "")»" + (a["due"].map { " para \($0)" } ?? "")
        case "complete_reminder": return "Completar «\(a["title"] ?? "")»"
        case "create_event": return "«\(a["title"] ?? "")» el \(Self.friendlyDate(a["start"], timeZone: timeZone))" + (a["duration_minutes"].map { " (\($0) min)" } ?? "")
        case "run_shortcut": return "Atajo «\(a["name"] ?? "")»" + (a["input"].map { " con entrada: \($0)" } ?? "")
        case "ask_claude": return "Pregunta: \(a["prompt"] ?? "")"
        case "save_memory": return a["text"] ?? ""
        case "forget_memory", "search_memory": return a["query"] ?? ""
        case "device_info": return "Consultar \(a["what"] ?? "all")"
        case "list_reminders": return "Listar recordatorios"
        case "get_weather": return "Clima en \(a["city"] ?? "")"
        case "list_events": return "Eventos de \(a["date"] ?? "hoy")" + (a["days"].map { " (\($0) días)" } ?? "")
        case "find_contact": return "Buscar «\(a["name"] ?? "")»"
        case "compose_email":
            return "Correo" + (a["to"].map { " para \($0)" } ?? "") + (a["subject"].map { " — \($0)" } ?? "") + ": «\(String((a["body"] ?? "").prefix(160)))»"
        case "compose_message":
            return "\(a["app"] == "whatsapp" ? "WhatsApp" : "Mensaje")" + (a["to"].map { " para \($0)" } ?? "") + ": «\(String((a["body"] ?? "").prefix(160)))»"
        case "call_phone": return "Llamar al \(a["number"] ?? "")"
        default: return call.name
        }
    }

    /// Convierte el historial en turnos alternados user/assistant dentro de un presupuesto de caracteres.
    /// Gemma y otros exigen alternancia estricta, así que se fusionan turnos consecutivos del mismo rol.
    static func turns(from messages: [ChatMessage], budget: Int) -> [ChatTurn] {
        var collected: [ChatTurn] = []
        var used = 0
        for message in messages.reversed() where message.role != .tool {
            let role: ChatTurn.Role = message.role == .user ? .user : .assistant
            var text = message.text
            if let attachments = message.attachments, !attachments.isEmpty {
                // El contenido de los archivos no se repite en los turnos anteriores: solo se recuerda que hubo adjuntos.
                text += " [adjuntó: " + attachments.map { UntrustedContent.safeLabel($0.name, limit: 50) }.joined(separator: ", ") + "]"
            }
            let cost = text.count
            if used + cost > budget, !collected.isEmpty { break }
            used += cost
            collected.append(ChatTurn(role: role, content: text))
        }
        collected.reverse()

        var merged: [ChatTurn] = []
        for turn in collected {
            if let last = merged.last, last.role == turn.role {
                merged[merged.count - 1].content += "\n" + turn.content
            } else {
                merged.append(turn)
            }
        }
        // La conversación debe empezar con el usuario.
        while let first = merged.first, first.role == .assistant { merged.removeFirst() }
        // Y terminar con el asistente, porque a continuación va el turno del usuario actual.
        // Un turno de usuario huérfano (envío anterior que falló) se descarta: no se inventa respuesta.
        if let last = merged.last, last.role == .user { merged.removeLast() }
        return merged
    }
}
