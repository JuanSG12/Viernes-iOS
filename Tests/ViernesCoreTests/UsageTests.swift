import XCTest
@testable import ViernesCore

final class UsageTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15

    private func openAI(budget: Double? = 10, withPrice: Bool = true) -> UsageSettings {
        var settings = UsageSettings(monthlyBudgetUSD: budget)
        if withPrice { settings.setPrice(PriceEntry(providerID: "openai", model: "gpt-4o-mini", inputPerMillionUSD: 1, outputPerMillionUSD: 4)) }
        return settings
    }

    func testCostComesOnlyFromTheUsersPrices() {
        let price = PriceEntry(providerID: "openai", model: "m", inputPerMillionUSD: 2, outputPerMillionUSD: 8)
        XCTAssertEqual(UsageCost.cost(TokenUsage(input: 500_000, output: 250_000), price: price) ?? -1, 3.0, accuracy: 1e-9)
        XCTAssertNil(UsageCost.cost(TokenUsage(input: 1, output: 1), price: nil), "Sin tarifa no hay costo inventado")
        XCTAssertEqual(UsageEstimator.tokens(forCharacters: 0), 0)
        XCTAssertEqual(UsageEstimator.tokens(forCharacters: 1), 1)
        XCTAssertEqual(UsageEstimator.tokens(forCharacters: 400), 100)
        XCTAssertEqual(UsageCost.format(12.5), "US$ 12,50")
        XCTAssertEqual(UsageCost.format(0.004), "< US$ 0,01")
    }

    func testGateAllowsWhenThereIsNoBudgetOrTheProviderIsFree() {
        let none = UsageGate.check(providerID: "openai", model: "gpt-4o-mini", settings: openAI(budget: nil), records: [], now: now)
        XCTAssertEqual(none, .allow)
        let free = UsageGate.check(providerID: "groq", model: "x", settings: openAI(budget: 5, withPrice: false), records: [], now: now)
        XCTAssertEqual(free, .allow, "Groq no es de pago por defecto: no se bloquea ni pide tarifa")
    }

    func testUnauthorizedProvidersReceiveNothing() {
        var settings = openAI()
        settings.setPolicy(ProviderPolicy(providerID: "groq", authorized: false, paid: false))
        guard case .block(let reason) = UsageGate.check(providerID: "groq", model: "x", settings: settings, records: [], now: now) else {
            return XCTFail("Debía bloquear")
        }
        XCTAssertTrue(reason.contains("no está autorizado") && reason.contains("no cambio de proveedor"), reason)
    }

    func testAPaidProviderWithABudgetNeedsAPrice() {
        guard case .block(let reason) = UsageGate.check(providerID: "openai", model: "gpt-4o-mini", settings: openAI(withPrice: false), records: [], now: now) else {
            return XCTFail("Sin tarifa y con presupuesto debe bloquear")
        }
        XCTAssertTrue(reason.contains("falta la tarifa"), reason)
    }

    func testBudgetWarnsAtTheThresholdAndBlocksAtTheLimit() {
        let settings = openAI(budget: 10)
        func record(_ cost: Double, at when: Date) -> UsageRecord {
            UsageRecord(date: when, providerID: "openai", model: "gpt-4o-mini", input: 1, output: 1, costUSD: cost)
        }
        XCTAssertEqual(UsageGate.check(providerID: "openai", model: "gpt-4o-mini", settings: settings, records: [record(5, at: now)], now: now), .allow)
        guard case .warn(let warning) = UsageGate.check(providerID: "openai", model: "gpt-4o-mini", settings: settings, records: [record(8.5, at: now)], now: now) else {
            return XCTFail("Al 85 % debía avisar")
        }
        XCTAssertTrue(warning.contains("US$ 8,50") && warning.contains("US$ 10,00"), warning)
        guard case .block(let reason) = UsageGate.check(providerID: "openai", model: "gpt-4o-mini", settings: settings,
                                                        records: [record(6, at: now), record(4, at: now)], now: now) else {
            return XCTFail("Al llegar al límite debía bloquear")
        }
        XCTAssertTrue(reason.contains("Alcanzaste el presupuesto") && reason.contains("no envié nada") && reason.contains("no cambio de proveedor"), reason)
    }

    func testOnlyThisMonthAndOnlyPaidProvidersCount() {
        var settings = openAI(budget: 10)
        settings.setPolicy(ProviderPolicy(providerID: "groq", authorized: true, paid: false))
        let january = date(2027, 1, 20), december = date(2026, 12, 20)
        let records = [
            UsageRecord(date: december, providerID: "openai", model: "m", input: 1, output: 1, costUSD: 50),
            UsageRecord(date: january, providerID: "groq", model: "m", input: 1, output: 1, costUSD: 50),
            UsageRecord(date: january, providerID: "openai", model: "m", input: 1, output: 1, costUSD: 2),
            UsageRecord(date: january, providerID: "openai", model: "m", input: 1, output: 1, costUSD: nil)
        ]
        let spent = UsageGate.paidSpend(records: records, settings: settings, now: date(2027, 1, 25), calendar: calendar)
        XCTAssertEqual(spent, 2, accuracy: 1e-9, "Ni el mes pasado, ni un proveedor gratuito, ni lo que no tiene costo calculado")
        XCTAssertEqual(UsageGate.check(providerID: "openai", model: "gpt-4o-mini", settings: settings, records: records, now: date(2027, 2, 1), calendar: calendar), .allow,
                       "Al cambiar de mes el presupuesto vuelve a empezar")
    }

    func testSummaryAndPruning() {
        let january = date(2027, 1, 10)
        let records = [
            UsageRecord(date: january, providerID: "openai", model: "a", input: 100, output: 50, costUSD: 0.5),
            UsageRecord(date: january, providerID: "openai", model: "b", input: 10, output: 5, isEstimate: true, costUSD: nil),
            UsageRecord(date: january, providerID: "groq", model: "c", input: 1, output: 1, costUSD: nil),
            UsageRecord(date: date(2026, 11, 1), providerID: "groq", model: "c", input: 9, output: 9)
        ]
        let summary = UsageSummary.month(records: records, now: date(2027, 1, 20), calendar: calendar)
        XCTAssertEqual(summary.map(\.providerID), ["openai", "groq"])
        XCTAssertEqual(summary[0].requests, 2)
        XCTAssertEqual(summary[0].input, 110)
        XCTAssertEqual(summary[0].costUSD, 0.5, accuracy: 1e-9)
        XCTAssertTrue(summary[0].missingPrice && summary[0].anyEstimate)

        let old = UsageRecord(date: date(2025, 1, 1), providerID: "groq", model: "c", input: 1, output: 1)
        XCTAssertEqual(UsageSummary.pruned([old] + records, now: date(2027, 1, 20), calendar: calendar).count, 4, "Se descarta lo anterior a 13 meses")
        XCTAssertEqual(UsageSummary.pruned(records, now: date(2027, 1, 20), calendar: calendar, maxRecords: 2).count, 2)
    }

    func testSettingsAreSanitizedAndOlderSettingsStillLoad() throws {
        var settings = UsageSettings(monthlyBudgetUSD: -5, alertFraction: 7)
        settings.policies = [ProviderPolicy(providerID: "desconocido", paid: true), ProviderPolicy(providerID: "groq", paid: true), ProviderPolicy(providerID: "groq", paid: false)]
        settings.prices = [PriceEntry(providerID: "openai", model: "ok", inputPerMillionUSD: 1, outputPerMillionUSD: 2),
                           PriceEntry(providerID: "openai", model: "ok", inputPerMillionUSD: 9, outputPerMillionUSD: 9),
                           PriceEntry(providerID: "openai", model: "neg", inputPerMillionUSD: -1, outputPerMillionUSD: 2),
                           PriceEntry(providerID: "otro", model: "x", inputPerMillionUSD: 1, outputPerMillionUSD: 2)]
        let clean = settings.sanitized()
        XCTAssertNil(clean.monthlyBudgetUSD)
        XCTAssertEqual(clean.alertFraction, UsageSettings.alertFractionDefault)
        XCTAssertEqual(clean.policies.map(\.providerID), ["groq"])
        XCTAssertEqual(clean.prices.count, 1)
        XCTAssertEqual(clean.prices[0].inputPerMillionUSD, 1)

        XCTAssertEqual(try JSONDecoder().decode(UsageSettings.self, from: Data("{}".utf8)), .default)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings.default))
        XCTAssertNil(decoded.usage)
        XCTAssertEqual(decoded.usageSettings, .default)
        XCTAssertTrue(UsageSettings.default.policy(for: "openai").paid)
        XCTAssertFalse(UsageSettings.default.policy(for: "groq").paid)
        XCTAssertTrue(UsageSettings.default.policy(for: "groq").authorized, "Por defecto lo que ya funcionaba sigue funcionando")
    }

    func testProvidersAndStreamUsageRequest() throws {
        XCTAssertEqual(CloudProviders.all.map(\.id), ["groq", "gemini", "openai", "cerebras"])
        XCTAssertEqual(Set(CloudProviders.all.map(\.id)).count, 4)
        XCTAssertEqual(CloudProviders.all.filter(\.streamUsage).map(\.id), ["openai"], "Solo se envía stream_options a quien lo documenta")

        func body(_ include: Bool) throws -> [String: Any] {
            let data = try OpenAIChatProtocol.requestBody(model: "m", system: "s", turns: [ChatTurn(role: .user, content: "hola")], maxTokens: 100,
                                                          temperature: 0.5, includeUsage: include)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        XCTAssertNil(try body(false)["stream_options"])
        XCTAssertEqual((try body(true)["stream_options"] as? [String: Bool])?["include_usage"], true)
    }

    func testUsageIsReadFromTheStreamWhenTheProviderReportsIt() {
        let openAI = #"data: {"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":45,"total_tokens":165}}"#
        XCTAssertEqual(OpenAIChatProtocol.parseUsage(openAI), TokenUsage(input: 120, output: 45))
        let groq = #"data: {"choices":[{"delta":{},"finish_reason":"stop"}],"x_groq":{"usage":{"prompt_tokens":10,"completion_tokens":3}}}"#
        XCTAssertEqual(OpenAIChatProtocol.parseUsage(groq), TokenUsage(input: 10, output: 3))
        XCTAssertNil(OpenAIChatProtocol.parseUsage(#"data: {"choices":[{"delta":{"content":"hola"}}]}"#))
        XCTAssertNil(OpenAIChatProtocol.parseUsage("data: [DONE]"))
        XCTAssertNil(OpenAIChatProtocol.parseUsage("basura"))
        XCTAssertNil(OpenAIChatProtocol.parseUsage(#"data: {"usage":{"prompt_tokens":"muchos"}}"#))
        // El texto normal sigue leyéndose igual: añadir el consumo no cambió el resto del protocolo.
        XCTAssertEqual(OpenAIChatProtocol.parseStreamLine(#"data: {"choices":[{"delta":{"content":"hola"}}]}"#), .delta("hola"))
    }

    func testProviderLimitsAreShownOnlyWhenReported() {
        let none = ProviderLimitsSnapshot.from(headers: ["content-type": "text/event-stream"])
        XCTAssertTrue(none.isEmpty, "Si el proveedor no informa nada, no se muestra nada")
        let some = ProviderLimitsSnapshot.from(headers: ["x-ratelimit-remaining-requests": "14399", "x-ratelimit-limit-requests": "14400", "x-ratelimit-remaining-tokens": "5990"])
        XCTAssertFalse(some.isEmpty)
        XCTAssertEqual(some.requestsRemaining, "14399")
        XCTAssertEqual(some.tokensRemaining, "5990")
        XCTAssertNil(some.tokensLimit)
    }

    func testNewProvidersAreNotOfferedAsImageReaders() {
        XCTAssertNil(CapabilityMatrix.visionProfile(providerID: "openai", chatModel: "gpt-4o-mini"))
        XCTAssertNil(CapabilityMatrix.visionProfile(providerID: "cerebras", chatModel: "gpt-oss-120b"))
        XCTAssertNotNil(CapabilityMatrix.visionProfile(providerID: "gemini", chatModel: "gemini-2.5-flash"))
        let profile = CapabilityMatrix.chatProfile(descriptor: ModelCatalog.cloudDescriptor, cloud: CloudBrainSettings(providerID: "openai", model: "gpt-4o-mini"))
        XCTAssertFalse(profile.capabilities.imageInput)
    }
}
