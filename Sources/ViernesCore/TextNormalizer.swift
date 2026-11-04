import Foundation

/// Normalización de texto en español para búsqueda y comparación.
public enum TextNormalizer {
    /// Palabras vacías frecuentes del español; no aportan a la recuperación de memoria.
    public static let stopwords: Set<String> = [
        "a", "al", "algo", "ante", "con", "como", "cual", "cuando", "de", "del", "desde", "donde",
        "el", "ella", "ellos", "en", "entre", "era", "es", "esa", "ese", "eso", "esta", "este",
        "esto", "fue", "ha", "han", "hay", "la", "las", "le", "les", "lo", "los", "me", "mi", "mis",
        "muy", "no", "nos", "o", "para", "pero", "por", "porque", "que", "se", "ser", "si", "sin",
        "sobre", "son", "su", "sus", "te", "tu", "tus", "un", "una", "uno", "unos", "unas", "y", "ya",
        "yo", "mas", "tambien", "esta", "estan", "estoy", "tengo", "tiene"
    ]

    /// Minúsculas y sin diacríticos: "Canción" -> "cancion".
    public static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
            .lowercased()
    }

    /// Tokens alfanuméricos plegados, sin palabras vacías.
    public static func tokens(_ text: String, dropStopwords: Bool = true) -> [String] {
        let folded = fold(text)
        var result: [String] = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        if dropStopwords { result = result.filter { !stopwords.contains($0) } }
        return result
    }

    /// Raíz muy simple: quita plural (-es/-s) y luego una -e final, para que "proyectos" encuentre "proyecto"
    /// y "mensajes"/"mensaje" o "nombres"/"nombre" converjan en la misma raíz.
    public static func stem(_ token: String) -> String {
        guard token.count > 4 else { return token }
        var result = token
        if result.hasSuffix("es") { result = String(result.dropLast(2)) }
        else if result.hasSuffix("s") { result = String(result.dropLast(1)) }
        if result.count > 4, result.hasSuffix("e") { result = String(result.dropLast(1)) }
        return result
    }

    /// Distancia de Levenshtein (para coincidencias difusas, p. ej. la palabra de activación).
    public static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[b.count]
    }
}
