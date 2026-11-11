import Foundation

// MARK: Contactos: modelo, permiso y directorio

public enum ContactAccess: Equatable, Sendable {
    case authorized, limited, denied, restricted, notDetermined

    public var canRead: Bool { self == .authorized || self == .limited }

    public var explanation: String {
        switch self {
        case .authorized: return "Viernes puede leer tus contactos."
        case .limited: return "iOS solo comparte con Viernes los contactos que elegiste. Si falta uno, añádelo en Ajustes › Viernes › Contactos."
        case .denied, .restricted: return "Viernes no tiene permiso para leer tus contactos. Actívalo en Ajustes › Viernes › Contactos."
        case .notDetermined: return "Todavía no diste permiso para leer tus contactos."
        }
    }
}

public struct ContactPhone: Equatable, Sendable {
    public var label: String
    public var number: String
    public init(label: String, number: String) {
        self.label = label
        self.number = number
    }
}

public struct ContactCard: Identifiable, Equatable, Sendable {
    public var id: String
    public var givenName: String
    public var familyName: String
    public var nickname: String
    public var organization: String
    public var phones: [ContactPhone]
    public var emails: [String]

    public init(id: String, givenName: String = "", familyName: String = "", nickname: String = "", organization: String = "",
                phones: [ContactPhone] = [], emails: [String] = []) {
        self.id = id
        self.givenName = givenName
        self.familyName = familyName
        self.nickname = nickname
        self.organization = organization
        self.phones = phones
        self.emails = emails
    }

    public var fullName: String { [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ") }
    public var displayName: String {
        if !fullName.isEmpty { return fullName }
        return nickname.isEmpty ? (organization.isEmpty ? "(sin nombre)" : organization) : nickname
    }
}

/// Origen de los contactos. La app lo implementa con `CNContactStore`; las pruebas, con una lista en memoria.
public protocol ContactDirectory: Sendable {
    func access() async -> ContactAccess
    func requestAccess() async -> ContactAccess
    func allContacts() async throws -> [ContactCard]
}

// MARK: Teléfonos

/// Normalización a formato internacional (E.164) con el código de país de la región del perfil. Es una tabla sencilla de 12 países,
/// NO una biblioteca completa de numeración: lo que no encaja devuelve `nil` y el asistente pide el número con prefijo.
public enum PhoneNumber {
    struct Region {
        let callingCode: String
        let lengths: [Int]
        /// El número nacional se marca con un 0 inicial que no forma parte del número internacional.
        let trunkZero: Bool
    }

    static let regions: [String: Region] = [
        "CO": Region(callingCode: "57", lengths: [10], trunkZero: false), "MX": Region(callingCode: "52", lengths: [10], trunkZero: false),
        "ES": Region(callingCode: "34", lengths: [9], trunkZero: false), "AR": Region(callingCode: "54", lengths: [10], trunkZero: true),
        "CL": Region(callingCode: "56", lengths: [9], trunkZero: false), "PE": Region(callingCode: "51", lengths: [9], trunkZero: false),
        "US": Region(callingCode: "1", lengths: [10], trunkZero: false), "BR": Region(callingCode: "55", lengths: [10, 11], trunkZero: true),
        "FR": Region(callingCode: "33", lengths: [9], trunkZero: true), "IT": Region(callingCode: "39", lengths: [9, 10], trunkZero: false),
        "DE": Region(callingCode: "49", lengths: [10, 11], trunkZero: true), "GB": Region(callingCode: "44", lengths: [10], trunkZero: true)
    ]

    public static func e164(_ raw: String, region: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }
        var digits = trimmed.filter { $0.isASCII && $0.isNumber }
        let hasPlus = trimmed.hasPrefix("+")
        let hasDoubleZero = !hasPlus && digits.hasPrefix("00")
        if hasPlus || hasDoubleZero {
            if hasDoubleZero { digits.removeFirst(2) }
            guard (8...15).contains(digits.count) else { return nil }
            return "+" + digits
        }
        guard let rules = regions[region.uppercased()] ?? regions["CO"] else { return nil }
        if rules.trunkZero, digits.hasPrefix("0") { digits.removeFirst() }
        if digits.hasPrefix(rules.callingCode), rules.lengths.contains(digits.count - rules.callingCode.count) { return "+" + digits }
        if rules.lengths.contains(digits.count) { return "+" + rules.callingCode + digits }
        return nil
    }

    /// Para mostrar: «+57 310 555 1234» (agrupa de tres en tres tras el prefijo; no es la forma oficial de cada país).
    public static func display(_ e164: String) -> String {
        let digits = e164.filter { $0.isNumber }
        for length in [3, 2, 1] where digits.count > length + 6 {
            let code = String(digits.prefix(length))
            if regions.values.contains(where: { $0.callingCode == code }) {
                var rest = Substring(digits.dropFirst(length))
                var groups: [String] = []
                while rest.count > 4 {
                    groups.append(String(rest.prefix(3)))
                    rest = rest.dropFirst(3)
                }
                groups.append(String(rest))
                return "+\(code) " + groups.joined(separator: " ")
            }
        }
        return "+" + digits
    }
}

// MARK: Búsqueda aproximada

public struct ContactMatch: Equatable, Sendable {
    public let card: ContactCard
    public let score: Double
    public let reason: String
}

public enum ContactResolution: Equatable, Sendable {
    case notFound
    case unique(ContactMatch)
    case ambiguous([ContactMatch])
}

public struct PhoneOption: Equatable, Sendable {
    public let e164: String
    public let label: String
    public let isMobile: Bool
    /// Para listarlo al asistente (que puede ser un modelo en la nube): solo las 4 últimas cifras, no el número completo.
    public var text: String { "\(label.isEmpty ? "teléfono" : label) terminado en \(e164.suffix(4))" }
}

public enum PhoneChoice: Equatable, Sendable {
    case chosen(PhoneOption)
    case choose([PhoneOption])
    case none
}

/// Resolución central de personas: la usan WhatsApp, SMS, llamadas, correo y la búsqueda de contactos. Pura y comprobable.
public enum ContactResolver {
    static func tokens(_ text: String) -> [String] { TextNormalizer.tokens(text, dropStopwords: false) }

    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var current = [i + 1]
            for (j, right) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let left = Array(a), right = Array(b)
        let longest = max(left.count, right.count)
        return longest == 0 ? 1 : 1 - Double(distance(left, right)) / Double(longest)
    }

