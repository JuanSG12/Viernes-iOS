import Foundation
import ViernesCore

/// Los modos de voz que el banco compara. Cada uno fuerza SU modo y el registro anota el que realmente habló (si el tiempo real
/// cayera a la voz del sistema, se vería en la medición).
enum VoiceBenchBackend: String, CaseIterable, Identifiable {
    case system, realtime, sentences

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Voz del sistema"
        case .realtime: return "ElevenLabs en tiempo real"
        case .sentences: return "ElevenLabs por frases"
        }
    }

    /// Estos modos gastan caracteres del plan de ElevenLabs y envían las frases de prueba (texto fijo, sin datos personales).
    var usesCloud: Bool { self != .system }

    /// Ajustes de voz para forzar este modo, o `nil` si no está disponible (sin voz de ElevenLabs elegida o sin clave).
    func settings(base: VoiceSettings) -> VoiceSettings? {
        var voice = base
        switch self {
        case .system:
            voice.elevenLabs = nil
            return voice
        case .realtime, .sentences:
            guard var cloud = base.elevenLabs, cloud.isUsable, CloudKeyStore.hasKey(providerID: ElevenLabsProtocol.keyProviderID) else { return nil }
            cloud.enabled = true
            cloud.realtime = (self == .realtime)
            voice.elevenLabs = cloud
            return voice
        }
    }
}

/// Memoria residente de la app en MB (para medir el efecto de cada modo de voz; es una medida ruidosa).
enum ResidentMemory {
    static func megabytes() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : nil
    }
}
