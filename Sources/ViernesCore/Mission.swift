import Foundation

// MARK: Modelo de una misión

public enum MissionStepStatus: String, Codable, Sendable {
    case pending, running, done, failed, skipped, cancelled, interrupted
}

public enum MissionStatus: String, Codable, Sendable {
    case running, completed, partial, cancelled, interrupted
}

/// Un paso: UNA herramienta con sus argumentos y de qué otros pasos depende. Los resultados guardados son los REALES.
public struct MissionStep: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var tool: String
    public var args: [String: String]
    public var dependsOn: [String]
    /// Se puede repetir un número limitado de veces si falla por un motivo pasajero (red).
    public var retryable: Bool
    public var status: MissionStepStatus
    public var attempts: Int
    public var result: String?
    public var failure: String?

    public init(id: String, title: String, tool: String, args: [String: String] = [:], dependsOn: [String] = [], retryable: Bool = false,
                status: MissionStepStatus = .pending, attempts: Int = 0, result: String? = nil, failure: String? = nil) {
        self.id = id
        self.title = title
        self.tool = tool
        self.args = args
        self.dependsOn = dependsOn
        self.retryable = retryable
        self.status = status
        self.attempts = attempts
        self.result = result
        self.failure = failure
    }
}

public struct MissionPlan: Equatable, Sendable {
    public var goal: String
    public var steps: [MissionStep]
    /// Lo que no se pudo planear (p. ej. «no sé tu ciudad»), para decírselo al usuario en vez de inventarlo.
    public var notes: [String]
    public init(goal: String, steps: [MissionStep], notes: [String] = []) {
        self.goal = goal
        self.steps = steps
        self.notes = notes
    }
}

public struct MissionState: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var goal: String
    public var createdAt: Date
    public var updatedAt: Date
    public var status: MissionStatus
    public var steps: [MissionStep]
    public var notes: [String]

    public init(id: UUID = UUID(), plan: MissionPlan, now: Date = Date()) {
        self.id = id
        self.goal = plan.goal
        self.createdAt = now
        self.updatedAt = now
        self.status = .running
        self.steps = plan.steps
        self.notes = plan.notes
    }
}

public struct StepOutcome: Sendable {
    public var ok: Bool
    public var text: String
    /// El fallo es del tipo que puede arreglarse reintentando (red, tiempo de espera).
    public var transient: Bool
    public init(ok: Bool, text: String, transient: Bool = false) {
        self.ok = ok
        self.text = text
        self.transient = transient
    }
}

/// Dónde se guardan las misiones (la app, cifradas por perfil; las pruebas, en memoria).
public protocol MissionStore: AnyObject, Sendable {
    func save(_ state: MissionState) async
    func loadAll() async -> [MissionState]
    func deleteAll() async
}

public actor InMemoryMissionStore: MissionStore {
    private var states: [UUID: MissionState] = [:]
    public private(set) var saveCount = 0
    public init() {}
    public func save(_ state: MissionState) async {
        states[state.id] = state
        saveCount += 1
    }
    public func loadAll() async -> [MissionState] { states.values.sorted { $0.createdAt > $1.createdAt } }
    public func deleteAll() async { states.removeAll() }
}

// MARK: Ejecución

