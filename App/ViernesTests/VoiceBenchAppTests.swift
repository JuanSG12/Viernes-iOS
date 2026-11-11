import XCTest
import ViernesCore
@testable import Viernes

final class VoiceBenchAppTests: XCTestCase {
    func testSystemModeAlwaysAvailableAndDropsTheCloudVoice() {
        var base = VoiceSettings.default
        base.elevenLabs = ElevenLabsSettings(enabled: true, voiceID: "abc", voiceName: "Voz", modelID: ElevenLabsSettings.defaultModelID)
        let system = VoiceBenchBackend.system.settings(base: base)
        XCTAssertNotNil(system)
        XCTAssertNil(system?.elevenLabs, "La voz del sistema no usa ElevenLabs")
        XCTAssertFalse(VoiceBenchBackend.system.usesCloud)
        XCTAssertTrue(VoiceBenchBackend.realtime.usesCloud && VoiceBenchBackend.sentences.usesCloud)
    }

    func testCloudModesAreUnavailableWithoutAVoiceOrAKey() {
        XCTAssertNil(VoiceBenchBackend.realtime.settings(base: .default), "Sin ElevenLabs configurado no se puede medir")
        var base = VoiceSettings.default
        base.elevenLabs = ElevenLabsSettings(enabled: true, voiceID: "abc", voiceName: "Voz", modelID: ElevenLabsSettings.defaultModelID)
        CloudKeyStore.delete(providerID: ElevenLabsProtocol.keyProviderID)
        XCTAssertNil(VoiceBenchBackend.sentences.settings(base: base), "Con voz pero sin clave tampoco")
    }

    func testResidentMemoryIsReadable() {
        let megabytes = ResidentMemory.megabytes()
        XCTAssertNotNil(megabytes)
        XCTAssertGreaterThan(megabytes ?? 0, 1)
    }
}
