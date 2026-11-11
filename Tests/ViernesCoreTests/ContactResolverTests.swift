import XCTest
@testable import ViernesCore

final class FakeDirectory: ContactDirectory, @unchecked Sendable {
    var state: ContactAccess
    var afterRequest: ContactAccess
    var cards: [ContactCard]
    private(set) var requests = 0
    init(state: ContactAccess = .authorized, afterRequest: ContactAccess = .authorized, cards: [ContactCard]) {
        self.state = state
        self.afterRequest = afterRequest
        self.cards = cards
    }
    func access() async -> ContactAccess { state }
    func requestAccess() async -> ContactAccess {
        requests += 1
        state = afterRequest
        return state
    }
    func allContacts() async throws -> [ContactCard] { cards }
}

final class PhoneNumberTests: XCTestCase {
    func testNationalNumbersGetTheRegionCountryCode() {
        XCTAssertEqual(PhoneNumber.e164("310 555 1234", region: "CO"), "+573105551234")
        XCTAssertEqual(PhoneNumber.e164("(310) 555-1234", region: "CO"), "+573105551234")
        XCTAssertEqual(PhoneNumber.e164("+57 310 555 1234", region: "CO"), "+573105551234")
        XCTAssertEqual(PhoneNumber.e164("0057 310 555 1234", region: "CO"), "+573105551234")
        XCTAssertEqual(PhoneNumber.e164("573105551234", region: "CO"), "+573105551234", "Ya trae el código de país")
        XCTAssertEqual(PhoneNumber.e164("55 1234 5678", region: "MX"), "+525512345678")
        XCTAssertEqual(PhoneNumber.e164("612 345 678", region: "ES"), "+34612345678")
        XCTAssertEqual(PhoneNumber.e164("06 12 34 56 78", region: "FR"), "+33612345678", "El 0 inicial nacional se quita")
        XCTAssertEqual(PhoneNumber.e164("(415) 555-2671", region: "US"), "+14155552671")
        XCTAssertEqual(PhoneNumber.e164("14155552671", region: "US"), "+14155552671")
        XCTAssertEqual(PhoneNumber.e164("310 555 1234", region: "ZZ"), "+573105551234", "Región desconocida: se usa Colombia")
    }

    func testInvalidNumbersAreRejectedInsteadOfGuessed() {
        for bad in ["12345", "abc", "310 555 1234 ext 5", "", "+12", "3105551"] {
            XCTAssertNil(PhoneNumber.e164(bad, region: "CO"), bad)
        }
        XCTAssertEqual(PhoneNumber.e164("+44 7911 123456", region: "CO"), "+447911123456", "Con «+» se respeta el prefijo dado")
    }

    func testDisplayGroupsTheDigits() {
        XCTAssertEqual(PhoneNumber.display("+573105551234"), "+57 310 555 1234")
        XCTAssertEqual(PhoneNumber.display("+34612345678"), "+34 612 345 678")
    }
}

final class ContactResolverTests: XCTestCase {
    private let karenG = ContactCard(id: "1", givenName: "Karen", familyName: "Gómez",
                                     phones: [ContactPhone(label: "casa", number: "601 234 5678"), ContactPhone(label: "móvil", number: "310 555 1234")],
                                     emails: ["karen@example.com"])
    private let karenR = ContactCard(id: "2", givenName: "Karen", familyName: "Ruiz", phones: [ContactPhone(label: "móvil", number: "320 111 2222")])
    private let carlos = ContactCard(id: "3", givenName: "Carlos", familyName: "Pérez", nickname: "Jefe", organization: "Industrias Sur",
                                     phones: [ContactPhone(label: "trabajo", number: "+57 601 999 8888")])
    private let ana = ContactCard(id: "4", givenName: "Ana", organization: "ACME", phones: [ContactPhone(label: "iPhone", number: "300 000 0001")])
    private let maria = ContactCard(id: "5", givenName: "María José", familyName: "Cruz")

    private var all: [ContactCard] { [karenG, karenR, carlos, ana, maria] }