/// Ejecuta un plan: respeta las dependencias, lanza en paralelo las consultas seguras (hasta `maxParallel`) y las acciones UNA a UNA
/// (cada una con su confirmación), reintenta un número limitado de veces lo que falla por motivos pasajeros, se puede cancelar,
/// guarda su estado tras cada cambio y marca como saltado lo que dependía de algo que falló. Nunca inventa un resultado.
public actor MissionRunner {
    public static let maxParallel = 3
    public static let maxAttempts = 2

    private let store: MissionStore?
    private let clock: @Sendable () -> Date
    private let retryDelayNanoseconds: UInt64

    public init(store: MissionStore? = nil, clock: @escaping @Sendable () -> Date = { Date() }, retryDelayNanoseconds: UInt64 = 700_000_000) {
        self.store = store
        self.clock = clock
        self.retryDelayNanoseconds = retryDelayNanoseconds
    }

    static func isQuery(_ step: MissionStep) -> Bool { ToolCatalog.definition(named: step.tool)?.risk == .safe }

    public func run(_ plan: MissionPlan, execute: @escaping @Sendable (MissionStep) async -> StepOutcome) async -> MissionState {
        await run(state: MissionState(plan: plan, now: clock()), execute: execute)
    }

    /// Continúa una misión interrumpida: solo se repiten los pasos que no terminaron.
    public func resume(_ saved: MissionState, execute: @escaping @Sendable (MissionStep) async -> StepOutcome) async -> MissionState {
        var state = saved
        state.status = .running
        for index in state.steps.indices where [.running, .interrupted, .cancelled].contains(state.steps[index].status) {
            state.steps[index].status = .pending
            state.steps[index].failure = nil
        }
        return await run(state: state, execute: execute)
    }

    private func persist(_ state: inout MissionState) async {
        state.updatedAt = clock()
        await store?.save(state)
    }

    private func run(state initial: MissionState, execute: @escaping @Sendable (MissionStep) async -> StepOutcome) async -> MissionState {
        var state = initial
        await persist(&state)
        while true {
            if Task.isCancelled { return await finishCancelled(&state) }
            // Lo que depende de algo fallido (o saltado) no se ejecuta: se salta y se dice por qué.
            var changed = false
            for index in state.steps.indices where state.steps[index].status == .pending {
                let blockers = state.steps[index].dependsOn.compactMap { id in state.steps.first { $0.id == id } }
                    .filter { [.failed, .skipped, .cancelled].contains($0.status) }
                if let first = blockers.first {
                    state.steps[index].status = .skipped
                    state.steps[index].failure = "Depende de «\(first.title)», que no se pudo completar."
                    changed = true
                }
            }
            if changed { await persist(&state) }

            let ready = state.steps.filter { step in
                step.status == .pending && step.dependsOn.allSatisfy { id in state.steps.first { $0.id == id }?.status == .done }
            }
            guard !ready.isEmpty else { break }
            let queries = ready.filter(Self.isQuery)
            let batch = queries.isEmpty ? [ready[0]] : Array(queries.prefix(Self.maxParallel))
            for step in batch {
                if let index = state.steps.firstIndex(where: { $0.id == step.id }) { state.steps[index].status = .running }
            }
            await persist(&state)

            let delay = retryDelayNanoseconds
            let results: [(String, StepOutcome, Int)] = await withTaskGroup(of: (String, StepOutcome, Int).self) { group in
                for step in batch {
                    group.addTask {
                        var attempts = 0
                        var outcome = StepOutcome(ok: false, text: "No se ejecutó.")
                        while attempts < Self.maxAttempts {
                            attempts += 1
                            if Task.isCancelled { return (step.id, StepOutcome(ok: false, text: "Cancelado."), attempts) }
                            outcome = await execute(step)
                            if outcome.ok { break }
                            guard step.retryable, outcome.transient, attempts < Self.maxAttempts else { break }
                            try? await Task.sleep(nanoseconds: delay)
                        }
                        return (step.id, outcome, attempts)
                    }
                }
                var collected: [(String, StepOutcome, Int)] = []
                for await item in group { collected.append(item) }
                return collected
            }
            for (id, outcome, attempts) in results {
                guard let index = state.steps.firstIndex(where: { $0.id == id }) else { continue }
                state.steps[index].attempts += attempts
                // Verificación: un paso «correcto» sin ningún dato no cuenta como hecho.
                if outcome.ok, outcome.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    state.steps[index].status = .failed
                    state.steps[index].failure = "La herramienta no devolvió ningún dato."
                } else if outcome.ok {
                    state.steps[index].status = .done
                    state.steps[index].result = outcome.text
                    state.steps[index].failure = nil
                } else {
                    state.steps[index].status = Task.isCancelled ? .cancelled : .failed
                    state.steps[index].failure = outcome.text
                }
            }
            await persist(&state)
        }
        if Task.isCancelled { return await finishCancelled(&state) }
        let allDone = state.steps.allSatisfy { $0.status == .done }
        state.status = allDone ? .completed : .partial
        await persist(&state)
        return state
    }

    private func finishCancelled(_ state: inout MissionState) async -> MissionState {
        for index in state.steps.indices where [.pending, .running].contains(state.steps[index].status) { state.steps[index].status = .cancelled }
        state.status = .cancelled
        await persist(&state)
        return state
    }

    /// Tras un cierre inesperado: lo que quedó «en curso» pasa a «interrumpida» (nunca se finge que terminó).
    public static func markInterrupted(_ states: [MissionState]) -> [MissionState] {
        states.map { saved in
            guard saved.status == .running else { return saved }
            var copy = saved
            copy.status = .interrupted
            for index in copy.steps.indices where [.pending, .running].contains(copy.steps[index].status) { copy.steps[index].status = .interrupted }
            return copy
        }
    }
}

// MARK: Misiones conocidas

public enum MissionKind: String, Sendable {
    case today, tomorrow, week
}

public struct MissionContext: Sendable {
    public var city: String?
    public init(city: String? = nil) { self.city = city }

    /// Ciudad que dijo el usuario en la orden («organiza mi día en Medellín») o que tiene guardada en su memoria («vivo en Cali»).
    public static func city(in text: String, memories: [MemoryItem]) -> String? {
        func clean(_ raw: String) -> String? {
            let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?¿¡\n"))
            guard (3...40).contains(value.count), !value.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) else { return nil }
            let blocked = ["la manana", "la tarde", "la noche", "el dia", "mi dia", "la semana", "casa", "la oficina", "el trabajo"]
            return blocked.contains(TextNormalizer.fold(value)) ? nil : value
        }
        func first(_ pattern: String, in source: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let range = NSRange(source.startIndex..., in: source)
            guard let match = regex.firstMatch(in: source, range: range), match.numberOfRanges > 1, let captured = Range(match.range(at: 1), in: source) else { return nil }
            return clean(String(source[captured]))
        }
        if let city = first("\\ben\\s+([\\p{L}][\\p{L} ]{2,39})\\s*[.!?]*$", in: text) { return city }
        for memory in memories where !memory.isPending {
            if let city = first("\\bvivo en\\s+([\\p{L}][\\p{L} ]{2,39})", in: memory.text) ?? first("\\bmi ciudad (?:es|:)\\s+([\\p{L}][\\p{L} ]{2,39})", in: memory.text) { return city }
        }
        return nil
    }
}

