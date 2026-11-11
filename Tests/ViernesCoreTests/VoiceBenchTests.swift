import XCTest
@testable import ViernesCore

final class VoiceBenchTests: XCTestCase {
    private func metrics(backend: String, firstAudio: Double, ended: Double, silences: [Double]? = nil, gaps: [Double] = [], bytes: Int = 0,
                         outcome: VoiceTurnMetrics.Outcome = .completed) -> VoiceTurnMetrics {
        var recorder = VoiceTurnRecorder(turn: 1, backend: backend, startedAt: 0)
        recorder.firstToken(at: 0)
        recorder.segmentReady(at: 0.01, characters: 20)
        recorder.firstAudio(at: firstAudio / 1_000)
        for gap in gaps { recorder.gap(ms: gap) }
        for silence in silences ?? [] { recorder.segmentSilence(ms: silence) }
        if bytes > 0 { recorder.audioScheduled(bytes: bytes, durationMs: 1_000) }
        recorder.finish(at: ended / 1_000, outcome: outcome)
        return recorder.metrics
    }

    func testThePhrasesAreFixedAndVaried() {
        XCTAssertEqual(VoiceBenchPhrases.all.count, 4)
        XCTAssertTrue(VoiceBenchPhrases.all.contains { $0.contains("¿") && $0.contains(";") }, "Hay una frase con pregunta y signos")
        XCTAssertTrue(VoiceBenchPhrases.all.contains { $0.count > 250 }, "Y una larga")
        XCTAssertLessThan(VoiceBenchPhrases.totalCharacters, 1_200, "Cada modo en la nube gasta pocos caracteres del plan")
        XCTAssertEqual(VoiceBenchPhrases.all[0], "Listo, ya lo hice.", "Las frases no cambian entre versiones: las mediciones deben seguir siendo comparables")
    }

    func testTheReportListsEachBackendAndOnlyWhatWasMeasured() {
        let runs = [
            VoiceBenchRun(backend: "voz del sistema", phraseIndex: 0, metrics: metrics(backend: "voz del sistema", firstAudio: 300, ended: 2_000, silences: [120, 90]), memoryDeltaMB: 1.5),
            VoiceBenchRun(backend: "voz del sistema", phraseIndex: 1, metrics: metrics(backend: "voz del sistema", firstAudio: 340, ended: 4_000, silences: [100]), memoryDeltaMB: 0.5),
            VoiceBenchRun(backend: "tiempo real", phraseIndex: 0, metrics: metrics(backend: "tiempo real", firstAudio: 700, ended: 2_500, gaps: [80], bytes: 200_000), memoryDeltaMB: nil)
        ]
        let text = VoiceBenchReport.text(runs: runs, device: "iPhone · iOS 18")
        XCTAssertTrue(text.contains("== tiempo real") && text.contains("== voz del sistema"))
        XCTAssertTrue(text.contains("4 frases fijas") && text.contains("iPhone · iOS 18"))
        XCTAssertTrue(text.contains("silencios entre frases (sintetizador del sistema): 3"), text)
        XCTAssertTrue(text.contains("audio recibido: 195 KB"), text)
        XCTAssertTrue(text.contains("tiempo total de la respuesta"))
        XCTAssertTrue(text.contains("voz del sistema: mediana +1.5 MB"), text)
        XCTAssertFalse(text.contains("tiempo real: mediana"), "Sin datos de memoria no se inventa una cifra")
        XCTAssertTrue(text.contains("Límites"))
        XCTAssertEqual(VoiceBenchReport.text(runs: []), "El banco todavía no ha medido nada.")
    }

    func testRunsThatDidNotFinishAreCounted() {
        let runs = [VoiceBenchRun(backend: "tiempo real", phraseIndex: 0, metrics: metrics(backend: "tiempo real", firstAudio: 500, ended: 900, outcome: .failed))]
        XCTAssertTrue(VoiceBenchReport.text(runs: runs).contains("Frases que no terminaron bien: 1 de 1"))
    }

    func testSilencesAreOptionalAndOldMetricsStillDecode() throws {
        var recorder = VoiceTurnRecorder(turn: 3, backend: "voz del sistema", startedAt: 0)
        recorder.segmentSilence(ms: -5)
        XCTAssertNil(recorder.metrics.silencesBetweenSegmentsMs, "Un valor negativo no se anota")
        recorder.segmentSilence(ms: 40)
        XCTAssertEqual(recorder.metrics.silencesBetweenSegmentsMs, [40])

        let old = VoiceTurnMetrics(turn: 7, backend: "tiempo real", startedAt: 0)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "silencesBetweenSegmentsMs")
        let decoded = try JSONDecoder().decode(VoiceTurnMetrics.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.silencesBetweenSegmentsMs)
        XCTAssertFalse(VoiceMetricsReport.summary([old]).contains("silencios entre frases"), "Un modo que no los mide no los muestra")
    }
}
