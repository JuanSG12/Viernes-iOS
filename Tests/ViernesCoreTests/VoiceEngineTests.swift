import XCTest
@testable import ViernesCore

// Motor de voz en tiempo real (0.7): segmentación, turnos, colchón anti-cortes, PCM, métricas y protocolo WebSocket de ElevenLabs.
// Todo es lógica pura con un reloj falso: las pruebas son reproducibles y no miden la red ni el teléfono.

private func segments(of text: String, chunk: Int) -> [SpeechSegment] {
    var segmenter = SpeechSegmenter()
    var out: [SpeechSegment] = []
    var buffer = ""
    for character in text {
        buffer.append(character)
        if buffer.count >= chunk { out += segmenter.feed(buffer); buffer = "" }
    }
    if !buffer.isEmpty { out += segmenter.feed(buffer) }
    out += segmenter.flush()
    return out
}

final class SpeechSegmenterTests: XCTestCase {
    func testShortSentencesAreMergedAndTheLastOneComesOutOnFlush() {
        let result = segments(of: "Hola. ¿Cómo estás? Muy bien, gracias.", chunk: 1000)
        XCTAssertEqual(result.map(\.text), ["Hola. ¿Cómo estás?", "Muy bien, gracias."])
        XCTAssertEqual(result.map(\.index), [0, 1])
        XCTAssertEqual(result[0].pauseAfter, 0.30, accuracy: 0.001, "Tras una pregunta, pausa algo mayor")
    }

    func testTheFirstSegmentLeavesAtTheFirstLongClauseBeforeTheSentenceEnds() {
        var segmenter = SpeechSegmenter()
        let early = segmenter.feed("Entiendo que quieres saber qué tengo en tu agenda de hoy, déjame")
        XCTAssertEqual(early.map(\.text), ["Entiendo que quieres saber qué tengo en tu agenda de hoy,"], "Empieza a hablar sin esperar al final de la frase")
        XCTAssertTrue(segmenter.feed(" revisarla con calma").isEmpty)
        XCTAssertEqual(segmenter.flush().map(\.text), ["déjame revisarla con calma"])
    }