public enum MissionTemplates {
    static func has(_ folded: String, _ phrases: [String]) -> Bool { phrases.contains { folded.contains($0) } }

    /// ¿La orden pide una de las misiones conocidas? Solo frases claras: una pregunta suelta («¿qué clima hace mañana?») NO es una misión.
    public static func match(_ text: String) -> MissionKind? {
        let folded = TextNormalizer.fold(text)
        if has(folded, ["organiza mi semana", "organizame la semana", "planea mi semana", "resumen de mi semana", "como viene mi semana", "prepara mi semana"]) { return .week }
        if has(folded, ["organiza el dia de manana", "organiza manana", "organizame manana", "planea manana", "prepara manana", "planea el dia de manana"]) { return .tomorrow }
        if has(folded, ["organiza mi manana", "organiza mi dia", "organizame el dia", "organizame la manana", "planea mi dia", "planea mi manana",
                        "prepara mi dia", "resumen de mi dia", "como viene mi dia", "como esta mi dia"]) { return .today }
        return nil
    }

    public static func plan(_ kind: MissionKind, goal: String, context: MissionContext) -> MissionPlan {
        var steps: [MissionStep] = []
        var notes: [String] = []
        switch kind {
        case .today:
            steps.append(MissionStep(id: "agenda", title: "Eventos de hoy", tool: "list_events", args: ["date": "today"]))
        case .tomorrow:
            steps.append(MissionStep(id: "agenda", title: "Eventos de mañana", tool: "list_events", args: ["date": "tomorrow"]))
        case .week:
            steps.append(MissionStep(id: "agenda", title: "Eventos de los próximos 7 días", tool: "list_events", args: ["date": "today", "days": "7"]))
        }
        steps.append(MissionStep(id: "recordatorios", title: "Recordatorios pendientes", tool: "list_reminders", args: ["limit": kind == .week ? "20" : "10"]))
        if kind != .week {
            if let city = context.city {
                steps.append(MissionStep(id: "clima", title: "Clima en \(city)", tool: "get_weather", args: ["city": city], retryable: true))
            } else {
                notes.append("No sé en qué ciudad estás, así que no consulté el clima: el usuario puede decirlo en la orden («…en Medellín») o guardarlo con «recuerda que vivo en…».")
            }
        }
        return MissionPlan(goal: goal, steps: steps, notes: notes)
    }
}

// MARK: Informe

public enum MissionReport {
    /// Resultados REALES de cada paso para dárselos al modelo, con la regla de no inventar lo que falta ni los conflictos.
    public static func resultLines(_ state: MissionState) -> [String] {
        var lines = ["Misión «\(state.goal)» — resultados REALES de cada paso:"]
        for (index, step) in state.steps.enumerated() {
            switch step.status {
            case .done: lines.append("\(index + 1). \(step.title): \(step.result ?? "")")
            case .skipped: lines.append("\(index + 1). \(step.title): NO SE EJECUTÓ. \(step.failure ?? "")")
            case .cancelled, .interrupted: lines.append("\(index + 1). \(step.title): NO TERMINÓ (cancelado o interrumpido).")
            default: lines.append("\(index + 1). \(step.title): NO DISPONIBLE. \(step.failure ?? "Falló.")")
            }
        }
        for note in state.notes { lines.append("Nota: \(note)") }
        lines.append("Con ESTOS datos y solo con ellos haz un resumen breve y ordenado; señala un conflicto de horario únicamente si dos eventos se solapan según las horas de arriba. Lo que diga «NO DISPONIBLE» o «NO SE EJECUTÓ», dilo con el motivo y NO lo inventes.")
        return lines
    }

    /// Texto para la pantalla de misiones.
    public static func text(_ state: MissionState) -> String {
        var lines = ["«\(state.goal)» — \(label(state.status))"]
        for step in state.steps {
            lines.append("\(symbol(step.status)) \(step.title)\(step.attempts > 1 ? " (\(step.attempts) intentos)" : "")")
            if let detail = step.status == .done ? step.result : step.failure, !detail.isEmpty { lines.append("   " + String(detail.prefix(400))) }
        }
        for note in state.notes { lines.append("• " + note) }
        return lines.joined(separator: "\n")
    }

    public static func label(_ status: MissionStatus) -> String {
        switch status {
        case .running: return "en curso"
        case .completed: return "completada"
        case .partial: return "parcial (faltaron datos)"
        case .cancelled: return "cancelada"
        case .interrupted: return "interrumpida"
        }
    }

    static func symbol(_ status: MissionStepStatus) -> String {
        switch status {
        case .done: return "✓"
        case .failed: return "✗"
        case .skipped: return "↷"
        case .cancelled, .interrupted: return "⏸"
        case .running: return "…"
        case .pending: return "·"
        }
    }
}
