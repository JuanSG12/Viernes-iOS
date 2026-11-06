import Foundation

public enum EngineAvailability: Equatable, Sendable {
    case ready
    case needsDownload(approxMB: Int)
    case unavailable(reason: String)
}

public enum EngineError: Error, Equatable, LocalizedError {
    case notReady(String)
    case generationFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notReady(let reason): return "El modelo no está listo: \(reason)"
        case .generationFailed(let reason): return "Falló la generación: \(reason)"
        case .cancelled: return "Generación cancelada."
        }
    }
}

/// Motores que pueden avisar de una espera (p. ej. «el proveedor pidió esperar 6 s») para mostrarla en pantalla.
public protocol EngineStatusReporting: AnyObject {
    var onStatus: (@Sendable (String?) -> Void)? { get set }
}

/// Contrato común de todos los "cerebros" locales. `generate` emite DELTAS de texto (no acumulados).
public protocol LanguageModelEngine: AnyObject, Sendable {
    var descriptor: ModelDescriptor { get }
    func availability() async -> EngineAvailability
    /// Descarga y/o carga el modelo en memoria. `progress` va de 0 a 1.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<String, Error>
    /// Libera memoria (p. ej. al pasar a segundo plano o cambiar de modelo).
    func unload() async
}