    func testClausesAreNotCutAfterTheFirstSegment() {
        let result = segments(of: "Primero te saludo con calma. Después, con mucho gusto y sin ninguna prisa, te cuento el plan completo de la tarde, que es largo. Fin.", chunk: 1000)
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result[1].text.hasPrefix("Después, con mucho gusto"), "Las comas ya no parten fragmentos: solo la frase completa")
        XCTAssertTrue(result[1].text.hasSuffix("que es largo."))
    }

    func testNeverCutsDecimalsAbbreviationsInitialsOrLowercaseContinuations() {
        XCTAssertEqual(segments(of: "El Dr. García pagó 3.14 pesos. Luego se fue.", chunk: 1000).map(\.text),
                       ["El Dr. García pagó 3.14 pesos.", "Luego se fue."])
        XCTAssertEqual(segments(of: "Compré pan, leche, etc. y luego volví a casa. Fin.", chunk: 1000).map(\.text),
                       ["Compré pan, leche, etc. y luego volví a casa.", "Fin."])
        XCTAssertEqual(segments(of: "Hablé con J. Pérez ayer. Todo bien.", chunk: 1000).map(\.text),
                       ["Hablé con J. Pérez ayer.", "Todo bien."])
        XCTAssertEqual(segments(of: "Nos vemos a las 5 p. m. en la oficina. Gracias.", chunk: 1000).map(\.text),
                       ["Nos vemos a las 5 p. m. en la oficina.", "Gracias."])
    }

    func testListsAndParagraphsCutAtLineEndsAndLoseTheirMarkers() {
        XCTAssertEqual(segments(of: "1. Primero\n2. Segundo", chunk: 1000).map(\.text), ["Primero", "Segundo"])
        XCTAssertEqual(segments(of: "## Título\nTexto del párrafo.", chunk: 1000).map(\.text), ["Título", "Texto del párrafo."])
    }

    func testNothingIsSpokenForMarkupOnlyText() {
        XCTAssertTrue(segments(of: "**", chunk: 1).isEmpty)
        XCTAssertTrue(segments(of: "  \n \n ", chunk: 2).isEmpty)
    }

    func testAnEndingWithoutLookaheadWaitsForMoreTextThenFlushes() {
        var segmenter = SpeechSegmenter()
        XCTAssertTrue(segmenter.feed("Hola, soy Viernes.").isEmpty, "Aún no se sabe si «.» cierra la frase (podría ser «Viernes.com»)")
        XCTAssertEqual(segmenter.flush().map(\.text), ["Hola, soy Viernes."])
        XCTAssertTrue(segmenter.flush().isEmpty)
    }

    func testVeryLongSentencesAreSplitBelowTheMaximum() {
        let words = (0..<60).map { "palabra\($0)" }.joined(separator: " ")
        let result = segments(of: words, chunk: 1000)
        XCTAssertGreaterThan(result.count, 1)
        for piece in result { XCTAssertLessThanOrEqual(piece.text.count, 220, piece.text) }
        XCTAssertEqual(result.map(\.text).joined(separator: " "), words, "No se pierde ni se repite nada")
    }

    func testTheResultDoesNotDependOnHowTheDeltasArrive() {
        let samples = [
            "Claro, ahora mismo reviso tu agenda de hoy y te cuento lo que tienes pendiente, empezando por la reunión de las tres. Después viene la llamada con tu jefe a las cinco de la tarde. ¿Quieres que te recuerde algo? Eso es todo por hoy...",
            "Mira esto:\n1. Primero revisa el contrato.\n2. Luego firma con el Dr. Pérez a las 5 p. m. en punto.\n\nPara terminar, el total es 3.14 millones. Gracias",
            String(repeating: "una frase larga sin ningún signo de puntuación que sigue y sigue ", count: 7) + ". Fin del texto.",
            "¡Listo! Ya está. Sí. No. Tal vez... Quizá sí, quizá no, depende de lo que digas ahora mismo con tranquilidad. Adiós."
        ]
        for text in samples {
            let whole = segments(of: text, chunk: 100_000)
            XCTAssertFalse(whole.isEmpty)
            for size in [1, 2, 3, 5, 8, 13, 34] {
                XCTAssertEqual(segments(of: text, chunk: size), whole, "chunk \(size): \(text.prefix(40))")
            }
        }
    }
}

final class VoiceTurnLedgerTests: XCTestCase {
    private func segment(_ index: Int, _ text: String) -> SpeechSegment { SpeechSegment(index: index, text: text, pauseAfter: 0.2) }

    func testSegmentsAreAcceptedOnlyOnceAndInOrder() {
        var ledger = VoiceTurnLedger()
        let turn = ledger.beginTurn()
        XCTAssertEqual(ledger.accept(segment(0, "Uno."), turn: turn), .accepted)
        XCTAssertEqual(ledger.accept(segment(0, "Uno."), turn: turn), .duplicate, "Un reintento no se vuelve a hablar")
        XCTAssertEqual(ledger.accept(segment(2, "Tres."), turn: turn), .outOfOrder, "No se habla fuera de orden")
        XCTAssertEqual(ledger.accept(segment(1, "Dos."), turn: turn), .accepted)
        XCTAssertTrue(ledger.endText(turn: turn))
        XCTAssertEqual(ledger.accept(segment(2, "Tres."), turn: turn), .afterEnd)
    }

