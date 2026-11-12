import XCTest
@testable import ViernesCore

// Pruebas de unidad (núcleo): clasificación de errores de proveedores, API nativa de Gemini, enrutador, ahorro de tokens.
// No tocan la red ni ningún proveedor real: usan cuerpos de error con la forma documentada de cada proveedor.

final class ProviderFailureTests: XCTestCase {
    private func classify(_ status: Int, _ body: String, headers: [String: String] = [:]) -> ProviderFailure {
        ProviderFailureClassifier.classify(status: status, headers: headers, body: body)
    }

    func testOpenAIInsufficientQuotaIsBillingAndIsNeverRetried() {
        let body = #"{"error":{"message":"You exceeded your current quota, please check your plan and billing details.","type":"insufficient_quota","param":null,"code":"insufficient_quota"}}"#
        let failure = classify(429, body)
        XCTAssertEqual(failure.kind, .insufficientCredit)
        XCTAssertNil(failure.automaticWait, "Esperar no arregla un saldo agotado")
        let message = failure.userMessage(provider: "OpenAI", model: "gpt-4o-mini")
        XCTAssertTrue(message.contains("No se reintentó"))
        XCTAssertFalse(message.contains("plan gratuito"), "No se sabe qué plan tiene la cuenta")
    }

    func testGroqTokensPerMinuteWaitsAndKeepsTheRealFigures() {
        let body = #"{"error":{"message":"Rate limit reached for model `openai/gpt-oss-120b` in organization `org_x` service tier `on_demand` on tokens per minute (TPM): Limit 8000, Used 7243, Requested 1984. Please try again in 5.4s. Need more tokens?","type":"tokens","code":"rate_limit_exceeded"}}"#
        let failure = classify(429, body)
        XCTAssertEqual(failure.kind, .tokensPerMinute)
        XCTAssertEqual(failure.retryAfter ?? 0, 5.4, accuracy: 0.001)
        XCTAssertEqual(failure.automaticWait ?? 0, 5.4, accuracy: 0.001)
        XCTAssertEqual(failure.detail, "límite 8000, usados 7243, pedidos 1984")
        XCTAssertTrue(failure.userMessage(provider: "Groq", model: "m").contains("TOKENS por minuto"))
    }

    func testGroqDailyQuotaIsNotRetried() {
        let body = #"{"error":{"message":"Rate limit reached on tokens per day (TPD): Limit 100000, Used 99800, Requested 1200. Please try again in 14m24s.","type":"tokens","code":"rate_limit_exceeded"}}"#
        let failure = classify(429, body)
        XCTAssertEqual(failure.kind, .dailyQuota)
        XCTAssertEqual(failure.retryAfter ?? 0, 864, accuracy: 0.001)
        XCTAssertNil(failure.automaticWait)
        XCTAssertTrue(failure.userMessage(provider: "Groq", model: "m").contains("DIARIA"))
    }

