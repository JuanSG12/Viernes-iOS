import Foundation

public enum SensitiveFinding: String, Sendable, Equatable {
    case cardNumber = "número de tarjeta"
    case secretPhrase = "contraseña o clave"
    case apiKey = "clave de API o token"
    case governmentID = "documento de identidad"
}

/// Detecta datos que Viernes NO debe guardar en memoria ni en resúmenes.
/// Es una red de seguridad heurística, no una garantía: se documenta en SECURITY.md.
public enum SensitiveDataRedactor {
    public struct Result: Equatable, Sendable {
        public let findings: [SensitiveFinding]
        public let redacted: String
        public var isSensitive: Bool { !findings.isEmpty }
    }

    public static func scan(_ text: String) -> Result {
        var findings: [SensitiveFinding] = []
        var redacted = text

        // 1. Tarjetas: 13–19 dígitos (con espacios o guiones) que pasan Luhn.
        if let regex = try? NSRegularExpression(pattern: "\\b(?:\\d[ -]?){13,19}\\b") {
            let ns = redacted as NSString
            let matches = regex.matches(in: redacted, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                let candidate = ns.substring(with: match.range)
                let digits = candidate.filter(\.isNumber)
                if (13...19).contains(digits.count), luhnValid(digits) {
                    findings.append(.cardNumber)
                    redacted = (redacted as NSString).replacingCharacters(in: match.range, with: "[tarjeta]")
                }
            }
        }

        // 2. Contraseñas dichas explícitamente.
        let secretPattern = "(?i)\\b(contrase(?:ñ|n)a|password|clave|pin|c[oó]digo de seguridad)(?:\\s+es\\b|\\s*[:=])\\s*\\S+"
        if replace(pattern: secretPattern, in: &redacted, with: "[secreto]") { findings.append(.secretPhrase) }

        // 3. Claves de API / tokens típicos.
        let keyPattern = "\\b(?:sk-[A-Za-z0-9_\\-]{16,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|xox[abprs]-[A-Za-z0-9\\-]{10,}|[A-Fa-f0-9]{40,})\\b"
        if replace(pattern: keyPattern, in: &redacted, with: "[token]") { findings.append(.apiKey) }

        // 3b. Cadenas largas tipo base64 sin espacios (≥ 32 caracteres con mezcla de clases).
        if let regex = try? NSRegularExpression(pattern: "\\b[A-Za-z0-9+/_\\-]{32,}={0,2}") {
            let ns = redacted as NSString
            for match in regex.matches(in: redacted, range: NSRange(location: 0, length: ns.length)).reversed() {
                let candidate = ns.substring(with: match.range)
                let hasUpper = candidate.contains { $0.isUppercase }
                let hasLower = candidate.contains { $0.isLowercase }
                let hasDigit = candidate.contains { $0.isNumber }
                if hasUpper && hasLower && hasDigit {
                    findings.append(.apiKey)
                    redacted = (redacted as NSString).replacingCharacters(in: match.range, with: "[token]")
                }
            }
        }

        // 4. Documentos de identidad dichos explícitamente (cédula, pasaporte, DNI, NIT...).
        let idPattern = "(?i)\\b(c[eé]dula|pasaporte|dni|nit|ssn)\\s*(?:n[uú]mero|no\\.?|#|es|:)?\\s*[\\d\\.\\-]{6,}"
        if replace(pattern: idPattern, in: &redacted, with: "[documento]") { findings.append(.governmentID) }

        var seen = Set<SensitiveFinding>()
        let unique = findings.filter { seen.insert($0).inserted }
        return Result(findings: unique, redacted: redacted)
    }

    public static func luhnValid(_ digits: String) -> Bool {
        var sum = 0
        var alternate = false
        for char in digits.reversed() {
            guard var n = char.wholeNumberValue else { return false }
            if alternate {
                n *= 2
                if n > 9 { n -= 9 }
            }
            sum += n
            alternate.toggle()
        }
        return sum % 10 == 0 && !digits.isEmpty
    }

    private static func replace(pattern: String, in text: inout String, with replacement: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard regex.firstMatch(in: text, range: range) != nil else { return false }
        text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
        return true
    }
}