    /// Todas las palabras de la consulta coinciden con alguna palabra del campo: exacta (`exact`) o como comienzo.
    private static func covers(_ query: [String], _ field: [String]) -> (all: Bool, exact: Bool) {
        guard !query.isEmpty, !field.isEmpty else { return (false, false) }
        var exact = true
        for word in query {
            if field.contains(word) { continue }
            if field.contains(where: { $0.hasPrefix(word) && word.count >= 2 }) { exact = false; continue }
            return (false, false)
        }
        return (true, exact)
    }

    static func score(_ query: String, _ card: ContactCard) -> (Double, String)? {
        let folded = TextNormalizer.fold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        let words = tokens(query)
        guard !folded.isEmpty, !words.isEmpty else { return nil }
        if TextNormalizer.fold(card.fullName) == folded { return (1.0, "nombre completo") }
        if !card.nickname.isEmpty, TextNormalizer.fold(card.nickname) == folded { return (0.95, "apodo") }
        let nameWords = tokens(card.givenName) + tokens(card.familyName)
        let byName = covers(words, nameWords)
        if byName.all { return (byName.exact ? 0.9 : 0.8, "nombre") }
        let byNickname = covers(words, tokens(card.nickname))
        if byNickname.all { return (byNickname.exact ? 0.85 : 0.7, "apodo") }
        let byOrganization = covers(words, tokens(card.organization))
        if byOrganization.all { return (0.6, "empresa") }
        // Tolerancia a errores de dictado o de escritura («Caren» → «Karen»): cada palabra debe parecerse a alguna del nombre.
        let candidates = nameWords + tokens(card.nickname)
        var total = 0.0
        for word in words {
            guard word.count >= 3 else { return nil }
            let best = candidates.map { similarity(word, $0) }.max() ?? 0
            guard best >= 0.75 else { return nil }
            total += best
        }
        return (0.4 + 0.3 * total / Double(words.count), "parecido")
    }

