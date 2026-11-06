import SwiftUI
import ViernesCore

/// Tarjeta nativa de clima. Todos los datos vienen de Open-Meteo (`ToolCard.fields`); si un dato no llegó, no se dibuja.
/// No usa imágenes: símbolos del sistema y degradados.
struct WeatherCard: View {
    let card: ToolCard

    private func field(_ key: String) -> String? { card.fields[key] }

    private var symbol: String { field("symbol") ?? "cloud.fill" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Theme.silver, Theme.accent)
                    .font(.system(size: 46, weight: .regular))
                    .shadow(color: Theme.accent.opacity(0.45), radius: 14)
                    .frame(width: 64)
                VStack(alignment: .leading, spacing: 2) {
                    if let temp = field("temp") {
                        Text("\(temp)°").font(Theme.display(40, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    }
                    if let condition = field("condition") {
                        Text(condition).font(Theme.body(15, weight: .medium)).foregroundStyle(Theme.textPrimary.opacity(0.9))
                    }
                    if let feels = field("feels"), feels != field("temp") {
                        Text("Sensación de \(feels)°").font(Theme.body(12)).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }

            if let place = field("place") {
                Label(place, systemImage: "mappin.and.ellipse")
                    .font(Theme.body(13)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }

            let metrics = metricItems
            if !metrics.isEmpty {
                Divider().overlay(Theme.steel)
                HStack(spacing: 0) {
                    ForEach(metrics.indices, id: \.self) { index in
                        VStack(spacing: 4) {
                            Image(systemName: metrics[index].icon).font(.system(size: 15)).foregroundStyle(Theme.accent)
                            Text(metrics[index].value).font(Theme.body(15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            Text(metrics[index].label).font(Theme.body(11)).foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            if let line = dayLine(prefix: "Hoy", max: field("tmax"), min: field("tmin"), rain: nil) {
                Text(line).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
            }
            if let line = dayLine(prefix: "Mañana", max: field("tomorrowMax"), min: field("tomorrowMin"), rain: field("tomorrowRain")) {
                Text(line).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(16)
        .background(
            ZStack {
                LinearGradient(colors: [Theme.carbon, Theme.ink], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Theme.accent.opacity(0.22), .clear], center: .topTrailing, startRadius: 4, endRadius: 220)
                LinearGradient(colors: [Theme.silver.opacity(0.06), .clear], startPoint: .top, endPoint: .center)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.rim(Theme.accent, silverAmount: 0.4), lineWidth: 0.9))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier("weather-card")
    }

    private var metricItems: [(icon: String, value: String, label: String)] {
        var items: [(String, String, String)] = []
        if let rain = field("rain") { items.append(("drop.fill", "\(rain) %", "Lluvia")) }
        if let wind = field("wind") { items.append(("wind", "\(wind) km/h", "Viento")) }
        if let humidity = field("humidity") { items.append(("humidity.fill", "\(humidity) %", "Humedad")) }
        return items
    }

    private func dayLine(prefix: String, max: String?, min: String?, rain: String?) -> String? {
        guard let max = max, let min = min else { return nil }
        var line = "\(prefix.uppercased())  máx \(max)° · mín \(min)°"
        if let rain = rain { line += " · lluvia \(rain) %" }
        return line
    }

    private var spoken: String {
        var parts = ["Clima"]
        if let place = field("place") { parts.append("en \(place)") }
        if let temp = field("temp") { parts.append("\(temp) grados") }
        if let condition = field("condition") { parts.append(condition) }
        if let rain = field("rain") { parts.append("probabilidad de lluvia \(rain) por ciento") }
        if let wind = field("wind") { parts.append("viento \(wind) kilómetros por hora") }
        if let humidity = field("humidity") { parts.append("humedad \(humidity) por ciento") }
        return parts.joined(separator: ", ")
    }
}
