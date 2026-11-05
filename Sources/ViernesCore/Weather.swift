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
