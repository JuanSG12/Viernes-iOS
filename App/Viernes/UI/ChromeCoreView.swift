import SwiftUI

/// Estado interno del núcleo que debe SUAVIZARSE entre fotogramas (si dependiera solo del reloj, cambiar de estado
/// haría saltar la rotación). Es una clase para poder mutarla dentro del cierre de dibujo de `Canvas`.
final class CoreClock {
    var phase: Double = 0
    var speed: Double = 0.2
    var energy: Double = 0.3
    var deform: Double = 1
    var squash: Double = 1
    private var last: Double = 0

    func advance(now: Double, speed targetSpeed: Double, energy targetEnergy: Double, deform targetDeform: Double, squash targetSquash: Double) {
        let dt: Double = last == 0 ? 0 : min(max(now - last, 0), 0.2)
        last = now
        let slow = min(1, dt * 4)
        speed += (targetSpeed - speed) * slow
        energy += (targetEnergy - energy) * min(1, dt * 6)
        deform += (targetDeform - deform) * min(1, dt * 10)
        squash += (targetSquash - squash) * slow
        phase += dt * speed
    }
}

/// Núcleo de Viernes: anillos de cromo oscuro deformados y entrelazados, con luz naranja incandescente.
/// Dibuja con `Canvas` (sin Metal, sin dependencias) y reacciona SOLO a estados reales de la app:
/// escucha (nivel del micrófono), pensamiento (partículas que convergen), habla (pulso por palabra),
/// herramientas (líneas que conectan nodos) y espera (casi quieto). 0 fps en segundo plano.
struct ChromeCoreView: View {
    let state: CoreState
    let level: Float           // 0…1, nivel del micrófono (escucha)
    let pulse: Date            // última palabra pronunciada (habla)
    let acting: Bool           // hay una herramienta ejecutándose de verdad
    let reducedEffects: Bool

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = CoreClock()

    private var calm: Bool { reduceMotion || reducedEffects }

    private var frameInterval: Double {
        if calm { return 1.0 / 6.0 }
        if acting { return 1.0 / 30.0 }
        switch state {
        case .idle: return 1.0 / 12.0
        case .disconnected: return 1.0 / 8.0
        default: return 1.0 / 30.0
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval, paused: scenePhase != .active)) { timeline in
            Canvas { context, size in
                let renderer = ChromeCoreRenderer(state: state, level: Double(level), pulse: pulse, acting: acting, calm: calm, clock: clock)
                renderer.draw(&context, size: size, now: timeline.date)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Núcleo de Viernes")
        .accessibilityValue(acting ? "Ejecutando herramientas" : state.title)
    }
}

private struct CoreRing {
    let radius: Double
    let squash: Double
    let tilt: Double
    let width: Double
    let spin: Double
    let a1: Double
    let a2: Double
    let phase: Double
}

private struct ChromeCoreRenderer {
    let state: CoreState
    let level: Double
    let pulse: Date
    let acting: Bool
    let calm: Bool
    let clock: CoreClock

    private static let rings: [CoreRing] = [
        CoreRing(radius: 0.70, squash: 0.44, tilt: -0.55, width: 15, spin: 0.040, a1: 0.05, a2: 0.030, phase: 0.0),
        CoreRing(radius: 0.62, squash: 0.52, tilt: 0.95, width: 12, spin: -0.055, a1: 0.06, a2: 0.040, phase: 1.7),
        CoreRing(radius: 0.82, squash: 0.30, tilt: 0.25, width: 7, spin: 0.025, a1: 0.04, a2: 0.020, phase: 3.1)
    ]
    /// Propiedad calculada (no almacenada) para no volver privado el inicializador de miembros.
    private var steps: Int { 96 }