    public static func rank(_ query: String, in cards: [ContactCard], limit: Int = 8) -> [ContactMatch] {
        let matches = cards.compactMap { card -> ContactMatch? in
            guard let (value, reason) = score(query, card), value >= 0.55 else { return nil }
            return ContactMatch(card: card, score: value, reason: reason)
        }
        let sorted = matches.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.card.displayName != b.card.displayName { return a.card.displayName < b.card.displayName }
            return a.card.id < b.card.id
        }
        return Array(sorted.prefix(limit))
    }

    public static func resolve(_ query: String, in cards: [ContactCard]) -> ContactResolution {
        let ranked = rank(query, in: cards)
        guard let top = ranked.first else { return .notFound }
        let close = ranked.filter { top.score - $0.score < 0.1 }
        return close.count == 1 ? .unique(top) : .ambiguous(Array(close.prefix(5)))
    }

    // MARK: Teléfonos de un contacto

    public static func isMobileLabel(_ label: String) -> Bool {
        let folded = TextNormalizer.fold(label)
        return ["mobile", "movil", "celular", "iphone", "cell", "whatsapp"].contains { folded.contains($0) }
    }

    /// Los teléfonos válidos del contacto en E.164, sin repetidos y con los móviles primero.
    public static func phoneOptions(for card: ContactCard, region: String) -> [PhoneOption] {
        var seen = Set<String>()
        var options: [PhoneOption] = []
        for phone in card.phones {
            guard let number = PhoneNumber.e164(phone.number, region: region), seen.insert(number).inserted else { continue }
            options.append(PhoneOption(e164: number, label: phone.label, isMobile: isMobileLabel(phone.label)))
        }
        return options.filter(\.isMobile) + options.filter { !$0.isMobile }
    }

    public static func choosePhone(for card: ContactCard, region: String) -> PhoneChoice {
        let options = phoneOptions(for: card, region: region)
        guard !options.isEmpty else { return .none }
        let mobiles = options.filter(\.isMobile)
        if mobiles.count == 1 { return .chosen(mobiles[0]) }
        if mobiles.isEmpty, options.count == 1 { return .chosen(options[0]) }
        return .choose(mobiles.count > 1 ? mobiles : options)
    }
}

// MARK: Destinatarios (lo que usan las herramientas)

public enum RecipientKind: Sendable { case phone, email }

public enum RecipientOutcome: Equatable, Sendable {
    /// `value`: teléfono en E.164 o dirección de correo; `detail`: etiqueta («móvil»).
    case resolved(name: String, value: String, detail: String)
    /// Texto para el asistente: qué opciones hay y que debe preguntarle al usuario cuál.
    case needsChoice(String)
    case notFound(String)
    case noValue(String)
    case noAccess(ContactAccess)

    /// Mensaje de fallo para el modelo (nil si se resolvió).
    public var failureText: String? {
        switch self {
        case .resolved: return nil
        case .needsChoice(let text): return text
        case .notFound(let text), .noValue(let text): return text
        case .noAccess(let access):
            return access.explanation + " Dile al usuario cómo activarlo, o pídele el número o la dirección directamente. No inventes ni supongas datos."
        }
    }
}

