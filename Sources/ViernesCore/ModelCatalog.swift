import Foundation

public enum ModelBackend: Equatable, Sendable {
    /// Modelo del sistema (framework FoundationModels, iOS 26+). No se descarga.
    case appleFoundation
    /// Modelo cuantizado de Hugging Face ejecutado con MLX Swift.
    case mlx(repo: String)
    /// Modelo en la nube vía API compatible con OpenAI (Groq, Gemini…) con una clave gratuita del usuario.
    /// El texto de la conversación SALE del teléfono hacia el proveedor elegido.
    case cloud
}

public struct ModelDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let backend: ModelBackend
    /// Tamaño aproximado de descarga. 0 = viene con el sistema.
    public let approxDownloadMB: Int
    /// Memoria física mínima recomendada del dispositivo (GB).
    public let minDeviceRAMGB: Int
    public let license: String
    /// Valoración editorial 1–5 de calidad en español. NO es un benchmark: ver LOCAL_MODELS.md.
    public let spanishQuality: Int
    /// Etiquetas de razonamiento (<think>) que hay que retirar y desactivar.
    public let emitsThinkTags: Bool
    public let notes: String

    public var isSystemModel: Bool { backend == .appleFoundation }
    public var isCloud: Bool { backend == .cloud }
    /// El texto de la conversación sale del dispositivo hacia un servidor.
    public var sendsTextOffDevice: Bool { isCloud }
    /// Pesos descargados y cargados en la memoria del iPhone (MLX).
    public var usesLocalWeights: Bool { if case .mlx = backend { return true }; return false }
    public var requiresDownload: Bool { approxDownloadMB > 0 }

    public init(id: String, displayName: String, backend: ModelBackend, approxDownloadMB: Int,
                minDeviceRAMGB: Int, license: String, spanishQuality: Int,
                emitsThinkTags: Bool = false, notes: String) {
        self.id = id
        self.displayName = displayName
        self.backend = backend
        self.approxDownloadMB = approxDownloadMB
        self.minDeviceRAMGB = minDeviceRAMGB
        self.license = license
        self.spanishQuality = spanishQuality
        self.emitsThinkTags = emitsThinkTags
        self.notes = notes
    }
}

public enum ModelFit: String, Sendable {
    case recommended = "Recomendado"
    case possible = "Posible"
    case notRecommended = "No recomendado"
}

public enum ModelCatalog {
    public static let appleFoundationID = "apple.foundation"

    /// Catálogo intercambiable. Los repos MLX son los de la comunidad `mlx-community` (cuantización 4 bits).
    public static let all: [ModelDescriptor] = [
        ModelDescriptor(
            id: appleFoundationID, displayName: "Apple Intelligence (en el dispositivo)",
            backend: .appleFoundation, approxDownloadMB: 0, minDeviceRAMGB: 8,
            license: "Términos de Apple (incluido en iOS)", spanishQuality: 4,
            notes: "Modelo del sistema, sin descarga. Requiere iOS 26+, un iPhone compatible con Apple Intelligence y tenerlo activado. Español soportado."
        ),
        ModelDescriptor(
            id: "qwen3-1.7b-4bit", displayName: "Qwen3 1.7B (4 bits)",
            backend: .mlx(repo: "mlx-community/Qwen3-1.7B-4bit"), approxDownloadMB: 1000, minDeviceRAMGB: 6,
            license: "Apache 2.0", spanishQuality: 3, emitsThinkTags: true,
            notes: "Buen equilibrio tamaño/calidad. Multilingüe, incluye español. Limitado en razonamiento largo."
        ),
        ModelDescriptor(
            id: "gemma3-1b-qat-4bit", displayName: "Gemma 3 1B QAT (4 bits)",
            backend: .mlx(repo: "mlx-community/gemma-3-1b-it-qat-4bit"), approxDownloadMB: 770, minDeviceRAMGB: 4,
            license: "Términos de uso de Gemma", spanishQuality: 3,
            notes: "El más ligero y rápido del catálogo. Respuestas simples; se equivoca más en datos."
        ),
        ModelDescriptor(
            id: "llama3.2-3b-4bit", displayName: "Llama 3.2 3B Instruct (4 bits)",
            backend: .mlx(repo: "mlx-community/Llama-3.2-3B-Instruct-4bit"), approxDownloadMB: 1800, minDeviceRAMGB: 8,
            license: "Llama 3.2 Community License", spanishQuality: 3,
            notes: "Español entre los idiomas oficialmente soportados. Licencia con condiciones (ver LOCAL_MODELS.md)."
        ),
        ModelDescriptor(
            id: "qwen3-4b-4bit", displayName: "Qwen3 4B (4 bits)",
            backend: .mlx(repo: "mlx-community/Qwen3-4B-4bit"), approxDownloadMB: 2300, minDeviceRAMGB: 8,
            license: "Apache 2.0", spanishQuality: 4, emitsThinkTags: true,
            notes: "Mayor calidad local del catálogo; más lento y con más consumo. Solo para iPhone con 8 GB o más."
        )
    ]

