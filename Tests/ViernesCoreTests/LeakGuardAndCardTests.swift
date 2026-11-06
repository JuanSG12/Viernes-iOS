import XCTest
@testable import ViernesCore

final class LeakGuardAndCardTests: XCTestCase {
    private func run(_ chunks: [String]) -> String {
        let guardrail = LeakGuard()
        var out = ""
        for chunk in chunks { out += guardrail.feed(chunk) }
        out += guardrail.finish()
        return out
    }

    private func chars(_ text: String) -> [String] { text.map { String($0) } }

    // MARK: LeakGuard

    func testPlainTextPassesUnchangedWholeOrCharByChar() {
        let text = "Hola, ¿en qué te ayudo? Hoy hay {sol} y 18 grados."
        XCTAssertEqual(run([text]), text)
        XCTAssertEqual(run(chars(text)), text)
    }

    func testMarkdownListsAreNotMistakenForToolEchoes() {
        let text = "Puedes:\n- crear un recordatorio\n- consultar el clima\n- abrir una app"
        XCTAssertEqual(run([text]), text)
        XCTAssertEqual(run(chars(text)), text, "Aunque llegue letra a letra")
    }

    func testLegacyMarkerAndResultLinesAreRemoved() {
        let leaked = "[RESULTADO_HERRAMIENTA]\n- get_weather: ÉXITO. Ahora mismo hay 18 grados.\n\nEn Medellín hacen 18 grados."
        XCTAssertEqual(run([leaked]), "En Medellín hacen 18 grados.")
        XCTAssertEqual(run(chars(leaked)), "En Medellín hacen 18 grados.", "También partido en trozos mínimos")
    }

    func testMarkerInTheMiddleOfAnAnswerIsRemovedWithItsBlock() {
        let leaked = "Listo. [RESULTADO_HERRAMIENTA]\n- list_events: ÉXITO. Sin eventos.\n- create_reminder: ÉXITO. Creado.\nTe avisaré a las 8."
        XCTAssertEqual(run([leaked]), "Listo. Te avisaré a las 8.")
    }

    func testToolCallJSONIsRemoved() {
        XCTAssertEqual(run([#"{"name":"get_weather","args":{"city":"Bogotá"}}"# + "\nHace frío."]), "Hace frío.")
        XCTAssertEqual(run(chars(#"{"name":"get_weather","args":{}}"# + "\nHace frío.")), "Hace frío.")
    }

    func testToolEchoLineWithoutMarkerIsRemoved() {
        XCTAssertEqual(run(["- get_weather: FALLÓ. Sin conexión.\nNo pude consultar el clima."]), "No pude consultar el clima.")
    }

    func testHeldBackTailIsReleasedAtTheEnd() {
        XCTAssertEqual(run(["Mira {", "\"nam"]), "Mira {\"nam", "Un posible principio de etiqueta se suelta al terminar si no llegó a serlo")
        XCTAssertEqual(run(["Lista:\n- ge"]), "Lista:\n- ge")
    }

    // MARK: Tarjeta de clima

    private let place = GeoPlace(name: "Medellín", region: "Antioquia", country: "Colombia", latitude: 6.25, longitude: -75.56)
    private let forecast = """
    {"current":{"temperature_2m":18.4,"relative_humidity_2m":72,"apparent_temperature":17.6,"weather_code":2,"wind_speed_10m":9.4},
     "daily":{"temperature_2m_max":[21.1,22.0],"temperature_2m_min":[12.0,12.5],"precipitation_probability_max":[40,60]}}
    """

    func testWeatherCardCarriesOnlyRealOpenMeteoData() throws {
        let card = try XCTUnwrap(WeatherService.card(place: place, forecast: Data(forecast.utf8)))
        XCTAssertEqual(card.kind, .weather)
        XCTAssertEqual(card.fields["place"], "Medellín (Antioquia, Colombia)")
        XCTAssertEqual(card.fields["city"], "Medellín")
        XCTAssertEqual(card.fields["temp"], "18")
        XCTAssertEqual(card.fields["feels"], "18")
        XCTAssertEqual(card.fields["condition"], "Parcialmente nublado")
        XCTAssertEqual(card.fields["symbol"], "cloud.sun.fill")
        XCTAssertEqual(card.fields["humidity"], "72")
        XCTAssertEqual(card.fields["wind"], "9")
        XCTAssertEqual(card.fields["rain"], "40")
        XCTAssertEqual(card.fields["tmax"], "21")
        XCTAssertEqual(card.fields["tmin"], "12")
        XCTAssertEqual(card.fields["tomorrowRain"], "60")
    }

    func testWeatherCardOmitsMissingValuesInsteadOfInventingThem() throws {
        let sparse = #"{"current":{"temperature_2m":20.0}}"#
        let card = try XCTUnwrap(WeatherService.card(place: place, forecast: Data(sparse.utf8)))
        XCTAssertEqual(card.fields["temp"], "20")
        for key in ["humidity", "wind", "rain", "tmax", "condition", "feels"] { XCTAssertNil(card.fields[key], key) }
        XCTAssertNil(WeatherService.card(place: place, forecast: Data("{}".utf8)))
        XCTAssertNil(WeatherService.card(place: place, forecast: Data("basura".utf8)))
    }

    func testRecordsWithCardsAndHiddenFlagStayBackwardCompatibleWhenDecoded() throws {
        let record = ActionRecord(tool: "get_weather", summary: "Clima en Medellín", outcome: .executed("ok"),
                                  card: ToolCard(kind: .weather, fields: ["temp": "18"]))
        let decoded = try JSONDecoder().decode(ActionRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
        XCTAssertTrue(decoded.isVisible)

        // Historial guardado antes de que existieran estos campos.
        var dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        dictionary.removeValue(forKey: "card")
        dictionary.removeValue(forKey: "showToUser")
        let legacy = try JSONDecoder().decode(ActionRecord.self, from: JSONSerialization.data(withJSONObject: dictionary))
        XCTAssertNil(legacy.card)
        XCTAssertTrue(legacy.isVisible)
        XCTAssertFalse(ActionRecord(tool: "x", summary: "", outcome: .declined, showToUser: false).isVisible)
    }

    func testEngineAttachesTheCardToTheRecordWhileTheModelStillSeesText() async {
        final class CardExecutor: ToolExecutor, @unchecked Sendable {
            func execute(_ call: ToolCall) async -> ToolOutcome {
                .card("Ahora mismo en Medellín hay 18 grados.", ToolCard(kind: .weather, fields: ["temp": "18", "place": "Medellín"]))
            }
        }
        let scripted = ScriptedEngine(script: [[#"<tool>{"name":"get_weather","args":{"city":"Medellín"}}</tool>"#], ["Hay 18 grados en Medellín."]])
        let engine = ConversationEngine(engine: scripted, memory: InMemoryMemoryStore(), executor: CardExecutor(), confirmer: nil)
        let events = await collect(await engine.send("Clima en Medellín"))
        let record = events.actionRecords.first
        XCTAssertEqual(record?.card?.fields["temp"], "18")
        XCTAssertEqual(record?.outcome, .executed("Ahora mismo en Medellín hay 18 grados."))
        XCTAssertTrue((scripted.requests[1].turns.last?.content ?? "").contains("18 grados"), "El modelo recibe el texto real")
    }
}
