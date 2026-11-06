import UIKit

/// Imágenes generadas por código para el núcleo 3D (sin archivos de recursos ni dependencias).
enum CoreEnvironment {
    /// Mapa de entorno equirectangular de estudio oscuro: lo que REFLEJA el cromo. Fondo casi negro, dos cajas de luz blancas
    /// alargadas, una franja cenital y una franja naranja cálida. El contraste alto es lo que hace que el metal parezca metal.
    static func studioMap(width: Int = 1024, height: Int = 512) -> UIImage {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let space = CGColorSpaceCreateDeviceRGB()

            // Base: degradado vertical (cielo apenas más claro, horizonte negro, suelo cálido muy tenue).
            let base = CGGradient(colorsSpace: space, colors: [
                UIColor(white: 0.20, alpha: 1).cgColor, UIColor(white: 0.03, alpha: 1).cgColor,
                UIColor(white: 0.01, alpha: 1).cgColor, UIColor(red: 0.30, green: 0.10, blue: 0.02, alpha: 1).cgColor
            ] as CFArray, locations: [0, 0.38, 0.62, 1])!
            cg.drawLinearGradient(base, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

            func softbox(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, color: UIColor, alpha: CGFloat) {
                let rect = CGRect(x: x * size.width, y: y * size.height, width: w * size.width, height: h * size.height)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.18)
                cg.saveGState()
                cg.setShadow(offset: .zero, blur: rect.width * 0.35, color: color.withAlphaComponent(alpha * 0.8).cgColor)
                color.withAlphaComponent(alpha).setFill()
                path.fill()
                cg.restoreGState()
            }
            softbox(x: 0.17, y: 0.14, w: 0.05, h: 0.58, color: .white, alpha: 1.0)          // caja de luz vertical izquierda
            softbox(x: 0.58, y: 0.20, w: 0.10, h: 0.46, color: UIColor(white: 0.95, alpha: 1), alpha: 0.95)
            softbox(x: 0.0, y: 0.07, w: 1.0, h: 0.035, color: .white, alpha: 0.75)          // franja cenital
            softbox(x: 0.83, y: 0.24, w: 0.045, h: 0.52, color: UIColor(red: 1.0, green: 0.42, blue: 0.0, alpha: 1), alpha: 1.0)
            softbox(x: 0.36, y: 0.80, w: 0.20, h: 0.05, color: UIColor(red: 1.0, green: 0.50, blue: 0.10, alpha: 1), alpha: 0.9)
        }
    }

    /// Destello en cruz con halo (se dibuja como un plano que mira a la cámara, mezcla aditiva).
    static func flareTexture(size: Int = 256) -> UIImage {
        let side = CGFloat(size)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let cg = context.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let center = CGPoint(x: side / 2, y: side / 2)
            let halo = CGGradient(colorsSpace: space, colors: [
                UIColor(white: 1, alpha: 0.95).cgColor, UIColor(red: 1, green: 0.62, blue: 0.25, alpha: 0.55).cgColor,
                UIColor(red: 1, green: 0.35, blue: 0.0, alpha: 0.0).cgColor
            ] as CFArray, locations: [0, 0.18, 1])!
            cg.drawRadialGradient(halo, startCenter: center, startRadius: 0, endCenter: center, endRadius: side / 2, options: [])
            // Líneas de la cruz con desvanecido en los extremos.
            for (dx, dy) in [(1.0, 0.0), (0.0, 1.0)] {
                let from = CGPoint(x: center.x - CGFloat(dx) * side / 2, y: center.y - CGFloat(dy) * side / 2)
                let to = CGPoint(x: center.x + CGFloat(dx) * side / 2, y: center.y + CGFloat(dy) * side / 2)
                let line = CGGradient(colorsSpace: space, colors: [
                    UIColor(white: 1, alpha: 0).cgColor, UIColor(white: 1, alpha: 0.9).cgColor, UIColor(white: 1, alpha: 0).cgColor
                ] as CFArray, locations: [0, 0.5, 1])!
                cg.saveGState()
                cg.setLineWidth(3)
                cg.addRect(CGRect(x: min(from.x, to.x) - (dy == 1 ? 1.5 : 0), y: min(from.y, to.y) - (dx == 1 ? 1.5 : 0),
                                  width: dx == 1 ? side : 3, height: dy == 1 ? side : 3))
                cg.clip()
                cg.drawLinearGradient(line, start: from, end: to, options: [])
                cg.restoreGState()
            }
        }
    }
}
