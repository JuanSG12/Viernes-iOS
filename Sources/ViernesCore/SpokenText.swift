import Foundation

/// Convierte lo que se DICE en lo que se quiso ESCRIBIR. Hoy: direcciones de correo dictadas
/// («kisameyguy arroba gmail punto com» → «kisameyguy@gmail.com»). Puro y comprobable.
public enum SpokenText {
    private static let trailingPunctuation = CharacterSet(charactersIn: ",.;:!?¡¿\"'()<>")

    private static func strip(_ token: String) -> String {
        token.trimmingCharacters(in: trailingPunctuation)
    }

    private static func isWordlike(_ token: String) -> Bool {
        let cleaned = strip(token)
        return !cleaned.isEmpty && cleaned.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }

    private static func isDot(_ token: String) -> Bool {
        let folded = TextNormalizer.fold(token)
        return folded == "punto" || folded == "."
    }

    /// Sustituye, dentro de un texto, cada «<usuario> arroba <dominio> punto <extensión>» por la dirección escrita.
    /// Sin la palabra «arroba» (o un «@» suelto) no toca nada, así que una frase normal con «punto» queda igual.
    public static func normalizeEmails(in text: String) -> String {
        var words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var changed = false
        var index = 0
        while index < words.count {
            let isAt = TextNormalizer.fold(strip(words[index])) == "arroba" || words[index] == "@"
            guard isAt, index >= 1, index + 1 < words.count, isWordlike(words[index - 1]), isWordlike(words[index + 1]) else {
                index += 1
                continue
            }

            // Parte local: la palabra anterior, más «punto», «guion» o «guion bajo» con la palabra que los precede.
            var local = strip(words[index - 1])
            var start = index - 1
            while start >= 2 {
                let previous = TextNormalizer.fold(words[start - 1])
                if isDot(words[start - 1]), isWordlike(words[start - 2]) {
                    local = strip(words[start - 2]) + "." + local
                    start -= 2
                } else if previous == "bajo", start >= 3, TextNormalizer.fold(words[start - 2]) == "guion", isWordlike(words[start - 3]) {
                    local = strip(words[start - 3]) + "_" + local
                    start -= 3
                } else if previous == "guion", isWordlike(words[start - 2]) {
                    local = strip(words[start - 2]) + "-" + local
                    start -= 2
                } else {
                    break
                }
            }

            // Dominio: palabra, y mientras haya «punto» + palabra, otra parte.
            var domain = strip(words[index + 1])
            var end = index + 1
            while end + 2 < words.count, isDot(words[end + 1]), isWordlike(words[end + 2]) {
                domain += "." + strip(words[end + 2])
                end += 2
            }
            guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else {
                index += 1
                continue
            }

            let address = (local + "@" + domain).lowercased()
            words.replaceSubrange(start...end, with: [address])
            changed = true
            index = start + 1
        }
        return changed ? words.joined(separator: " ") : text
    }

    /// Deja un argumento «to» como dirección limpia: dictada o con espacios de más, en minúsculas y sin signos alrededor.
    /// No valida: eso lo hace `ContactFormat.isValidEmail`.
    public static func cleanEmailAddress(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("mailto:") { text = String(text.dropFirst("mailto:".count)) }
        text = normalizeEmails(in: text)
        guard text.contains("@") else { return text }
        text = String(text.filter { !$0.isWhitespace })
        text = text.trimmingCharacters(in: trailingPunctuation)
        return text.lowercased()
    }
}