    func testAFirstNameSharedByTwoPeopleIsAmbiguousAndAFullNameIsNot() {
        guard case .ambiguous(let matches) = ContactResolver.resolve("Karen", in: all) else { return XCTFail("Debía ser ambiguo") }
        XCTAssertEqual(Set(matches.map(\.card.id)), ["1", "2"])
        guard case .unique(let match) = ContactResolver.resolve("Karen Gómez", in: all) else { return XCTFail("Debía ser único") }
        XCTAssertEqual(match.card.id, "1")
        guard case .ambiguous = ContactResolver.resolve("Kar", in: all) else { return XCTFail("Un comienzo común es ambiguo") }
    }

    func testNicknameOrganizationAccentsAndPrefixesFindTheRightPerson() {
        func id(_ query: String) -> String? {
            if case .unique(let match) = ContactResolver.resolve(query, in: all) { return match.card.id }
            return nil
        }
        XCTAssertEqual(id("jefe"), "3")
        XCTAssertEqual(id("acme"), "4")
        XCTAssertEqual(id("perez"), "3", "Sin acentos")
        XCTAssertEqual(id("Pérez"), "3")
        XCTAssertEqual(id("maria"), "5")
        XCTAssertEqual(id("maría josé cruz"), "5")
    }

    func testDictationMistakesStillFindThePerson() {
        guard case .unique(let match) = ContactResolver.resolve("Caren Gomez", in: all) else { return XCTFail("Caren Gomez debía encontrar a Karen Gómez") }
        XCTAssertEqual(match.card.id, "1")
        XCTAssertEqual(match.reason, "parecido")
        XCTAssertEqual(ContactResolver.resolve("Zacarias", in: all), .notFound)
        XCTAssertEqual(ContactResolver.resolve("", in: all), .notFound)
    }

    func testRankingIsDeterministic() {
        let first = ContactResolver.rank("Karen", in: all).map(\.card.id)
        for _ in 0..<20 { XCTAssertEqual(ContactResolver.rank("Karen", in: all.shuffled()).map(\.card.id), first) }
    }

    func testPhoneChoicePrefersMobileAndNeverGuessesBetweenSeveral() {
        guard case .chosen(let option) = ContactResolver.choosePhone(for: karenG, region: "CO") else { return XCTFail("Debía elegir el móvil") }
        XCTAssertEqual(option.e164, "+573105551234")
        XCTAssertTrue(option.isMobile)
        guard case .chosen(let only) = ContactResolver.choosePhone(for: carlos, region: "CO") else { return XCTFail("Un solo número se usa") }
        XCTAssertEqual(only.e164, "+576019998888")

        let twoMobiles = ContactCard(id: "9", givenName: "Luis", phones: [ContactPhone(label: "móvil", number: "310 111 1111"), ContactPhone(label: "celular", number: "311 222 2222")])
        guard case .choose(let options) = ContactResolver.choosePhone(for: twoMobiles, region: "CO") else { return XCTFail("Dos móviles: se pregunta") }
        XCTAssertEqual(options.count, 2)

        let twoOthers = ContactCard(id: "8", givenName: "Eva", phones: [ContactPhone(label: "casa", number: "601 111 1111"), ContactPhone(label: "trabajo", number: "601 222 2222")])
        guard case .choose = ContactResolver.choosePhone(for: twoOthers, region: "CO") else { return XCTFail("Dos fijos: se pregunta") }

        let bad = ContactCard(id: "7", givenName: "Pia", phones: [ContactPhone(label: "móvil", number: "123")])
        XCTAssertEqual(ContactResolver.choosePhone(for: bad, region: "CO"), .none)
        let duplicated = ContactCard(id: "6", givenName: "Dup", phones: [ContactPhone(label: "móvil", number: "310 555 1234"), ContactPhone(label: "iPhone", number: "+57 (310) 555-1234")])
        guard case .chosen = ContactResolver.choosePhone(for: duplicated, region: "CO") else { return XCTFail("El mismo número dos veces es uno solo") }
    }
}

