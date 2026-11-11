import Foundation
import ViernesCore

/// Descargas con restricciones de seguridad: solo https público, sin cookies ni credenciales, CADA redirección se revisa con la misma
/// política y el tamaño está acotado. No se ejecuta JavaScript ni se muestra la página: solo se extrae su texto.
final class WebFetcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url, WebURLPolicy.validate(url.absoluteString) != nil { completionHandler(request) } else { completionHandler(nil) }
    }

    func data(for request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= maxBytes { break }
        }
        return (data, http)
    }
}

enum WebResearchClient {
    private static let fetcher = WebFetcher()

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "Sin conexión a internet."
        case .timedOut: return "El servidor tardó demasiado en responder."
        case .cancelled: return "La descarga se canceló (o una redirección no era un enlace https público)."
        default: return "Error de red: \(error.localizedDescription)"
        }
    }

    /// Busca con el proveedor elegido. La clave sale solo hacia ese proveedor; nunca se muestra ni se registra.
    static func search(provider: WebSearchProvider, query: String, count: Int, language: String?) async -> (outcome: ToolOutcome, results: [WebSearchResult]) {
        guard let key = CloudKeyStore.read(providerID: provider.keyProviderID) else {
            return (.failure("Falta la clave de \(provider.displayName). El usuario puede guardarla en Ajustes › Investigación web."), [])
        }
        guard let spec = WebSearchProtocol.request(provider: provider, query: query, count: count, key: key, language: language) else {
            return (.failure("No pude construir la búsqueda."), [])
        }
        var request = URLRequest(url: spec.url)
        request.httpMethod = spec.method
        request.httpBody = spec.body
        request.timeoutInterval = 20
        for (name, value) in spec.headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, http) = try await fetcher.data(for: request, maxBytes: 600_000)
            switch http.statusCode {
            case 200..<300:
                let results = WebSearchProtocol.parse(provider: provider, data: data)
                if results.isEmpty {
                    return (.success("Busqué «\(UntrustedContent.safeLabel(query, limit: 100))» en \(provider.displayName) y no hubo resultados útiles. Dilo y NO inventes información."), [])
                }
                return (.success(WebResultsFormat.results(query: query, results)), results)
            case 401, 403:
                return (.failure("\(provider.displayName) rechazó la clave (error \(http.statusCode)). Revísala en Ajustes › Investigación web."), [])
            case 402, 432, 433:
                return (.failure("\(provider.displayName) dice que el plan o el crédito se agotó (error \(http.statusCode)). Revisa tu cuenta en su panel."), [])
            case 429:
                let wait = http.value(forHTTPHeaderField: "retry-after").map { " Pide esperar \($0) s." } ?? ""
                return (.failure("\(provider.displayName) alcanzó su límite de peticiones.\(wait) Inténtalo de nuevo más tarde."), [])
            default:
                return (.failure("\(provider.displayName) respondió con el error \(http.statusCode)."), [])
            }
        } catch let error as URLError {
            return (.failure(describe(error)), [])
        } catch {
            return (.failure("No pude completar la búsqueda: \(error.localizedDescription)"), [])
        }
    }

    /// Lee el texto de una página https pública.
    static func readPage(urlString: String) async -> (outcome: ToolOutcome, title: String?, url: String) {
        guard let url = WebURLPolicy.validate(urlString) else {
            return (.failure("Solo puedo leer enlaces https públicos (sin direcciones IP ni redes locales)."), nil, urlString)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("text/html,text/plain;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue("Viernes/0.8 (asistente personal; lee una página que pidió el usuario)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, http) = try await fetcher.data(for: request, maxBytes: 1_500_000)
            guard (200..<300).contains(http.statusCode) else {
                return (.failure("La página respondió con el error \(http.statusCode)."), nil, url.absoluteString)
            }
            let type = (http.mimeType ?? "").lowercased()
            guard type.hasPrefix("text/") || type.contains("xhtml") else {
                return (.failure("Esa dirección no es una página de texto (tipo \(type.isEmpty ? "desconocido" : type))."), nil, url.absoluteString)
            }
            let final = http.url?.absoluteString ?? url.absoluteString
            let extracted = HTMLTextExtractor.extract(String(decoding: data, as: UTF8.self), limit: 6_000)
            guard extracted.text.count >= 200 else {
                return (.failure("No pude extraer texto legible de esa página (puede necesitar JavaScript o estar vacía). No la uses como fuente."), extracted.title, final)
            }
            return (.success(WebResultsFormat.page(title: extracted.title, url: final, text: extracted.text)), extracted.title, final)
        } catch let error as URLError {
            return (.failure(describe(error)), nil, url.absoluteString)
        } catch {
            return (.failure("No pude leer la página: \(error.localizedDescription)"), nil, url.absoluteString)
        }
    }
}

/// Historial de investigaciones de ESTE perfil, cifrado con su clave. Guarda qué se buscó y qué fuentes salieron o se leyeron
/// (nunca el texto de las páginas). Se conservan las 50 más recientes.
actor ResearchLog {
    private var records: [ResearchRecord] = []
    private let vault: Vault
    private let fileURL: URL
    private static let capacity = 50

    init(vault: Vault, path: String, base: URL? = nil) {
        self.vault = vault
        let root = base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        fileURL = root.appendingPathComponent(path)
        if let data = try? Data(contentsOf: fileURL), let loaded = try? vault.open([ResearchRecord].self, from: data) { records = loaded }
    }

    func record(query: String, results: [WebSearchResult]) {
        records.append(ResearchRecord(query: String(query.prefix(300)), sources: results.map { ResearchSource(title: $0.title, url: $0.url) }))
        if records.count > Self.capacity { records.removeFirst(records.count - Self.capacity) }
        persist()
    }

    /// Una página leída se anota en la investigación más reciente (si fue hace menos de 15 minutos) o como una nueva.
    func noteRead(title: String?, url: String, now: Date = Date()) {
        let source = ResearchSource(title: title ?? url, url: url)
        if var last = records.last, now.timeIntervalSince(last.date) < 900 {
            if !last.sources.contains(source) { last.sources.append(source) }
            records[records.count - 1] = last
        } else {
            records.append(ResearchRecord(query: "Lectura de una página", sources: [source]))
        }
        persist()
    }

    func all() -> [ResearchRecord] { records.sorted { $0.date > $1.date } }

    func clear() {
        records = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persist() {
        guard let sealed = try? vault.seal(records) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? sealed.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
