import Foundation

public enum ConversationEvent: Sendable {
    case thinking
    case delta(String)                       // texto visible (sin etiquetas de herramienta ni <think>)
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

    public init(memoryPolicy: MemoryPolicy = .default, claudeMode: ClaudeMode = .disabled, spokenOutput: Bool = true,
                maxToolRounds: Int = 3, maxCallsPerRound: Int = 3, historyCharBudget: Int = 6_000,
                memoryContextLimit: Int = 5, timeZone: TimeZone = .current) {
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
    private let maxStoredMessages = 60

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
    public func resetConversation() { history.removeAll() }
    public func restore(_ messages: [ChatMessage]) { history = Array(messages.suffix(maxStoredMessages)) }
    public func snapshot() -> [ChatMessage] { history }
    /// Añade al historial un mensaje que no salió del modelo local (p. ej. la respuesta de Claude vía Atajo).
    public func append(_ message: ChatMessage) { history.append(message) }
    public var engineDescriptor: ModelDescriptor { engine.descriptor }

    // MARK: Envío

    public func send(_ text: String) -> AsyncStream<ConversationEvent> {
        AsyncStream { continuation in
            let task = Task { [self] in
                await self.run(text, continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ userText: String, _ out: AsyncStream<ConversationEvent>.Continuation) async {
        out.yield(.thinking)
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { out.yield(.failed("No escuché nada.")); return }

        history.append(ChatMessage(role: .user, text: trimmed, date: clock()))
        var actions: [ActionRecord] = []
        var firstUserSuffix = ""

        // 1) Orden explícita de memoria ("recuerda que…"): el usuario lo pidió con palabras.
        if let command = MemoryCommand.parse(trimmed) {
            let record = await handleMemoryCommand(command)
            actions.append(record)
            out.yield(.action(record))
            firstUserSuffix = "\n\n" + Persona.resultMarker + "\n" + Self.describe(record)
        }

        // 2) Contexto de memoria local para este mensaje.
        var contextMemories: [MemoryItem] = []
        if config.memoryPolicy.enabled, let all = try? await memory.all() {
            contextMemories = MemoryRetriever.context(query: trimmed, items: all, limit: config.memoryContextLimit, now: clock())
        }

        let system = Persona.systemPrompt(PersonaContext(
            now: clock(), timeZone: config.timeZone, engine: engine.descriptor, memories: contextMemories,
            tools: availableTools(), claudeMode: config.claudeMode, spokenOutput: config.spokenOutput
        ))

        var turns = Self.turns(from: Array(history.dropLast()), budget: config.historyCharBudget)
        turns.append(ChatTurn(role: .user, content: trimmed + firstUserSuffix))

        var displayText = ""
        for round in 0..<max(1, config.maxToolRounds) {
            if Task.isCancelled { return }
            let filter = StreamingTagFilter(specs: [
                .init(open: Persona.toolOpen, close: Persona.toolClose, capture: true),
                .init(open: "<think>", close: "</think>", capture: false)
            ])
            var roundVisible = ""

            do {
                let request = GenerationRequest(system: system, turns: turns)
                for try await delta in engine.generate(request) {
                    if Task.isCancelled { return }
                    var piece = filter.feed(delta)
                    if roundVisible.isEmpty { piece = String(piece.drop(while: { $0.isWhitespace })) }
                    if !piece.isEmpty {
                        if roundVisible.isEmpty, !displayText.isEmpty { out.yield(.delta("\n\n")); displayText += "\n\n" }
                        roundVisible += piece
                        displayText += piece
                        out.yield(.delta(piece))
                    }
                }
                var tail = filter.finish()
                if roundVisible.isEmpty { tail = String(tail.drop(while: { $0.isWhitespace })) }
                if !tail.isEmpty { roundVisible += tail; displayText += tail; out.yield(.delta(tail)) }
            } catch is CancellationError {
                return
            } catch {
                out.yield(.failed(error.localizedDescription))
                return
            }

            let toolBlocks = filter.captured.filter { $0.open == Persona.toolOpen }
            if toolBlocks.isEmpty && filter.unterminatedBlocks == 0 { break }

            var records: [ActionRecord] = []
            for block in toolBlocks.prefix(config.maxCallsPerRound) {
                guard let call = ToolCallParser.parse(block.content) else {
                    records.append(ActionRecord(tool: "desconocida", summary: "Llamada de herramienta malformada",
                                                outcome: .failed("El formato de la llamada no era válido."), date: clock()))
                    continue
                }
                records.append(await perform(call))
            }
            if toolBlocks.isEmpty && filter.unterminatedBlocks > 0 && roundVisible.isEmpty {
                records.append(ActionRecord(tool: "desconocida", summary: "Respuesta truncada",
                                            outcome: .failed("La respuesta del modelo se cortó."), date: clock()))
            }
            for record in records { out.yield(.action(record)) }
            actions.append(contentsOf: records)

            if records.isEmpty || round == config.maxToolRounds - 1 { break }

            // Siguiente ronda: el modelo ve su propia llamada y el resultado REAL.
            let rawAssistant = ([roundVisible] + toolBlocks.map { "\(Persona.toolOpen)\($0.content)\(Persona.toolClose)" })
                .filter { !$0.isEmpty }.joined(separator: "\n")
            turns.append(ChatTurn(role: .assistant, content: rawAssistant))
            turns.append(ChatTurn(role: .user, content: Persona.resultMarker + "\n" + records.map(Self.describe).joined(separator: "\n")))
        }

        let finalText = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if finalText.isEmpty && actions.isEmpty {
            out.yield(.failed("El modelo no devolvió texto. Prueba de nuevo o cambia de modelo."))
            return
        }
        let message = ChatMessage(role: .assistant, text: finalText, date: clock(), actions: actions, engineName: engine.descriptor.displayName)
        history.append(message)
        if history.count > maxStoredMessages { history.removeFirst(history.count - maxStoredMessages) }
        out.yield(.completed(message))
    }

    // MARK: Herramientas

    func availableTools() -> [ToolDefinition] {
        ToolCatalog.all.filter { tool in
            if tool.name == "ask_claude" { return config.claudeMode != .disabled }
            if ToolCatalog.memoryToolNames.contains(tool.name) { return config.memoryPolicy.enabled }
            return executor != nil
        }
    }

    private func perform(_ call: ToolCall) async -> ActionRecord {
        let validated: ToolCall
        do {
            validated = try ToolValidator.validate(call, timeZone: config.timeZone)
        } catch {
            return ActionRecord(tool: call.name, summary: call.name, outcome: .failed(error.localizedDescription), date: clock())
        }
        guard availableTools().contains(where: { $0.name == validated.name }) else {
            return ActionRecord(tool: validated.name, summary: validated.name,
                                outcome: .failed("Esa herramienta no está disponible o está desactivada."), date: clock())
        }
        let definition = ToolCatalog.definition(named: validated.name)!
        let summary = Self.summary(for: validated)

        if definition.risk == .sensitive {
            guard let confirmer = confirmer else {
                return ActionRecord(tool: validated.name, summary: summary, outcome: .failed("No hay forma de pedir confirmación."), date: clock())
            }
            let approved = await confirmer.confirm(ConfirmationRequest(
                tool: validated.name, title: Self.confirmationTitle(validated.name), detail: summary))
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
        case .success(let text): return ActionRecord(tool: validated.name, summary: summary, outcome: .executed(text), date: clock())
        case .failure(let reason): return ActionRecord(tool: validated.name, summary: summary, outcome: .failed(reason), date: clock())
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
            case .success(let text): return ActionRecord(tool: "forget_memory", summary: "Olvidar: \(query)", outcome: .executed(text), date: clock())
            case .failure(let reason): return ActionRecord(tool: "forget_memory", summary: "Olvidar: \(query)", outcome: .failed(reason), date: clock())
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
        case "run_shortcut": return "Ejecutar Atajo"
        case "ask_claude": return "Enviar a Claude"
        case "save_memory": return "Guardar en memoria"
        case "forget_memory": return "Olvidar recuerdo"
        default: return "Confirmar acción"
        }
    }

    static func summary(for call: ToolCall) -> String {
        let a = call.args
        switch call.name {
        case "open_app": return "Abrir \(a["app"] ?? "app")"
        case "open_url": return a["url"] ?? ""
        case "create_reminder": return "«\(a["title"] ?? "")»" + (a["due"].map { " para \($0)" } ?? "")
        case "complete_reminder": return "Completar «\(a["title"] ?? "")»"
        case "create_event": return "«\(a["title"] ?? "")» el \(a["start"] ?? "")" + (a["duration_minutes"].map { " (\($0) min)" } ?? "")
        case "run_shortcut": return "Atajo «\(a["name"] ?? "")»" + (a["input"].map { " con entrada: \($0)" } ?? "")
        case "ask_claude": return "Pregunta: \(a["prompt"] ?? "")"
        case "save_memory": return a["text"] ?? ""
        case "forget_memory", "search_memory": return a["query"] ?? ""
        case "device_info": return "Consultar \(a["what"] ?? "all")"
        case "list_reminders": return "Listar recordatorios"
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
            let cost = message.text.count
            if used + cost > budget, !collected.isEmpty { break }
            used += cost
            collected.append(ChatTurn(role: role, content: message.text))
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
