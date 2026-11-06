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

    /// SOLO para las capturas del CI (`--uitest --uitest-no-effects`): aísla el núcleo 3D de la capa de efectos para depurar el aspecto.
    static var overlayDisabledForQA: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--uitest") && arguments.contains("--uitest-no-effects")
    }

    static var renders3D: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--uitest") && !arguments.contains("--uitest-3d") { return false }
        return MTLCreateSystemDefaultDevice() != nil
    }

    var body: some View {
        Group {
            if Self.renders3D && !reducedEffects {
                ZStack {
                    CoreSceneView(
                        input: CoreSceneInput(state: state, level: level, pulse: pulse.timeIntervalSinceReferenceDate, calm: reduceMotion),
                        paused: scenePhase != .active)
                    // Resplandor, partículas y red de herramientas: capas 2D transparentes ENCIMA de la escena 3D (el bloom HDR de
                    // SceneKit se retiró: dejaba cuadrados negros).
                    if !Self.overlayDisabledForQA {
                        CoreGlow(state: state, paused: scenePhase != .active || reduceMotion)
                        CoreEffectsOverlay(state: state, paused: scenePhase != .active || reduceMotion)
                    }
                }
                    .mask(
                        // La escena es opaca (gris casi negro): el borde se funde con el fondo de la app.
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

/// Resplandor 2D del núcleo (sustituye al bloom): halo naranja que respira según el estado y un punto blanco-cálido en el centro.
/// Degradados radiales sencillos con mezcla normal; solo anima (a 20 fps) cuando el núcleo está activo.
private struct CoreGlow: View {
    let state: CoreVisualState
    let paused: Bool

    private var tint: Color {
        switch state {
        case .error: return Color(red: 1.0, green: 0.27, blue: 0.36)
        case .offline: return Color(red: 0.55, green: 0.58, blue: 0.64)
        case .thinking: return Theme.amber
        default: return Theme.accent
        }
    }

    private var strength: Double {
        switch state {
        case .idle: return 0.08
        case .listening: return 0.12
        case .speaking: return 0.14
        case .thinking: return 0.16
        case .executing: return 0.20
        case .error: return 0.16
        case .offline: return 0.03
        }
    }

    var body: some View {
        let animated = state != .idle && state != .offline
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: paused || !animated)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let rate: Double = (state == .thinking || state == .executing) ? 3.0 : 1.4
            let pulse: Double = animated ? 1 + 0.14 * sin(time * rate) : 1
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                ZStack {
                    RadialGradient(
                        colors: [tint.opacity(strength * pulse), tint.opacity(strength * 0.35 * pulse), .clear],
                        center: .center, startRadius: 0, endRadius: side * 0.46)
                    RadialGradient(
                        colors: [Color(red: 1.0, green: 0.92, blue: 0.75).opacity(min(0.9, strength * 1.8 * pulse)), .clear],
                        center: .center, startRadius: 0, endRadius: side * 0.07)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Efectos 2D sobre el núcleo 3D: al PENSAR, puntos de luz que entran en espiral hacia el centro; al EJECUTAR una herramienta,
/// nodos que orbitan unidos al centro por líneas que pulsan. Solo se dibujan (y solo avanza el reloj) en esos dos estados.
private struct CoreEffectsOverlay: View {
    let state: CoreVisualState
    let paused: Bool

    var body: some View {
        if state == .thinking || state == .executing {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { timeline in
                Canvas { context, size in
                    draw(&context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func glowDot(_ context: inout GraphicsContext, at point: CGPoint, radius: CGFloat, color: Color, alpha: Double) {
        let halo = CGRect(x: point.x - radius * 3, y: point.y - radius * 3, width: radius * 6, height: radius * 6)
        context.fill(Path(ellipseIn: halo), with: .radialGradient(
            Gradient(colors: [color.opacity(alpha * 0.55), color.opacity(0)]), center: point, startRadius: 0, endRadius: radius * 3))
        let core = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: core), with: .color(Color.white.opacity(alpha * 0.9)))
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2

        if state == .thinking {
            for index in 0..<22 {
                let p: Double = (time * 0.3 + Double(index) * 0.618034).truncatingRemainder(dividingBy: 1)
                let r: Double = Double(radius) * (0.95 * (1 - p) + 0.08)
                let angle: Double = Double(index) * 2.39996 + time * (0.8 + p)
                let point = CGPoint(x: Double(center.x) + cos(angle) * r, y: Double(center.y) + sin(angle) * r * 0.66)
                glowDot(&context, at: point, radius: CGFloat(1.0 + 1.6 * p), color: Theme.amber, alpha: 0.25 + 0.75 * (1 - p))
            }
        } else {
            let count = 5
            var nodes: [CGPoint] = []
            for index in 0..<count {
                let angle: Double = time * 1.1 + Double(index) * 2 * Double.pi / Double(count)
                nodes.append(CGPoint(x: Double(center.x) + cos(angle) * Double(radius) * 0.86,
                                     y: Double(center.y) + sin(angle) * Double(radius) * 0.52))
            }
            for (index, node) in nodes.enumerated() {
                let pulse: Double = 0.35 + 0.65 * pow(sin(time * 5 + Double(index)), 2)
                var line = Path()
                line.move(to: center)
                line.addLine(to: node)
                context.stroke(line, with: .linearGradient(
                    Gradient(colors: [Theme.accent.opacity(0.9 * pulse), Theme.accent.opacity(0.05)]), startPoint: center, endPoint: node),
                    style: StrokeStyle(lineWidth: 1.2))
                var edge = Path()
                edge.move(to: node)
                edge.addLine(to: nodes[(index + 1) % count])
                context.stroke(edge, with: .color(Theme.accent.opacity(0.22)), style: StrokeStyle(lineWidth: 0.8))
                glowDot(&context, at: node, radius: 2.6, color: Theme.accent, alpha: 0.5 + 0.5 * pulse)
            }
        }
    }
}
