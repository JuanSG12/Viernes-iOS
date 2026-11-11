import Foundation

// MARK: Consumo, tarifas y presupuesto (todo puro y comprobable)

public struct TokenUsage: Equatable, Codable, Sendable {
    public var input: Int
    public var output: Int
    /// `true` si el proveedor no informó el consumo y se calculó a partir del texto (≈ 4 caracteres por token).
    public var isEstimate: Bool
    public init(input: Int, output: Int, isEstimate: Bool = false) {
        self.input = max(0, input)
        self.output = max(0, output)
        self.isEstimate = isEstimate
    }
}

public enum UsageEstimator {
    public static func tokens(forCharacters count: Int) -> Int { count <= 0 ? 0 : max(1, (count + 3) / 4) }
}

public struct UsageRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var providerID: String
    public var model: String
    public var input: Int
    public var output: Int
    public var isEstimate: Bool
    /// Costo estimado en USD con la tarifa que había configurada; `nil` si no había tarifa (el consumo en tokens sí cuenta).
    public var costUSD: Double?

    public init(id: UUID = UUID(), date: Date = Date(), providerID: String, model: String, input: Int, output: Int,
                isEstimate: Bool = false, costUSD: Double? = nil) {
        self.id = id
        self.date = date
        self.providerID = providerID
        self.model = model
        self.input = input
        self.output = output
        self.isEstimate = isEstimate
        self.costUSD = costUSD
    }
}

/// Tarifa en USD por millón de tokens. Las escribe el usuario (o se copian de la página de precios del proveedor): Viernes **no trae
/// tarifas propias**, porque cambian y no se pueden verificar desde la app. Sin tarifa no hay costo estimado.
public struct PriceEntry: Codable, Equatable, Sendable {
    public var providerID: String
    public var model: String
    public var inputPerMillionUSD: Double
    public var outputPerMillionUSD: Double
    public var updatedAt: Date
    public init(providerID: String, model: String, inputPerMillionUSD: Double, outputPerMillionUSD: Double, updatedAt: Date = Date()) {
        self.providerID = providerID
        self.model = model
        self.inputPerMillionUSD = inputPerMillionUSD
        self.outputPerMillionUSD = outputPerMillionUSD
        self.updatedAt = updatedAt
    }
}

public struct ProviderPolicy: Codable, Equatable, Sendable {
    public var providerID: String
    /// Si es `false`, Viernes no hace ninguna petición a este proveedor.
    public var authorized: Bool
    /// Si es `true`, el consumo cuenta contra el presupuesto mensual.
    public var paid: Bool
    public init(providerID: String, authorized: Bool = true, paid: Bool) {
        self.providerID = providerID
        self.authorized = authorized
        self.paid = paid
    }
}

public struct UsageSettings: Codable, Equatable, Sendable {
    public static let alertFractionDefault = 0.8

    /// Presupuesto mensual en USD para los proveedores marcados como de pago. `nil` = sin límite.
    public var monthlyBudgetUSD: Double?
    public var alertFraction: Double
    public var policies: [ProviderPolicy]
    public var prices: [PriceEntry]

    public static let `default` = UsageSettings()

    public init(monthlyBudgetUSD: Double? = nil, alertFraction: Double = UsageSettings.alertFractionDefault,
                policies: [ProviderPolicy] = [], prices: [PriceEntry] = []) {
        self.monthlyBudgetUSD = monthlyBudgetUSD
        self.alertFraction = alertFraction
        self.policies = policies
        self.prices = prices
    }

