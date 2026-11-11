import SwiftUI
import ViernesCore

/// Compañero de Windows (prueba de concepto): consulta archivos autorizados, procesos y la bandeja de mensajes de tu PC, en tu red local.
/// Todo es de solo lectura salvo lo que apruebes en el propio PC. Nada de lo que devuelve el PC se trata como una orden para Viernes.
struct CompanionView: View {
    @EnvironmentObject var model: AppModel
    @State private var host = ""
    @State private var portText = "8443"
    @State private var fingerprint = ""
    @State private var code = ""
    @State private var paired = false
    @State private var busy = false
    @State private var message: String?
    @State private var query = ""
    @State private var files: [CompanionFileHit] = []
    @State private var processes: [CompanionProcess] = []
    @State private var inbox: [CompanionOutboxMessage] = []

    private var settings: CompanionSettings? { model.settings.companionSettings }

    private func refreshPaired() { paired = settings != nil && CompanionToken.read() != nil }

    private func call(_ spec: CompanionRequestSpec) async -> Data? {
        guard let settings = settings, let token = CompanionToken.read() else { message = CompanionError.notPaired.localizedDescription; return nil }
        busy = true
        defer { busy = false }
        do {
            let (status, data) = try await CompanionClient(settings: settings).call(spec, token: token)
            guard (200..<300).contains(status) else {
                if status == 401 { message = "El PC ya no reconoce este emparejamiento (se revocó). Vuelve a emparejar." }
                else { message = CompanionError.rejected(status, CompanionResponses.errorMessage(data) ?? "").localizedDescription }
                return nil
            }
            message = nil
            return data
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    var body: some View {
        List {
            Section("Windows Companion") {
                Text("Un servicio que instalas TÚ en tu PC con Windows (carpeta «companion» del proyecto). Solo funciona en tu red local, con un código de emparejamiento de un solo uso, la huella de su certificado y una lista de cosas autorizadas en el PC. No puede ejecutar comandos libres.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.carbon.opacity(0.5))

            if !paired {
                Section("Emparejar") {
                    TextField("Dirección del PC (p. ej. 192.168.1.20)", text: $host).keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("companion-host")
                    TextField("Puerto", text: $portText).keyboardType(.numberPad)
                    TextField("Huella SHA-256 del certificado (la muestra el PC)", text: $fingerprint, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(Theme.mono(11)).accessibilityIdentifier("companion-fingerprint")
                    TextField("Código de 8 dígitos", text: $code).keyboardType(.numberPad).accessibilityIdentifier("companion-code")
                    Button(busy ? "Emparejando…" : "Emparejar") { pair() }
                        .disabled(busy || host.isEmpty || fingerprint.isEmpty || code.count != 8)
                        .accessibilityIdentifier("companion-pair")
                    Text("En el PC: «node server.js start --pair». Compara la huella con la que muestra el PC: si no coincide, no te emparejes.")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                .listRowBackground(Theme.carbon.opacity(0.5))
            } else if let settings = settings {
                Section("Emparejado con \(settings.host)") {
                    Button("Desemparejar y olvidar el token", role: .destructive) { unpair() }
                    Text("El PC también puede revocar este emparejamiento cuando quiera.").font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                .listRowBackground(Theme.carbon.opacity(0.5))

                Section("Buscar archivos autorizados") {
                    TextField("Nombre del archivo", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("companion-query")
                    Button("Buscar") { Task { if let data = await call(CompanionRequests.searchFiles(query: query)) { files = CompanionResponses.files(data) } } }
                        .disabled(busy || query.trimmingCharacters(in: .whitespaces).count < 2)
                        .accessibilityIdentifier("companion-search")
                    ForEach(files) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.path).font(.footnote).foregroundStyle(Theme.textPrimary)
                            Text("\(file.folder) · \(file.size / 1024) KB").font(.caption2).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .listRowBackground(Theme.carbon.opacity(0.5))

                Section("Procesos y bandeja") {
                    Button("Ver procesos del PC") { Task { if let data = await call(CompanionRequests.processes()) { processes = Array(CompanionResponses.processes(data).prefix(40)) } } }
                        .disabled(busy)
                    ForEach(processes) { process in Text("\(process.name) · \(process.pid) · \(process.memory)").font(Theme.mono(10)).foregroundStyle(Theme.textPrimary) }
                    Button("Recibir mensajes del PC") { Task { if let data = await call(CompanionRequests.outbox) { inbox = CompanionResponses.outbox(data) + inbox } } }
                        .disabled(busy)
                    ForEach(inbox) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.text).font(.footnote).foregroundStyle(Theme.textPrimary)
                            Text(item.time).font(.caption2).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Text("Los mensajes son texto que escribiste en el PC («node server.js send …»); aquí solo se muestran.").font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                .listRowBackground(Theme.carbon.opacity(0.5))
            }

            if let message = message {
                Section { Text(message).font(.footnote).foregroundStyle(Theme.textPrimary).accessibilityIdentifier("companion-message") }
                    .listRowBackground(Theme.carbon.opacity(0.5))
            }
        }
        .chromeList()
        .navigationTitle("Windows Companion")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshPaired() }
    }

    private func pair() {
        guard let normalized = CompanionFingerprint.normalize(fingerprint) else { message = "La huella debe ser un SHA-256 de 64 caracteres hexadecimales (con o sin «:»)."; return }
        guard let port = Int(portText), CompanionAddress.validate(host: host, port: port) else {
            message = "Solo se aceptan direcciones de tu red local (10.x, 172.16–31.x, 192.168.x, nombres «.local») y un puerto entre 1024 y 65535."
            return
        }
        let candidate = CompanionSettings(host: host.trimmingCharacters(in: .whitespaces), port: port, fingerprint: normalized, deviceName: "iPhone")
        busy = true
        Task {
            defer { busy = false }
            do {
                let (status, data) = try await CompanionClient(settings: candidate).call(CompanionRequests.pair(code: code, deviceName: candidate.deviceName), token: nil)
                guard status == 200, let result = CompanionResponses.pair(data) else {
                    throw CompanionError.rejected(status, CompanionResponses.errorMessage(data) ?? "")
                }
                guard CompanionToken.save(result.token) else { throw CompanionError.badAnswer }
                model.settings.companion = candidate
                code = ""
                refreshPaired()
                message = "Emparejado con «\(result.name)». El token quedó en el Llavero de este perfil."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func unpair() {
        Task {
            _ = await call(CompanionRequests.revoke)          // si el PC no responde, igualmente se olvida el token aquí
            CompanionToken.delete()
            model.settings.companion = nil
            files = []; processes = []; inbox = []
            refreshPaired()
            message = "Desemparejado."
        }
    }
}
