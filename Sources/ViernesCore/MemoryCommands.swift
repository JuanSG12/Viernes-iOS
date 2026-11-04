import Foundation

/// Órdenes explícitas de memoria dichas por el usuario ("recuerda que…", "olvida lo de…").
/// Es la ÚNICA vía de guardado automático: el usuario lo pidió con palabras.
public enum MemoryCommand: Equatable, Sendable {
    case remember(String)
    case forget(String)

    public static func parse(_ text: String) -> MemoryCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = TextNormalizer.fold(trimmed)

        let rememberPrefixes = ["recuerda que ", "recuerda: ", "acuerdate de que ", "acuerdate que ", "guarda en memoria que ", "anota que ", "toma nota de que "]
        for prefix in rememberPrefixes where folded.hasPrefix(prefix) {
            let body = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : .remember(body)
        }
        let forgetPrefixes = ["olvida que ", "olvida lo de ", "olvida eso de ", "olvida ", "borra de tu memoria ", "elimina de tu memoria "]
        for prefix in forgetPrefixes where folded.hasPrefix(prefix) {
            let body = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : .forget(body)
        }
        return nil
    }

    /// Clasificación sencilla del tipo de recuerdo para la política de memoria.
    public static func classify(_ text: String) -> MemoryKind {
        let folded = TextNormalizer.fold(text)
        let projectHints = ["proyecto", "estoy construyendo", "estoy desarrollando", "estoy trabajando en", "app ", "aplicacion", "repositorio"]
        let preferenceHints = ["prefiero", "me gusta", "no me gusta", "odio", "siempre quiero", "quiero que me", "háblame", "hablame", "respuestas "]
        if projectHints.contains(where: { folded.contains(TextNormalizer.fold($0)) }) { return .project }
        if preferenceHints.contains(where: { folded.contains(TextNormalizer.fold($0)) }) { return .preference }
        return .fact
    }
}
