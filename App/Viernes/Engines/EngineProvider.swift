import Foundation
import ViernesCore

/// Crea el motor adecuado para un descriptor del catálogo y informa de la disponibilidad del modelo del sistema.
enum EngineProvider {
    static func foundationModelsAvailability() -> EngineAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return FoundationModelsEngine.currentAvailability() }
        #endif
        return .unavailable(reason: "Requiere iOS 26 o superior.")
    }

    static var isFoundationModelAvailable: Bool {
        if case .ready = foundationModelsAvailability() { return true }
        return false
    }

    /// Gemini usa su API nativa; los demás proveedores (Groq, OpenAI, Cerebras) la API compatible con OpenAI.
    static func makeCloudEngine(descriptor: ModelDescriptor, settings: CloudBrainSettings, usage: UsageHooks?) -> LanguageModelEngine {
        if settings.sanitized().providerID == CloudProviders.gemini.id {
            return GeminiEngine(descriptor: descriptor, settings: settings, usage: usage)
        }
        return CloudEngine(descriptor: descriptor, settings: settings, usage: usage)
    }

    static func makeEngine(for descriptor: ModelDescriptor, cloud: CloudBrainSettings = .default, usage: UsageHooks? = nil) -> LanguageModelEngine? {
        switch descriptor.backend {
        case .cloud:
            return makeCloudEngine(descriptor: descriptor, settings: cloud, usage: usage)
        case .appleFoundation:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) { return FoundationModelsEngine() }
            #endif
            return nil
        case .mlx:
            #if canImport(MLXLLM)
            return MLXEngine(descriptor: descriptor)
            #else
            return nil
            #endif
        }
    }
}
