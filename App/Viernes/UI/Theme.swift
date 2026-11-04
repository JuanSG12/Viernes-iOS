import SwiftUI

/// Identidad visual: azul profundo, cian eléctrico, vidrio translúcido. Original; sin copiar ningún diseño de película.
enum Theme {
    static let abyss = Color(red: 0.008, green: 0.024, blue: 0.059)       // #02060F
    static let deep = Color(red: 0.016, green: 0.082, blue: 0.169)        // #04152B
    static let blue = Color(red: 0.04, green: 0.30, blue: 0.62)
    static let cyan = Color(red: 0.0, green: 0.90, blue: 1.0)             // cian eléctrico
    static let ice = Color(red: 0.62, green: 0.97, blue: 1.0)
    static let amber = Color(red: 1.0, green: 0.69, blue: 0.13)
    static let alert = Color(red: 1.0, green: 0.30, blue: 0.43)
    static let textPrimary = Color(red: 0.86, green: 0.97, blue: 1.0)
    static let textSecondary = Color(red: 0.55, green: 0.75, blue: 0.85)

    static func color(for state: CoreState) -> Color {
        switch state {
        case .idle: return cyan
        case .listening: return ice
        case .thinking: return Color(red: 0.45, green: 0.55, blue: 1.0)
        case .speaking: return cyan
        case .error: return alert
        case .disconnected: return amber
        }
    }

    static var background: some View {
        ZStack {
            LinearGradient(colors: [abyss, deep, abyss], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [blue.opacity(0.35), .clear], center: .center, startRadius: 10, endRadius: 420)
        }
        .ignoresSafeArea()
    }

    static func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .tracking(2.2)
            .foregroundStyle(textSecondary)
    }
}

/// Panel de vidrio con borde luminoso.
struct GlassPanel<Content: View>: View {
    var tint: Color = Theme.cyan
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .background(Theme.deep.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [tint.opacity(0.65), tint.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
            )
    }
}

struct HoloButtonStyle: ButtonStyle {
    var tint: Color = Theme.cyan
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(tint.opacity(configuration.isPressed ? 0.28 : 0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.6), lineWidth: 0.8))
    }
}

/// Fondo de lista/formulario coherente con el tema.
struct HoloListStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .tint(Theme.cyan)
            .foregroundStyle(Theme.textPrimary)
            .toolbarBackground(Theme.abyss, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

extension View {
    func holoList() -> some View { modifier(HoloListStyle()) }
}