    func testCancellingInvalidatesEverythingFromTheOldTurn() {
        var ledger = VoiceTurnLedger()
        let first = ledger.beginTurn()
        XCTAssertEqual(ledger.accept(segment(0, "Hola."), turn: first), .accepted)
        ledger.cancel()
        XCTAssertFalse(ledger.isCurrent(first))
        XCTAssertEqual(ledger.accept(segment(1, "Tardío."), turn: first), .stale, "Un fragmento tardío del turno cancelado se descarta")
        ledger.recordSpoken(characters: 5, turn: first)
        XCTAssertEqual(ledger.spokenCharacters, 0)
        let second = ledger.beginTurn()
        XCTAssertGreaterThan(second, first)
        XCTAssertEqual(ledger.accept(segment(0, "Nuevo."), turn: second), .accepted, "El turno nuevo empieza limpio")
        XCTAssertEqual(ledger.accept(segment(0, "Viejo."), turn: first), .stale)
    }

    func testRemainingTextResumesAfterWhatWasAlreadySpoken() {
        var ledger = VoiceTurnLedger()
        let turn = ledger.beginTurn()
        _ = ledger.accept(segment(0, "Hola, soy Viernes."), turn: turn)
        _ = ledger.accept(segment(1, "Te cuento tu agenda."), turn: turn)
        XCTAssertEqual(ledger.sentCharacters, 40)
        XCTAssertEqual(ledger.remainingText(), "Hola, soy Viernes. Te cuento tu agenda.")
        ledger.recordSpoken(characters: 19, turn: turn)
        XCTAssertEqual(ledger.remainingText(), "Te cuento tu agenda.")
        ledger.recordSpoken(characters: 6, turn: turn)         // cae a media palabra («Te cue|nto»)
        XCTAssertEqual(ledger.remainingText(), "tu agenda.", "Se retoma en la palabra siguiente, sin repetir lo dicho")
        ledger.recordSpoken(characters: 500, turn: turn)
        XCTAssertEqual(ledger.remainingText(), "", "Nunca se cuenta más de lo enviado")
    }
}

final class JitterBufferAndPCMTests: XCTestCase {
    func testPlaybackStartsWithACushionAndRebuffersLessAfterAnUnderrun() {
        let policy = JitterBufferPolicy()
        XCTAssertFalse(policy.shouldPlay(bufferedMs: 100, wasPlaying: false, inputFinished: false, heldMs: 0))
        XCTAssertTrue(policy.shouldPlay(bufferedMs: 250, wasPlaying: false, inputFinished: false, heldMs: 0))
        XCTAssertFalse(policy.shouldPlay(bufferedMs: 100, wasPlaying: true, inputFinished: false, heldMs: 0))
        XCTAssertTrue(policy.shouldPlay(bufferedMs: 150, wasPlaying: true, inputFinished: false, heldMs: 0))
        XCTAssertTrue(policy.shouldPlay(bufferedMs: 40, wasPlaying: false, inputFinished: true, heldMs: 0), "Si ya no llegará más, se suena lo que haya")
        XCTAssertTrue(policy.shouldPlay(bufferedMs: 60, wasPlaying: false, inputFinished: false, heldMs: 1_300), "Un flujo estancado no deja en silencio para siempre")
        XCTAssertFalse(policy.shouldPlay(bufferedMs: 0, wasPlaying: false, inputFinished: true, heldMs: 5_000), "Sin audio no hay nada que sonar")
    }

    func testPCMDecodingHandlesChunksSplitInTheMiddleOfASample() {
        let bytes: [UInt8] = [0xE8, 0x03, 0x18, 0xFC, 0xFF, 0x7F, 0x00, 0x80]        // 1000, -1000, 32767, -32768
        var whole = PCMStreamDecoder()
        let expected = whole.decode(Data(bytes))
        XCTAssertEqual(expected.count, 4)
        XCTAssertEqual(expected[0], 1000 / 32_768, accuracy: 1e-6)
        XCTAssertEqual(expected[1], -1000 / 32_768, accuracy: 1e-6)
        XCTAssertEqual(expected[3], -1, accuracy: 1e-6)
        for split in [1, 3, 5, 7] {
            var decoder = PCMStreamDecoder()
            let joined = decoder.decode(Data(bytes[..<split])) + decoder.decode(Data(bytes[split...]))
            XCTAssertEqual(joined, expected, "corte en \(split)")
        }
        var odd = PCMStreamDecoder()
        XCTAssertTrue(odd.decode(Data([0x01])).isEmpty, "Un byte suelto se guarda para el siguiente trozo")
        odd.reset()
        XCTAssertEqual(odd.decode(Data([0x00, 0x40])), [0.5])
        XCTAssertEqual(PCMStreamDecoder.milliseconds(frames: 24_000, sampleRate: 24_000), 1_000, accuracy: 0.001)
        XCTAssertEqual(PCMStreamDecoder.milliseconds(frames: 1, sampleRate: 0), 0)
    }
}

