import Foundation
import os

/// Registro técnico LOCAL (no se envía a ningún sitio): estados de permisos y errores, para depurar sin ensuciar la conversación.
/// Nunca guarda el contenido de eventos, contactos ni mensajes: solo estados, conteos y mensajes de error.
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()

    private let logger = Logger(subsystem: "com.example.viernes", category: "diagnostico")
    private let lock = NSLock()
    private var entries: [String] = []

    func log(_ message: String) {
        let stamp = Self.formatter.string(from: Date())
        logger.notice("\(message, privacy: .private)")
        lock.withLock {
            entries.append("\(stamp)  \(message)")
            if entries.count > 200 { entries.removeFirst(entries.count - 200) }
        }
    }

    var recent: [String] { lock.withLock { entries } }
    func clear() { lock.withLock { entries.removeAll() } }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