    private enum CodingKeys: String, CodingKey { case monthlyBudgetUSD, alertFraction, policies, prices }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        monthlyBudgetUSD = (try? c.decodeIfPresent(Double.self, forKey: .monthlyBudgetUSD)) ?? nil
        alertFraction = (try? c.decodeIfPresent(Double.self, forKey: .alertFraction)) ?? Self.alertFractionDefault
        policies = (try? c.decodeIfPresent([ProviderPolicy].self, forKey: .policies)) ?? []
        prices = (try? c.decodeIfPresent([PriceEntry].self, forKey: .prices)) ?? []
    }

    /// Por defecto todos los proveedores están autorizados (así lo que ya funcionaba sigue funcionando) y solo OpenAI cuenta como de
    /// pago: Groq, Gemini y Cerebras ofrecen planes gratuitos; si el usuario usa una clave de pago en ellos, la marca como tal.
    public static func defaultPaid(_ providerID: String) -> Bool { providerID == "openai" }

    public func policy(for providerID: String) -> ProviderPolicy {
        policies.first { $0.providerID == providerID } ?? ProviderPolicy(providerID: providerID, authorized: true, paid: Self.defaultPaid(providerID))
    }

    public mutating func setPolicy(_ policy: ProviderPolicy) {
        if let index = policies.firstIndex(where: { $0.providerID == policy.providerID }) { policies[index] = policy } else { policies.append(policy) }
    }

    public func price(providerID: String, model: String) -> PriceEntry? {
        prices.first { $0.providerID == providerID && $0.model == model }
    }

    public mutating func setPrice(_ entry: PriceEntry) {
        if let index = prices.firstIndex(where: { $0.providerID == entry.providerID && $0.model == entry.model }) { prices[index] = entry } else { prices.append(entry) }
    }

    public func sanitized() -> UsageSettings {
        var copy = self
        if let budget = monthlyBudgetUSD { copy.monthlyBudgetUSD = (budget.isFinite && budget > 0 && budget <= 100_000) ? budget : nil }
        copy.alertFraction = (alertFraction.isFinite && alertFraction > 0 && alertFraction < 1) ? alertFraction : Self.alertFractionDefault
        let known = Set(CloudProviders.all.map(\.id))
        var seenPolicies = Set<String>()
        copy.policies = policies.filter { known.contains($0.providerID) && seenPolicies.insert($0.providerID).inserted }
        var seenPrices = Set<String>()
        copy.prices = prices.filter {
            known.contains($0.providerID) && !$0.model.isEmpty && $0.model.count <= 100
                && $0.inputPerMillionUSD.isFinite && $0.inputPerMillionUSD >= 0 && $0.inputPerMillionUSD <= 10_000
                && $0.outputPerMillionUSD.isFinite && $0.outputPerMillionUSD >= 0 && $0.outputPerMillionUSD <= 10_000
                && seenPrices.insert($0.providerID + "|" + $0.model).inserted
        }
        return copy
    }
}

extension AppSettings {
    public var usageSettings: UsageSettings { usage ?? .default }
}

public enum UsageCost {
    public static func cost(_ usage: TokenUsage, price: PriceEntry?) -> Double? {
        guard let price = price else { return nil }
        return Double(usage.input) / 1_000_000 * price.inputPerMillionUSD + Double(usage.output) / 1_000_000 * price.outputPerMillionUSD
    }

    public static func format(_ usd: Double) -> String {
        usd < 0.01 && usd > 0 ? "< US$ 0,01" : String(format: "US$ %.2f", usd).replacingOccurrences(of: ".", with: ",")
    }
}

public enum UsageGateDecision: Equatable, Sendable {
    case allow
    case warn(String)
    case block(String)
}

