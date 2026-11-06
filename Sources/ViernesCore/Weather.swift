import Foundation

public struct GeoPlace: Equatable, Sendable {
    public let name: String
    public let region: String?
    public let country: String?
    public let latitude: Double
    public let longitude: Double

    public var label: String {
        let extra = [region, country].compactMap { $0 }.filter { !$0.isEmpty && $0 != name }
        return extra.isEmpty ? name : "\(name) (\(extra.joined(separator: ", ")))"
    }
}

/// Clima con Open-Meteo (https://open-meteo.com): API pública, sin clave ni cuenta. Solo se envía el nombre de la ciudad
/// (geocodificación) y las coordenadas resultantes (pronóstico). Aquí solo hay URLs y formato; la red vive en la app.
public enum WeatherService {
    public static func geocodingURL(city: String) -> URL? {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: city),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "es"),
            URLQueryItem(name: "format", value: "json")
        ]
        return components?.url
    }

    public static func forecastURL(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "2")
        ]
        return components?.url
    }

    public static func parsePlace(_ data: Data) -> GeoPlace? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (object["results"] as? [[String: Any]])?.first,
              let name = first["name"] as? String,
              let latitude = number(first["latitude"]), let longitude = number(first["longitude"]) else { return nil }
        return GeoPlace(name: name, region: first["admin1"] as? String, country: first["country"] as? String,
                        latitude: latitude, longitude: longitude)
    }

    /// Texto pensado para leerse en voz alta: sin símbolos (°C, %, km/h) que el sintetizador lea mal.
    public static func summary(place: GeoPlace, forecast data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = object["current"] as? [String: Any],
              let temperature = number(current["temperature_2m"]) else { return nil }

        var parts: [String] = []
        var now = "Ahora mismo en \(place.label) hay \(rounded(temperature)) grados"
        if let feels = number(current["apparent_temperature"]) { now += ", con sensación de \(rounded(feels))" }
        if let code = number(current["weather_code"]) { now += ", y está \(describe(code: Int(code)))" }
        parts.append(now + ".")

        var extras: [String] = []
        if let humidity = number(current["relative_humidity_2m"]) { extras.append("humedad del \(rounded(humidity)) por ciento") }
        if let wind = number(current["wind_speed_10m"]) { extras.append("viento de \(rounded(wind)) kilómetros por hora") }
        if !extras.isEmpty { parts.append(extras.joined(separator: " y ").capitalizedFirst + ".") }

        if let daily = object["daily"] as? [String: Any] {
            let maxima = (daily["temperature_2m_max"] as? [Any])?.compactMap(number) ?? []
            let minima = (daily["temperature_2m_min"] as? [Any])?.compactMap(number) ?? []
            let rain = (daily["precipitation_probability_max"] as? [Any])?.compactMap(number) ?? []
            for (index, label) in ["Hoy", "Mañana"].enumerated() where index < maxima.count && index < minima.count {
                var line = "\(label), máxima de \(rounded(maxima[index])) y mínima de \(rounded(minima[index])) grados"
                if index < rain.count { line += ", con \(rounded(rain[index])) por ciento de probabilidad de lluvia" }
                parts.append(line + ".")
            }
        }
        return parts.joined(separator: " ")
    }

    /// Datos para la tarjeta de clima (todo textos ya formateados). Solo contiene lo que Open-Meteo devolvió:
    /// si un dato falta, su campo no existe y la tarjeta no lo muestra.
    public static func card(place: GeoPlace, forecast data: Data) -> ToolCard? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = object["current"] as? [String: Any],
              let temperature = number(current["temperature_2m"]) else { return nil }
        var fields: [String: String] = ["place": place.label, "city": place.name, "temp": String(rounded(temperature))]
        if let feels = number(current["apparent_temperature"]) { fields["feels"] = String(rounded(feels)) }
        if let code = number(current["weather_code"]) {
            fields["code"] = String(Int(code))
            fields["condition"] = conditionTitle(code: Int(code))
            fields["symbol"] = symbolName(code: Int(code))
        }
        if let humidity = number(current["relative_humidity_2m"]) { fields["humidity"] = String(rounded(humidity)) }
        if let wind = number(current["wind_speed_10m"]) { fields["wind"] = String(rounded(wind)) }
        if let daily = object["daily"] as? [String: Any] {
            let maxima = (daily["temperature_2m_max"] as? [Any])?.compactMap(number) ?? []
            let minima = (daily["temperature_2m_min"] as? [Any])?.compactMap(number) ?? []
            let rain = (daily["precipitation_probability_max"] as? [Any])?.compactMap(number) ?? []
            if let value = maxima.first { fields["tmax"] = String(rounded(value)) }
            if let value = minima.first { fields["tmin"] = String(rounded(value)) }
            if let value = rain.first { fields["rain"] = String(rounded(value)) }
            if maxima.count > 1 { fields["tomorrowMax"] = String(rounded(maxima[1])) }
            if minima.count > 1 { fields["tomorrowMin"] = String(rounded(minima[1])) }
            if rain.count > 1 { fields["tomorrowRain"] = String(rounded(rain[1])) }
        }
        return ToolCard(kind: .weather, fields: fields)
    }

    /// Título corto de la condición para la tarjeta.
    public static func conditionTitle(code: Int) -> String {
        switch code {
        case 0: return "Despejado"
        case 1: return "Mayormente despejado"
        case 2: return "Parcialmente nublado"
        case 3: return "Nublado"
        case 45, 48: return "Niebla"
        case 51, 53, 55: return "Llovizna"
        case 56, 57: return "Llovizna helada"
        case 61: return "Lluvia ligera"
        case 63: return "Lluvia moderada"
        case 65: return "Lluvia fuerte"
        case 66, 67: return "Lluvia helada"
        case 71, 73, 75, 77: return "Nieve"
        case 80, 81: return "Chubascos"
        case 82: return "Chubascos fuertes"
        case 85, 86: return "Chubascos de nieve"
        case 95: return "Tormenta eléctrica"
        case 96, 99: return "Tormenta con granizo"
        default: return "Condiciones variables"
        }
    }

    /// Nombre de símbolo SF para la condición (la UI lo dibuja con símbolos del sistema, no con imágenes).
    public static func symbolName(code: Int) -> String {
        switch code {
        case 0: return "sun.max.fill"
        case 1: return "sun.max"
        case 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67: return "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 80, 81, 82: return "cloud.heavyrain.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    /// Códigos WMO que usa Open-Meteo.
    static func describe(code: Int) -> String {
        switch code {
        case 0: return "despejado"
        case 1: return "mayormente despejado"
        case 2: return "parcialmente nublado"
        case 3: return "nublado"
        case 45, 48: return "con niebla"
        case 51, 53, 55: return "con llovizna"
        case 56, 57: return "con llovizna helada"
        case 61: return "con lluvia ligera"
        case 63: return "con lluvia moderada"
        case 65: return "con lluvia fuerte"
        case 66, 67: return "con lluvia helada"
        case 71, 73, 75, 77: return "con nieve"
        case 80, 81: return "con chubascos"
        case 82: return "con chubascos fuertes"
        case 85, 86: return "con chubascos de nieve"
        case 95: return "con tormenta eléctrica"
        case 96, 99: return "con tormenta y granizo"
        default: return "con condiciones variables"
        }
    }

    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
    private static func rounded(_ value: Double) -> Int { Int(value.rounded()) }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