    public static let cloudID = "cloud.openai-compatible"

    /// El cerebro en la nube NO está en `all` (no se descarga ni se compara por RAM); se elige en su propia pantalla.
    public static let cloudDescriptor = ModelDescriptor(
        id: cloudID, displayName: "IA en la nube (clave gratuita)",
        backend: .cloud, approxDownloadMB: 0, minDeviceRAMGB: 0,
        license: "Términos del proveedor elegido", spanishQuality: 5,
        notes: "Modelo grande en un servidor (Groq o Gemini). Conversa como una IA de verdad, pero tus mensajes salen del iPhone."
    )

    public static func descriptor(id: String) -> ModelDescriptor? {
        if id == cloudID { return cloudDescriptor }
        return all.first { $0.id == id }
    }
}

/// Heurística de idoneidad por RAM. Documentada en LOCAL_MODELS.md; hay que validarla en dispositivo.
public enum ModelRecommender {
    /// iOS suele limitar la app a ~45–55 % de la RAM física (más con el entitlement
    /// `increased-memory-limit`). Estimamos huella = descarga × 1.3 + 0.4 GB de caché KV.
    public static func fit(for model: ModelDescriptor, physicalMemoryBytes: UInt64, foundationAvailable: Bool) -> ModelFit {
        if model.isSystemModel { return foundationAvailable ? .recommended : .notRecommended }
        let ramGB = Double(physicalMemoryBytes) / 1_073_741_824
        let budgetGB = ramGB * 0.5
        let footprintGB = Double(model.approxDownloadMB) / 1024 * 1.3 + 0.4
        if ramGB + 0.5 < Double(model.minDeviceRAMGB) { return .notRecommended }
        if footprintGB <= budgetGB * 0.75 { return .recommended }
        if footprintGB <= budgetGB { return .possible }
        return .notRecommended
    }

    /// Mejor opción por defecto: sistema si está disponible; si no, el MLX de mayor calidad en español que encaje.
    public static func defaultModel(physicalMemoryBytes: UInt64, foundationAvailable: Bool) -> ModelDescriptor {
        if foundationAvailable, let system = ModelCatalog.descriptor(id: ModelCatalog.appleFoundationID) { return system }
        let candidates = ModelCatalog.all.filter {
            !$0.isSystemModel && fit(for: $0, physicalMemoryBytes: physicalMemoryBytes, foundationAvailable: false) == .recommended
        }
        let best = candidates.sorted {
            ($0.spanishQuality, -$0.approxDownloadMB) > ($1.spanishQuality, -$1.approxDownloadMB)
        }.first
        return best ?? ModelCatalog.all.first { $0.id == "gemma3-1b-qat-4bit" }!
    }
}
