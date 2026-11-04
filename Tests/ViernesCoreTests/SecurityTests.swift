import XCTest
@testable import ViernesCore

final class SecurityTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    // MARK: Redactor

    func testRedactorFindsSecrets() {
        XCTAssertTrue(SensitiveDataRedactor.scan("pago con 4111 1111 1111 1111").findings.contains(.cardNumber))
        XCTAssertTrue(SensitiveDataRedactor.scan("mi contraseña es hunter2").findings.contains(.secretPhrase))
        XCTAssertTrue(SensitiveDataRedactor.scan("usa sk-abcdefghijklmnopqrstuvwx").findings.contains(.apiKey))
        XCTAssertTrue(SensitiveDataRedactor.scan("mi cédula es 1020304050").findings.contains(.governmentID))
    }

    func testRedactorDoesNotFlagOrdinaryText() {
        for text in ["Quiero un café a las 5", "Mi teléfono termina en 4567", "Prefiero respuestas cortas", "La clave del éxito es constancia"] {
            XCTAssertFalse(SensitiveDataRedactor.scan(text).isSensitive, text)
        }
        // 16 dígitos que NO pasan Luhn no son una tarjeta.
        XCTAssertFalse(SensitiveDataRedactor.scan("pedido 4111 1111 1111 1112").findings.contains(.cardNumber))
    }

    func testRedactionReplacesValues() {
        let result = SensitiveDataRedactor.scan("mi contraseña es hunter2 y la tarjeta 4111111111111111")
        XCTAssertFalse(result.redacted.contains("hunter2"))
        XCTAssertFalse(result.redacted.contains("4111111111111111"))
    }

    func testLuhn() {
        XCTAssertTrue(SensitiveDataRedactor.luhnValid("4111111111111111"))
        XCTAssertFalse(SensitiveDataRedactor.luhnValid("4111111111111112"))
        XCTAssertFalse(SensitiveDataRedactor.luhnValid(""))
    }

    // MARK: Validación de herramientas

    func testUnknownToolRejected() {
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "rm_rf", args: [:]))) {
            XCTAssertEqual($0 as? ToolValidationError, .unknownTool("rm_rf"))
        }
    }

    func testMissingRequiredArgumentRejected() {
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "create_reminder", args: ["notes": "x"]))) {
            XCTAssertEqual($0 as? ToolValidationError, .missingArgument(tool: "create_reminder", argument: "title"))
        }
    }

    func testOpenURLOnlyAllowsPlainHTTPS() {
        func ok(_ url: String) -> Bool { (try? ToolValidator.validate(ToolCall(name: "open_url", args: ["url": url]))) != nil }
        XCTAssertTrue(ok("https://www.apple.com/es"))
        XCTAssertFalse(ok("http://www.apple.com"))
        XCTAssertFalse(ok("javascript:alert(1)"))
        XCTAssertFalse(ok("tel:+573001234567"))
        XCTAssertFalse(ok("https://user:pass@evil.example.com"))
        XCTAssertFalse(ok("https://localhost"))
        XCTAssertFalse(ok("file:///etc/passwd"))
    }

    func testOpenAppUsesAllowlist() {
        XCTAssertNotNil(AppLinkCatalog.resolve("Spotify"))
        XCTAssertEqual(AppLinkCatalog.resolve("Calendario")?.displayName, "Calendario")
        XCTAssertEqual(AppLinkCatalog.resolve("música")?.key, "music")
        XCTAssertNil(AppLinkCatalog.resolve("Banco Nacional"))
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "open_app", args: ["app": "mi banco"])))
    }

    func testReminderAndEventDates() throws {
        let valid = try ToolValidator.validate(ToolCall(name: "create_reminder", args: ["title": "Llamar", "due": "2026-11-05T09:00"]), timeZone: utc)
        XCTAssertEqual(valid.args["due"], "2026-11-05T09:00")
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "create_reminder", args: ["title": "Llamar", "due": "mañana"]), timeZone: utc))
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "create_event", args: ["title": "Reunión", "start": "2026-11-05T15:00", "duration_minutes": "0"]), timeZone: utc))
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "create_event", args: ["title": "Reunión", "start": "2026-11-05T15:00", "duration_minutes": "99999"]), timeZone: utc))
        XCTAssertNoThrow(try ToolValidator.validate(ToolCall(name: "create_event", args: ["title": "Reunión", "start": "2026-11-05T15:00", "duration_minutes": "45"]), timeZone: utc))
    }

    func testDateParsing() {
        let expected = ISO8601DateFormatter().date(from: "2026-11-05T09:00:00Z")!
        XCTAssertEqual(DateParsing.parse("2026-11-05T09:00", timeZone: utc), expected)
        XCTAssertEqual(DateParsing.parse("2026-11-05T09:00:00Z", timeZone: utc), expected)
        XCTAssertEqual(DateParsing.parse("2026-11-05T04:00:00-05:00", timeZone: utc), expected)
        XCTAssertNil(DateParsing.parse("pasado mañana", timeZone: utc))
    }

    func testAskClaudeRefusesSensitiveText() {
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "ask_claude", args: ["prompt": "mi contraseña es hunter2, ¿es segura?"])))
        XCTAssertNoThrow(try ToolValidator.validate(ToolCall(name: "ask_claude", args: ["prompt": "Explícame qué es un monad"])))
    }

    func testUnexpectedArgumentsAreDropped() throws {
        let call = try ToolValidator.validate(ToolCall(name: "open_app", args: ["app": "spotify", "evil": "x"]))
        XCTAssertEqual(call.args, ["app": "spotify"])
    }

    func testSaveMemoryKindValidation() {
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "save_memory", args: ["text": "x", "kind": "summary"])))
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "save_memory", args: ["text": "x", "kind": "otro"])))
        XCTAssertNoThrow(try ToolValidator.validate(ToolCall(name: "save_memory", args: ["text": "x", "kind": "fact"])))
    }

    func testToolCallParser() {
        let call = ToolCallParser.parse(#"{"name":"list_reminders","args":{"limit":5}}"#)
        XCTAssertEqual(call, ToolCall(name: "list_reminders", args: ["limit": "5"]))
        XCTAssertNil(ToolCallParser.parse("no es json"))
        XCTAssertNil(ToolCallParser.parse(#"{"args":{}}"#))
    }

    func testEverySensitiveToolHasADefinition() {
        let sensitive = ToolCatalog.all.filter { $0.risk == .sensitive }.map(\.name)
        for name in ["open_url", "create_reminder", "complete_reminder", "create_event", "run_shortcut", "ask_claude", "save_memory", "forget_memory"] {
            XCTAssertTrue(sensitive.contains(name), "\(name) debe ser sensible")
        }
        XCTAssertEqual(Set(ToolCatalog.all.map(\.name)).count, ToolCatalog.all.count)
    }

    // MARK: Enlaces

    func testDeepLinkParsing() {
        XCTAssertEqual(DeepLink.parse(URL(string: "viernes://listen")!), .listen)
        XCTAssertEqual(DeepLink.parse(URL(string: "viernes://ask?q=hola%20mundo")!), .ask("hola mundo"))
        XCTAssertEqual(DeepLink.parse(URL(string: "viernes://ask")!), .unknown)
        XCTAssertEqual(DeepLink.parse(URL(string: "https://example.com")!), .unknown)
        XCTAssertEqual(DeepLink.parse(URL(string: "viernes://claude-result?result=x")!), .unknown)      // sin nonce
        XCTAssertEqual(DeepLink.parse(URL(string: "viernes://claude-result?nonce=N&result=Hola")!), .claudeResult(nonce: "N", text: "Hola"))
    }

    func testClaudeShortcutURLCarriesNonceCallback() throws {
        let url = try XCTUnwrap(ClaudeLinkBuilder.shortcutURL(name: "Preguntar a Claude", input: "¿Qué es un monad?", nonce: "ABC"))
        XCTAssertEqual(url.scheme, "shortcuts")
        XCTAssertEqual(url.host, "x-callback-url")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "name" }?.value, "Preguntar a Claude")
        let success = try XCTUnwrap(items.first { $0.name == "x-success" }?.value)
        XCTAssertEqual(DeepLink.parse(URL(string: success + "&result=Respuesta")!), .claudeResult(nonce: "ABC", text: "Respuesta"))
    }

    func testPendingClaudeRequestRejectsWrongOrExpiredNonce() {
        let now = Date()
        let request = PendingClaudeRequest(nonce: "N1", prompt: "hola", createdAt: now)
        XCTAssertTrue(request.isValid(for: "N1", now: now.addingTimeInterval(10)))
        XCTAssertFalse(request.isValid(for: "N2", now: now.addingTimeInterval(10)))
        XCTAssertFalse(request.isValid(for: "N1", now: now.addingTimeInterval(3_600)))
    }

    func testClaudeModesNeverClaimIntegrationWhenOnlyOpeningTheApp() {
        let text = ClaudeMode.openApp.honestDescription
        XCTAssertTrue(text.contains("NO integra"))
        XCTAssertNotNil(ClaudeLinkBuilder.newChatURL(prompt: "hola & adiós"))
        XCTAssertEqual(ClaudeLinkBuilder.openAppURL().absoluteString, "claude://")
    }

    func testSourceContainsNoAnthropicKeysOrEndpoints() throws {
        // Garantía estática: el core jamás habla con api.anthropic.com ni contiene claves.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        guard let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            return XCTFail("No se pudo leer Sources")
        }
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let content = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(content.contains("api.anthropic.com"), file.lastPathComponent)
            XCTAssertFalse(content.contains("x-api-key"), file.lastPathComponent)
            XCTAssertNil(content.range(of: "sk-ant-[A-Za-z0-9_-]{10,}", options: .regularExpression), file.lastPathComponent)
        }
    }
}
