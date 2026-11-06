import SceneKit
import UIKit
import simd

/// Malla procedural de un anillo-banda: un anillo de radio mayor `R` cuya sección es una elipse (más ancha que gruesa),
/// con torsión opcional a lo largo del anillo y una ondulación suave del radio. Es el «cromo líquido» de la referencia:
/// no un toro perfecto, sino una banda orgánica que gira sobre sí misma.
enum BandRingMesh {
    /// - Parameters:
    ///   - majorRadius: radio del anillo.
    ///   - halfWidth: semieje de la sección en la dirección radial (cuando no hay torsión).
    ///   - halfThickness: semieje perpendicular al plano del anillo.
    ///   - twists: vueltas COMPLETAS de la sección a lo largo del anillo (entero; 0 = sin torsión).
    ///   - wobble: amplitud relativa de la ondulación del radio (0…0.2).
    static func make(majorRadius: Float, halfWidth: Float, halfThickness: Float,
                     twists: Int = 1, wobble: Float = 0.04,
                     segments: Int = 150, sides: Int = 32) -> SCNGeometry {
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        vertices.reserveCapacity((segments + 1) * (sides + 1))
        normals.reserveCapacity((segments + 1) * (sides + 1))

        for i in 0...segments {
            let u = Float(i) / Float(segments) * 2 * Float.pi
            let radius = majorRadius * (1 + wobble * sin(3 * u) + 0.5 * wobble * sin(5 * u + 1))
            let radial = SIMD3<Float>(cos(u), sin(u), 0)
            let normalAxis = SIMD3<Float>(0, 0, 1)
            let center = radial * radius
            let theta = Float(twists) * u
            let e1 = radial * cos(theta) + normalAxis * sin(theta)          // eje ancho de la sección
            let e2 = -radial * sin(theta) + normalAxis * cos(theta)         // eje fino
            for j in 0...sides {
                let v = Float(j) / Float(sides) * 2 * Float.pi
                let position = center + e1 * (halfWidth * cos(v)) + e2 * (halfThickness * sin(v))
                // Normal de una elipse: gradiente de (x/a)² + (y/b)².
                let normal = simd_normalize(e1 * (cos(v) / halfWidth) + e2 * (sin(v) / halfThickness))
                vertices.append(SCNVector3(position.x, position.y, position.z))
                normals.append(SCNVector3(normal.x, normal.y, normal.z))
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(segments * sides * 6)
        let stride = sides + 1
        for i in 0..<segments {
            for j in 0..<sides {
                let a = UInt32(i * stride + j)
                let b = UInt32((i + 1) * stride + j)
                let c = b + 1
                let d = a + 1
                indices.append(contentsOf: [a, b, c, a, c, d])
            }
        }

        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        return geometry
    }
}
