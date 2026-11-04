import SwiftUI

/// Núcleo holográfico de Viernes. Dibuja con `Canvas` (una sola capa, sin Metal) y baja la tasa de fotogramas
/// según el estado para cuidar la batería: 8 fps en espera, 30 fps cuando hay actividad, 0 fps en segundo plano.
struct HoloCoreView: View {
    let state: CoreState
    let level: Float           // 0…1, nivel del micrófono (escucha)
    let pulse: Date            // última palabra pronunciada (habla)
    let reducedEffects: Bool

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var frameInterval: Double {
        if reduceMotion || reducedEffects { return 1.0 / 10.0 }
        switch state {
        case .idle, .disconnected: return 1.0 / 8.0
        default: return 1.0 / 30.0
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval, paused: scenePhase != .active)) { timeline in
            Canvas { context, size in
                draw(&context, size: size, time: timeline.date.timeIntervalSinceReferenceDate, now: timeline.date)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Núcleo de Viernes")
        .accessibilityValue(state.title)
    }

    // MARK: Dibujo

    private func draw(_ context: inout GraphicsContext, size: CGSize, time: Double, now: Date) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2
        let color = Theme.color(for: state)
        let motion = (reduceMotion || reducedEffects) ? 0.25 : 1.0

        // Intensidad por estado.
        let energy: Double
        switch state {
        case .idle: energy = 0.35 + 0.08 * sin(time * 1.2)
        case .listening: energy = 0.55 + Double(level) * 0.9
        case .thinking: energy = 0.7 + 0.15 * sin(time * 6)
        case .speaking:
            let since = max(0, now.timeIntervalSince(pulse))
            energy = 0.55 + 0.45 * exp(-since * 5) + 0.08 * sin(time * 9)
        case .error: energy = 0.6 + 0.3 * (sin(time * 14) > 0 ? 1 : 0)
        case .disconnected: energy = 0.18 + 0.05 * sin(time * 0.8)
        }

        // Halo exterior.
        let haloRadius = radius * (0.80 + 0.18 * energy)
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - haloRadius, y: center.y - haloRadius, width: haloRadius * 2, height: haloRadius * 2)),
            with: .radialGradient(Gradient(colors: [color.opacity(0.32 * energy + 0.08), color.opacity(0)]),
                                  center: center, startRadius: radius * 0.1, endRadius: haloRadius)
        )

        // Anillos con segmentos que giran en sentidos opuestos.
        let ringSpecs: [(r: Double, width: CGFloat, segments: Int, speed: Double, dash: Double)] = [
            (0.92, 1.0, 72, 0.05, 0.50), (0.78, 2.2, 6, -0.12, 0.62), (0.64, 1.0, 40, 0.18, 0.40), (0.50, 3.0, 3, -0.30, 0.55)
        ]
        let speedFactor: Double = state == .thinking ? 3.2 : (state == .disconnected ? 0.15 : 1.0)
        for (index, ring) in ringSpecs.enumerated() {
            let r = radius * ring.r
            let rotation = time * ring.speed * speedFactor * motion * 2 * .pi
            let segmentAngle = 2 * .pi / Double(ring.segments)
            for segment in 0..<ring.segments {
                let start = rotation + Double(segment) * segmentAngle
                var path = Path()
                path.addArc(center: center, radius: r, startAngle: .radians(start),
                            endAngle: .radians(start + segmentAngle * ring.dash), clockwise: false)
                let opacity = (0.25 + 0.55 * energy) * (index.isMultiple(of: 2) ? 0.8 : 1.0)
                context.stroke(path, with: .color(color.opacity(min(opacity, 1))), lineWidth: ring.width)
            }
        }

        // Forma de onda radial (escucha y habla).
        if state == .listening || state == .speaking {
            let spikes = 96
            let base = radius * 0.40
            var path = Path()
            for spike in 0...spikes {
                let angle = Double(spike) / Double(spikes) * 2 * .pi
                let wave = sin(angle * 7 + time * 5 * motion) * 0.5 + sin(angle * 13 - time * 3 * motion) * 0.5
                let amplitude = radius * 0.12 * energy * (0.4 + 0.6 * abs(wave))
                let point = CGPoint(x: center.x + cos(angle) * (base + amplitude), y: center.y + sin(angle) * (base + amplitude))
                if spike == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            context.stroke(path, with: .color(Theme.ice.opacity(0.9)), lineWidth: 1.4)
        }

        // Partículas orbitando (pensamiento).
        if state == .thinking {
            for particle in 0..<14 {
                let phase = Double(particle) / 14.0
                let angle = time * 2.4 * motion + phase * 2 * .pi
                let wobble: Double = 0.30 + 0.28 * (0.5 + 0.5 * sin(time * 1.3 + phase * 9))
                let orbit = radius * CGFloat(wobble)
                let point = CGPoint(x: center.x + CGFloat(cos(angle)) * orbit, y: center.y + CGFloat(sin(angle)) * orbit)
                context.fill(Path(ellipseIn: CGRect(x: point.x - 2.2, y: point.y - 2.2, width: 4.4, height: 4.4)), with: .color(Theme.ice))
            }
        }

        // Núcleo.
        let coreRadius = radius * (0.20 + 0.07 * energy)
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - coreRadius, y: center.y - coreRadius, width: coreRadius * 2, height: coreRadius * 2)),
            with: .radialGradient(Gradient(colors: [.white.opacity(0.95), color.opacity(0.85), color.opacity(0.05)]),
                                  center: center, startRadius: 0, endRadius: coreRadius)
        )

        // Desconexión: línea de corte.
        if state == .disconnected {
            var slash = Path()
            slash.move(to: CGPoint(x: center.x - radius * 0.25, y: center.y + radius * 0.25))
            slash.addLine(to: CGPoint(x: center.x + radius * 0.25, y: center.y - radius * 0.25))
            context.stroke(slash, with: .color(Theme.amber.opacity(0.9)), lineWidth: 2)
        }
    }
}