final class VoiceMetricsTests: XCTestCase {
    func testRecorderComputesEveryMilestoneFromAnInjectedClock() throws {
        var recorder = VoiceTurnRecorder(turn: 7, backend: "tiempo real", startedAt: 100)
        recorder.firstToken(at: 100.2)
        recorder.firstToken(at: 100.9)                       // solo cuenta el primero
        recorder.segmentReady(at: 100.25, characters: 40)
        recorder.segmentReady(at: 100.6, characters: 60)
        recorder.firstAudio(at: 100.55)
        recorder.audioScheduled(bytes: 48_000, durationMs: 1_000)
        recorder.gap(ms: 80)
        recorder.gap(ms: 0)                                   // un hueco de cero no es un hueco
        recorder.discarded()
        recorder.connectionError()
        recorder.reconnected()
        recorder.fellBack()
        recorder.interrupted(at: 101.0)
        recorder.silenced(at: 101.003)
        recorder.finish(at: 101.1, outcome: .interrupted, note: "tocó el núcleo")
        recorder.finish(at: 150, outcome: .completed)         // un turno solo termina una vez
        let metrics = recorder.metrics
        XCTAssertEqual(try XCTUnwrap(metrics.firstTokenMs), 200, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(metrics.firstSegmentMs), 50, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(metrics.firstAudioMs), 550, accuracy: 0.01)
        XCTAssertEqual(metrics.segments, 2)
        XCTAssertEqual(metrics.charactersSent, 100)
        XCTAssertEqual(metrics.audioBytes, 48_000)
        XCTAssertEqual(metrics.gapsMs, [80])
        XCTAssertEqual(metrics.totalGapMs, 80)
        XCTAssertEqual(metrics.discardedSegments, 1)
        XCTAssertEqual(metrics.connectionErrors, 1)
        XCTAssertEqual(metrics.reconnects, 1)
        XCTAssertTrue(metrics.fellBackToSystemVoice)
        XCTAssertEqual(try XCTUnwrap(metrics.silenceAfterInterruptMs), 3, accuracy: 0.01)
        XCTAssertEqual(metrics.outcome, .interrupted)
        XCTAssertEqual(metrics.note, "tocó el núcleo")
        XCTAssertEqual(try XCTUnwrap(metrics.endedAtMs), 1_100, accuracy: 0.01)
        let back = try? JSONDecoder().decode(VoiceTurnMetrics.self, from: JSONEncoder().encode(metrics))
        XCTAssertEqual(back, metrics)
    }

    func testPercentilesAndTheReportOnlyStateWhatWasMeasured() {
        XCTAssertEqual(VoiceMetricsReport.percentile([5, 1, 3, 2, 4], 0.5), 3)
        XCTAssertEqual(VoiceMetricsReport.percentile([5, 1, 3, 2, 4], 0.95), 5)
        XCTAssertEqual(VoiceMetricsReport.percentile([5, 1, 3, 2, 4], 0), 1)
        XCTAssertNil(VoiceMetricsReport.percentile([], 0.5))
        XCTAssertEqual(VoiceMetricsReport.summary([]), "Sin turnos de voz registrados todavía.")

        var a = VoiceTurnRecorder(turn: 1, backend: "tiempo real", startedAt: 0)
        a.firstToken(at: 0.3); a.firstAudio(at: 0.9); a.gap(ms: 120); a.finish(at: 3, outcome: .completed)
        var b = VoiceTurnRecorder(turn: 2, backend: "voz del sistema", startedAt: 0)
        b.firstToken(at: 0.2); b.firstAudio(at: 0.5); b.finish(at: 2, outcome: .completed)
        let report = VoiceMetricsReport.summary([a.metrics, b.metrics])
        XCTAssertTrue(report.contains("Turnos de voz registrados: 2"))
        XCTAssertTrue(report.contains("== tiempo real (1 turnos)"))
        XCTAssertTrue(report.contains("== voz del sistema (1 turnos)"))
        XCTAssertTrue(report.contains("cortes inesperados: 1"))
        XCTAssertTrue(report.contains("900 ms"), "Mediana del primer audio de tiempo real")
        XCTAssertFalse(report.contains("garantiza"))
    }
}

