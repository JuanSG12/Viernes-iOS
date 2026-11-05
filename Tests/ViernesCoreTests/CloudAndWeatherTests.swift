import XCTest
@testable import ViernesCore

final class CloudAndWeatherTests: XCTestCase {
    // MARK: Cerebro en la nube

    func testStreamLineParsing() {
        XCTAssertEqual(OpenAIChatProtocol.parseStreamLine(#"data: {"choices":[{"delta":{"content":"Hola"}}]}"#), .delta("Hola"))
        XCTAssertEqual(OpenAIChatProtocol.parseStreamLine(#"data:{"choices":[{"delta":{"content":" mundo"}}]}"#), .delta(" mundo"))
        XCTAssertEqual(OpenAIChatProtocol.parseStreamLine("data: [DONE]"), .done)
        XCTAssertEqual(OpenAIChatProtocol.parseStreamLine(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#), .ignore)
        XCTAssertEqual(OpenAIChatProtocol.parseStreamLine(#"data: {"choices":[{"delta":{"content":""}}]}"#), .ignore)
        XCTAssertEqual(OpenAIChatProtocol.parseStreamLine(": keep-alive"), .ignore)
        XCTAssertEqual(OpenAIChatProtocol.parseStreamLine("data: no es json"), .ignore)
    }

    func testRequestBodyHasSystemFirstThenAlternatingTurns() throws {
        let turns = [ChatTurn(role: .user, content: "hola"), ChatTurn(role: .assistant, content: "¿en qué te ayudo?"), ChatTurn(role: .user, content: "dime un dato")]
        let data = try OpenAIChatProtocol.requestBody(model: "llama-3.3-70b-versatile", system: "Eres Viernes.", turns: turns, maxTokens: 512, temperature: 0.6)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "llama-3.3-70b-versatile")
        XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertEqual(object["max_tokens"] as? Int, 512)
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user", "assistant", "user"])
        XCTAssertEqual(messages.first?["content"], "Eres Viernes.")
    }

    func testReasoningModelsGetLowEffortAndOthersDoNot() throws {
        func body(_ model: String) throws -> [String: Any] {
            let data = try OpenAIChatProtocol.requestBody(model: model, system: "s", turns: [ChatTurn(role: .user, content: "hola")], maxTokens: 1500, temperature: 0.6)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        XCTAssertEqual(try body("openai/gpt-oss-120b")["reasoning_effort"] as? String, "low")
        XCTAssertEqual(try body("openai/gpt-oss-20b")["reasoning_effort"] as? String, "low")
        XCTAssertNil(try body("gemini-2.5-flash")["reasoning_effort"], "Otros modelos rechazarían el parámetro")
        XCTAssertNil(try body("llama-x")["reasoning_effort"])
        XCTAssertGreaterThanOrEqual(OpenAIChatProtocol.minimumCloudTokens, 1_000)
        XCTAssertEqual(CloudProviders.groq.defaultModel, "openai/gpt-oss-120b")
    }

    func testPersonaTellsTheModelToActWithoutAskingForTextConfirmation() {
        let prompt = Persona.systemPrompt(PersonaContext(engine: ModelCatalog.cloudDescriptor, claudeMode: .openApp))
        XCTAssertTrue(prompt.contains("DE INMEDIATO"))
        XCTAssertTrue(prompt.contains("hoja de confirmación"))
    }

    func testErrorMessagesAreInSpanishAndNeverLeakSecrets() {
        let auth = OpenAIChatProtocol.errorMessage(status: 401, body: #"{"error":{"message":"Invalid API Key sk-secret"}}"#, provider: "Groq", model: "m")
        XCTAssertTrue(auth.contains("rechazó la clave"))
        XCTAssertFalse(auth.contains("sk-secret"))
        XCTAssertTrue(OpenAIChatProtocol.errorMessage(status: 429, body: "", provider: "Groq", model: "m").contains("límite"))
        XCTAssertTrue(OpenAIChatProtocol.errorMessage(status: 404, body: "", provider: "Groq", model: "xyz").contains("xyz"))
        XCTAssertTrue(OpenAIChatProtocol.errorMessage(status: 503, body: "", provider: "Groq", model: "m").contains("problemas"))
        let other = OpenAIChatProtocol.errorMessage(status: 400, body: #"[{"error":{"message":"modelo no soporta esto"}}]"#, provider: "Gemini", model: "m")
        XCTAssertTrue(other.contains("modelo no soporta esto"))
    }

    func testParseModelIDsStripsGeminiPrefixAndSorts() {
        let json = #"{"data":[{"id":"models/gemini-2.5-flash"},{"id":"llama-x"},{"id":"models/gemini-2.0-flash"}]}"#
        XCTAssertEqual(OpenAIChatProtocol.parseModelIDs(Data(json.utf8)), ["gemini-2.0-flash", "gemini-2.5-flash", "llama-x"])
        XCTAssertEqual(OpenAIChatProtocol.parseModelIDs(Data("basura".utf8)), [])
    }

    func testPresetsAreHTTPSOnlyAndEndpointsAreBuilt() {
        for preset in CloudProviders.all {
            XCTAssertTrue(preset.baseURL.hasPrefix("https://"), preset.id)
            XCTAssertFalse(preset.baseURL.hasSuffix("/"), preset.id)
            XCTAssertNotNil(OpenAIChatProtocol.endpoint(preset, path: "chat/completions"))
        }
        let insecure = CloudProviderPreset(id: "x", displayName: "X", baseURL: "http://example.com/v1", defaultModel: "m", keyPageURL: "https://example.com", note: "")
        XCTAssertNil(OpenAIChatProtocol.endpoint(insecure, path: "models"), "Nunca se envía una clave por http")
        XCTAssertEqual(OpenAIChatProtocol.endpoint(CloudProviders.groq, path: "models")?.absoluteString, "https://api.groq.com/openai/v1/models")
    }

    func testCloudSettingsAreSanitized() {
        XCTAssertEqual(CloudBrainSettings(providerID: "desconocido", model: "  ").sanitized(), .default)
        XCTAssertEqual(CloudBrainSettings(providerID: "gemini", model: " gemini-2.5-flash ").sanitized().model, "gemini-2.5-flash")
        XCTAssertEqual(CloudBrainSettings(providerID: "groq", model: "con espacio").sanitized().model, CloudProviders.groq.defaultModel)
        XCTAssertEqual(CloudBrainSettings(providerID: "groq", model: String(repeating: "a", count: 101)).sanitized().model, CloudProviders.groq.defaultModel)
    }

    func testSettingsSavedBeforeCloudExistedStillDecode() throws {
        var dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.default)) as? [String: Any])
        dictionary.removeValue(forKey: "cloud")
        let legacy = try JSONSerialization.data(withJSONObject: dictionary)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertNil(decoded.cloud)
        XCTAssertEqual(decoded.cloudBrain, .default)
    }

    func testAPIKeyFormat() {
        XCTAssertEqual(APIKeyFormat.clean("  gsk_abcdefghijklmnopqrstuvwxyz0123456789\n"), "gsk_abcdefghijklmnopqrstuvwxyz0123456789")
        XCTAssertNil(APIKeyFormat.clean("corta"))
        XCTAssertNil(APIKeyFormat.clean("clave con espacios dentro de la cadena larga"))
        XCTAssertNil(APIKeyFormat.clean("clave-con-ñ-no-ascii-abcdefghijklmnop"))
    }

    func testCloudDescriptorAndPersonaDescribeTheRealBrain() {
        let descriptor = ModelCatalog.descriptor(id: ModelCatalog.cloudID)
        XCTAssertEqual(descriptor?.isCloud, true)
        XCTAssertEqual(descriptor?.sendsTextOffDevice, true)
        XCTAssertEqual(descriptor?.usesLocalWeights, false)
        XCTAssertFalse(ModelCatalog.all.contains { $0.isCloud }, "La nube no se mezcla con los modelos que se descargan")

        let prompt = Persona.systemPrompt(PersonaContext(engine: ModelCatalog.cloudDescriptor))
        XCTAssertTrue(prompt.contains("en la nube"))
        XCTAssertFalse(prompt.contains("modelo pequeño"), "No debe decir que es un modelo pequeño local")
        XCTAssertFalse(prompt.contains("/no_think"))
    }

    func testClaudeIsOpenAppByDefaultAndPersonaExplainsWhenDisabled() {
        XCTAssertEqual(ClaudeBridgeConfig().mode, .openApp)
        let qwen = ModelCatalog.all.first { $0.id == "qwen3-1.7b-4bit" }!
        let prompt = Persona.systemPrompt(PersonaContext(engine: qwen, claudeMode: .disabled))
        XCTAssertTrue(prompt.contains("Ajustes › Claude"))
    }

    // MARK: Clima

    private let geocoding = #"{"results":[{"name":"Medellín","latitude":6.25184,"longitude":-75.56359,"country":"Colombia","admin1":"Antioquia"}]}"#
    private let forecast = """
    {"current":{"temperature_2m":18.4,"relative_humidity_2m":72,"apparent_temperature":18.0,"weather_code":3,"wind_speed_10m":9.4},
     "daily":{"time":["2026-11-05","2026-11-06"],"temperature_2m_max":[21.1,22.0],"temperature_2m_min":[12.0,12.5],"precipitation_probability_max":[40,60]}}
    """

    func testGeocodingAndForecastURLs() throws {
        let geo = try XCTUnwrap(WeatherService.geocodingURL(city: "Bogotá, Colombia"))
        XCTAssertEqual(geo.host, "geocoding-api.open-meteo.com")
        XCTAssertEqual(geo.scheme, "https")
        XCTAssertFalse(geo.absoluteString.contains(" "))
        let url = try XCTUnwrap(WeatherService.forecastURL(latitude: 6.25184, longitude: -75.56359)).absoluteString
        XCTAssertTrue(url.contains("latitude=6.2518"))
        XCTAssertTrue(url.contains("longitude=-75.5636"))
        XCTAssertTrue(url.hasPrefix("https://api.open-meteo.com/"))
    }

    func testParsePlace() throws {
        let place = try XCTUnwrap(WeatherService.parsePlace(Data(geocoding.utf8)))
        XCTAssertEqual(place.name, "Medellín")
        XCTAssertEqual(place.label, "Medellín (Antioquia, Colombia)")
        XCTAssertEqual(place.latitude, 6.25184, accuracy: 0.0001)
        XCTAssertNil(WeatherService.parsePlace(Data(#"{"results":[]}"#.utf8)))
        XCTAssertNil(WeatherService.parsePlace(Data(#"{}"#.utf8)))
    }

    func testSummaryIsSpokenSpanishWithoutSymbols() throws {
        let place = try XCTUnwrap(WeatherService.parsePlace(Data(geocoding.utf8)))
        let text = try XCTUnwrap(WeatherService.summary(place: place, forecast: Data(forecast.utf8)))
        XCTAssertTrue(text.contains("Medellín (Antioquia, Colombia) hay 18 grados"))
        XCTAssertTrue(text.contains("nublado"))
        XCTAssertTrue(text.lowercased().contains("humedad del 72 por ciento"))
        XCTAssertTrue(text.contains("Hoy, máxima de 21 y mínima de 12 grados, con 40 por ciento de probabilidad de lluvia"))
        XCTAssertTrue(text.contains("Mañana, máxima de 22"))
        for symbol in ["°", "%", "km/h"] { XCTAssertFalse(text.contains(symbol), "El texto se lee en voz alta: sin «\(symbol)»") }
        XCTAssertNil(WeatherService.summary(place: place, forecast: Data("basura".utf8)))
    }

    func testWeatherCodesAreDescribed() {
        XCTAssertEqual(WeatherService.describe(code: 0), "despejado")
        XCTAssertEqual(WeatherService.describe(code: 63), "con lluvia moderada")
        XCTAssertEqual(WeatherService.describe(code: 95), "con tormenta eléctrica")
        XCTAssertEqual(WeatherService.describe(code: 1234), "con condiciones variables")
    }

    func testWeatherToolIsSafeAndValidated() throws {
        XCTAssertEqual(ToolCatalog.definition(named: "get_weather")?.risk, .safe)
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "get_weather", args: [:])))
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "get_weather", args: ["city": String(repeating: "a", count: 81)])))
        let ok = try ToolValidator.validate(ToolCall(name: "get_weather", args: ["city": "  Bogotá "]))
        XCTAssertEqual(ok.args["city"], "Bogotá")
        XCTAssertEqual(ConversationEngine.summary(for: ok), "Clima en Bogotá")
    }
}
