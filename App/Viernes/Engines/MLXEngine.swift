import Foundation
import ViernesCore

// ⚠️ ARCHIVO DE MAYOR RIESGO DE COMPILACIÓN. Escrito leyendo el README y las fuentes de mlx-swift-lm 3.32.x
// (ChatSession, ModelConfiguration, macro #huggingFaceLoadModelContainer) SIN poder compilarlo (el entorno de
// desarrollo era Windows). Si Xcode reporta un cambio de firma, el arreglo está acotado a este único archivo.
// Ver LOCAL_MODELS.md › "Verificación pendiente".

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Cerebro local #2: modelos cuantizados de `mlx-community` ejecutados con MLX Swift en la GPU del iPhone.
final class MLXEngine: LanguageModelEngine, @unchecked Sendable {
    let descriptor: ModelDescriptor
    private let repo: String
    private let lock = NSLock()
    private var container: ModelContainer?

    init?(descriptor: ModelDescriptor) {
        guard case .mlx(let repo) = descriptor.backend else { return nil }
        self.descriptor = descriptor
        self.repo = repo
    }

    private var loaded: ModelContainer? {
        lock.lock(); defer { lock.unlock() }
        return container
    }

    func availability() async -> EngineAvailability {
        loaded != nil ? .ready : .needsDownload(approxMB: descriptor.approxDownloadMB)
    }

    /// Descarga (primera vez, requiere internet y es una decisión explícita del usuario) y carga en memoria.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        if loaded != nil { progress(1); return }
        do {
            let configuration = ModelConfiguration(id: repo)
            let model = try await #huggingFaceLoadModelContainer(
                configuration: configuration,
                progressHandler: { value in progress(value.fractionCompleted) }
            )
            setContainer(model)
            progress(1)
        } catch {
            throw EngineError.notReady(error.localizedDescription)
        }
    }

    func unload() async { setContainer(nil) }

    // Bloqueo en funciones síncronas: NSLock.lock() está prohibido dentro de contextos async.
    private func setContainer(_ value: ModelContainer?) {
        lock.lock(); defer { lock.unlock() }
        container = value
    }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let model = self.loaded else {
                    continuation.finish(throwing: EngineError.notReady("El modelo no está cargado."))
                    return
                }
                guard let last = request.turns.last else {
                    continuation.finish()
                    return
                }
                do {
                    let history: [Chat.Message] = request.turns.dropLast().map {
                        $0.role == .user ? .user($0.content) : .assistant($0.content)
                    }
                    let session = ChatSession(
                        model,
                        instructions: request.system,
                        history: history,
                        generateParameters: GenerateParameters(maxTokens: request.maxTokens, temperature: Float(request.temperature))
                    )
                    for try await piece in session.streamResponse(to: last.content) {
                        continuation.yield(piece)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: EngineError.cancelled)
                } catch {
                    continuation.finish(throwing: EngineError.generationFailed(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
