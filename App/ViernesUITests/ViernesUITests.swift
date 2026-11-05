import XCTest

/// Pruebas de interfaz sobre simulador (almacén en RAM, sin tocar datos reales).
final class ViernesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(skipOnboarding: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"] + (skipOnboarding ? ["--uitest-skip-onboarding"] : [])
        app.launchEnvironment["VIERNES_KEYCHAIN_SERVICE"] = "com.example.viernes.uitests"   // no toca la clave real
        app.launch()
        return app
    }

    /// Los TextField con `axis: .vertical` se exponen como textViews; este helper acepta cualquier tipo de elemento.
    private func field(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// En runners lentos el primer toque a veces no enfoca el campo («has keyboard focus»): se reintenta hasta que aparece el teclado.
    private func typeText(_ text: String, into element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<3 {
            element.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 4) { break }
        }
        element.typeText(text)
    }

    /// Las listas son perezosas: una fila fuera de pantalla no existe para XCUITest. Se desplaza hacia abajo y, si hace falta, hacia arriba.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !element.exists && attempts < 6 { app.swipeUp(); attempts += 1 }
        attempts = 0
        while !element.exists && attempts < 10 { app.swipeDown(); attempts += 1 }
    }

    func testOnboardingExplainsThenStarts() {
        let app = launch(skipOnboarding: false)
        let start = app.buttons["onboarding-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Cerebro local"].exists)
        start.tap()
        XCTAssertTrue(app.otherElements["core"].waitForExistence(timeout: 5) || app.buttons["mic"].waitForExistence(timeout: 5))
    }

    func testMainScreenControlsExistAndAreHittable() {
        let app = launch()
        for id in ["mic", "toggle-keyboard", "toggle-speech", "open-settings", "open-memory", "open-history", "new-conversation"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Falta el botón \(id)")
            XCTAssertTrue(button.isHittable, "\(id) no es pulsable")
        }
        XCTAssertTrue(app.staticTexts["state-label"].exists)
    }

    func testKeyboardToggleRevealsTextFieldAndSendIsDisabledWhenEmpty() {
        let app = launch()
        app.buttons["toggle-keyboard"].tap()
        let input = field(app, "text-input")
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        // Id propio: la tecla «send» del teclado del sistema también se llama «send» y haría la búsqueda ambigua.
        XCTAssertFalse(app.buttons["send-message"].isEnabled)
        typeText("hola", into: input, in: app)
        XCTAssertTrue(app.buttons["send-message"].isEnabled)
    }

    func testTypedMessageAppearsInConversation() {
        let app = launch()
        app.buttons["toggle-keyboard"].tap()
        let input = field(app, "text-input")
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        typeText("mensaje de prueba", into: input, in: app)
        app.buttons["send-message"].tap()
        XCTAssertTrue(app.staticTexts["mensaje de prueba"].waitForExistence(timeout: 5))
    }

    func testSettingsScreensAreReachable() {
        let app = launch()
        app.buttons["open-settings"].tap()
        let destinations: [(id: String, title: String)] = [
            ("settings-model", "Modelo local"), ("settings-claude", "Claude"), ("settings-voice", "Voz y habla"),
            ("settings-listening", "Escucha y activación"), ("settings-privacy", "Privacidad"), ("settings-permissions", "Permisos")
        ]
        for destination in destinations {
            let row = app.buttons[destination.id]
            reveal(row, in: app)
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Falta la fila \(destination.id)")
            row.tap()
            XCTAssertTrue(app.navigationBars[destination.title].waitForExistence(timeout: 5), "No abrió \(destination.title)")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    func testWakeWordToggleExplainsLimitations() {
        let app = launch()
        app.buttons["open-settings"].tap()
        app.buttons["settings-listening"].tap()
        XCTAssertTrue(app.switches["wake-toggle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'iOS no permite'")).firstMatch.exists)
        XCTAssertEqual(app.switches["wake-toggle"].value as? String, "0")      // apagada por defecto
    }

    func testClaudeModesAreHonestlyDescribed() {
        let app = launch()
        app.buttons["open-settings"].tap()
        app.buttons["settings-claude"].tap()
        XCTAssertTrue(app.buttons["claude-mode-openApp"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["claude-mode-openApp"].label.contains("NO integra Claude"))      // el botón agrupa su texto
        app.buttons["claude-mode-shortcut"].tap()
        XCTAssertTrue(app.textFields["claude-shortcut-name"].waitForExistence(timeout: 3))
    }

    func testMemoryAddEditFlow() {
        let app = launch()
        app.buttons["open-memory"].tap()
        let add = app.buttons["Añadir recuerdo"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let text = field(app, "memory-text")
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        typeText("Prefiero respuestas cortas", into: text, in: app)
        app.buttons["memory-save"].tap()
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Prefiero respuestas cortas'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    func testMemoryRefusesSensitiveText() {
        let app = launch()
        app.buttons["open-memory"].tap()
        app.buttons["Añadir recuerdo"].tap()
        let text = field(app, "memory-text")
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        typeText("mi contraseña es hunter2", into: text, in: app)
        XCTAssertFalse(app.buttons["memory-save"].isEnabled)
    }

    func testPrivacyEraseRequiresConfirmation() {
        let app = launch()
        app.buttons["open-settings"].tap()
        app.buttons["settings-privacy"].tap()
        let erase = app.buttons["erase-all"]
        // La lista es perezosa: el botón del final no existe en pantalla hasta que se desplaza.
        var attempts = 0
        while !erase.exists && attempts < 10 { app.swipeUp(); attempts += 1 }
        XCTAssertTrue(erase.waitForExistence(timeout: 5))
        erase.tap()
        XCTAssertTrue(app.buttons["Borrar memoria, historial y ajustes"].waitForExistence(timeout: 3))
    }

    func testPermissionsScreenListsEachPermissionWithItsReason() {
        let app = launch()
        app.buttons["open-settings"].tap()
        app.buttons["settings-permissions"].tap()
        for id in ["permission-mic", "permission-speech", "permission-reminders", "permission-calendar"] {
            XCTAssertTrue(field(app, id).waitForExistence(timeout: 5), "Falta \(id)")
        }
    }
}
