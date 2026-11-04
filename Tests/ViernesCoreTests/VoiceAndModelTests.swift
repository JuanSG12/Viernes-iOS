import XCTest
@testable import ViernesCore

final class VoiceAndModelTests: XCTestCase {
    // MARK: Filtro de etiquetas

    private func makeFilter() -> StreamingTagFilter {
        StreamingTagFilter(specs: [
            .init(open: "<think>", close: "</think>", capture: false),
            .init(open: "<tool>", close: "</tool>", capture: true)
        ])
    }

    func testFilterSplitsAcrossChunks() {
        let filter = makeFilter()
        var visible = ""
        for chunk in ["Hola <thi", "nk>razonando</think>Listo <tool>{\"a\":1}</to", "ol> fin"] { visible += filter.feed(chunk) }
        visible += filter.finish()
        XCTAssertEqual(visible, "Hola Listo  fin")
        XCTAssertEqual(filter.captured, [.init(open: "<tool>", content: "{\"a\":1}")])
    }

    func testFilterIsChunkingInvariant() {
        let text = "Antes <think>duda</think>Medio <tool>{\"name\":\"x\"}</tool> Después"
        let whole = makeFilter()
        let expected = whole.feed(text) + whole.finish()
        let perChar = makeFilter()
        var visible = ""
        for character in text { visible += perChar.feed(String(character)) }
        visible += perChar.finish()
        XCTAssertEqual(visible, expected)
        XCTAssertEqual(perChar.captured, whole.captured)
    }

    func testFilterDropsUnterminatedBlocksAndFlagsThem() {
        let filter = makeFilter()
        var visible = filter.feed("A <think>nunca cierra")
        visible += filter.finish()
        XCTAssertEqual(visible, "A ")
        XCTAssertEqual(filter.unterminatedBlocks, 1)
    }

    func testFilterKeepsLoneAngleBrackets() {
        let filter = makeFilter()
        let out = filter.feed("2 < 3 y 5 > 4") + filter.finish()
        XCTAssertEqual(out, "2 < 3 y 5 > 4")
    }

    // MARK: Palabra de activación

    func testWakeWordMatching() {
        let matcher = WakeWordMatcher()
        XCTAssertEqual(matcher.match(in: "Viernes")?.trailingCommand, "")
        XCTAssertEqual(matcher.match(in: "Oye Viernes, abre Spotify")?.trailingCommand, "abre Spotify")
        XCTAssertEqual(matcher.match(in: "biernes enciende la música")?.trailingCommand, "enciende la música")
        XCTAssertNil(matcher.match(in: "el viernes voy al cine"))
        XCTAssertNil(matcher.match(in: "hoy es viernes"))
        XCTAssertNil(matcher.match(in: "vienes mañana"))
        XCTAssertNil(matcher.match(in: "buenos días"))
    }

    // MARK: Silencio

    func testSilenceDetectorEndsUtteranceAfterSpeechThenSilence() {
        var detector = SilenceDetector()
        var ended: Int?
        for i in 0..<60 {
            let time = Double(i) * 0.1
            let level: Float = i < 10 ? -20 : -60
            if detector.process(levelDB: level, at: time) == .endOfUtterance { ended = i; break }
        }
        let index = try? XCTUnwrap(ended)
        XCTAssertNotNil(index)
        XCTAssertTrue((20...25).contains(index ?? -1), "terminó en \(String(describing: index))")
    }

    func testSilenceDetectorTimesOutWithoutSpeech() {
        var detector = SilenceDetector()
        var decision = SilenceDetector.Decision.keepListening
        for i in 0..<100 where decision == .keepListening { decision = detector.process(levelDB: -62, at: Double(i) * 0.1) }
        XCTAssertEqual(decision, .noSpeech)
    }

    func testSilenceDetectorIgnoresShortClicks() {
        var detector = SilenceDetector()
        var decision = SilenceDetector.Decision.keepListening
        for i in 0..<100 where decision == .keepListening {
            decision = detector.process(levelDB: i == 5 ? -10 : -62, at: Double(i) * 0.1)
        }
        XCTAssertEqual(decision, .noSpeech)
    }

