import XCTest
@testable import ViernesCore

final class CloudVoiceTests: XCTestCase {
    private let goodID = "21m00Tcm4TlvDq8ikWAM"

    func testVoiceIDValidationProtectsTheURLPath() {
        XCTAssertTrue(ElevenLabsProtocol.isValidVoiceID(goodID))
        for bad in ["", "corto", "../../v1/user", "abc def ghi jkl mno", "voz/otra/cosa/xxxxx", "ñandú12345678901", String(repeating: "a", count: 41)] {
            XCTAssertFalse(ElevenLabsProtocol.isValidVoiceID(bad), bad)
            XCTAssertNil(ElevenLabsProtocol.speechURL(voiceID: bad), bad)
        }
        let url = ElevenLabsProtocol.speechURL(voiceID: goodID)?.absoluteString
        XCTAssertEqual(url, "https://api.elevenlabs.io/v1/text-to-speech/\(goodID)?output_format=mp3_44100_128")
        XCTAssertEqual(ElevenLabsProtocol.voicesURL?.absoluteString, "https://api.elevenlabs.io/v1/voices")
    }

    func testRequestBodyAndSpeedMapping() throws {
        let data = try ElevenLabsProtocol.requestBody(text: "Hola, soy Viernes.", modelID: "eleven_flash_v2_5", speed: 1.0)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["text"] as? String, "Hola, soy Viernes.")
        XCTAssertEqual(object["model_id"] as? String, "eleven_flash_v2_5")
        let settings = try XCTUnwrap(object["voice_settings"] as? [String: Any])
        XCTAssertEqual(settings["speed"] as? Double, 1.0)

        XCTAssertEqual(ElevenLabsProtocol.speed(forRate: 0.5), 1.0, accuracy: 0.001)
        XCTAssertEqual(ElevenLabsProtocol.speed(forRate: 0.3), 0.7, accuracy: 0.001)      // recortado al mínimo de la API
        XCTAssertEqual(ElevenLabsProtocol.speed(forRate: 0.65), 1.2, accuracy: 0.001)     // recortado al máximo de la API
    }

    func testParseVoicesKeepsOnlyValidIDsAndSortsByName() {
        let json = """
        {"voices":[
          {"voice_id":"\(goodID)","name":"Rachel","category":"premade","labels":{"accent":"american","gender":"female","age":"young"}},
          {"voice_id":"EXAVITQu4vr4xnSDxMaL","name":"Bella","category":"premade","labels":{}},
          {"voice_id":"../x","name":"Mala"}
        ]}
        """
        let voices = ElevenLabsProtocol.parseVoices(Data(json.utf8))
        XCTAssertEqual(voices.map(\.name), ["Bella", "Rachel"])
        XCTAssertEqual(voices.last?.detail, "american · female · young")
        XCTAssertEqual(voices.last?.category, "premade")
        XCTAssertTrue(ElevenLabsProtocol.parseVoices(Data("basura".utf8)).isEmpty)
    }

    func testErrorsUseTheRealReasonNotJustTheHTTPCode() {
        // La cuota agotada llega como 401: el motivo real está en detail.status.
        let quota = ElevenLabsProtocol.errorMessage(status: 401, body: #"{"detail":{"status":"quota_exceeded","message":"You have 0 credits remaining"}}"#)
        XCTAssertTrue(quota.contains("cuota"))
        let plan = ElevenLabsProtocol.errorMessage(status: 402, body: #"{"detail":{"status":"payment_required","message":"Free users cannot use library voices via the API"}}"#)
        XCTAssertTrue(plan.contains("plan gratuito"))
        XCTAssertTrue(ElevenLabsProtocol.errorMessage(status: 401, body: #"{"detail":{"status":"detected_unusual_activity"}}"#).contains("VPN"))
        XCTAssertTrue(ElevenLabsProtocol.errorMessage(status: 401, body: #"{"detail":{"status":"invalid_api_key"}}"#).contains("rechazó la clave"))
        XCTAssertTrue(ElevenLabsProtocol.errorMessage(status: 404, body: "").contains("voz"))
        XCTAssertTrue(ElevenLabsProtocol.errorMessage(status: 429, body: "").contains("demasiadas"))
        XCTAssertTrue(ElevenLabsProtocol.errorMessage(status: 502, body: "").contains("problemas"))
        let generic = ElevenLabsProtocol.errorMessage(status: 422, body: #"{"detail":"texto inválido"}"#)
        XCTAssertTrue(generic.contains("texto inválido"))
    }

    func testSettingsSanitizeAndGateUsability() {
        XCTAssertFalse(ElevenLabsSettings.default.isUsable)
        let ready = ElevenLabsSettings(enabled: true, voiceID: goodID, voiceName: "Rachel", modelID: "eleven_flash_v2_5")
        XCTAssertTrue(ready.isUsable)
        // Una voz inválida apaga el interruptor en vez de construir una URL peligrosa.
        let broken = ElevenLabsSettings(enabled: true, voiceID: "../etc", voiceName: "x", modelID: "eleven_flash_v2_5").sanitized()
        XCTAssertFalse(broken.enabled)
        XCTAssertEqual(broken.voiceID, "")
        XCTAssertEqual(ElevenLabsSettings(enabled: false, voiceID: goodID, voiceName: "", modelID: "Modelo Raro!").sanitized().modelID, ElevenLabsSettings.defaultModelID)
        XCTAssertEqual(ElevenLabsSettings(enabled: false, voiceID: goodID, voiceName: String(repeating: "n", count: 200), modelID: "eleven_multilingual_v2").sanitized().voiceName.count, 60)
    }

    func testVoiceSettingsSavedBeforeCloudVoiceStillDecode() throws {
        var dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(VoiceSettings.default)) as? [String: Any])
        dictionary.removeValue(forKey: "elevenLabs")
        let decoded = try JSONDecoder().decode(VoiceSettings.self, from: JSONSerialization.data(withJSONObject: dictionary))
        XCTAssertNil(decoded.elevenLabs)
        XCTAssertEqual(decoded, VoiceSettings.default)

        var withCloud = VoiceSettings.default
        withCloud.elevenLabs = ElevenLabsSettings(enabled: true, voiceID: goodID, voiceName: "Rachel", modelID: "eleven_flash_v2_5")
        let roundTrip = try JSONDecoder().decode(VoiceSettings.self, from: JSONEncoder().encode(withCloud))
        XCTAssertEqual(roundTrip, withCloud)
        XCTAssertEqual(withCloud.sanitized().elevenLabs, withCloud.elevenLabs)
    }
}
