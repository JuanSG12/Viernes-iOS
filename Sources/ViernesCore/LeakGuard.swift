import Foundation

/// Guardián de salida en streaming: impide que lo INTERNO llegue a la conversación o a la voz.
/// Quita, aunque el modelo lo repita por error: la etiqueta `[RESULTADO_HERRAMIENTA]`, JSON de llamadas
/// (`{"name":…`) y líneas de resultado con forma `- nombre_de_herramienta: …`, junto con el bloque que las sigue.
/// Funciona por trozos (los deltas del modelo pueden partir una etiqueta por la mitad) y solo retiene el mínimo
/// necesario para decidir, así que no retrasa el habla frase a frase.
public final class LeakGuard {
    private enum Mode { case normal, dropLine, blockCheck }

    private var mode: Mode = .normal
    private var pending = ""
    private var atLineStart = true

    /// Se puede aparecer en cualquier posición del texto.
    private static let anywhere: [String] = ["[RESULTADO_HERRAMIENTA]", "{\"name\":", "<function=", "<tool_call>"]
    /// Solo al principio de una línea: eco de resultados («- get_weather: ÉXITO…»).
    private static let lineStart: [String] = ToolCatalog.all.map { "- \($0.name):" }

    public init() {}

    public func feed(_ piece: String) -> String {
        pending += piece
        return process(final: false)
    }

    /// Vacía lo retenido (fin de la respuesta).
    public func finish() -> String { process(final: true) }

    private func process(final: Bool) -> String {
        var out = ""
        while !pending.isEmpty {
            switch mode {
            case .dropLine:
                if let newline = pending.firstIndex(of: "\n") {
                    pending = String(pending[pending.index(after: newline)...])
                    mode = .blockCheck
                } else {
                    pending = ""
                    return out
                }
            case .blockCheck:
                pending = String(pending.drop(while: { $0 == "\n" || $0 == "\r" || $0 == " " }))
                guard let first = pending.first else { return out }
                if "-•[{<".contains(first) {
                    mode = .dropLine
                } else {
                    mode = .normal
                    atLineStart = true
                }
            case .normal:
                if !scanNormal(final: final, out: &out) { return out }
            }
        }
        return out
    }

    /// Devuelve `true` si cambió de modo (hay que seguir procesando) y `false` si ya no hay nada más que hacer ahora.
    private func scanNormal(final: Bool, out: inout String) -> Bool {
        let chars = Array(pending)
        var index = 0
        while index < chars.count {
            let rest = String(chars[index...])
            if atLineStart {
                if Self.lineStart.contains(where: { rest.hasPrefix($0) }) {
                    out += String(chars[..<index])
                    pending = rest
                    mode = .dropLine
                    atLineStart = false
                    return true
                }
                if !final, Self.lineStart.contains(where: { $0.count > rest.count && $0.hasPrefix(rest) }) {
                    out += String(chars[..<index])
                    pending = rest              // podría ser el principio de un eco: se espera al siguiente trozo
                    return false
                }
            }
            for token in Self.anywhere {
                if rest.hasPrefix(token) {
                    out += String(chars[..<index])
                    pending = String(rest.dropFirst(token.count))
                    mode = .dropLine
                    return true
                }
                if !final, token.count > rest.count, token.hasPrefix(rest) {
                    out += String(chars[..<index])
                    pending = rest
                    return false
                }
            }
            atLineStart = (chars[index] == "\n")
            index += 1
        }
        out += pending
        pending = ""
        return false
    }
}
