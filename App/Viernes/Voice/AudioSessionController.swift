import AVFoundation

/// Único punto que configura la sesión de audio. Sin modos de fondo: la sesión solo está activa mientras la app lo está.
enum AudioSessionController {
    /// `preferBuiltInMic`: usa el micrófono del iPhone aunque haya audífonos Bluetooth (su micrófono, de perfil de llamada, tiene
    /// mucha menos calidad y es una causa frecuente de mala transcripción).
    static func activateForConversation(preferBuiltInMic: Bool = false) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        try session.setActive(true, options: [])
        if preferBuiltInMic, let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
    }

    static func activateForPlaybackOnly() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true, options: [])
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
