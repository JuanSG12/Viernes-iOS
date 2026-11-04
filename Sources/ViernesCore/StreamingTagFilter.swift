import Foundation

/// Filtro de flujo que retira (y opcionalmente captura) bloques delimitados por etiquetas,
/// p. ej. `<think>…</think>` de Qwen3 o `<tool>{…}</tool>` de llamadas a herramientas.
/// Es seguro con fragmentos arbitrarios: retiene sufijos que podrían ser el inicio de una etiqueta.
public final class StreamingTagFilter {
    public struct Spec: Sendable {
        public let open: String
        public let close: String
        public let capture: Bool
        public init(open: String, close: String, capture: Bool) {
            self.open = open
            self.close = close
            self.capture = capture
        }
    }

    public struct Captured: Equatable, Sendable {
        public let open: String
        public let content: String
    }

    private let specs: [Spec]
    private var buffer = ""
    private var active: Spec?
    private var activeContent = ""
    public private(set) var captured: [Captured] = []
    /// Bloques abiertos que nunca se cerraron (salida truncada del modelo).
    public private(set) var unterminatedBlocks = 0

    public init(specs: [Spec]) { self.specs = specs }

    public func feed(_ chunk: String) -> String {
        buffer += chunk
        var visible = ""
        while true {
            if let spec = active {
                if let range = buffer.range(of: spec.close) {
                    activeContent += buffer[..<range.lowerBound]
                    if spec.capture { captured.append(Captured(open: spec.open, content: activeContent)) }
                    activeContent = ""
                    active = nil
                    buffer = String(buffer[range.upperBound...])
                    continue
                }
                let keep = Self.partialSuffixLength(of: buffer, matching: spec.close)
                activeContent += buffer.dropLast(keep)
                buffer = String(buffer.suffix(keep))
                break
            } else {
                var best: (range: Range<String.Index>, spec: Spec)?
                for spec in specs {
                    if let range = buffer.range(of: spec.open),
                       best == nil || range.lowerBound < best!.range.lowerBound {
                        best = (range, spec)
                    }
                }
                if let best = best {
                    visible += buffer[..<best.range.lowerBound]
                    buffer = String(buffer[best.range.upperBound...])
                    active = best.spec
                    continue
                }
                let keep = specs.map { Self.partialSuffixLength(of: buffer, matching: $0.open) }.max() ?? 0
                visible += buffer.dropLast(keep)
                buffer = String(buffer.suffix(keep))
                break
            }
        }
        return visible
    }

    /// Vacía lo retenido al terminar el flujo.
    public func finish() -> String {
        defer { buffer = ""; activeContent = ""; active = nil }
        if active != nil {
            unterminatedBlocks += 1
            return ""            // bloque sin cerrar: se descarta, nunca se muestra a medias
        }
        return buffer
    }

    /// Longitud del mayor sufijo de `text` que sea prefijo propio de `tag`.
    static func partialSuffixLength(of text: String, matching tag: String) -> Int {
        let maxLength = min(text.count, tag.count - 1)
        guard maxLength > 0 else { return 0 }
        for length in stride(from: maxLength, through: 1, by: -1) where text.hasSuffix(String(tag.prefix(length))) {
            return length
        }
        return 0
    }
}
