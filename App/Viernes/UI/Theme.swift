import SwiftUI

/// Sistema de diseño de Viernes: BLACK CHROME / NEURAL ORANGE.
/// Negro profundo, grafito, cromo oscuro y plata; el naranja eléctrico es el único color de energía.
/// Original: no copia ningún diseño de película ni de otras apps de asistentes.
enum Theme {
    // MARK: Materiales base (de más oscuro a más claro)
    static let ink = Color(red: 0.020, green: 0.020, blue: 0.027)          // #050507  fondo
    static let graphite = Color(red: 0.055, green: 0.058, blue: 0.067)     // #0E0F11
    static let carbon = Color(red: 0.086, green: 0.090, blue: 0.102)       // #16171A  superficies
    static let steel = Color(red: 0.190, green: 0.200, blue: 0.230)        // #30333B  bordes
    static let chrome = Color(red: 0.620, green: 0.650, blue: 0.700)       // #9EA6B3
    static let silver = Color(red: 0.900, green: 0.920, blue: 0.950)       // #E6EBF2  reflejos

    // MARK: Energía
    static let accent = Color(red: 1.0, green: 0.42, blue: 0.0)            // #FF6B00  naranja eléctrico
    static let ember = Color(red: 1.0, green: 0.55, blue: 0.12)            // #FF8C1F  brasa
    static let amber = Color(red: 1.0, green: 0.77, blue: 0.24)            // #FFC43D  ámbar incandescente (advertencias)
    static let alert = Color(red: 1.0, green: 0.27, blue: 0.36)            // #FF455C  error

    // MARK: Texto
    static let textPrimary = Color(red: 0.95, green: 0.95, blue: 0.96)
    static let textSecondary = Color(red: 0.60, green: 0.62, blue: 0.67)

    // MARK: Medidas
    enum Space { static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24 }
    enum Radius { static let s: CGFloat = 10, m: CGFloat = 16, l: CGFloat = 24 }

    // MARK: Tipografía (sistema, sin fuentes externas)
    /// Títulos: anchos y firmes.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.expanded)
    }
    static func body(_ size: CGFloat = 15, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func mono(_ size: CGFloat = 11, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: Estados
    static func color(for state: CoreState) -> Color {
        switch state {
        case .idle: return ember
        case .listening: return accent
        case .thinking: return amber
        case .speaking: return accent
        case .error: return alert
        case .disconnected: return chrome
        }
    }

    // MARK: Fondo (estático: cero coste de animación)
    static var background: some View {
        ZStack {
            LinearGradient(colors: [ink, graphite, ink], startPoint: .top, endPoint: .bottom)
            // Reflejo cromado diagonal.
            LinearGradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: silver.opacity(0.055), location: 0.32),
                .init(color: .clear, location: 0.48),
                .init(color: accent.opacity(0.05), location: 0.92)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            // Luz cálida desde abajo a la derecha y destello frío arriba a la izquierda.
            RadialGradient(colors: [accent.opacity(0.17), .clear], center: UnitPoint(x: 0.88, y: 1.0), startRadius: 10, endRadius: 400)
            RadialGradient(colors: [silver.opacity(0.07), .clear], center: UnitPoint(x: 0.08, y: 0.0), startRadius: 10, endRadius: 320)
        }
        .ignoresSafeArea()
    }

    static func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(mono(11))
            .tracking(2.4)
            .foregroundStyle(textSecondary)
    }

    /// Borde con luz de canto: plata arriba a la izquierda, color de energía abajo a la derecha.
    static func rim(_ tint: Color = accent, silverAmount: Double = 0.38) -> LinearGradient {
        LinearGradient(colors: [silver.opacity(silverAmount), steel.opacity(0.35), tint.opacity(0.55)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Superficie metálica oscura con borde de luz. Base de paneles, entradas y tarjetas.
struct ChromeSurface: ViewModifier {
    var tint: Color = Theme.accent
    var radius: CGFloat = Theme.Radius.m

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.carbon.opacity(0.92), Theme.graphite.opacity(0.92)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.rim(tint), lineWidth: 0.8))
    }
}

extension View {
    func chromeSurface(tint: Color = Theme.accent, radius: CGFloat = Theme.Radius.m) -> some View {
        modifier(ChromeSurface(tint: tint, radius: radius))
    }
    func chromeList() -> some View { modifier(ChromeListStyle()) }
}

/// Panel con contenido (avisos, confirmaciones).
struct ChromePanel<Content: View>: View {
    var tint: Color = Theme.accent
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .chromeSurface(tint: tint)
    }
}

/// Botón de texto: cápsula metálica con borde de luz.
struct ChromeButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body(14, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(
                Capsule().fill(LinearGradient(colors: [Theme.carbon, Theme.graphite], startPoint: .top, endPoint: .bottom))
                    .overlay(Capsule().fill(tint.opacity(configuration.isPressed ? 0.26 : 0.08)))
            )
            .overlay(Capsule().strokeBorder(Theme.rim(tint, silverAmount: 0.25), lineWidth: 0.9))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Botón redondo con icono (barra superior y controles).
struct ChromeIconButtonStyle: ButtonStyle {
    var tint: Color = Theme.silver
    var size: CGFloat = 40
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                Circle().fill(RadialGradient(colors: [Theme.carbon, Theme.ink], center: .topLeading, startRadius: 2, endRadius: size))
                    .overlay(Circle().fill(Theme.accent.opacity(configuration.isPressed ? 0.20 : 0)))
            )
            .overlay(Circle().strokeBorder(Theme.rim(Theme.accent, silverAmount: 0.3), lineWidth: 0.8))
    }
}

/// Fondo de lista/formulario coherente con el tema.
struct ChromeListStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .tint(Theme.accent)
            .foregroundStyle(Theme.textPrimary)
            .toolbarBackground(Theme.ink, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

/// Marca compacta: dos órbitas cromadas entrelazadas con un punto de energía. Estática (no consume).
struct ViernesMark: View {
    var size: CGFloat = 34

    var body: some View {
        Canvas { context, canvasSize in
            let c = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let r = min(canvasSize.width, canvasSize.height) / 2 * 0.86
            for (tilt, shade) in [(-0.62, 0.85), (0.62, 0.6)] {
                var path = Path()
                for step in 0...72 {
                    let a = Double(step) / 72 * 2 * .pi
                    let x = cos(a) * r, y = sin(a) * r * 0.46
                    let rx = x * cos(tilt) - y * sin(tilt), ry = x * sin(tilt) + y * cos(tilt)
                    let p = CGPoint(x: c.x + rx, y: c.y + ry)
                    if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                path.closeSubpath()
                context.stroke(path, with: .conicGradient(Gradient(colors: [Theme.silver.opacity(shade), Theme.steel, Theme.chrome, Theme.accent, Theme.steel, Theme.silver.opacity(shade)]), center: c, angle: .degrees(20)),
                               style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round))
            }
            context.fill(Path(ellipseIn: CGRect(x: c.x - 2.2, y: c.y - 2.2, width: 4.4, height: 4.4)), with: .color(Theme.accent))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
