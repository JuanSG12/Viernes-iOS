import AVFoundation
import Speech
import EventKit
import Contacts
import LocalAuthentication

enum PermissionState: Equatable {
    case notDetermined, granted, denied, restricted, writeOnly

    var label: String {
        switch self {
        case .notDetermined: return "Sin solicitar"
        case .granted: return "Concedido"
        case .denied: return "Denegado"
        case .restricted: return "Restringido"
        case .writeOnly: return "Solo escritura"
        }
    }
    var isGranted: Bool { self == .granted || self == .writeOnly }
}

/// Lectura y solicitud de permisos. Cada solicitud se hace SOLO tras explicar para qué sirve (ver OnboardingView).
@MainActor
enum Permissions {
    static var microphone: PermissionState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    static var speech: PermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    static var reminders: PermissionState { map(EKEventStore.authorizationStatus(for: .reminder)) }
    static var calendar: PermissionState { map(EKEventStore.authorizationStatus(for: .event)) }

    static var contacts: PermissionState {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    private static func map(_ status: EKAuthorizationStatus) -> PermissionState {
        switch status {
        case .fullAccess, .authorized: return .granted
        case .writeOnly: return .writeOnly
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    static func requestMicrophone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    static func requestSpeech() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status == .authorized) }
        }
    }

    static var biometricsAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