public enum UsageGate {
    public static func monthStart(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    /// Gasto estimado del mes en los proveedores de pago (solo cuentan los registros con costo calculado).
    public static func paidSpend(records: [UsageRecord], settings: UsageSettings, now: Date, calendar: Calendar = .current) -> Double {
        let start = monthStart(now, calendar: calendar)
        return records
            .filter { $0.date >= start && $0.date <= now.addingTimeInterval(86_400) && settings.policy(for: $0.providerID).paid }
            .reduce(0) { $0 + ($1.costUSD ?? 0) }
    }

    /// Se consulta ANTES de cada petición. Nunca cambia de proveedor: solo permite, avisa o bloquea con el motivo.
    public static func check(providerID: String, model: String, settings raw: UsageSettings, records: [UsageRecord], now: Date,
                             calendar: Calendar = .current) -> UsageGateDecision {
        let settings = raw.sanitized()
        let name = CloudProviders.all.first { $0.id == providerID }?.displayName ?? providerID
        let policy = settings.policy(for: providerID)
        guard policy.authorized else {
            return .block("«\(name)» no está autorizado en este perfil, así que no le envié nada. Actívalo en Ajustes › Consumo y presupuesto, o elige otro cerebro (no cambio de proveedor por mi cuenta).")
        }
        guard policy.paid, let budget = settings.monthlyBudgetUSD else { return .allow }
        guard settings.price(providerID: providerID, model: model) != nil else {
            return .block("Hay un presupuesto mensual activo y «\(name)» es de pago, pero falta la tarifa de «\(model)»: sin ella no puedo estimar el costo ni respetar el límite. Escríbela en Ajustes › Consumo y presupuesto, o márcalo como gratuito. No envié nada.")
        }
        let spent = paidSpend(records: records, settings: settings, now: now, calendar: calendar)
        if spent >= budget {
            return .block("Alcanzaste el presupuesto mensual de \(UsageCost.format(budget)) (gastado ≈ \(UsageCost.format(spent)), estimado con tus tarifas), así que detuve las solicitudes a proveedores de pago y no envié nada. Sube el límite en Ajustes › Consumo y presupuesto, usa un cerebro gratuito o local, o espera al mes siguiente. No cambio de proveedor por mi cuenta.")
        }
        if spent >= budget * settings.alertFraction {
            return .warn("Llevas ≈ \(UsageCost.format(spent)) de tu presupuesto mensual de \(UsageCost.format(budget)) (estimado con tus tarifas).")
        }
        return .allow
    }
}

public struct ProviderUsageSummary: Equatable, Sendable {
    public var providerID: String
    public var requests: Int
    public var input: Int
    public var output: Int
    public var costUSD: Double
    /// Hubo peticiones sin tarifa: el costo es parcial.
    public var missingPrice: Bool
    public var anyEstimate: Bool
}

public enum UsageSummary {
    /// Resumen del mes por proveedor, ordenado por número de peticiones.
    public static func month(records: [UsageRecord], now: Date, calendar: Calendar = .current) -> [ProviderUsageSummary] {
        let start = UsageGate.monthStart(now, calendar: calendar)
        var byProvider: [String: ProviderUsageSummary] = [:]
        for record in records where record.date >= start {
            var item = byProvider[record.providerID] ?? ProviderUsageSummary(providerID: record.providerID, requests: 0, input: 0, output: 0,
                                                                              costUSD: 0, missingPrice: false, anyEstimate: false)
            item.requests += 1
            item.input += record.input
            item.output += record.output
            if let cost = record.costUSD { item.costUSD += cost } else { item.missingPrice = true }
            if record.isEstimate { item.anyEstimate = true }
            byProvider[record.providerID] = item
        }
        return byProvider.values.sorted { $0.requests != $1.requests ? $0.requests > $1.requests : $0.providerID < $1.providerID }
    }

    /// Conserva 13 meses y un máximo de registros (el historial no puede crecer sin límite).
    public static func pruned(_ records: [UsageRecord], now: Date, calendar: Calendar = .current, maxRecords: Int = 20_000) -> [UsageRecord] {
        let cutoff = calendar.date(byAdding: .month, value: -13, to: UsageGate.monthStart(now, calendar: calendar)) ?? .distantPast
        return Array(records.filter { $0.date >= cutoff }.suffix(maxRecords))
    }
}

/// Lo último que informó un proveedor sobre sus límites (cabeceras `x-ratelimit-*`). Si no informó nada, no se muestra nada: no se inventan cuotas.
public struct ProviderLimitsSnapshot: Codable, Equatable, Sendable {
    public var date: Date
    public var requestsLimit: String?
    public var requestsRemaining: String?
    public var tokensLimit: String?
    public var tokensRemaining: String?
    public var resetRequests: String?
    public var resetTokens: String?

    public var isEmpty: Bool { [requestsLimit, requestsRemaining, tokensLimit, tokensRemaining].allSatisfy { $0 == nil } }

    public init(date: Date = Date(), requestsLimit: String? = nil, requestsRemaining: String? = nil, tokensLimit: String? = nil,
                tokensRemaining: String? = nil, resetRequests: String? = nil, resetTokens: String? = nil) {
        self.date = date
        self.requestsLimit = requestsLimit
        self.requestsRemaining = requestsRemaining
        self.tokensLimit = tokensLimit
        self.tokensRemaining = tokensRemaining
        self.resetRequests = resetRequests
        self.resetTokens = resetTokens
    }

    /// `headers`: nombres en minúsculas.
    public static func from(headers: [String: String], date: Date = Date()) -> ProviderLimitsSnapshot {
        func value(_ key: String) -> String? { headers[key].flatMap { $0.isEmpty ? nil : String($0.prefix(40)) } }
        return ProviderLimitsSnapshot(date: date, requestsLimit: value("x-ratelimit-limit-requests"), requestsRemaining: value("x-ratelimit-remaining-requests"),
                                      tokensLimit: value("x-ratelimit-limit-tokens"), tokensRemaining: value("x-ratelimit-remaining-tokens"),
                                      resetRequests: value("x-ratelimit-reset-requests"), resetTokens: value("x-ratelimit-reset-tokens"))
    }
}