    func testSilenceDetectorCapsLongSpeech() {
        var detector = SilenceDetector()
        var decision = SilenceDetector.Decision.keepListening
        for i in 0..<500 where decision == .keepListening { decision = detector.process(levelDB: -20, at: Double(i) * 0.1) }
        XCTAssertEqual(decision, .maxDurationReached)
    }

    // MARK: Texto para voz

    func testSpeechCleaningRemovesMarkdownEmojiAndURLs() {
        XCTAssertEqual(SpeechText.clean("**Hola** _mundo_ 😀 mira https://example.com/a"), "Hola mundo mira un enlace")
        XCTAssertEqual(SpeechText.clean("## Título\n- uno\n- dos"), "Título\nuno\ndos")
        XCTAssertEqual(SpeechText.clean("[Apple](https://apple.com) es una marca"), "Apple es una marca")
    }

    func testSpeechChunksSplitSentencesWithPauses() {
        let chunks = SpeechText.chunks("Hola. ¿Cómo estás? Bien")
        XCTAssertEqual(chunks.map(\.text), ["Hola.", "¿Cómo estás?", "Bien"])
        XCTAssertEqual(chunks.last?.pauseAfter, 0)
        XCTAssertGreaterThan(chunks[0].pauseAfter, 0)
        XCTAssertEqual(SpeechText.chunks("Pi vale 3.14 aprox. Listo").count, 2)
        XCTAssertTrue(SpeechText.chunks("   ").isEmpty)
    }

