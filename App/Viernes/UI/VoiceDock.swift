import SwiftUI

/// Barras de onda a un lado del micrófono. Se mueven SOLO al escuchar (nivel real del micrófono) o al hablar
/// (pulso real por palabra); en espera quedan quietas y el reloj de animación está en pausa.
struct WaveBars: View {
    let state: CoreState
    let level: Float
    let pulse: Date
    let mirrored: Bool
    let calm: Bool

    @Environment(\.scenePhase) private var scenePhase

    private var active: Bool { state == .listening || state == .speaking }
    private let count = 9

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: scenePhase != .active || !active || calm)) { timeline in
            Canvas { context, size in
                draw(&context, size: size, now: timeline.date)
            }
        }
        .frame(height: 34)
        .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, now: Date) {
        let time: Double = now.timeIntervalSinceReferenceDate
        let since: Double = max(0, now.timeIntervalSince(pulse))
        var amplitude: Double = 0
        if state == .listening { amplitude = 0.15 + Double(level) * 0.95 }
        if state == .speaking { amplitude = 0.2 + 0.8 * exp(-since * 5) }

        let barWidth: CGFloat = 3
        let gap: CGFloat = (size.width - barWidth * CGFloat(count)) / CGFloat(count - 1)
        let tint = Theme.color(for: state)
        for i in 0..<count {
            // i = 0 es la barra más lejana del micrófono; la más cercana es la más alta.
            let closeness: Double = Double(i) / Double(count - 1)
            let envelope: Double = 0.25 + 0.75 * pow(closeness, 1.2)
            let shimmer: Double = 0.55 + 0.45 * abs(sin(time * 7 + Double(i) * 0.9 + (mirrored ? 1.3 : 0)))
            let height: CGFloat = 3 + CGFloat(envelope * (active ? amplitude * shimmer : 0.18) * 28)
            let slot: Int = mirrored ? (count - 1 - i) : i
            let x: CGFloat = CGFloat(slot) * (barWidth + gap)
            let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
            let opacity: Double = (active ? 0.45 : 0.22) + 0.55 * closeness * (active ? 1 : 0.4)
            context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(tint.opacity(opacity)))
        }
    }
}

/// Emblema del micrófono: anillo cromado con luz de energía. Es el botón de voz (id «mic»).
struct MicEmblem: View {
    let state: CoreState
    let icon: String
    let label: String
    let action: () -> Void

    private var tint: Color { Theme.color(for: state) }
    private var active: Bool { state == .listening || state == .speaking || state == .thinking }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(tint.opacity(active ? 0.30 : 0.10)).frame(width: 64, height: 64).blur(radius: 12)
                Circle().fill(RadialGradient(colors: [Theme.carbon, Theme.ink], center: .topLeading, startRadius: 2, endRadius: 64))
                    .frame(width: 60, height: 60)
                Circle().strokeBorder(
                    AngularGradient(colors: [Theme.silver.opacity(0.95), Theme.steel, tint, Theme.steel, Theme.silver.opacity(0.95)], center: .center),
                    lineWidth: 2)
                    .frame(width: 60, height: 60)
                Image(systemName: icon)
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(active ? tint : Theme.silver)
            }
            .frame(width: 66, height: 66)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("mic")
    }
}

/// Cápsula de voz: ondas a ambos lados del micrófono, con luz naranja en el borde inferior.
struct VoiceDock: View {
    @EnvironmentObject var model: AppModel

    private var state: CoreState { model.coreState }
    private var calm: Bool { model.settings.reducedEffects }
    private var live: Bool { state == .listening || state == .speaking }

    var body: some View {
        HStack(spacing: 10) {
            WaveBars(state: state, level: model.audioLevel, pulse: model.speakPulse, mirrored: false, calm: calm)
            MicEmblem(state: state, icon: icon, label: label) { model.micTapped() }
            WaveBars(state: state, level: model.audioLevel, pulse: model.speakPulse, mirrored: true, calm: calm)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(
            Capsule().fill(LinearGradient(colors: [Theme.carbon.opacity(0.95), Theme.ink], startPoint: .top, endPoint: .bottom))
        )
        .overlay(Capsule().strokeBorder(Theme.rim(Theme.color(for: state), silverAmount: 0.3), lineWidth: 0.9))
        .shadow(color: Theme.accent.opacity(live ? 0.35 : 0.10), radius: 16, y: 6)
    }

    private var icon: String {
        switch state {
        case .listening: return "stop.fill"
        case .speaking: return "hand.raised.fill"
        case .thinking: return "xmark"
        default: return "mic"
        }
    }

    private var label: String {
        switch state {
        case .listening: return "Terminar de hablar"
        case .speaking: return "Interrumpir"
        case .thinking: return "Cancelar"
        default: return "Hablar con Viernes"
        }
    }
}
