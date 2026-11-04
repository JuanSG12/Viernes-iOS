import XCTest
@testable import ViernesCore

final class SentenceStreamerTests: XCTestCase {
    func testEmitsCompleteSentencesAcrossDeltas() {
        var streamer = SentenceStreamer()
        var out: [String] = []
        for delta in ["Hola, ", "¿cómo est", "ás? Muy bien. Y", " tú?"] { out += streamer.feed(delta) }
        out += streamer.flush().map { [$0] } ?? []
        XCTAssertEqual(out, ["Hola, ¿cómo estás?", "Muy bien.", "Y tú?"])
    }

    func testDoesNotSplitDecimals() {
        var streamer = SentenceStreamer()
        var out = streamer.feed("Pi vale 3.14 más o menos. Listo ")
        out += streamer.flush().map { [$0] } ?? []
        XCTAssertEqual(out, ["Pi vale 3.14 más o menos.", "Listo"])
    }

    func testHoldsBackPunctuationUntilNextCharacterArrives() {
        var streamer = SentenceStreamer()
        XCTAssertTrue(streamer.feed("Uno.").isEmpty)         // aún podría ser "Uno.5"
        XCTAssertEqual(streamer.feed(" Dos"), ["Uno."])
        XCTAssertEqual(streamer.flush(), "Dos")
        XCTAssertNil(streamer.flush())
    }

    func testNewlinesAreBoundaries() {
        var streamer = SentenceStreamer()
        XCTAssertEqual(streamer.feed("Primero\nSegundo\n"), ["Primero", "Segundo"])
    }
}