    func draw(_ ctx: inout GraphicsContext, size: CGSize, now: Date) {
        let time: Double = now.timeIntervalSinceReferenceDate
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius: CGFloat = min(size.width, size.height) / 2
        let unit: CGFloat = radius / 160
        let tint = Theme.color(for: state)
        let since: Double = max(0, now.timeIntervalSince(pulse))

        // Objetivos por estado (se suavizan en `CoreClock`).
        var targetEnergy: Double
        var targetDeform: Double = 1
        var targetSpeed: Double = 0.22
        var targetSquash: Double = 1
        switch state {
        case .idle:
            targetEnergy = 0.28 + 0.05 * sin(time * 0.9)
        case .listening:
            targetEnergy = 0.5 + level * 0.9
            targetDeform = 1 + 7 * level
            targetSpeed = 0.5
        case .thinking:
            targetEnergy = 0.7 + 0.12 * sin(time * 3)
            targetSpeed = acting ? 1.0 : 0.65
            targetSquash = 0.88
        case .speaking:
            targetEnergy = 0.55 + 0.45 * exp(-since * 5)
            targetDeform = 1 + 4.5 * exp(-since * 4)
            targetSpeed = 0.6
        case .error:
            targetEnergy = sin(time * 14) > 0 ? 0.9 : 0.5
            targetDeform = sin(time * 18) > 0 ? 3 : 1
            targetSpeed = 0.8
        case .disconnected:
            targetEnergy = 0.10 + 0.03 * sin(time * 0.8)
            targetSpeed = 0.04
        }
        if acting { targetEnergy = max(targetEnergy, 0.85) }
        if calm { targetSpeed *= 0.2; targetDeform = 1 + (targetDeform - 1) * 0.3 }
        clock.advance(now: time, speed: targetSpeed, energy: targetEnergy, deform: targetDeform, squash: targetSquash)
        let energy: Double = clock.energy

        drawHalo(&ctx, center: center, radius: radius, tint: tint, energy: energy)
        drawOrbits(&ctx, center: center, radius: radius, time: time, energy: energy)
        drawRipples(&ctx, center: center, radius: radius, tint: tint, time: time, since: since)
        if state == .thinking { drawConvergingParticles(&ctx, center: center, radius: radius, tint: tint, time: time) }

        // Anillos: primero las mitades traseras, luego el centro y por último las delanteras (da profundidad).
        var geometry: [[CGPoint]] = []
        for ring in Self.rings { geometry.append(points(for: ring, center: center, radius: radius, time: time)) }
        let half = steps / 2
        for (index, ring) in Self.rings.enumerated() {
            let pts = geometry[index]
            drawTube(&ctx, path: polyline(pts, half...steps), ring: ring, unit: unit, center: center, tint: tint, energy: energy)
        }
        drawSpark(&ctx, center: center, radius: radius, tint: tint, energy: energy, time: time)
        for (index, ring) in Self.rings.enumerated() {
            let pts = geometry[index]
            drawTube(&ctx, path: polyline(pts, 0...half), ring: ring, unit: unit, center: center, tint: tint, energy: energy)
        }
        if state != .disconnected {
            for (index, ring) in Self.rings.enumerated() {
                drawHeat(&ctx, pts: geometry[index], ring: ring, unit: unit, tint: tint, energy: energy)
            }
        }
        if acting { drawToolNetwork(&ctx, center: center, radius: radius, tint: tint, time: time) }
    }

    // MARK: Geometría

    private func points(for ring: CoreRing, center: CGPoint, radius: CGFloat, time: Double) -> [CGPoint] {
        var result: [CGPoint] = []
        result.reserveCapacity(steps + 1)
        let rotation: Double = ring.tilt + clock.phase * ring.spin * 25
        let cosR: Double = cos(rotation)
        let sinR: Double = sin(rotation)
        let scale: Double = state == .thinking ? 0.94 : 1.0
        let base: Double = Double(radius) * ring.radius * scale
        for i in 0...steps {
            let theta: Double = Double(i) / Double(steps) * 2 * Double.pi
            let wobbleA: Double = ring.a1 * sin(2 * theta + time * 0.9 + ring.phase)
            let wobbleB: Double = ring.a2 * sin(3 * theta - time * 0.6 + ring.phase)
            let r: Double = base * (1 + clock.deform * (wobbleA + wobbleB))
            let x0: Double = r * cos(theta)
            let y0: Double = r * sin(theta) * ring.squash * clock.squash
            let x: Double = x0 * cosR - y0 * sinR
            let y: Double = x0 * sinR + y0 * cosR
            result.append(CGPoint(x: Double(center.x) + x, y: Double(center.y) + y))
        }
        return result
    }

