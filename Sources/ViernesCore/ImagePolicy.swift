import Foundation

/// Una imagen ya reducida y codificada, lista para enviarse a un modelo con visión.
public struct ImagePart: Equatable, Sendable {
    public var mimeType: String
    public var base64: String
    public var name: String
    public init(mimeType: String, base64: String, name: String) {
        self.mimeType = mimeType
        self.base64 = base64
        self.name = name
    }
    public var dataURL: String { "data:\(mimeType);base64,\(base64)" }
    /// Tamaño aproximado de los bytes ya decodificados.
    public var approximateBytes: Int { base64.count / 4 * 3 }
}

/// Reglas de reducción y compresión de imágenes (el recorte y la codificación los hace la app con ImageIO).
public enum ImagePolicy {
    /// Lado mayor tras reducir: suficiente para leer texto de una captura y para describir una foto sin gastar cuota.
    public static let maxLongSide = 1_568
    public static let minLongSide = 640
    /// Protección contra imágenes diminutas en bytes pero gigantes en píxeles.
    public static let maxPixels = 120_000_000
    /// Tope del JPEG ya codificado (en base64 ocupa ≈ 4/3). Conservador: un tercero cita 4 MB en base64 para Groq (sin confirmar).
    public static let maxPayloadBytes = 2_900_000
    public static let qualityLadder: [Double] = [0.82, 0.68, 0.55, 0.42]
    public static let shrinkFactor = 0.75

    public static func checkPixels(name: String, width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw AttachmentError.unreadableImage(name: name) }
        if width * height > maxPixels { throw AttachmentError.tooLarge(name: name, bytes: width * height, limit: maxPixels) }
    }

    /// Tamaño final conservando la proporción. Nunca amplía.
    public static func targetSize(width: Int, height: Int, longSide: Int = maxLongSide) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > longSide, longest > 0 else { return (width, height) }
        let scale = Double(longSide) / Double(longest)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// Intentos de codificación, del que más calidad conserva al que menos: se acepta el primero que cabe en `maxPayloadBytes`.
    public static func encodingSteps(width: Int, height: Int) -> [(longSide: Int, quality: Double)] {
        let original = max(width, height)
        var side = min(maxLongSide, original)
        var steps: [(longSide: Int, quality: Double)] = []
        for _ in 0..<3 {
            for quality in qualityLadder { steps.append((side, quality)) }
            let next = Int(Double(side) * shrinkFactor)
            if next < minLongSide { break }
            side = next
        }
        return steps
    }
}
