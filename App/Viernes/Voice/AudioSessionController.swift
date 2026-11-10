import AVFoundation

/// Único punto que configura la sesión de audio. Sin modos de fondo: la sesión solo está activa mientras la app lo está.
enum AudioSessionController {
    /// Hay una sesión `playAndRecord` ya configurada y activa por Viernes. Evita repetir `setCategory`/`setActive` (que pueden
    /// reconfigurar la ruta de audio y producir cortes, sobre todo con Bluetooth) cada vez que se encola una frase.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var configured = false

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
        lock.withLock { configured = true }
    }

    /// Como `activateForConversation`, pero solo si hace falta (la primera vez, o tras una interrupción o un cambio de ruta).
    static func ensureConversationActive() throws {
        if lock.withLock({ configured }) { return }
        try activateForConversation()
    }

    /// La sesión pudo quedar desconfigurada (interrupción, cambio de ruta, reinicio de los servicios de audio): la próxima
    /// vez se configura de nuevo.
    static func invalidate() { lock.withLock { configured = false } }

    static func activateForPlaybackOnly() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true, options: [])
        invalidate()
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        invalidate()
    }
}

/// Avisos del sistema de audio que afectan a lo que Viernes está diciendo: llamadas o Siri (interrupción) y cambios de ruta
/// (audífonos que se desconectan). Solo observa; quien habla decide qué hacer.
@MainActor
final class AudioSessionWatcher {
    static let shared = AudioSessionWatcher()

    enum Event: Equatable {
        case interruptionBegan
        case interruptionEnded
        /// Se desconectó el dispositivo de salida (p. ej. audífonos): lo habitual es detener la voz, no sacarla por el altavoz.
        case outputLost
        case routeChanged
        case mediaServicesReset
    }

    var onEvent: ((Event) -> Void)?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in self?.handleInterruption(rawType) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let rawReason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in self?.handleRouteChange(rawReason) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in
                AudioSessionController.invalidate()
                self?.onEvent?(.mediaServicesReset)
            }
        })
    }

    private func handleInterruption(_ rawType: UInt?) {
        guard let rawType = rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        AudioSessionController.invalidate()
        onEvent?(type == .began ? .interruptionBegan : .interruptionEnded)
    }

    private func handleRouteChange(_ rawReason: UInt?) {
        guard let rawReason = rawReason, let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            onEvent?(.outputLost)
        case .newDeviceAvailable, .override, .routeConfigurationChange:
            onEvent?(.routeChanged)
        default:
            break
        }
    }
}