public enum RecipientResolver {
    /// `digits`: últimas cifras del número que el usuario eligió cuando el contacto tenía varios.
    public static func resolve(_ query: String, kind: RecipientKind, directory: ContactDirectory, region: String,
                               digits: String? = nil) async -> RecipientOutcome {
        var access = await directory.access()
        if access == .notDetermined { access = await directory.requestAccess() }
        guard access.canRead else { return .noAccess(access) }
        let cards: [ContactCard]
        do { cards = try await directory.allContacts() } catch {
            return .notFound("No pude leer los contactos ahora mismo. Pídele al usuario el dato directamente.")
        }
        switch ContactResolver.resolve(query, in: cards) {
        case .notFound:
            let limited = access == .limited ? " (iOS solo comparte con Viernes los contactos que el usuario eligió: puede añadirlo en Ajustes › Viernes › Contactos)" : ""
            return .notFound("No encontré a «\(query)» en los contactos\(limited). Pídele al usuario el nombre completo o el dato directamente; no inventes ni supongas datos.")
        case .ambiguous(let matches):
            let lines = matches.enumerated().map { index, match in
                "\(index + 1)) \(match.card.displayName)" + (match.card.organization.isEmpty || match.card.organization == match.card.displayName ? "" : " (\(match.card.organization))")
            }
            return .needsChoice("Hay varios contactos que coinciden con «\(query)»: \(lines.joined(separator: "; ")). NO elijas: pregúntale al usuario cuál es y vuelve a llamar con el nombre completo de ese contacto.")
        case .unique(let match):
            let card = match.card
            switch kind {
            case .phone:
                switch ContactResolver.choosePhone(for: card, region: region) {
                case .chosen(let option):
                    return .resolved(name: card.displayName, value: option.e164, detail: option.label.isEmpty ? "teléfono" : option.label)
                case .choose(let options):
                    let wanted = (digits ?? "").filter { $0.isASCII && $0.isNumber }
                    if wanted.count >= 3 {
                        let picked = options.filter { $0.e164.hasSuffix(wanted) }
                        if picked.count == 1 { return .resolved(name: card.displayName, value: picked[0].e164, detail: picked[0].label.isEmpty ? "teléfono" : picked[0].label) }
                    }
                    return .needsChoice("\(card.displayName) tiene varios teléfonos: \(options.enumerated().map { "\($0.offset + 1)) \($0.element.text)" }.joined(separator: "; ")). NO elijas: pregúntale al usuario cuál usar (por las últimas cifras) y vuelve a llamar con «contact» = «\(card.displayName)» y las últimas cifras elegidas en «digits».")
                case .none:
                    let raw = card.phones.isEmpty ? "no tiene teléfonos guardados" : "tiene teléfonos que no pude interpretar como válidos (\(card.phones.map(\.number).joined(separator: ", ")))"
                    return .noValue("\(card.displayName) \(raw). Pídele al usuario el número con prefijo internacional; no inventes uno.")
                }
            case .email:
                var seenEmails = Set<String>()
                let emails = card.emails.filter { seenEmails.insert($0.lowercased()).inserted }
                switch emails.count {
                case 0: return .noValue("\(card.displayName) no tiene correos guardados. Pídele la dirección al usuario; no inventes una.")
                case 1: return .resolved(name: card.displayName, value: emails[0], detail: "correo")
                default:
                    return .needsChoice("\(card.displayName) tiene varios correos: \(emails.enumerated().map { "\($0.offset + 1)) \($0.element)" }.joined(separator: "; ")). NO elijas: pregúntale al usuario cuál usar y vuelve a llamar con esa dirección en «to».")
                }
            }
        }
    }
}

// MARK: Enlaces

/// Enlaces para abrir WhatsApp, Mensajes y el marcador. WhatsApp documenta `https://wa.me/<número internacional>?text=<texto codificado>`
/// (el texto aparece precargado; el usuario debe pulsar Enviar). Sin número, `wa.me/?text=` deja elegir el contacto.
public enum MessageLinks {
    public static func encode(_ value: String, keep: String = "") -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~" + keep)
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func digits(_ e164: String?) -> String { (e164 ?? "").filter { $0.isASCII && $0.isNumber } }

    public static func whatsApp(e164: String?, text: String) -> URL? {
        URL(string: "https://wa.me/\(digits(e164))?text=\(encode(text))")
    }

    /// Esquema propio de la app: alternativa si el enlace universal no se pudo abrir.
    public static func whatsAppScheme(e164: String?, text: String) -> URL? {
        let phone = digits(e164)
        return URL(string: "whatsapp://send?" + (phone.isEmpty ? "" : "phone=\(phone)&") + "text=\(encode(text))")
    }

    public static func sms(e164: String?, text: String) -> URL? {
        URL(string: "sms:\(e164.map { encode($0, keep: "+") } ?? "")&body=\(encode(text))")
    }

    public static func tel(e164: String) -> URL? { URL(string: "tel:\(encode(e164, keep: "+"))") }
}