final class RecipientResolverTests: XCTestCase {
    private let karenG = ContactCard(id: "1", givenName: "Karen", familyName: "Gómez",
                                     phones: [ContactPhone(label: "móvil", number: "310 555 1234")], emails: ["karen@example.com"])
    private let karenR = ContactCard(id: "2", givenName: "Karen", familyName: "Ruiz", phones: [ContactPhone(label: "móvil", number: "320 111 2222")],
                                     emails: ["kr@example.com", "karen.ruiz@work.com"])
    private let luis = ContactCard(id: "3", givenName: "Luis", familyName: "Mora",
                                   phones: [ContactPhone(label: "móvil", number: "310 111 4567"), ContactPhone(label: "celular", number: "311 222 8901")])

    func testUniquePersonResolvesToAnInternationalNumber() async {
        let outcome = await RecipientResolver.resolve("Karen Gómez", kind: .phone, directory: FakeDirectory(cards: [karenG, karenR]), region: "CO")
        XCTAssertEqual(outcome, .resolved(name: "Karen Gómez", value: "+573105551234", detail: "móvil"))
    }

    func testAmbiguousPeopleAreListedWithoutPhoneNumbers() async throws {
        let outcome = await RecipientResolver.resolve("Karen", kind: .phone, directory: FakeDirectory(cards: [karenG, karenR]), region: "CO")
        guard case .needsChoice(let text) = outcome else { return XCTFail("Debía pedir elegir: \(outcome)") }
        XCTAssertTrue(text.contains("Karen Gómez") && text.contains("Karen Ruiz") && text.contains("NO elijas"))
        XCTAssertFalse(text.contains("3105551234") || text.contains("3201112222"), "El texto no lleva números completos")
    }

    func testSeveralNumbersAskWhichOneAndTheLastDigitsPickIt() async {
        let directory = FakeDirectory(cards: [luis])
        let asked = await RecipientResolver.resolve("Luis", kind: .phone, directory: directory, region: "CO")
        guard case .needsChoice(let text) = asked else { return XCTFail("Debía preguntar: \(asked)") }
        XCTAssertTrue(text.contains("terminado en 4567") && text.contains("terminado en 8901"))
        XCTAssertFalse(text.contains("3101114567"))
        let picked = await RecipientResolver.resolve("Luis", kind: .phone, directory: directory, region: "CO", digits: "8901")
        XCTAssertEqual(picked, .resolved(name: "Luis Mora", value: "+573112228901", detail: "celular"))
        let vague = await RecipientResolver.resolve("Luis", kind: .phone, directory: directory, region: "CO", digits: "11")
        guard case .needsChoice = vague else { return XCTFail("Dos cifras no bastan para elegir") }
    }

    func testPermissionStatesAreHonest() async {
        let denied = FakeDirectory(state: .denied, cards: [karenG])
        let outcome = await RecipientResolver.resolve("Karen", kind: .phone, directory: denied, region: "CO")
        XCTAssertEqual(outcome, .noAccess(.denied))
        XCTAssertTrue(outcome.failureText?.contains("Ajustes") ?? false)
        XCTAssertEqual(denied.requests, 0, "Un permiso denegado no se vuelve a pedir")

        let asking = FakeDirectory(state: .notDetermined, afterRequest: .authorized, cards: [karenG])
        let granted = await RecipientResolver.resolve("Karen", kind: .phone, directory: asking, region: "CO")
        XCTAssertEqual(asking.requests, 1)
        guard case .resolved = granted else { return XCTFail("Tras conceder el permiso debía resolver") }

        let refused = FakeDirectory(state: .notDetermined, afterRequest: .denied, cards: [karenG])
        let none = await RecipientResolver.resolve("Karen", kind: .phone, directory: refused, region: "CO")
        XCTAssertEqual(none, .noAccess(.denied))

        let limited = FakeDirectory(state: .limited, cards: [karenG])
        let missing = await RecipientResolver.resolve("Zacarías", kind: .phone, directory: limited, region: "CO")
        guard case .notFound(let text) = missing else { return XCTFail("Debía decir que no lo encontró") }
        XCTAssertTrue(text.contains("eligió") && text.contains("no inventes"), text)
    }