final class ElevenLabsRealtimeTests: XCTestCase {
    private let voice = "21m00Tcm4TlvDq8ikWAM"

    func testURLForTheTextToSpeechWebSocketWithFlash() {
        XCTAssertEqual(
            ElevenLabsRealtime.websocketURL(voiceID: voice, modelID: "eleven_flash_v2_5")?.absoluteString,
            "wss://api.elevenlabs.io/v1/text-to-speech/\(voice)/stream-input?model_id=eleven_flash_v2_5&output_format=pcm_24000&inactivity_timeout=60&sync_alignment=true&language_code=es&auto_mode=true")
        let balanced = ElevenLabsRealtime.websocketURL(voiceID: voice, modelID: "eleven_flash_v2_5", tuning: .balanced)?.absoluteString ?? ""
        XCTAssertFalse(balanced.contains("auto_mode"))
        let multilingual = ElevenLabsRealtime.websocketURL(voiceID: voice, modelID: "eleven_multilingual_v2")?.absoluteString ?? ""
        XCTAssertTrue(multilingual.contains("model_id=eleven_multilingual_v2"))
        XCTAssertFalse(multilingual.contains("language_code"), "multilingual_v2 no admite language_code")
        XCTAssertNil(ElevenLabsRealtime.websocketURL(voiceID: "../x", modelID: "eleven_flash_v2_5"), "El identificador de voz va en la ruta: se valida")
    }

    func testDialogueModelsAreNeverUsedOnTheTextToSpeechSocket() {
        for model in ["eleven_v4_turbo", "eleven_v4", "eleven_v3", "eleven_v3_conversational", "eleven_ttv_v3"] {
            XCTAssertFalse(ElevenLabsRealtime.isRealtimeCompatible(modelID: model), model)
            XCTAssertEqual(ElevenLabsRealtime.compatibleModelID(model), "eleven_flash_v2_5", model)
            let url = ElevenLabsRealtime.websocketURL(voiceID: voice, modelID: model)?.absoluteString ?? ""
            XCTAssertTrue(url.contains("model_id=eleven_flash_v2_5"), "\(model) → el protocolo de Text-to-Speech usa Flash")
            XCTAssertFalse(url.contains("text-to-dialogue"), "Nunca se mezclan los protocolos")
        }
        for model in ["eleven_flash_v2_5", "eleven_turbo_v2_5", "eleven_multilingual_v2"] {
            XCTAssertTrue(ElevenLabsRealtime.isRealtimeCompatible(modelID: model), model)
            XCTAssertEqual(ElevenLabsRealtime.compatibleModelID(model), model)
        }
    }

