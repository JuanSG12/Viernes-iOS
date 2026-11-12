import SwiftUI
import ViernesCore

/// Consumo de los proveedores en la nube, presupuesto mensual, proveedores autorizados y tarifas. Todo lo que muestra sale de lo que
/// el proveedor informó o de las tarifas que escribiste: no hay cuotas ni precios inventados.
struct UsageView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { UsageContent(usage: model.usage) }
}

private struct UsageContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var usage: UsageStore
    @State private var budgetText = ""
    @State private var priceProvider = CloudProviders.openAI.id
    @State private var priceModel = ""
    @State private var priceInput = ""
    @State private var priceOutput = ""
    @State private var confirmClear = false
    @State private var refreshTick = 0

    private var settings: UsageSettings { model.settings.usageSettings }

    /// Filas de consumo por proveedor y modelo, con el total y la distinción entre lo medido y lo estimado.
    @ViewBuilder
    private func usageRows(_ rows: [ModelUsageSummary], empty: String) -> some View {
        if rows.isEmpty {
            Text(empty).font(.footnote).foregroundStyle(Theme.textSecondary)
        } else {
            let totals = UsageSummary.totals(rows)
            Text("Total: \(totals.requests) peticiones · \(totals.input) tokens de entrada + \(totals.output) de salida = \(totals.input + totals.output)")
                .font(.footnote).foregroundStyle(Theme.textPrimary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(name(row.providerID)) · \(row.model)").foregroundStyle(Theme.textPrimary)
                    Text("\(row.requests) peticiones · \(row.input) entrada · \(row.output) salida · \(row.total) en total")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    Text(sourceText(row)).font(.caption2).foregroundStyle(Theme.textSecondary)
                    Text(row.missingPrice ? "Costo sin calcular: falta la tarifa de este modelo (más abajo)." : "≈ \(UsageCost.format(row.costUSD)) (estimado con tus tarifas)")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func sourceText(_ row: ModelUsageSummary) -> String {
        if row.estimatedRequests == 0 { return "Tokens medidos por el proveedor." }
        if row.measuredRequests == 0 { return "Tokens estimados por Viernes: el proveedor no los informó." }
        return "\(row.measuredRequests) peticiones medidas por el proveedor y \(row.estimatedRequests) estimadas."
    }

    /// Estado real de un proveedor: sin clave, sin autorización, en pausa (con el motivo) o disponible.
    private func availabilityText(_ preset: CloudProviderPreset) -> String {
        guard CloudKeyStore.hasKey(providerID: preset.id) else { return "Sin clave guardada." }
        guard settings.policy(for: preset.id).authorized else { return "Clave guardada, pero NO autorizado en este perfil." }
        let status = ProviderHealth.breaker.status(preset.id)
        if status.isOpen {
            let until = status.openUntil.map { $0.formatted(date: .omitted, time: .shortened) } ?? "un rato"
            return "En pausa (\(status.kind?.title ?? "fallos repetidos")) hasta las \(until)." + (status.lastMessage.map { " " + String($0.prefix(140)) } ?? "")
        }
        if let message = status.lastMessage, status.consecutiveFailures > 0 { return "Disponible, con un fallo reciente: " + String(message.prefix(120)) }
        return "Disponible (clave guardada y autorizado)."
    }

    private func update(_ change: (inout UsageSettings) -> Void) {
        var current = model.settings.usageSettings
        change(&current)
        model.settings.usage = current.sanitized()
    }

    private func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    private func name(_ providerID: String) -> String { CloudProviders.all.first { $0.id == providerID }?.displayName ?? providerID }

    private var spent: Double { UsageGate.paidSpend(records: usage.records, settings: settings, now: Date()) }

    private var budgetStatus: String {
        guard let budget = settings.monthlyBudgetUSD else { return "Sin presupuesto: los proveedores de pago no tienen límite en Viernes." }
        let text = "Gastado ≈ \(UsageCost.format(spent)) de \(UsageCost.format(budget)) este mes (estimado con tus tarifas)."
        if spent >= budget { return text + " LÍMITE ALCANZADO: las solicitudes a proveedores de pago están detenidas." }
        if spent >= budget * settings.alertFraction { return text + " Ya pasaste el \(Int(settings.alertFraction * 100)) %." }
        return text
    }

    var body: some View {
        List {
            Section("Hoy") {
                usageRows(UsageSummary.today(records: usage.records, now: Date()), empty: "Todavía no hay peticiones a proveedores en la nube hoy.")
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Este mes") {
                usageRows(UsageSummary.thisMonth(records: usage.records, now: Date()), empty: "Todavía no hay peticiones a proveedores en la nube este mes.")
                Text("Medido = tokens que informó el proveedor. Estimado = Viernes los calculó por el texto (≈ 4 caracteres por token) porque el proveedor no los informó.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Disponibilidad de proveedores") {
                ForEach(CloudProviders.all) { preset in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.displayName).foregroundStyle(Theme.textPrimary)
                        Text(availabilityText(preset)).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                Button("Reintentar ahora (levantar las pausas)") {
                    for preset in CloudProviders.all { ProviderHealth.breaker.reset(preset.id) }
                    refreshTick += 1
                }
                .accessibilityIdentifier("usage-reset-breaker")
                Text("Tras un fallo que esperar no arregla (cuota diaria, sin crédito, clave inválida) o fallos repetidos del servicio, Viernes pausa ese proveedor un rato en vez de insistir. «Reintentar ahora» levanta la pausa.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))
            .id(refreshTick)

            Section("Presupuesto mensual") {
                Text(budgetStatus).font(.footnote).foregroundStyle(Theme.textPrimary).accessibilityIdentifier("usage-status")
                HStack {
                    ForEach([5.0, 10.0, 20.0], id: \.self) { value in
                        Button(UsageCost.format(value).replacingOccurrences(of: ",00", with: "")) { update { $0.monthlyBudgetUSD = value } }
                            .buttonStyle(.bordered).tint(settings.monthlyBudgetUSD == value ? Theme.accent : .gray)
                            .accessibilityIdentifier(value == 5 ? "usage-budget-5" : (value == 10 ? "usage-budget-10" : "usage-budget-20"))
                    }
                    Button("Sin límite") { update { $0.monthlyBudgetUSD = nil } }
                        .buttonStyle(.bordered).tint(settings.monthlyBudgetUSD == nil ? Theme.accent : .gray)
                        .accessibilityIdentifier("usage-budget-none")
                }
                HStack {
                    TextField("Otro monto en USD", text: $budgetText).keyboardType(.decimalPad).accessibilityIdentifier("usage-budget-field")
                    Button("Guardar") {
                        if let value = number(budgetText) { update { $0.monthlyBudgetUSD = value }; budgetText = "" }
                    }
                    .disabled(number(budgetText) == nil)
                }
                Picker("Avisar al llegar a", selection: Binding(get: { settings.alertFraction },
                                                                set: { value in update { $0.alertFraction = value } })) {
                    ForEach([0.5, 0.7, 0.8, 0.9], id: \.self) { Text("\(Int($0 * 100)) % del presupuesto").tag($0) }
                }
                .accessibilityIdentifier("usage-alert-fraction")
                Text("Cuenta solo lo de los proveedores marcados «de pago». Al llegar al límite, Viernes deja de enviar solicitudes a esos proveedores y te lo dice; avisa al \(Int(settings.alertFraction * 100)) %. Nunca cambia a otro proveedor por su cuenta. Es una estimación con las tarifas que escribiste abajo; la factura real la manda el proveedor.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Proveedores") {
                ForEach(CloudProviders.all) { preset in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: Binding(get: { settings.policy(for: preset.id).authorized },
                                             set: { value in update { var policy = $0.policy(for: preset.id); policy.authorized = value; $0.setPolicy(policy) } })) {
                            Text("\(preset.displayName): autorizado").foregroundStyle(Theme.textPrimary)
                        }
                        .accessibilityIdentifier("usage-authorized-\(preset.id)")
                        Toggle(isOn: Binding(get: { settings.policy(for: preset.id).paid },
                                             set: { value in update { var policy = $0.policy(for: preset.id); policy.paid = value; $0.setPolicy(policy) } })) {
                            Text("De pago (cuenta en el presupuesto)").font(.footnote).foregroundStyle(Theme.textSecondary)
                        }
                        if let snapshot = usage.limits[preset.id] {
                            Text(limitsText(snapshot)).font(.caption2).foregroundStyle(Theme.textSecondary)
                        } else {
                            Text("Sin límites informados por el proveedor.").font(.caption2).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                Text("Un proveedor no autorizado no recibe nada. Groq, Gemini y Cerebras tienen planes gratuitos: márcalos «de pago» solo si usas una clave con cobro.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Tarifas (USD por millón de tokens)") {
                ForEach(settings.prices.indices, id: \.self) { index in
                    let entry = settings.prices[index]
                    HStack {
                        Text("\(name(entry.providerID)) · \(entry.model)").font(.footnote).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("entrada \(entry.inputPerMillionUSD, specifier: "%.2f") · salida \(entry.outputPerMillionUSD, specifier: "%.2f")")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                .onDelete { offsets in update { $0.prices.remove(atOffsets: offsets) } }
                Picker("Proveedor", selection: $priceProvider) {
                    ForEach(CloudProviders.all) { Text($0.displayName).tag($0.id) }
                }
                TextField("Modelo (p. ej. el que usas)", text: $priceModel).autocorrectionDisabled().textInputAutocapitalization(.never)
                HStack {
                    TextField("Entrada", text: $priceInput).keyboardType(.decimalPad)
                    TextField("Salida", text: $priceOutput).keyboardType(.decimalPad)
                }
                Button("Guardar tarifa") {
                    if let input = number(priceInput), let output = number(priceOutput) {
                        update { $0.setPrice(PriceEntry(providerID: priceProvider, model: priceModel.trimmingCharacters(in: .whitespaces), inputPerMillionUSD: input, outputPerMillionUSD: output)) }
                        priceInput = ""
                        priceOutput = ""
                    }
                }
                .disabled(priceModel.trimmingCharacters(in: .whitespaces).isEmpty || number(priceInput) == nil || number(priceOutput) == nil)
                .accessibilityIdentifier("usage-price-save")
                Text("Viernes no trae tarifas propias porque cambian y no puede verificarlas: cópialas de la página de precios de tu proveedor. Sin tarifa no hay costo estimado, y con un presupuesto activo un modelo de pago sin tarifa se bloquea para no gastar sin control.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            Section("Historial reciente") {
                let recent = Array(usage.records.suffix(20).reversed())
                if recent.isEmpty { Text("Sin registros.").font(.footnote).foregroundStyle(Theme.textSecondary) }
                ForEach(recent) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(name(record.providerID)) · \(record.model)").font(.footnote).foregroundStyle(Theme.textPrimary)
                        Text("\(record.date.formatted(date: .abbreviated, time: .shortened)) · \(record.input) + \(record.output) tokens\(record.isEstimate ? " (estimado)" : "")\(record.costUSD.map { " · ≈ \(UsageCost.format($0))" } ?? "")")
                            .font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                }
                Button("Borrar el historial de consumo", role: .destructive) { confirmClear = true }
                    .disabled(usage.records.isEmpty)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))
        }
        .chromeList()
        .navigationTitle("Consumo y presupuesto")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("¿Borrar el historial de consumo?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Borrar historial", role: .destructive) { usage.clear() }
        } message: { Text("Se borra el registro de este perfil; el presupuesto del mes vuelve a empezar de cero. No se puede deshacer.") }
        .onAppear { if priceModel.isEmpty { priceModel = model.settings.cloudBrain.model; priceProvider = model.settings.cloudBrain.providerID } }
    }

    private func limitsText(_ snapshot: ProviderLimitsSnapshot) -> String {
        var parts: [String] = []
        if let remaining = snapshot.requestsRemaining { parts.append("peticiones restantes: \(remaining)\(snapshot.requestsLimit.map { " de \($0)" } ?? "")") }
        if let remaining = snapshot.tokensRemaining { parts.append("tokens restantes: \(remaining)\(snapshot.tokensLimit.map { " de \($0)" } ?? "")") }
        return "Último informe del proveedor (\(snapshot.date.formatted(date: .omitted, time: .shortened))): " + parts.joined(separator: " · ")
    }
}