    private func polyline(_ pts: [CGPoint], _ range: ClosedRange<Int>) -> Path {
        var path = Path()
        var first = true
        for i in range {
            if first { path.move(to: pts[i]); first = false } else { path.addLine(to: pts[i]) }
        }
        return path
    }

    // MARK: Cromo

    private func chromeGradient(tint: Color, energy: Double) -> Gradient {
        let reflection: Double = 0.30 + 0.55 * min(1, energy)
        return Gradient(stops: [
            Gradient.Stop(color: Color(white: 0.07), location: 0.00),
            Gradient.Stop(color: Color(white: 0.30), location: 0.10),
            Gradient.Stop(color: Color(white: 0.88), location: 0.19),
            Gradient.Stop(color: Color.white, location: 0.23),
            Gradient.Stop(color: Color(white: 0.45), location: 0.31),
            Gradient.Stop(color: Color(white: 0.06), location: 0.44),
            Gradient.Stop(color: Color(white: 0.22), location: 0.56),
            Gradient.Stop(color: tint.opacity(reflection), location: 0.67),
            Gradient.Stop(color: Color(white: 0.05), location: 0.75),
            Gradient.Stop(color: Color(white: 0.55), location: 0.88),
            Gradient.Stop(color: Color(white: 0.07), location: 1.00)
        ])
    }