    func testGeminiNamesTheExactQuotaThatWasExceeded() {
        let day = #"""
        {"error":{"code":429,"message":"You exceeded your current quota, please check your plan and billing details.\nPlease retry in 34.7s.","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaMetric":"generativelanguage.googleapis.com/generate_content_free_tier_requests","quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier"}]},{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"34s"}]}}
        """#
        let daily = classify(429, day)
        XCTAssertEqual(daily.kind, .dailyQuota)
        XCTAssertEqual(daily.retryAfter ?? 0, 34, accuracy: 0.001, "retryDelay de Google manda sobre el texto")
        XCTAssertNil(daily.automaticWait)

        let minuteTokens = #"{"error":{"code":429,"message":"quota","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"GenerateContentInputTokensPerModelPerMinute-FreeTier"}]}]}}"#
        XCTAssertEqual(classify(429, minuteTokens).kind, .tokensPerMinute)
        let minuteRequests = #"{"error":{"code":429,"message":"quota","status":"RESOURCE_EXHAUSTED","details":[{"violations":[{"quotaId":"GenerateRequestsPerMinutePerProjectPerModel-FreeTier"}]}]}}"#
        XCTAssertEqual(classify(429, minuteRequests).kind, .requestsPerMinute)
    }

    func testMissingModelAndInvalidKeyAreConfigurationErrors() {
        let notFound = classify(404, #"{"error":{"code":404,"message":"models/gemini-2.5-flash is not found for API version v1beta, or is not supported for generateContent.","status":"NOT_FOUND"}}"#)
        XCTAssertEqual(notFound.kind, .modelNotFound)
        XCTAssertFalse(notFound.allowsFailover, "Un modelo inexistente se arregla en Ajustes, no se esquiva")
        XCTAssertNil(notFound.automaticWait)
        XCTAssertTrue(notFound.userMessage(provider: "Google Gemini", model: "gemini-2.5-flash").contains("Probar conexión"))

        let badKey = classify(400, #"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}"#)
        XCTAssertEqual(badKey.kind, .invalidKey)
        XCTAssertEqual(classify(401, #"{"error":{"message":"Incorrect API key provided","code":"invalid_api_key"}}"#).kind, .invalidKey)
        XCTAssertEqual(classify(403, #"{"error":{"message":"x","code":"insufficient_quota"}}"#).kind, .insufficientCredit, "El motivo de cuota manda aunque venga con otro código HTTP")
        XCTAssertEqual(classify(402, "").kind, .insufficientCredit)
        XCTAssertEqual(classify(403, #"{"error":{"message":"Permission denied on resource"}}"#).kind, .authentication)
    }

    func testServiceOutagesAreRetriedBrieflyAndRetryAfterHeaderIsHonored() {
        let unavailable = classify(503, #"{"error":{"code":503,"message":"The model is overloaded. Please try again later.","status":"UNAVAILABLE"}}"#)
        XCTAssertEqual(unavailable.kind, .unavailable)
        XCTAssertEqual(unavailable.automaticWait, 2)
        XCTAssertTrue(unavailable.allowsFailover)

        let plain = #"{"error":{"message":"Slow down"}}"#
        let short = classify(429, plain, headers: ["retry-after": "12"])
        XCTAssertEqual(short.kind, .temporaryRateLimit)
        XCTAssertEqual(short.automaticWait, 12)
        XCTAssertNil(classify(429, plain, headers: ["retry-after": "120"]).automaticWait, "Una espera larga se informa, no se espera a ciegas")
        XCTAssertEqual(classify(429, plain).automaticWait, 8, "Sin dato del proveedor: una espera prudente")
    }

    func testResetHeadersSetTheWaitOnlyForTheMatchingLimit() {
        let body = #"{"error":{"message":"Rate limit reached on tokens per minute (TPM): Limit 6000, Used 5900, Requested 400."}}"#
        let failure = classify(429, body, headers: ["x-ratelimit-reset-tokens": "7.2s", "x-ratelimit-reset-requests": "1m0s"])
        XCTAssertEqual(failure.kind, .tokensPerMinute)
        XCTAssertEqual(failure.retryAfter ?? 0, 7.2, accuracy: 0.001)
    }

    func testUnknownBodiesNeverCrashAndStayConservative() {
        XCTAssertEqual(classify(429, "no es json").kind, .temporaryRateLimit)
        XCTAssertEqual(classify(429, #"{"message":"Too many requests","type":"too_many_requests_error","param":"quota","code":"token_quota_exceeded"}"#).kind, .temporaryRateLimit)
        XCTAssertEqual(classify(418, "").kind, .other)
        XCTAssertEqual(classify(500, "").kind, .unavailable)
    }

    func testCircuitBreakerStopsInsistingAndRecovers() {
        let breaker = ProviderCircuitBreaker()
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(breaker.allows("groq", now: now))

        breaker.recordFailure("groq", failure: ProviderFailure(kind: .dailyQuota, status: 429, retryAfter: 600), now: now)
        XCTAssertFalse(breaker.allows("groq", now: now.addingTimeInterval(599)))
        XCTAssertTrue(breaker.allows("groq", now: now.addingTimeInterval(601)))
        XCTAssertTrue(breaker.allows("gemini", now: now), "Otro proveedor no se ve afectado")

        breaker.recordFailure("x", failure: ProviderFailure(kind: .unavailable, status: 503), now: now)
        XCTAssertTrue(breaker.allows("x", now: now), "Un solo fallo del servicio no abre el interruptor")
        breaker.recordFailure("x", failure: ProviderFailure(kind: .unavailable, status: 503), now: now)
        XCTAssertFalse(breaker.allows("x", now: now.addingTimeInterval(10)))
        breaker.recordSuccess("x")
        XCTAssertTrue(breaker.allows("x", now: now.addingTimeInterval(10)))

        breaker.recordFailure("y", failure: ProviderFailure(kind: .modelNotFound, status: 404), now: now)
        XCTAssertTrue(breaker.allows("y", now: now), "Un error de configuración no deja al proveedor «caído»")

        breaker.recordFailure("z", failure: ProviderFailure(kind: .insufficientCredit, status: 429), now: now)
        XCTAssertFalse(breaker.allows("z", now: now.addingTimeInterval(800)))
        XCTAssertTrue(breaker.allows("z", now: now.addingTimeInterval(901)))
        breaker.recordFailure("z", failure: ProviderFailure(kind: .insufficientCredit, status: 429), now: now)
        breaker.reset("z")
        XCTAssertTrue(breaker.allows("z", now: now))

        let status = ProviderCircuitBreaker()
        status.recordFailure("openai", failure: ProviderFailure(kind: .insufficientCredit, status: 429), now: now)
        let message = status.pauseMessage(provider: "OpenAI", status: status.status("openai", now: now), now: now)
        XCTAssertTrue(message.contains("OpenAI") && message.contains("Reintentar ahora"))
    }

    func testTemporaryLimitsOpenTheBreakerOnlyBriefly() {
        let breaker = ProviderCircuitBreaker()
        let now = Date(timeIntervalSince1970: 2_000_000)
        breaker.recordFailure("groq", failure: ProviderFailure(kind: .tokensPerMinute, status: 429, retryAfter: 11), now: now)
        XCTAssertFalse(breaker.allows("groq", now: now.addingTimeInterval(5)))
        XCTAssertTrue(breaker.allows("groq", now: now.addingTimeInterval(12)))
    }
}

final class GeminiProtocolTests: XCTestCase {
    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func testModelIDsAndURLsAreValidatedBeforeTheyEnterAURL() {
        XCTAssertTrue(GeminiProtocol.isValidModelID("gemini-2.5-flash-lite"))
        XCTAssertFalse(GeminiProtocol.isValidModelID("../x"))
        XCTAssertFalse(GeminiProtocol.isValidModelID("a b"))
        XCTAssertFalse(GeminiProtocol.isValidModelID(""))
        XCTAssertFalse(GeminiProtocol.isValidModelID("a/b"))
        XCTAssertEqual(GeminiProtocol.streamURL(model: "gemini-2.5-flash-lite")?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:streamGenerateContent?alt=sse")
        XCTAssertNil(GeminiProtocol.streamURL(model: "x?key=1"))
        XCTAssertTrue(GeminiProtocol.modelsURL()?.absoluteString.contains("pageSize=200") ?? false)
        XCTAssertTrue(GeminiProtocol.modelsURL(pageToken: "a/b=")?.absoluteString.contains("pageToken=a%2Fb%3D") ?? false)
        XCTAssertFalse(GeminiProtocol.streamURL(model: "gemini-2.5-flash-lite")?.absoluteString.contains("key=") ?? true, "La clave va en una cabecera, nunca en la URL")
    }

    func testRequestBodyAlternatesRolesMergesRepeatsAndCarriesImages() throws {
        let turns = [
            ChatTurn(role: .assistant, content: "Hola, ¿en qué te ayudo?"),
            ChatTurn(role: .user, content: "a"),
            ChatTurn(role: .user, content: "b"),
            ChatTurn(role: .assistant, content: "c"),
            ChatTurn(role: .user, content: "mira", images: [ImagePart(mimeType: "image/png", base64: "AAAA", name: "x.png")])
        ]
        let object = json(try GeminiProtocol.requestBody(system: "SISTEMA", turns: turns, maxOutputTokens: 1_000, temperature: 0.5))
        let contents = object["contents"] as? [[String: Any]] ?? []
        XCTAssertEqual(contents.compactMap { $0["role"] as? String }, ["user", "model", "user"], "Empieza con el usuario y alterna")
        XCTAssertEqual((contents[0]["parts"] as? [[String: Any]])?.count, 2, "Los turnos seguidos del mismo rol se unen")
        let imageParts = contents[2]["parts"] as? [[String: Any]] ?? []
        let inline = imageParts.last?["inlineData"] as? [String: Any]
        XCTAssertEqual(inline?["mimeType"] as? String, "image/png")
        XCTAssertEqual(inline?["data"] as? String, "AAAA")
        let system = (object["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]]
        XCTAssertEqual(system?.first?["text"] as? String, "SISTEMA")
        let config = object["generationConfig"] as? [String: Any]
        XCTAssertEqual(config?["maxOutputTokens"] as? Int, 1_000)
        XCTAssertNil(config?["thinkingConfig"], "No se envían parámetros opcionales que algunos modelos rechazan")
    }

    func testStreamChunksCarryTextUsageAndFinishReason() {
        let first = GeminiProtocol.parseStreamLine(#"data: {"candidates":[{"content":{"parts":[{"text":"Hola"}],"role":"model"}}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":1,"totalTokenCount":11}}"#)
        XCTAssertEqual(first?.text, "Hola")
        XCTAssertEqual(first?.usage, TokenUsage(input: 10, output: 1))

        let thought = GeminiProtocol.parseStreamLine(#"data: {"candidates":[{"content":{"parts":[{"text":"pienso","thought":true},{"text":"Respuesta"}]}}]}"#)
        XCTAssertEqual(thought?.text, "Respuesta", "El razonamiento interno no se muestra")

        let last = GeminiProtocol.parseStreamLine(#"data: {"candidates":[{"content":{"parts":[{"text":"."}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":4,"thoughtsTokenCount":20}}"#)
        XCTAssertEqual(last?.finishReason, "STOP")
        XCTAssertEqual(last?.usage, TokenUsage(input: 10, output: 24), "El razonamiento se factura como salida")

        XCTAssertEqual(GeminiProtocol.parseStreamLine(#"data: {"promptFeedback":{"blockReason":"SAFETY"}}"#)?.blockReason, "SAFETY")
        XCTAssertNotNil(GeminiProtocol.parseStreamLine(#"data: {"error":{"code":500,"message":"x"}}"#)?.errorBody)
        XCTAssertNil(GeminiProtocol.parseStreamLine("data: [DONE]"))
        XCTAssertNil(GeminiProtocol.parseStreamLine(": comentario"))
        XCTAssertNil(GeminiProtocol.parseStreamLine("basura"))
    }

    func testResponseValidationExplainsEmptyAnswers() {
        XCTAssertNil(GeminiProtocol.validationError(producedText: true, finishReason: "STOP", blockReason: nil))
        XCTAssertNil(GeminiProtocol.validationError(producedText: true, finishReason: "MAX_TOKENS", blockReason: nil), "Con texto no se rechaza")
        XCTAssertTrue(GeminiProtocol.validationError(producedText: false, finishReason: "MAX_TOKENS", blockReason: nil)?.contains("agotó") ?? false)
        XCTAssertTrue(GeminiProtocol.validationError(producedText: false, finishReason: nil, blockReason: "SAFETY")?.contains("bloqueó") ?? false)
        XCTAssertTrue(GeminiProtocol.validationError(producedText: false, finishReason: "SAFETY", blockReason: nil)?.contains("filtros") ?? false)
        XCTAssertNotNil(GeminiProtocol.validationError(producedText: false, finishReason: "OTHER", blockReason: nil))
        XCTAssertNil(GeminiProtocol.validationError(producedText: false, finishReason: "STOP", blockReason: nil), "STOP sin texto lo trata el reintento del motor")
    }

    private let listJSON = #"""
    {"models":[
      {"name":"models/gemini-2.5-flash-lite","displayName":"Gemini 2.5 Flash-Lite","supportedGenerationMethods":["generateContent","countTokens"],"inputTokenLimit":1048576,"outputTokenLimit":65536},
      {"name":"models/gemini-embedding-001","supportedGenerationMethods":["embedContent"]},
      {"name":"models/gemini-2.5-flash-image","supportedGenerationMethods":["generateContent"]},
      {"name":"models/gemini-3.5-flash","supportedGenerationMethods":["generateContent"]},
      {"name":"models/gemma-3-27b-it","supportedGenerationMethods":["generateContent"]},
      {"name":"models/gemini-3.1-pro-preview","supportedGenerationMethods":["generateContent"]}
    ],"nextPageToken":"abc"}
    """#

    func testModelDiscoveryKeepsOnlyChatModelsAndSuggestsWithoutChoosing() {
        let page = GeminiModels.parseList(Data(listJSON.utf8))
        XCTAssertEqual(page.models.count, 6)
        XCTAssertEqual(page.nextPageToken, "abc")
        XCTAssertEqual(page.models.first?.inputTokenLimit, 1_048_576)
        let chat = GeminiModels.chatModels(page.models).map(\.id)
        XCTAssertEqual(chat, ["gemini-2.5-flash-lite", "gemini-3.1-pro-preview", "gemini-3.5-flash"],
                       "Sin embeddings, imágenes ni modelos que no admiten generateContent")
        XCTAssertEqual(GeminiModels.suggest(.light, from: page.models), "gemini-2.5-flash-lite")
        XCTAssertEqual(GeminiModels.suggest(.strong, from: page.models), "gemini-3.5-flash")

        let onlyLiteAndPreviewPro = page.models.filter { $0.id == "gemini-2.5-flash-lite" || $0.id == "gemini-3.1-pro-preview" }
        XCTAssertEqual(GeminiModels.suggest(.strong, from: onlyLiteAndPreviewPro), "gemini-3.1-pro-preview", "Sin nada estable, se sugiere una vista previa")
        XCTAssertNil(GeminiModels.suggest(.light, from: []))
        XCTAssertNil(GeminiModels.parseList(Data("no json".utf8)).nextPageToken)
    }

    func testCompatibleProvidersListFiltersNonChatModels() {
        let ids = ["gpt-4o-mini", "text-embedding-3-small", "whisper-large-v3", "openai/gpt-oss-120b", "llama-guard-4", "playai-tts"]
        XCTAssertEqual(CloudModelFilter.chatCandidates(ids), ["gpt-4o-mini", "openai/gpt-oss-120b"])
    }

    func testPresetsAreConsistentWithWhatWasVerified() {
        XCTAssertEqual(CloudProviders.gemini.defaultModel, "gemini-2.5-flash-lite")
        XCTAssertTrue(CloudProviders.openAI.note.contains("insufficient_quota"))
    }
}

final class RequestClassifierTests: XCTestCase {
    private func analyze(_ text: String, images: Bool = false, docs: Bool = false, previous: Set<ToolGroup> = [], asked: Bool = false) -> RequestAnalysis {
        RequestClassifier.analyze(text, hasImages: images, hasDocuments: docs, previousGroups: previous, lastAssistantAskedQuestion: asked)
    }

    func testEachKindOfRequestIsRecognized() {
        XCTAssertEqual(analyze("Hola Viernes, cómo estás").kind, .simpleChat)
        XCTAssertEqual(analyze("¿Qué es la fotosíntesis?").kind, .generalQuestion)
        XCTAssertEqual(analyze("Analiza paso a paso por qué sube el dólar").kind, .complexReasoning)
        XCTAssertEqual(analyze("Redacta un poema sobre el mar").kind, .contentGeneration)
        XCTAssertEqual(analyze("Recuerda que mi gata se llama Luna").kind, .memoryQuery)
        XCTAssertEqual(analyze("¿Qué ves aquí?", images: true).kind, .imageAnalysis)
        XCTAssertEqual(analyze("Resume esto", docs: true).kind, .documentAnalysis)
        XCTAssertEqual(analyze(String(repeating: "muy largo ", count: 50)).kind, .complexReasoning)
    }

    func testToolRequestsFindTheirTopics() {
        let whatsapp = analyze("Mándale un WhatsApp a Karen diciendo que llego tarde")
        XCTAssertEqual(whatsapp.kind, .toolExecution)
        XCTAssertTrue(whatsapp.groups.contains(.messaging))
        let mixed = analyze("Recuérdame llamar a Ana mañana a las 9")
        XCTAssertTrue(mixed.groups.contains(.reminders) && mixed.groups.contains(.messaging))
        XCTAssertTrue(analyze("¿Qué tengo en la agenda hoy?").groups.contains(.calendar))
        XCTAssertTrue(analyze("¿Va a llover mañana en Medellín?").groups.contains(.weather))
        XCTAssertTrue(analyze("Busca en internet las noticias de hoy").groups.contains(.web))
        XCTAssertTrue(analyze("Necesito una cita médica el martes").groups.contains(.calendar))
        XCTAssertTrue(RequestClassifier.groups(in: "Me excita la idea").isEmpty, "«excita» no contiene la palabra «cita»")
    }

    func testShortAnswersToAnAssistantQuestionKeepTheTopic() {
        let follow = analyze("A Checho", previous: [.messaging])
        XCTAssertEqual(follow.kind, .toolExecution)
        XCTAssertEqual(follow.groups, [.messaging])
        XCTAssertEqual(analyze("A Checho").kind, .simpleChat, "Sin tema anterior no hay nada que continuar")
        let longer = String(repeating: "x", count: 150)
        XCTAssertNotEqual(analyze(longer, previous: [.messaging], asked: false).kind, .toolExecution)
        XCTAssertEqual(analyze(longer, previous: [.messaging], asked: true).kind, .toolExecution, "Tras una pregunta del asistente se admite una respuesta más larga")
    }

    func testBudgetsAndTiersFollowTheKindOfRequest() {
        XCTAssertLessThan(RequestClass.simpleChat.outputBudget, RequestClass.complexReasoning.outputBudget)
        XCTAssertLessThan(RequestClass.simpleChat.historyChars, RequestClass.complexReasoning.historyChars)
        XCTAssertTrue(RequestClass.toolExecution.needsStrongModel && RequestClass.documentAnalysis.needsStrongModel)
        XCTAssertFalse(RequestClass.simpleChat.needsStrongModel || RequestClass.generalQuestion.needsStrongModel)
        XCTAssertTrue(RequestClass.simpleChat.localFriendly && RequestClass.memoryQuery.localFriendly)
        XCTAssertFalse(RequestClass.toolExecution.localFriendly)
        XCTAssertEqual(ToolGroups.group(of: "create_event"), .calendar)
        XCTAssertEqual(ToolGroups.group(of: "compose_message"), .messaging)
        XCTAssertEqual(ToolGroups.group(of: "web_search"), .web)
        for tool in ToolCatalog.all { _ = ToolGroups.group(of: tool.name) }
    }

    func testDeterministicAnswersOnlyForExactPhrases() {
        let now = ISO8601DateFormatter().date(from: "2026-11-12T15:42:00Z")!
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertTrue(DeterministicAnswers.answer(for: "¿Qué hora es?", now: now, timeZone: utc)?.contains("3:42") ?? false)
        XCTAssertTrue(DeterministicAnswers.answer(for: "Viernes, ¿qué hora es?", now: now, timeZone: utc)?.contains("3:42") ?? false)
        XCTAssertTrue(DeterministicAnswers.answer(for: "qué día es hoy", now: now, timeZone: utc)?.contains("12 de noviembre de 2026") ?? false)
        XCTAssertNil(DeterministicAnswers.answer(for: "¿Qué hora es en Tokio?", now: now, timeZone: utc), "Ante la duda se pregunta al modelo")
        XCTAssertNil(DeterministicAnswers.answer(for: "hola", now: now, timeZone: utc))
    }

    func testToolSplitKeepsDetailOnlyForTheTopic() {
        let split = ToolGroups.split(ToolCatalog.all, focus: [.calendar])
        XCTAssertTrue(split.detailed.contains { $0.name == "create_event" })
        XCTAssertFalse(split.detailed.contains { $0.name == "compose_message" })
        XCTAssertTrue(split.compact.contains { $0.name == "compose_message" })
        XCTAssertEqual(split.detailed.count + split.compact.count, ToolCatalog.all.count)
    }
}

final class TokenSavingPromptTests: XCTestCase {
    func testFocusedPromptIsMuchShorterAndKeepsEveryToolName() {
        let tools = ToolCatalog.all
        let full = Persona.systemPrompt(PersonaContext(engine: ModelCatalog.cloudDescriptor, tools: tools))
        let none = ToolGroups.split(tools, focus: [])
        let lean = Persona.systemPrompt(PersonaContext(engine: ModelCatalog.cloudDescriptor, tools: none.detailed, compactTools: none.compact, focus: []))
        XCTAssertLessThan(lean.count, full.count * 7 / 10)
        XCTAssertTrue(full.contains("Calendario: para CAMBIAR"))
        XCTAssertFalse(full.contains("Otras herramientas reales"), "Sin modo ahorro el prompt es el de siempre")
        XCTAssertFalse(lean.contains("Calendario: para CAMBIAR"))
        XCTAssertTrue(lean.contains("Otras herramientas reales"))
        for tool in tools { XCTAssertTrue(lean.contains(tool.name), "El modelo debe saber que «\(tool.name)» existe") }

        let calendar = ToolGroups.split(tools, focus: [.calendar])
        let focused = Persona.systemPrompt(PersonaContext(engine: ModelCatalog.cloudDescriptor, tools: calendar.detailed, compactTools: calendar.compact, focus: [.calendar]))
        XCTAssertTrue(focused.contains("Calendario: para CAMBIAR"))
        XCTAssertTrue(focused.contains("- create_event("))
        XCTAssertFalse(focused.contains("Mensajes y llamadas: para escribirle"))
    }
}

final class HistoryAndCacheTests: XCTestCase {
    private func messages(_ count: Int, length: Int) -> [ChatMessage] {
        var result: [ChatMessage] = []
        for index in 0..<count {
            let role: ChatRole = index % 2 == 0 ? .user : .assistant
            let letter: String = String(UnicodeScalar(UInt8(97 + index % 20)))
            result.append(ChatMessage(role: role, text: String(repeating: letter, count: length)))
        }
        return result
    }

    func testDroppedMessagesAreTheOldestOnesOutsideTheWindow() {
        let all = messages(6, length: 10)
        let dropped = HistoryCompactor.dropped(from: all, budget: 25)
        XCTAssertEqual(dropped.count, 4)
        XCTAssertEqual(dropped.first?.id, all.first?.id)
        XCTAssertTrue(HistoryCompactor.dropped(from: all, budget: 1_000).isEmpty)
    }

    func testDigestIsExtractiveBoundedAndLabeledAsPartial() {
        let digest = HistoryCompactor.digest(messages(10, length: 80), maxChars: 200)
        XCTAssertNotNil(digest)
        XCTAssertTrue(digest?.contains("recortado") ?? false)
        XCTAssertEqual((digest ?? "").components(separatedBy: "• ").count - 1, 2, "Respeta el límite de caracteres")
        XCTAssertNil(HistoryCompactor.digest([ChatMessage(role: .assistant, text: "solo asistente")]))
        XCTAssertNil(HistoryCompactor.digest([]))
    }

    func testCacheNeverStoresVolatileOrToolInformation() {
        XCTAssertTrue(ResponseCache.isCacheable(text: "¿Qué es la fotosíntesis?", kind: .generalQuestion))
        XCTAssertFalse(ResponseCache.isCacheable(text: "¿Qué clima hará hoy?", kind: .generalQuestion))
        XCTAssertFalse(ResponseCache.isCacheable(text: "Dame las noticias", kind: .generalQuestion))
        XCTAssertFalse(ResponseCache.isCacheable(text: "¿Qué tengo en la agenda?", kind: .toolExecution))
        XCTAssertFalse(ResponseCache.isCacheable(text: "¿Qué es esto?", kind: .imageAnalysis))
        XCTAssertFalse(ResponseCache.isCacheable(text: String(repeating: "a", count: 700), kind: .generalQuestion))
    }

    func testCacheExpiresAndIsBounded() {
        let cache = ResponseCache(capacity: 2, ttl: 60)
        let now = Date(timeIntervalSince1970: 5_000_000)
        cache.put("k1", text: "uno", now: now)
        XCTAssertEqual(cache.get("k1", now: now.addingTimeInterval(30)), "uno")
        XCTAssertNil(cache.get("k1", now: now.addingTimeInterval(61)), "Caduca")
        cache.put("a", text: "A", now: now)
        cache.put("b", text: "B", now: now)
        cache.put("c", text: "C", now: now)
        XCTAssertNil(cache.get("a", now: now), "Tiene un tamaño máximo")
        XCTAssertEqual(cache.get("c", now: now), "C")
        XCTAssertNotEqual(ResponseCache.key(provider: "p", model: "m", userText: "hola", context: "x"),
                          ResponseCache.key(provider: "p", model: "m", userText: "hola", context: "y"))
    }
}

final class IntelligenceRouterTests: XCTestCase {
    private let groqSelected = CloudBrainSettings(providerID: "groq", model: "openai/gpt-oss-120b")

    private func inputs(configured: Set<String> = ["gemini", "groq"], authorized: Set<String>? = nil, healthy: Set<String>? = nil,
                        local: Bool = false, selected: CloudBrainSettings? = nil) -> RouteInputs {
        RouteInputs(configured: configured, authorized: authorized ?? configured, healthy: healthy ?? configured, localReady: local,
                    selected: selected ?? groqSelected)
    }

    private func enabled(_ change: (inout RoutingSettings) -> Void = { _ in }) -> RoutingSettings {
        var settings = RoutingSettings.default
        settings.enabled = true
        change(&settings)
        return settings
    }

    func testDisabledRouterNeverRoutes() {
        XCTAssertNil(IntelligenceRouter.decide(kind: .simpleChat, settings: .default, inputs: inputs()), "Apagado por defecto: se usa el cerebro elegido")
    }

    func testFrequentTasksGoToTheEconomicModelAndHardOnesToTheStrongOne() {
        let simple = IntelligenceRouter.decide(kind: .simpleChat, settings: enabled(), inputs: inputs())
        XCTAssertEqual(simple?.target, .cloud(providerID: "gemini", model: "gemini-2.5-flash-lite"))
        XCTAssertEqual(simple?.fallbacks, [], "Sin «cambiar si falla» no hay reserva")

        let settings = enabled { $0.tiers["gemini"] = TierModels(light: "gemini-x-lite", strong: "gemini-x") }
        XCTAssertEqual(IntelligenceRouter.decide(kind: .simpleChat, settings: settings, inputs: inputs())?.target, .cloud(providerID: "gemini", model: "gemini-x-lite"))
        XCTAssertEqual(IntelligenceRouter.decide(kind: .complexReasoning, settings: settings, inputs: inputs())?.target, .cloud(providerID: "gemini", model: "gemini-x"))
        XCTAssertEqual(IntelligenceRouter.decide(kind: .toolExecution, settings: settings, inputs: inputs())?.target, .cloud(providerID: "gemini", model: "gemini-x"))
    }

    func testOnlyConfiguredAuthorizedAndHealthyProvidersAreEligible() {
        let order = inputs(authorized: ["groq"])
        XCTAssertEqual(IntelligenceRouter.decide(kind: .simpleChat, settings: enabled(), inputs: order)?.target,
                       .cloud(providerID: "groq", model: CloudProviders.groq.defaultModel), "Gemini no está autorizado")
        XCTAssertEqual(IntelligenceRouter.decide(kind: .simpleChat, settings: enabled(), inputs: inputs(healthy: ["groq"]))?.target,
                       .cloud(providerID: "groq", model: CloudProviders.groq.defaultModel), "Gemini está en pausa")
        XCTAssertNil(IntelligenceRouter.decide(kind: .simpleChat, settings: enabled(), inputs: inputs(configured: [])), "Nada elegible: se usa el cerebro de siempre")
        XCTAssertNil(IntelligenceRouter.decide(kind: .simpleChat, settings: enabled(), inputs: inputs(authorized: [])))
    }

    func testFailoverListsOnlyOtherEligibleProviders() {
        let settings = enabled { $0.allowFailover = true }
        let decision = IntelligenceRouter.decide(kind: .simpleChat, settings: settings, inputs: inputs())
        XCTAssertEqual(decision?.fallbacks, [.cloud(providerID: "groq", model: CloudProviders.groq.defaultModel)])
        let unauthorized = IntelligenceRouter.decide(kind: .simpleChat, settings: settings, inputs: inputs(authorized: ["gemini"]))
        XCTAssertEqual(unauthorized?.fallbacks, [], "Un proveedor no autorizado jamás es reserva")
    }

    func testEconomyProviderOnlyChangesTheEconomicTier() {
        let settings = enabled { $0.economyProviderID = "groq" }
        XCTAssertEqual(IntelligenceRouter.decide(kind: .simpleChat, settings: settings, inputs: inputs())?.target,
                       .cloud(providerID: "groq", model: CloudProviders.groq.defaultModel))
        XCTAssertEqual(IntelligenceRouter.decide(kind: .complexReasoning, settings: settings, inputs: inputs())?.target,
                       .cloud(providerID: "gemini", model: CloudProviders.gemini.defaultModel))
    }

    func testLocalModelIsPreferredForSimpleThingsOnlyWhenAskedAndReady() {
        let settings = enabled { $0.preferLocalForSimple = true }
        XCTAssertEqual(IntelligenceRouter.decide(kind: .simpleChat, settings: settings, inputs: inputs(local: true))?.target, RouteTarget.local)
        XCTAssertNotEqual(IntelligenceRouter.decide(kind: .simpleChat, settings: settings, inputs: inputs(local: false))?.target, RouteTarget.local)
        XCTAssertNotEqual(IntelligenceRouter.decide(kind: .toolExecution, settings: settings, inputs: inputs(local: true))?.target, RouteTarget.local)
        XCTAssertNotEqual(IntelligenceRouter.decide(kind: .simpleChat, settings: enabled(), inputs: inputs(local: true))?.target, RouteTarget.local)
    }

    func testStrongTierFallsBackToTheSelectedModelOfThatProvider() {
        let selected = CloudBrainSettings(providerID: "gemini", model: "gemini-9")
        XCTAssertEqual(IntelligenceRouter.decide(kind: .complexReasoning, settings: enabled(), inputs: inputs(selected: selected))?.target,
                       .cloud(providerID: "gemini", model: "gemini-9"))
        XCTAssertEqual(IntelligenceRouter.decide(kind: .simpleChat, settings: enabled(), inputs: inputs(selected: selected))?.target,
                       .cloud(providerID: "gemini", model: CloudProviders.gemini.defaultModel))
    }

    func testSettingsAreSanitized() {
        var settings = RoutingSettings.default
        settings.order = ["groq", "zzz", "groq"]
        settings.economyProviderID = "zzz"
        settings.tiers = ["gemini": TierModels(light: "a b", strong: " bueno "), "zzz": TierModels(light: "x")]
        let clean = settings.sanitized()
        XCTAssertEqual(clean.order, ["groq", "gemini", "cerebras", "openai"])
        XCTAssertNil(clean.economyProviderID)
        XCTAssertNil(clean.tiers["gemini"]?.light)
        XCTAssertEqual(clean.tiers["gemini"]?.strong, "bueno")
        XCTAssertNil(clean.tiers["zzz"])
        XCTAssertEqual(AppSettings.default.routingSettings, .default)
        XCTAssertTrue(AppSettings.default.tokenSaverEnabled)
    }
}

final class TokenSavingConversationTests: XCTestCase {
    private func make(script: [[String]], cloud: Bool = true, config: ConversationConfig = ConversationConfig()) -> (ConversationEngine, ScriptedEngine) {
        let scripted = cloud ? ScriptedEngine(script: script, descriptor: ModelCatalog.cloudDescriptor) : ScriptedEngine(script: script)
        return (ConversationEngine(engine: scripted, memory: InMemoryMemoryStore(), executor: RecordingExecutor(),
                                   confirmer: RecordingConfirmer(approve: true), config: config), scripted)
    }

    func testTimeAndDateAreAnsweredByCodeWithoutCallingTheModel() async {
        let (engine, scripted) = make(script: [])
        let events = await collect(await engine.send("¿Qué hora es?"))
        XCTAssertTrue(events.completedMessage?.text.hasPrefix("Son las") ?? false)
        XCTAssertTrue(scripted.requests.isEmpty, "Cero llamadas al modelo")
        let history = await engine.snapshot()
        XCTAssertEqual(history.map(\.role), [.user, .assistant])
    }

    func testSimpleChatSendsTheLeanPromptAndABoundedOutputToACloudBrain() async {
        let (engine, scripted) = make(script: [["Hola."]])
        _ = await collect(await engine.send("Hola Viernes, cuéntame algo"))
        let request = scripted.requests[0]
        XCTAssertFalse(request.system.contains("Calendario: para CAMBIAR"))
        XCTAssertTrue(request.system.contains("Otras herramientas reales"))
        XCTAssertEqual(request.outputBudget, RequestClass.simpleChat.outputBudget)
        XCTAssertFalse(request.sensitive)
    }

    func testLocalModelsAndTheSwitchOffKeepTheFullPrompt() async {
        let (local, localScripted) = make(script: [["Hola."]], cloud: false)
        _ = await collect(await local.send("Hola Viernes, cuéntame algo"))
        XCTAssertTrue(localScripted.requests[0].system.contains("Calendario: para CAMBIAR"), "El ahorro es solo para la nube")
        XCTAssertNil(localScripted.requests[0].outputBudget)

        let (off, offScripted) = make(script: [["Hola."]], config: ConversationConfig(optimizeTokens: false))
        _ = await collect(await off.send("Hola Viernes, cuéntame algo"))
        XCTAssertTrue(offScripted.requests[0].system.contains("Calendario: para CAMBIAR"))
        XCTAssertNil(offScripted.requests[0].outputBudget)
    }

    func testAShortAnswerToAToolQuestionKeepsTheMessagingGuide() async {
        let (engine, scripted) = make(script: [["¿Qué texto deseas que le envíe a Checho?"], ["Listo."]])
        _ = await collect(await engine.send("Mándale un WhatsApp a Checho"))
        _ = await collect(await engine.send("Dile que ya llegué"))
        XCTAssertTrue(scripted.requests[0].system.contains("Mensajes y llamadas: para escribirle"))
        XCTAssertTrue(scripted.requests[1].system.contains("Mensajes y llamadas: para escribirle"), "La respuesta corta sigue siendo del mismo tema")
    }

    func testTrimmedHistoryLeavesAShortLocalSummary() async {
        let (engine, scripted) = make(script: [["Hola."]])
        var old: [ChatMessage] = []
        let filler: String = String(repeating: "x", count: 280)
        for index in 0..<20 {
            let role: ChatRole = index % 2 == 0 ? .user : .assistant
            let text: String = "mensaje antiguo número \(index) \(filler)"
            old.append(ChatMessage(role: role, text: text))
        }
        await engine.restore(old)
        _ = await collect(await engine.send("Hola"))
        XCTAssertTrue(scripted.requests[0].system.contains("Resumen automático y recortado"))
        XCTAssertLessThanOrEqual(scripted.requests[0].turns.reduce(0) { $0 + $1.content.count }, RequestClass.simpleChat.historyChars + 400)
    }

    func testAnIdenticalSelfContainedQuestionIsServedFromTheLocalCache() async {
        let (engine, scripted) = make(script: [["Es el proceso con el que las plantas fabrican su alimento."]])
        let question = "¿Qué es la fotosíntesis en las plantas?"
        let first = await collect(await engine.send(question))
        let second = await collect(await engine.send(question))
        XCTAssertEqual(scripted.requests.count, 1, "La segunda vez no se llamó al proveedor")
        XCTAssertEqual(first.completedMessage?.text, second.completedMessage?.text)
    }

    func testVolatileQuestionsAreNeverServedFromTheCache() async {
        let (engine, scripted) = make(script: [["Soleado."], ["Nublado."]])
        let question = "¿Qué clima hace hoy en la ciudad de Medellín?"
        _ = await collect(await engine.send(question))
        let second = await collect(await engine.send(question))
        XCTAssertEqual(scripted.requests.count, 2)
        XCTAssertEqual(second.completedMessage?.text, "Nublado.")
    }

    func testRoutedBrainReplacesTheDefaultOneOnlyWhenAProviderIsGiven() async {
        let main = ScriptedEngine(script: [["principal"]], descriptor: ModelCatalog.cloudDescriptor)
        let routed = ScriptedEngine(script: [["enrutado"]], descriptor: ModelCatalog.cloudDescriptor)
        let engine = ConversationEngine(engine: main, memory: InMemoryMemoryStore(), executor: RecordingExecutor(),
                                        confirmer: RecordingConfirmer(approve: true), config: ConversationConfig())
        let kinds = KindRecorder()
        await engine.setRouteProvider { kind in
            kinds.add(kind)
            return routed
        }
        let events = await collect(await engine.send("Hola Viernes, cuéntame algo"))
        XCTAssertEqual(events.completedMessage?.text, "enrutado")
        XCTAssertTrue(main.requests.isEmpty)
        XCTAssertEqual(kinds.values, [.simpleChat])

        await engine.setRouteProvider { _ in nil }
        let again = await collect(await engine.send("Otra cosa distinta, cuéntame más"))
        XCTAssertEqual(again.completedMessage?.text, "principal")
    }
}

private final class KindRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [RequestClass] = []
    func add(_ kind: RequestClass) { lock.withLock { stored.append(kind) } }
    var values: [RequestClass] { lock.withLock { stored } }
}