    func testLongSentencesAreWrapped() {
        let long = Array(repeating: "palabra", count: 100).joined(separator: " ") + "."
        let chunks = SpeechText.chunks(long, maxLength: 120)
        XCTAssertGreaterThan(chunks.count, 4)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 130 })
    }

    // MARK: Selección de voz

    func testVoiceRankerPrefersQualityThenColombianThenFemale() {
        let voices = [
            VoiceDescriptor(identifier: "com.apple.voice.enhanced.es-CO.Soledad", name: "Soledad", language: "es-CO", quality: .enhanced, gender: .female),
            VoiceDescriptor(identifier: "com.apple.voice.premium.es-MX.Paulina", name: "Paulina", language: "es-MX", quality: .premium, gender: .female),
            VoiceDescriptor(identifier: "com.apple.eloquence.es-ES.Eddy", name: "Eddy", language: "es-ES", quality: .standard, gender: .male),
            VoiceDescriptor(identifier: "com.apple.voice.enhanced.es-MX.Juan", name: "Juan", language: "es-MX", quality: .enhanced, gender: .male),
            VoiceDescriptor(identifier: "com.apple.voice.premium.en-US.Zoe", name: "Zoe", language: "en-US", quality: .premium, gender: .female)
        ]
        let ranked = VoiceRanker.rank(voices)
        XCTAssertEqual(ranked.first?.name, "Paulina")                    // Premium > Mejorada
        XCTAssertEqual(ranked.last?.name, "Eddy")                        // eloquence = robótica
        XCTAssertFalse(ranked.contains { $0.language == "en-US" })       // solo español
        let enhancedOnly = voices.filter { $0.quality == .enhanced }
        XCTAssertEqual(VoiceRanker.best(enhancedOnly)?.name, "Soledad")  // misma calidad: es-CO y femenina ganan
        XCTAssertNil(VoiceRanker.best([]))
    }

    // MARK: Modelos

    func testCatalogIsConsistent() {
        XCTAssertEqual(Set(ModelCatalog.all.map(\.id)).count, ModelCatalog.all.count)
        XCTAssertNotNil(ModelCatalog.descriptor(id: ModelCatalog.appleFoundationID))
        for model in ModelCatalog.all where !model.isSystemModel {
            if case .mlx(let repo) = model.backend { XCTAssertTrue(repo.hasPrefix("mlx-community/")) }
            XCTAssertGreaterThan(model.approxDownloadMB, 0)
            XCTAssertFalse(model.license.isEmpty)
        }
    }

    private func gb(_ value: Double) -> UInt64 { UInt64(value * 1_073_741_824) }

    func testRecommenderRespectsDeviceMemory() {
        func fit(_ id: String, ram: Double) -> ModelFit {
            ModelRecommender.fit(for: ModelCatalog.descriptor(id: id)!, physicalMemoryBytes: gb(ram), foundationAvailable: false)
        }
        XCTAssertEqual(fit("qwen3-4b-4bit", ram: 8), .possible)
        XCTAssertEqual(fit("qwen3-4b-4bit", ram: 6), .notRecommended)
        XCTAssertEqual(fit("llama3.2-3b-4bit", ram: 6), .notRecommended)
        XCTAssertEqual(fit("qwen3-1.7b-4bit", ram: 6), .recommended)
        XCTAssertEqual(fit("gemma3-1b-qat-4bit", ram: 4), .recommended)
        XCTAssertEqual(fit("qwen3-1.7b-4bit", ram: 4), .notRecommended)
        XCTAssertEqual(ModelRecommender.fit(for: ModelCatalog.descriptor(id: ModelCatalog.appleFoundationID)!, physicalMemoryBytes: gb(8), foundationAvailable: false), .notRecommended)
    }

    func testDefaultModelPrefersSystemModelWhenAvailable() {
        XCTAssertEqual(ModelRecommender.defaultModel(physicalMemoryBytes: gb(8), foundationAvailable: true).id, ModelCatalog.appleFoundationID)
        let fallback = ModelRecommender.defaultModel(physicalMemoryBytes: gb(6), foundationAvailable: false)
        XCTAssertFalse(fallback.isSystemModel)
        XCTAssertEqual(fallback.id, "gemma3-1b-qat-4bit")
        XCTAssertFalse(ModelRecommender.defaultModel(physicalMemoryBytes: gb(2), foundationAvailable: false).isSystemModel)
    }

    // MARK: Personalidad y ajustes

    func testPersonaPromptCarriesHonestyRulesAndContext() {
        let memory = MemoryItem(kind: .preference, text: "Prefiere respuestas breves", source: .userExplicit)
        let qwen = ModelCatalog.descriptor(id: "qwen3-1.7b-4bit")!
        let prompt = Persona.systemPrompt(PersonaContext(engine: qwen, memories: [memory], claudeMode: .openApp))
        for needle in ["Viernes", "español colombiano", "Qwen3 1.7B", "Prefiere respuestas breves", "/no_think", "create_reminder", Persona.resultMarker, "no tienes acceso a internet", "solo abre Claude"] {
            XCTAssertTrue(prompt.contains(needle), "falta «\(needle)»")
        }
        let apple = ModelCatalog.descriptor(id: ModelCatalog.appleFoundationID)!
        XCTAssertFalse(Persona.systemPrompt(PersonaContext(engine: apple)).contains("/no_think"))
        XCTAssertFalse(Persona.systemPrompt(PersonaContext(engine: apple, spokenOutput: false)).contains("no uses markdown"))
    }

    func testSettingsSanitizationAndRoundTrip() throws {
        var settings = AppSettings.default
        settings.voice.rate = 5
        settings.voice.volume = -1
        settings.selectedModelID = "modelo-inexistente"
        settings.claude.shortcutName = "   "
        let clean = settings.sanitized()
        XCTAssertEqual(clean.voice.rate, 0.65)
        XCTAssertEqual(clean.voice.volume, 0)
        XCTAssertNil(clean.selectedModelID)
        XCTAssertEqual(clean.claude.shortcutName, "Preguntar a Claude")

        let data = try JSONEncoder().encode(AppSettings.default)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), AppSettings.default)
    }

    func testPrivacyDefaultsAreConservative() {
        let defaults = AppSettings.default
        XCTAssertFalse(defaults.wakeWordEnabled)
        XCTAssertFalse(defaults.continuousConversation)
        XCTAssertFalse(defaults.allowServerRecognition)      // el audio no sale del teléfono por defecto
        XCTAssertFalse(defaults.memory.autoSuggest)
        XCTAssertEqual(defaults.claude.mode, .disabled)
        XCTAssertEqual(defaults.transcriptRetention, .days7)
    }
}