    private func drawTube(_ ctx: inout GraphicsContext, path: Path, ring: CoreRing, unit: CGFloat, center: CGPoint, tint: Color, energy: Double) {
        let width: CGFloat = max(3, CGFloat(ring.width) * unit)
        let angle = Angle.radians(clock.phase * 3 + ring.phase)
        let body = GraphicsContext.Shading.conicGradient(chromeGradient(tint: tint, energy: energy), center: center, angle: angle)
        let glintAngle = Angle.radians(clock.phase * 3 + ring.phase + 0.314)
        let glint = GraphicsContext.Shading.conicGradient(
            Gradient(colors: [Color.clear, Color.white.opacity(0.85), Color.clear, Color.clear, Color.white.opacity(0.35), Color.clear]),
            center: center, angle: glintAngle)
        ctx.stroke(path, with: .color(Color.black.opacity(0.9)), style: StrokeStyle(lineWidth: width + 4 * unit + 1, lineCap: .round, lineJoin: .round))
        ctx.stroke(path, with: body, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        ctx.stroke(path, with: glint, style: StrokeStyle(lineWidth: max(1, width * 0.14), lineCap: .round, lineJoin: .round))
    }

    /// Segmento incandescente que recorre cada anillo.
    private func drawHeat(_ ctx: inout GraphicsContext, pts: [CGPoint], ring: CoreRing, unit: CGFloat, tint: Color, energy: Double) {
        let full = polyline(pts, 0...steps)
        let length: Double = 0.14 + 0.20 * min(1, energy)
        let travel: Double = clock.phase * 0.35 + ring.phase / 6.2832
        let offsets: [Double] = state == .thinking ? [0, 0.5] : [0]
        for offset in offsets {
            let start: Double = (travel + offset).truncatingRemainder(dividingBy: 1)
            var segments: [Path] = []
            if start + length <= 1 {
                segments.append(full.trimmedPath(from: start, to: start + length))
            } else {
                segments.append(full.trimmedPath(from: start, to: 1))
                segments.append(full.trimmedPath(from: 0, to: start + length - 1))
            }
            for segment in segments {
                ctx.stroke(segment, with: .color(tint.opacity(0.22 * energy + 0.05)), style: StrokeStyle(lineWidth: 11 * unit, lineCap: .round))
                ctx.stroke(segment, with: .color(tint.opacity(0.95)), style: StrokeStyle(lineWidth: max(1.4, 2.4 * unit), lineCap: .round))
                ctx.stroke(segment, with: .color(Color.white.opacity(0.9)), style: StrokeStyle(lineWidth: max(0.7, 0.9 * unit), lineCap: .round))
            }
        }
    }

    // MARK: Entorno

    private func glow(_ ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat, color: Color, opacity: Double) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        ctx.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(colors: [color.opacity(opacity), color.opacity(0)]),
                                                              center: center, startRadius: 0, endRadius: radius))
    }

    private func drawHalo(_ ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat, tint: Color, energy: Double) {
        glow(&ctx, center: center, radius: radius * CGFloat(0.85 + 0.15 * energy), color: tint, opacity: 0.08 + 0.20 * energy)
    }

    /// Órbitas finas de referencia con un satélite.
    private func drawOrbits(_ ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat, time: Double, energy: Double) {
        let specs: [(Double, Double, Double)] = [(0.96, 0.34, 0.5), (0.90, 0.58, -0.9), (0.99, 0.80, 1.4)]
        for (index, spec) in specs.enumerated() {
            let rotation: Double = spec.2 + clock.phase * 0.12 * Double(index + 1)
            let cosR: Double = cos(rotation)
            let sinR: Double = sin(rotation)
            var path = Path()
            let rx: Double = Double(radius) * spec.0
            let ry: Double = rx * spec.1
            for i in 0...64 {
                let theta: Double = Double(i) / 64 * 2 * Double.pi
                let x0: Double = rx * cos(theta)
                let y0: Double = ry * sin(theta)
                let point = CGPoint(x: Double(center.x) + x0 * cosR - y0 * sinR, y: Double(center.y) + x0 * sinR + y0 * cosR)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            ctx.stroke(path, with: .color(Theme.chrome.opacity(0.16)), style: StrokeStyle(lineWidth: 0.8))
            let satelliteAngle: Double = clock.phase * (1.4 + Double(index) * 0.5) + Double(index) * 2
            let sx: Double = rx * cos(satelliteAngle)
            let sy: Double = ry * sin(satelliteAngle)
            let satellite = CGPoint(x: Double(center.x) + sx * cosR - sy * sinR, y: Double(center.y) + sx * sinR + sy * cosR)
            ctx.fill(Path(ellipseIn: CGRect(x: satellite.x - 1.6, y: satellite.y - 1.6, width: 3.2, height: 3.2)),
                     with: .color(Theme.silver.opacity(0.35 + 0.5 * min(1, energy))))
        }
    }

    /// Ondas que se expanden: con el nivel del micrófono al escuchar y con cada palabra al hablar.
    private func drawRipples(_ ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat, tint: Color, time: Double, since: Double) {
        switch state {
        case .listening:
            for k in 0..<3 {
                let p: Double = (time * 0.6 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                let r: CGFloat = radius * CGFloat(0.5 + 0.5 * p)
                let alpha: Double = (1 - p) * (0.15 + level * 0.85)
                let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                ctx.stroke(Path(ellipseIn: rect), with: .color(tint.opacity(alpha)), style: StrokeStyle(lineWidth: 1.2))
            }
        case .speaking:
            let r: CGFloat = radius * CGFloat(0.45 + min(since, 1.0) * 0.55)
            let alpha: Double = exp(-since * 3.5) * 0.6
            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            ctx.stroke(Path(ellipseIn: rect), with: .color(tint.opacity(alpha)), style: StrokeStyle(lineWidth: 1.4))
        default:
            break
        }
    }

    /// Pensamiento: partículas que entran en espiral hacia el centro.
    private func drawConvergingParticles(_ ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat, tint: Color, time: Double) {
        for i in 0..<22 {
            let p: Double = (time * 0.28 + Double(i) * 0.618034).truncatingRemainder(dividingBy: 1)
            let r: Double = Double(radius) * (1.05 - 0.85 * p)
            let a: Double = Double(i) * 2.39996 + time * 0.9 * (1 + p)
            let point = CGPoint(x: Double(center.x) + cos(a) * r, y: Double(center.y) + sin(a) * r * 0.66)
            let size: Double = 1.2 + 2.2 * p
            ctx.fill(Path(ellipseIn: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)),
                     with: .color(tint.opacity((1 - p) * 0.9 + 0.1)))
        }
    }

    /// Chispa central con destellos en cruz.
    private func drawSpark(_ ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat, tint: Color, energy: Double, time: Double) {
        glow(&ctx, center: center, radius: radius * CGFloat(0.42 * (0.6 + 0.4 * energy)), color: tint, opacity: 0.55 * energy + 0.12)
        let sparkRadius: CGFloat = radius * CGFloat(0.06 + 0.07 * energy)
        let rect = CGRect(x: center.x - sparkRadius, y: center.y - sparkRadius, width: sparkRadius * 2, height: sparkRadius * 2)
        ctx.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(colors: [Color.white, tint.opacity(0.9), tint.opacity(0)]),
                                                              center: center, startRadius: 0, endRadius: sparkRadius))
        let flare: Double = Double(radius) * (0.22 + 0.45 * energy)
        let drift: Double = time * 0.08
        let baseAngles: [Double] = [0, Double.pi / 2, Double.pi / 4, 3 * Double.pi / 4]
        let scales: [Double] = [1.0, 1.0, 0.55, 0.55]
        for index in 0..<4 {
            let scale: Double = scales[index]
            let angle: Double = drift + baseAngles[index]
            let dx: Double = cos(angle) * flare * scale
            let dy: Double = sin(angle) * flare * scale
            var line = Path()
            line.move(to: CGPoint(x: Double(center.x) - dx, y: Double(center.y) - dy))
            line.addLine(to: CGPoint(x: Double(center.x) + dx, y: Double(center.y) + dy))
            ctx.stroke(line, with: .linearGradient(Gradient(colors: [Color.clear, Color.white.opacity(0.85 * min(1, energy + 0.2)), Color.clear]),
                                                   startPoint: CGPoint(x: Double(center.x) - dx, y: Double(center.y) - dy),
                                                   endPoint: CGPoint(x: Double(center.x) + dx, y: Double(center.y) + dy)),
                       style: StrokeStyle(lineWidth: scale > 0.9 ? 1.1 : 0.7, lineCap: .round))
        }
    }

    /// Ejecución de herramientas: nodos conectados al centro por líneas que pulsan.
    private func drawToolNetwork(_ ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat, tint: Color, time: Double) {
        let count = 5
        var nodes: [CGPoint] = []
        for j in 0..<count {
            let a: Double = clock.phase * 0.8 + Double(j) * 2 * Double.pi / Double(count)
            nodes.append(CGPoint(x: Double(center.x) + cos(a) * Double(radius) * 0.84, y: Double(center.y) + sin(a) * Double(radius) * 0.52))
        }
        for (j, node) in nodes.enumerated() {
            let pulse: Double = 0.35 + 0.65 * pow(sin(time * 5 + Double(j)), 2)
            var line = Path()
            line.move(to: center)
            line.addLine(to: node)
            ctx.stroke(line, with: .linearGradient(Gradient(colors: [tint.opacity(0.9 * pulse), tint.opacity(0)]), startPoint: center, endPoint: node),
                       style: StrokeStyle(lineWidth: 1))
            let next = nodes[(j + 1) % count]
            var edge = Path()
            edge.move(to: node)
            edge.addLine(to: next)
            ctx.stroke(edge, with: .color(tint.opacity(0.18)), style: StrokeStyle(lineWidth: 0.7))
            ctx.fill(Path(ellipseIn: CGRect(x: node.x - 2.4, y: node.y - 2.4, width: 4.8, height: 4.8)), with: .color(Color.white.opacity(0.4 + 0.6 * pulse)))
        }
    }
}