    func testClientMessagesFollowTheTextToSpeechProtocol() throws {
        let initial = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ElevenLabsRealtime.initialMessage(speed: 1.0).utf8)) as? [String: Any])
        XCTAssertEqual(initial["text"] as? String, " ", "El primer mensaje es un único espacio")
        let settings = try XCTUnwrap(initial["voice_settings"] as? [String: Any])
        XCTAssertEqual(settings["speed"] as? Double, 1.0)
        XCTAssertNil(initial["xi-api-key"], "La clave va en la cabecera, no en el mensaje")
        XCTAssertNil(initial["generation_config"])
        let fast = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ElevenLabsRealtime.initialMessage(speed: 9, tuning: .balanced).utf8)) as? [String: Any])
        XCTAssertEqual((fast["voice_settings"] as? [String: Any])?["speed"] as? Double, 1.2, "La velocidad se recorta al máximo de la API")
        XCTAssertNotNil(fast["generation_config"])

        XCTAssertEqual(ElevenLabsRealtime.textMessage("  Hola, qué tal.  "), #"{"text":"Hola, qué tal. "}"#, "El texto termina en un único espacio")
        XCTAssertEqual(ElevenLabsRealtime.closeMessage, #"{"text":""}"#)
        XCTAssertEqual(ElevenLabsRealtime.flushMessage, #"{"flush":true,"text":" "}"#)
    }

    func testServerMessagesAreParsed() {
        let audio = Data([1, 2, 3, 4])
        let withAlignment = #"{"audio":"\#(audio.base64EncodedString())","alignment":{"chars":["H","o","l","a"],"charStartTimesMs":[0,1,2,3],"charDurationsMs":[1,1,1,1]}}"#
        XCTAssertEqual(ElevenLabsRealtime.parse(withAlignment), .audio(audio, spokenCharacters: 4))
        XCTAssertEqual(ElevenLabsRealtime.parse(#"{"audio":"\#(audio.base64EncodedString())"}"#), .audio(audio, spokenCharacters: 0))
        XCTAssertEqual(ElevenLabsRealtime.parse(#"{"audio":null,"isFinal":true}"#), .final)
        XCTAssertEqual(ElevenLabsRealtime.parse(#"{"audio":null,"isFinal":null}"#), .ignore)
        XCTAssertEqual(ElevenLabsRealtime.parse("no es json"), .ignore)
        XCTAssertEqual(ElevenLabsRealtime.parse(#"{"audio":"%%%no-base64%%%"}"#), .ignore)
    }

    func testServerErrorsSeparateConfigurationProblemsFromTransientOnes() {
        func fatal(_ json: String) -> Bool? {
            if case .error(_, let isFatal) = ElevenLabsRealtime.parse(json) { return isFatal }
            return nil
        }
        XCTAssertEqual(fatal(#"{"message":"You have exceeded your quota"}"#), true)
        XCTAssertEqual(fatal(#"{"error":"invalid_api_key"}"#), true)
        XCTAssertEqual(fatal(#"{"detail":{"status":"voice_not_found","message":"Voice not found"}}"#), true)
        XCTAssertEqual(fatal(#"{"message":"Something odd happened"}"#), false)
        if case .error(let message, _) = ElevenLabsRealtime.parse(#"{"message":"You have exceeded your quota"}"#) {
            XCTAssertTrue(message.contains("cuota"))
        } else { XCTFail("Debía ser un error") }
        XCTAssertTrue(ElevenLabsRealtime.handshakeFailure(status: 401).fatal)
        XCTAssertTrue(ElevenLabsRealtime.handshakeFailure(status: 401).message.contains("rechazó"))
        XCTAssertTrue(ElevenLabsRealtime.handshakeFailure(status: 402).fatal, "Un plan que no permite la voz no se arregla reintentando")
        XCTAssertFalse(ElevenLabsRealtime.handshakeFailure(status: 503).fatal)
        XCTAssertTrue(ElevenLabsRealtime.handshakeFailure(status: 503).message.contains("problemas"))
    }

    func testRealtimeSettingIsOptionalAndOnByDefault() throws {
        XCTAssertTrue(ElevenLabsSettings.default.realtimeEnabled)
        var off = ElevenLabsSettings(enabled: true, voiceID: voice, voiceName: "Rachel", modelID: "eleven_flash_v2_5", realtime: false)
        XCTAssertFalse(off.realtimeEnabled)
        XCTAssertEqual(off.sanitized().realtime, false, "Sanear conserva la elección")
        off.realtime = nil
        XCTAssertTrue(off.realtimeEnabled)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(off)) as? [String: Any])
        object.removeValue(forKey: "realtime")
        let old = try JSONDecoder().decode(ElevenLabsSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.realtime, "Los ajustes guardados antes de 0.7 siguen leyéndose")
    }
}

// MARK: Simulación reproducible del recorrido texto → fragmentos → turno

final class VoicePipelineSimulationTests: XCTestCase {
    /// El modelo «escribe» 40 caracteres por segundo con un reloj falso: la voz debe poder empezar mucho antes de que termine
    /// y no debe perderse, repetirse ni desordenarse nada.
    func testSpeakingStartsBeforeTheModelFinishesAndNothingIsLostOrRepeated() throws {
        let text = "Claro, ahora mismo reviso tu agenda de hoy y te cuento lo que tienes pendiente. Primero tienes una reunión con Wendy a las tres y cuarenta y cinco de la tarde. Después hay una llamada con tu jefe a las cinco. Si quieres, te preparo un correo para avisar que llegarás tarde. Dime qué prefieres y lo dejo listo."
        var segmenter = SpeechSegmenter()
        var ledger = VoiceTurnLedger()
        let turn = ledger.beginTurn()
        var recorder = VoiceTurnRecorder(turn: turn, backend: "simulación", startedAt: 0)
        var spoken: [String] = []
        var now = 0.0
        var sawFirst = false
        let secondsPerCharacter = 1.0 / 40

        func take(_ list: [SpeechSegment]) {
            for segment in list {
                XCTAssertEqual(ledger.accept(segment, turn: turn), .accepted)
                recorder.segmentReady(at: now, characters: segment.text.count)
                spoken.append(segment.text)
            }
        }
        for character in text {
            now += secondsPerCharacter
            if !sawFirst { recorder.firstToken(at: now); sawFirst = true }
            take(segmenter.feed(String(character)))
        }
        let modelFinishedAt = now
        let firstTokenMs = try XCTUnwrap(recorder.metrics.firstTokenMs)
        let firstSegmentMs = try XCTUnwrap(recorder.metrics.firstSegmentMs)
        let firstSegmentAt = (firstTokenMs + firstSegmentMs) / 1_000
        take(segmenter.flush())

        XCTAssertLessThan(firstSegmentAt, modelFinishedAt * 0.5, "La primera frase sale antes de la mitad del tiempo que tarda el modelo")
        XCTAssertGreaterThanOrEqual(spoken.count, 3)
        XCTAssertEqual(spoken.joined(separator: " "), text, "No se pierde ni se repite ningún texto")
        XCTAssertEqual(recorder.metrics.charactersSent, spoken.reduce(0) { $0 + $1.count })
    }

    func testInterruptingMidTurnDropsLateFragmentsAndTheNextTurnStartsClean() {
        var ledger = VoiceTurnLedger()
        var segmenter = SpeechSegmenter()
        let first = ledger.beginTurn()
        var late: [SpeechSegment] = []
        for segment in segmenter.feed("Te explico el plan completo de hoy, paso por paso y sin prisa alguna. Después seguimos con lo demás, si quieres. ") {
            XCTAssertEqual(ledger.accept(segment, turn: first), .accepted)
        }
        ledger.cancel()                                        // el usuario interrumpe
        late = segmenter.feed("Esto llegó tarde y no debe sonar nunca más. ") + segmenter.flush()
        XCTAssertFalse(late.isEmpty)
        for segment in late { XCTAssertEqual(ledger.accept(segment, turn: first), .stale) }

        let second = ledger.beginTurn()
        var fresh = SpeechSegmenter()
        let next = fresh.feed("Nueva instrucción recibida correctamente, la atiendo ahora mismo. ") + fresh.flush()
        XCTAssertEqual(next.first?.index, 0)
        for segment in next { XCTAssertEqual(ledger.accept(segment, turn: second), .accepted) }
    }
}
