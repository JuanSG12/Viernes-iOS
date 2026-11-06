import Foundation

/// Rescata llamadas a herramientas que el modelo escribió en OTRO formato en lugar de `<tool>{…}</tool>`:
/// JSON suelto (`{"name":"list_events","arguments":{…}}`), `<function=nombre>{…}</function>`, `<tool_call>{…}</tool_call>`
/// o la forma `functions.nombre {…}`. Sin esto, un modelo que «prefiere» su formato nativo dejaba la respuesta vacía
/// (el guardián de fugas oculta ese JSON) y la acción nunca se ejecutaba.
///
/// Solo acepta herramientas que EXISTEN en el catálogo. No ejecuta nada: devuelve el JSON canónico y el motor lo trata como
/// cualquier otra llamada (validación, disponibilidad, confirmaciones por riesgo).
public enum ToolCallRecovery {
    /// Texto máximo que se examina (la búsqueda de llaves equilibradas es cuadrática en el peor caso).
    private static let maxScanned = 20_000

    /// JSON canónico `{"args":{…},"name":"…"}` de cada llamada hallada, en orden de aparición y sin repetidas.
    public static func extract(from raw: String, limit: Int = 4) -> [String] {
        let cleaned = strippingInternalBlocks(String(raw.prefix(maxScanned)))
        let chars = Array(cleaned)
        var results: [String] = []
        var index = 0

        while index < chars.count, results.count < limit {
            if starts(chars, at: index, with: "<function="), let (call, next) = functionTag(chars, at: index) {
                add(call, to: &results)
                index = next
                continue
            }
            if starts(chars, at: index, with: "functions."), let (call, next) = functionsDot(chars, at: index) {
                add(call, to: &results)
                index = next
                continue
            }
            if chars[index] == "{", let end = balancedEnd(chars, from: index) {
                let text = String(chars[index...end])
                if let data = text.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let call = ToolCallParser.call(from: object), ToolCatalog.definition(named: call.name) != nil {
                    add(call, to: &results)
                    index = end + 1
                    continue
                }
            }
            index += 1
        }
        return results
    }

    /// Forma canónica que entiende `ToolCallParser`.
    public static func canonicalJSON(_ call: ToolCall) -> String {
        let object: [String: Any] = ["name": call.name, "args": call.args]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    // MARK: Interno

    private static func add(_ call: ToolCall, to results: inout [String]) {
        let json = canonicalJSON(call)
        if !results.contains(json) { results.append(json) }
    }

    /// El razonamiento interno y los resultados no son llamadas: se quitan antes de buscar.
    private static func strippingInternalBlocks(_ text: String) -> String {
        var output = text
        for pattern in ["<think>.*?</think>", "<tool_result>.*?</tool_result>"] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { continue }
            output = regex.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: "")
        }
        return output
    }

    private static func starts(_ chars: [Character], at index: Int, with prefix: String) -> Bool {
        let p = Array(prefix)
        guard index + p.count <= chars.count else { return false }
        for offset in 0..<p.count where chars[index + offset] != p[offset] { return false }
        return true
    }

    /// `<function=nombre>{…}</function>` (también `<function=nombre{…}>`).
    private static func functionTag(_ chars: [Character], at start: Int) -> (ToolCall, Int)? {
        var cursor = start + "<function=".count
        var name = ""
        while cursor < chars.count, chars[cursor].isLetter || chars[cursor].isNumber || chars[cursor] == "_" || chars[cursor] == "." {
            name.append(chars[cursor]); cursor += 1
        }
        if name.hasPrefix("functions.") { name = String(name.dropFirst("functions.".count)) }
        guard ToolCatalog.definition(named: name) != nil else { return nil }
        return argumentsAfter(chars, from: cursor, name: name, window: 40)
    }

    /// `functions.nombre {…}` (formato «harmony» de algunos modelos abiertos).
    private static func functionsDot(_ chars: [Character], at start: Int) -> (ToolCall, Int)? {
        var cursor = start + "functions.".count
        var name = ""
        while cursor < chars.count, chars[cursor].isLetter || chars[cursor].isNumber || chars[cursor] == "_" {
            name.append(chars[cursor]); cursor += 1
        }
        guard ToolCatalog.definition(named: name) != nil else { return nil }
        // Un nombre suelto en una frase («functions.list_events») no es una llamada: aquí los argumentos son obligatorios.
        return argumentsAfter(chars, from: cursor, name: name, window: 80, requireObject: true)
    }

    /// Busca el objeto JSON de argumentos pocos caracteres después del nombre.
    private static func argumentsAfter(_ chars: [Character], from cursor: Int, name: String, window: Int,
                                       requireObject: Bool = false) -> (ToolCall, Int)? {
        var probe = cursor
        let limit = min(chars.count, cursor + window)
        while probe < limit, chars[probe] != "{" { probe += 1 }
        guard probe < limit, let end = balancedEnd(chars, from: probe),
              let data = String(chars[probe...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return requireObject ? nil : (ToolCall(name: name, args: [:]), cursor) }
        return (ToolCall(name: name, args: ToolCallParser.stringArguments(object)), end + 1)
    }

    /// Posición de la llave que cierra la que se abre en `start` (respeta cadenas y escapes).
    private static func balancedEnd(_ chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < chars.count {
            let character = chars[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }
}
