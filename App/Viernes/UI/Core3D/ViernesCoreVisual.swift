import SwiftUI
import SceneKit
import Metal

extension CoreVisualState {
    /// Traduce los estados reales de la app a estados visuales. Único punto donde se tocan «cerebro» y «representación».
    init(core: CoreState, executing: Bool) {
        if executing { self = .executing; return }
        switch core {
        case .idle: self = .idle
        case .listening: self = .listening
        case .thinking: self = .thinking
        case .speaking: self = .speaking
        case .error: self = .error
        case .disconnected: self = .offline
        }
    }

    /// Para el respaldo 2D.
    fileprivate var legacy: (state: CoreState, acting: Bool) {
        switch self {
        case .idle: return (.idle, false)
        case .listening: return (.listening, false)
        case .thinking: return (.thinking, false)
        case .speaking: return (.speaking, false)
        case .executing: return (.thinking, true)
        case .error: return (.error, false)
        case .offline: return (.disconnected, false)
        }
    }

    var accessibilityText: String {
        switch self {
        case .idle: return "En espera"
        case .listening: return "Escuchando"
        case .thinking: return "Pensando"
        case .speaking: return "Hablando"
        case .executing: return "Ejecutando herramientas"
        case .error: return "Error"
        case .offline: return "Sin cerebro"
        }
    }
}

/// Núcleo visual de Viernes: anillos de cromo tridimensionales (SceneKit) con luz naranja incandescente.
/// Componente independiente: recibe SOLO un estado visual, el nivel de audio y el pulso del habla.
/// Respaldo 2D (`ChromeCoreView`) si no hay Metal, si el usuario activó «efectos reducidos» o en las pruebas de UI
/// (el simulador del CI no es un buen juez de rendimiento 3D; `--uitest-3d` fuerza el 3D para las capturas).
struct ViernesCoreVisual: View {
    let state: CoreVisualState
    var level: Float = 0
    var pulse: Date = .distantPast
    var reducedEffects: Bool = false

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var renders3D: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--uitest") && !arguments.contains("--uitest-3d") { return false }
        return MTLCreateSystemDefaultDevice() != nil
    }

    var body: some View {
        Group {
            if Self.renders3D && !reducedEffects {
                CoreSceneView(
                    input: CoreSceneInput(state: state, level: level, pulse: pulse.timeIntervalSinceReferenceDate, calm: reduceMotion),
                    paused: scenePhase != .active)
                    .mask(
                        // La escena es opaca (el bloom HDR no admite fondo transparente): el borde se funde con el fondo de la app.
                        GeometryReader { proxy in
                            RadialGradient(stops: [
                                .init(color: .black, location: 0.0), .init(color: .black, location: 0.60), .init(color: .clear, location: 1.0)
                            ], center: .center, startRadius: 0, endRadius: min(proxy.size.width, proxy.size.height) / 2)
                        }
                    )
            } else {
                ChromeCoreView(state: state.legacy.state, level: level, pulse: pulse, acting: state.legacy.acting, reducedEffects: reducedEffects)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Núcleo de Viernes")
        .accessibilityValue(state.accessibilityText)
    }
}

private struct CoreSceneView: UIViewRepresentable {
    let input: CoreSceneInput
    let paused: Bool

    func makeCoordinator() -> CoreSceneController { CoreSceneController() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.cameraNode
        view.delegate = context.coordinator
        view.backgroundColor = UIColor(red: 0.032, green: 0.033, blue: 0.040, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true
        view.isUserInteractionEnabled = false        // los toques los recibe SwiftUI (el núcleo es un botón)
        view.preferredFramesPerSecond = 60
        context.coordinator.update(input)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.update(input)
        view.isPlaying = !paused
        view.preferredFramesPerSecond = (input.state == .idle || input.state == .offline) ? 20 : 60
    }
}