    func testEmailResolutionAndMissingData() async {
        let one = await RecipientResolver.resolve("Karen Gómez", kind: .email, directory: FakeDirectory(cards: [karenG, karenR]), region: "CO")
        XCTAssertEqual(one, .resolved(name: "Karen Gómez", value: "karen@example.com", detail: "correo"))
        let many = await RecipientResolver.resolve("Karen Ruiz", kind: .email, directory: FakeDirectory(cards: [karenG, karenR]), region: "CO")
        guard case .needsChoice(let text) = many else { return XCTFail("Dos correos: se pregunta") }
        XCTAssertTrue(text.contains("kr@example.com") && text.contains("karen.ruiz@work.com"))
        let nothing = ContactCard(id: "4", givenName: "Sin", familyName: "Datos")
        let empty = await RecipientResolver.resolve("Sin Datos", kind: .email, directory: FakeDirectory(cards: [nothing]), region: "CO")
        guard case .noValue(let message) = empty else { return XCTFail("Sin correo guardado") }
        XCTAssertTrue(message.contains("no inventes"))
        let noPhone = await RecipientResolver.resolve("Sin Datos", kind: .phone, directory: FakeDirectory(cards: [nothing]), region: "CO")
        guard case .noValue = noPhone else { return XCTFail("Sin teléfono guardado") }
    }
}

final class MessageLinkTests: XCTestCase {
    func testWhatsAppUsesTheDocumentedFormatWithAnInternationalNumber() {
        XCTAssertEqual(MessageLinks.whatsApp(e164: "+573105551234", text: "llego en veinte minutos")?.absoluteString,
                       "https://wa.me/573105551234?text=llego%20en%20veinte%20minutos")
        XCTAssertEqual(MessageLinks.whatsApp(e164: nil, text: "hola")?.absoluteString, "https://wa.me/?text=hola", "Sin número deja elegir el contacto")
        XCTAssertEqual(MessageLinks.whatsAppScheme(e164: "+573105551234", text: "hola")?.absoluteString, "whatsapp://send?phone=573105551234&text=hola")
    }

    func testTheTextCannotInjectParameters() {
        let url = MessageLinks.whatsApp(e164: "+573105551234", text: "a&phone=1#b?é 😀")?.absoluteString ?? ""
        XCTAssertTrue(url.hasPrefix("https://wa.me/573105551234?text="))
        XCTAssertEqual(url.components(separatedBy: "&").count, 1, "Ningún & sin codificar")
        XCTAssertEqual(url.components(separatedBy: "#").count, 1)
        XCTAssertEqual(url.components(separatedBy: "?").count, 2)
        XCTAssertTrue(url.contains("%26phone%3D1%23b%3F%C3%A9%20%F0%9F%98%80"), url)
    }

    func testSmsAndPhoneLinks() {
        XCTAssertEqual(MessageLinks.sms(e164: "+573105551234", text: "hola mundo")?.absoluteString, "sms:+573105551234&body=hola%20mundo")
        XCTAssertEqual(MessageLinks.tel(e164: "+573105551234")?.absoluteString, "tel:+573105551234")
    }

    func testMessagingToolsAcceptANameAndRejectANameAsAPhone() throws {
        let byName = try ToolValidator.validate(ToolCall(name: "compose_message", args: ["body": "Llego en veinte minutos", "contact": "Karen", "app": "WhatsApp"]))
        XCTAssertEqual(byName.args["contact"], "Karen")
        XCTAssertEqual(byName.args["app"], "whatsapp")
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "compose_message", args: ["body": "x", "to": "Karen"])))
        XCTAssertNoThrow(try ToolValidator.validate(ToolCall(name: "call_phone", args: ["contact": "Karen", "digits": "1234"])))
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "call_phone", args: [:])))
        XCTAssertNoThrow(try ToolValidator.validate(ToolCall(name: "compose_email", args: ["body": "Hola", "contact": "Karen"])))
    }
}
