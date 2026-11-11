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

    private var settings: UsageSettings { model.settings.usageSettings }

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
            Section("Este mes") {
                let rows = UsageSummary.month(records: usage.records, now: Date())
                if rows.isEmpty {
                    Text("Todavía no hay peticiones a proveedores en la nube este mes.").font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                ForEach(rows, id: \.providerID) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name(row.providerID)).foregroundStyle(Theme.textPrimary)
                        Text("\(row.requests) peticiones · \(row.input) tokens de entrada · \(row.output) de salida\(row.anyEstimate ? " (algunos estimados)" : "")")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                        Text(row.missingPrice ? "Costo parcial o sin calcular: falta la tarifa de algún modelo." : "≈ \(UsageCost.format(row.costUSD))")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                Text("Los tokens son los que informó el proveedor; si no los informó, se estiman por el texto (≈ 4 caracteres por token) y se marcan como estimados.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

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
