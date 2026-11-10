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

    /// Los controles secundarios viven en el menú «Más» (referencia visual). Se busca por identificador y, si hace falta, por texto.
    private func menuItem(_ app: XCUIApplication, id: String, label: String) -> XCUIElement {
        let byID = app.buttons[id]
        if byID.waitForExistence(timeout: 3) { return byID }
        return app.buttons[label]
    }

    private func openMemory(_ app: XCUIApplication) {
        let more = app.buttons["quick-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "Falta el menú Más")
        more.tap()
        let item = menuItem(app, id: "open-memory", label: "Memoria")
        XCTAssertTrue(item.waitForExistence(timeout: 5), "El menú Más no ofrece Memoria")
        item.tap()
    }

    func testMoreMenuOffersMemoryHistoryAndNewConversation() {
        let app = launch()
        let more = app.buttons["quick-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        XCTAssertTrue(menuItem(app, id: "open-memory", label: "Memoria").waitForExistence(timeout: 5))
        XCTAssertTrue(menuItem(app, id: "open-history", label: "Historial").exists)
        XCTAssertTrue(menuItem(app, id: "new-conversation", label: "Nueva conversación").exists)
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
        for id in ["mic", "toggle-keyboard", "toggle-speech", "open-settings", "quick-more", "quick-today", "quick-tasks", "quick-weather"] {
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
        openMemory(app)
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
        openMemory(app)
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

    // MARK: Adjuntos

    func testAttachMenuOffersEverySourceAndSaysWhatTheDeviceCannotDo() {
        let app = launch()
        app.buttons["toggle-keyboard"].tap()
        let attach = app.buttons["attach-menu"]
        XCTAssertTrue(attach.waitForExistence(timeout: 5), "Falta el botón de adjuntar junto al campo de texto")
        attach.tap()
        XCTAssertTrue(menuItem(app, id: "attach-photo", label: "Foto de la fototeca").waitForExistence(timeout: 5))
        XCTAssertTrue(menuItem(app, id: "attach-file", label: "Archivo (PDF, Word, Excel, texto…)").exists)
        // El simulador no tiene cámara: la opción aparece desactivada y lo dice, en vez de fallar al tocarla.
        let camera = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Tomar una foto'")).firstMatch
        XCTAssertTrue(camera.exists)
        XCTAssertFalse(camera.isEnabled)
        XCTAssertTrue(camera.label.contains("sin cámara"))
    }

    private func chip(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Adjunto \(name)")).firstMatch
    }

    func testAttachmentsShowTheirRealStatesAndErrorsAreExplained() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest", "--uitest-skip-onboarding", "--uitest-demo-attachments"]
        app.launchEnvironment["VIERNES_KEYCHAIN_SERVICE"] = "com.example.viernes.uitests"
        app.launch()

        let sheet = chip(app, "ventas.csv")
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "El CSV debe aparecer como adjunto")
        XCTAssertTrue(sheet.label.contains("CSV"), "Listo: «\(sheet.label)»")

        let note = chip(app, "nota.txt")
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        XCTAssertTrue(note.label.contains("con avisos"), "El texto con órdenes sospechosas lleva aviso: «\(note.label)»")

        let photo = chip(app, "factura.jpg")
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        XCTAssertTrue(photo.label.contains("Imagen"), "La imagen se lee y queda lista: «\(photo.label)»")

        // Un archivo que dice ser PDF pero es texto se rechaza con su motivo y no viaja.
        let fake = chip(app, "falso.pdf")
        XCTAssertTrue(fake.waitForExistence(timeout: 10))
        XCTAssertTrue(fake.label.contains("no se pudo leer"), "«\(fake.label)»")
        fake.tap()
        let error = app.descendants(matching: .any).matching(identifier: "attachment-error").firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5), "El detalle explica el error")
        XCTAssertTrue(error.label.contains("dice ser un PDF") || app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'dice ser un PDF'")).firstMatch.exists)
        app.buttons["Cerrar"].tap()

        let remove = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Quitar falso.pdf")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertFalse(chip(app, "falso.pdf").waitForExistence(timeout: 2), "Quitado")
    }

    // MARK: Biblioteca

    private func openLibrary(_ app: XCUIApplication) {
        let more = app.buttons["quick-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "Falta el menú Más")
        more.tap()
        let item = menuItem(app, id: "open-library", label: "Biblioteca")
        XCTAssertTrue(item.waitForExistence(timeout: 5), "El menú Más no ofrece la Biblioteca")
        item.tap()
    }

    func testEmptyLibraryExplainsItselfAndOffersEveryWayToAdd() {
        let app = launch()
        openLibrary(app)
        XCTAssertTrue(field(app, "library-empty").waitForExistence(timeout: 5), "La biblioteca vacía dice qué es y cómo llenarla")
        let add = app.buttons["library-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(menuItem(app, id: "library-add-file", label: "Añadir archivo…").waitForExistence(timeout: 5))
        XCTAssertTrue(menuItem(app, id: "library-add-note", label: "Nueva nota").exists)
        XCTAssertTrue(menuItem(app, id: "library-collections", label: "Proyectos y carpetas").exists)
    }

    func testLibraryShowsRealIndexedItemsSearchesByContentAndDeletes() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest", "--uitest-skip-onboarding", "--uitest-demo-library"]
        app.launchEnvironment["VIERNES_KEYCHAIN_SERVICE"] = "com.example.viernes.uitests"
        app.launch()
        openLibrary(app)

        // Los tres elementos pasaron por el pipeline real y quedaron indexados.
        let contract = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "contrato, indexado")).firstMatch
        XCTAssertTrue(contract.waitForExistence(timeout: 20), "El contrato debe aparecer indexado")
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "ventas, indexado")).firstMatch.exists)
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Ideas del proyecto, indexado")).firstMatch.exists)

        // Búsqueda por contenido: «salario» solo está dentro del contrato.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("salario")
        let hit = app.buttons["library-hit"].firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 10), "La búsqueda por contenido debe devolver el fragmento")
        XCTAssertTrue(hit.label.contains("contrato"), "El resultado dice de qué documento sale: «\(hit.label)»")
        hit.tap()

        // Detalle: título editable y borrado con confirmación.
        let title = app.textFields["library-item-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "contrato")
        let delete = app.buttons["library-item-delete"]
        if !delete.exists { app.swipeUp() }
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons["Eliminar"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Borrar pide confirmación")
        confirm.tap()

        // Ya no aparece al buscar lo mismo. El borrado y la nueva búsqueda son asíncronos: el resultado viejo sigue en pantalla unos
        // instantes, así que se ESPERA a que desaparezca (`waitForExistence` devolvería «sí existe» al instante).
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["library-hit"].firstMatch)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 15), .completed, "Lo borrado deja de aparecer en las búsquedas")
    }

    // MARK: Perfiles

    private func openSettingsRow(_ app: XCUIApplication, _ id: String) {
        app.buttons["open-settings"].tap()
        let row = app.buttons[id]
        _ = row.waitForExistence(timeout: 5)
        reveal(row, in: app)
        XCTAssertTrue(row.exists, "Falta la fila \(id) en Configuración")
        row.tap()
    }

    private func contractRow(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "contrato, indexado")).firstMatch
    }

    func testProfilesKeepTheirDataSeparateAndSwitchingBringsEachOneBack() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest", "--uitest-skip-onboarding", "--uitest-demo-library"]
        app.launchEnvironment["VIERNES_KEYCHAIN_SERVICE"] = "com.example.viernes.uitests"
        app.launch()

        // El perfil principal tiene su biblioteca (documentos que pasaron por el pipeline real).
        openLibrary(app)
        XCTAssertTrue(contractRow(app).waitForExistence(timeout: 20), "El contrato debe estar en el perfil principal")
        app.buttons["Cerrar"].tap()

        // Crear un perfil nuevo y entrar en él.
        openSettingsRow(app, "settings-profiles")
        let newProfile = app.buttons["profile-new"]
        XCTAssertTrue(newProfile.waitForExistence(timeout: 5))
        newProfile.tap()
        let nameField = app.alerts.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.typeText("Beto")
        app.alerts.buttons["Crear y entrar"].tap()

        // En el perfil nuevo no está nada del principal.
        openLibrary(app)
        XCTAssertTrue(field(app, "library-empty").waitForExistence(timeout: 10), "El perfil nuevo empieza con la biblioteca vacía")
        XCTAssertFalse(contractRow(app).exists, "El contrato del perfil principal no aparece en el otro perfil")
        app.buttons["Cerrar"].tap()

        // Volver al principal: sus documentos siguen ahí.
        openSettingsRow(app, "settings-profiles")
        let principal = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Principal, ")).firstMatch
        XCTAssertTrue(principal.waitForExistence(timeout: 5))
        XCTAssertTrue(principal.label.contains("inactivo"), "El principal ya no es el activo: «\(principal.label)»")
        principal.tap()
        let switchButton = app.buttons["profile-switch"]
        XCTAssertTrue(switchButton.waitForExistence(timeout: 5))
        switchButton.tap()
        openLibrary(app)
        XCTAssertTrue(contractRow(app).waitForExistence(timeout: 20), "Al volver, el perfil principal conserva su biblioteca")
    }

    func testPersonalityShowsExactlyWhatIsAddedToTheModel() {
        let app = launch()
        openSettingsRow(app, "settings-personality")
        let preview = field(app, "personality-preview")
        reveal(preview, in: app)
        XCTAssertTrue(preview.exists)
        XCTAssertTrue(preview.label.contains("Nada"), "Con los valores por defecto no se añade nada: «\(preview.label)»")

        let name = app.textFields["personality-name"]
        reveal(name, in: app)
        typeText("Jarvis", into: name, in: app)
        let autonomy = app.segmentedControls["personality-autonomy"]
        reveal(autonomy, in: app)
        XCTAssertTrue(autonomy.exists, "Falta el selector de autonomía")
        autonomy.buttons.element(boundBy: 0).tap()          // «Prudente» es el primer segmento

        reveal(preview, in: app)
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Jarvis"), object: preview)
        XCTAssertEqual(XCTWaiter().wait(for: [updated], timeout: 10), .completed, "La vista previa refleja el nombre elegido: «\(preview.label)»")
        XCTAssertTrue(preview.label.contains("Prudencia"), "Y la autonomía elegida: «\(preview.label)»")
        XCTAssertTrue(preview.label.contains("honestidad"), "Y siempre la nota de que no cambia las reglas: «\(preview.label)»")
    }

    func testPermissionsScreenListsEachPermissionWithItsReason() {
        let app = launch()
        app.buttons["open-settings"].tap()
        // La lista de ajustes es perezosa: según la altura de la hoja, «Permisos» puede quedar fuera de pantalla y no existir
        // para XCUITest hasta desplazarse.
        let permissions = app.buttons["settings-permissions"]
        _ = permissions.waitForExistence(timeout: 5)
        reveal(permissions, in: app)
        permissions.tap()
        for id in ["permission-mic", "permission-speech", "permission-reminders", "permission-calendar"] {
            XCTAssertTrue(field(app, id).waitForExistence(timeout: 5), "Falta \(id)")
        }
    }
}
