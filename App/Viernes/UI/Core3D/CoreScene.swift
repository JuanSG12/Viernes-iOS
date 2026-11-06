import SceneKit
import UIKit
import simd

/// Estados visuales del núcleo. Es SOLO representación: no conoce al cerebro, ni a las herramientas, ni a la voz.
/// Quien lo use traduce sus estados reales a este enum.
enum CoreVisualState: Equatable {
    case idle, listening, thinking, speaking, executing, error, offline
}

/// Lo que la interfaz le comunica a la escena en cada cambio (valores simples).
struct CoreSceneInput {
    var state: CoreVisualState = .idle
    var level: Float = 0                 // 0…1, nivel de audio al escuchar
    var pulse: TimeInterval = 0          // instante (timeIntervalSinceReferenceDate) de la última palabra dicha
    var calm: Bool = false               // «reducir movimiento»: menos velocidad y amplitud
}

/// Escena SceneKit del núcleo: dos anillos de cromo ENTRELAZADOS (como eslabones, sin atravesarse), un tercer anillo orbital,
/// tiras incandescentes, una chispa central que ilumina el metal desde dentro y bloom para el resplandor.
final class CoreSceneController: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    let scene = SCNScene()
    let cameraNode = SCNNode()

    // Nodos animados
    private let assembly = SCNNode()                 // los dos anillos entrelazados
    private let ringA = SCNNode()                    // soporte fijo del eslabón A (posición)
    private let spinA = SCNNode()                    // gira sobre el eje de simetría del eslabón (un solo eje: sin ambigüedad de orden)
    private let ringB = SCNNode()
    private let spinB = SCNNode()
    private let orbit = SCNNode()                    // anillo exterior
    private let sparkNode = SCNNode()
    private let flareNode = SCNNode()
    private let coreLight = SCNLight()
    private let rimWarm = SCNLight()
    private let camera = SCNCamera()
    private let particleRoot = SCNNode()
    private var particles: [SCNNode] = []
    private let toolRoot = SCNNode()
    private var toolDots: [SCNNode] = []
    private var toolLines: [SCNNode] = []
    private var heatMaterials: [SCNMaterial] = []
    private let sparkMaterial = SCNMaterial()
    private let flareMaterial = SCNMaterial()

    // Estado compartido con la UI (hilo principal) y el hilo de render.
    private let lock = NSLock()
    private var input = CoreSceneInput()

    // Estado suavizado (solo hilo de render).
    private var energy: Float = 0.3
    private var spinSpeed: Float = 0.25
    private var phase: Float = 0
    private var deform: Float = 0
    private var lastTime: TimeInterval = 0

    private static let linkRadius: Float = 0.80
    private static let linkOffset: Float = 0.40

    override init() {
        super.init()
        buildScene()
    }

    func update(_ newInput: CoreSceneInput) {
        lock.lock()
        input = newInput
        lock.unlock()
    }

    private func currentInput() -> CoreSceneInput {
        lock.lock()
        defer { lock.unlock() }
        return input
    }

    // MARK: Construcción

    private func chrome(diffuse: CGFloat, roughness: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor(white: diffuse, alpha: 1)
        material.metalness.contents = 1.0
        material.roughness.contents = roughness
        material.isDoubleSided = true          // sin depender del sentido de los triángulos de la malla
        return material
    }

    private func heatStrip(radius: Float, pipe: Float) -> SCNNode {
        let torus = SCNTorus(ringRadius: CGFloat(radius), pipeRadius: CGFloat(pipe))
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.black
        material.emission.contents = UIColor(red: 1.0, green: 0.42, blue: 0.0, alpha: 1)
        torus.materials = [material]
        heatMaterials.append(material)
        let node = SCNNode(geometry: torus)
        node.eulerAngles.x = .pi / 2           // SCNTorus gira alrededor de Y; las bandas viven en el plano XY
        return node
    }

    private func buildScene() {
        scene.background.contents = UIColor(red: 0.032, green: 0.033, blue: 0.040, alpha: 1)
        scene.lightingEnvironment.contents = CoreEnvironment.studioMap()
        scene.lightingEnvironment.intensity = 1.9

        let radius = Self.linkRadius
        // Dos eslabones: A en el plano XY centrado en (−d,0,0); B en el plano XZ centrado en (+d,0,0). Con d = R/2 se enlazan.
        spinA.geometry = BandRingMesh.make(majorRadius: radius, halfWidth: 0.17, halfThickness: 0.05, twists: 1, wobble: 0.045)
        spinA.geometry?.materials = [chrome(diffuse: 0.07, roughness: 0.17)]
        ringA.position = SCNVector3(-Self.linkOffset, 0, 0)
        ringA.addChildNode(spinA)
        ringA.addChildNode(heatStrip(radius: radius * 0.83, pipe: 0.011))

        spinB.geometry = BandRingMesh.make(majorRadius: radius, halfWidth: 0.15, halfThickness: 0.048, twists: 2, wobble: 0.05)
        spinB.geometry?.materials = [chrome(diffuse: 0.09, roughness: 0.24)]
        ringB.position = SCNVector3(Self.linkOffset, 0, 0)
        ringB.eulerAngles.x = .pi / 2                // tumbado sobre el plano XZ (un solo eje)
        ringB.addChildNode(spinB)
        ringB.addChildNode(heatStrip(radius: radius * 0.83, pipe: 0.011))

        assembly.addChildNode(ringA)
        assembly.addChildNode(ringB)

        // Anillo orbital exterior, fino y más claro.
        orbit.geometry = BandRingMesh.make(majorRadius: 1.58, halfWidth: 0.055, halfThickness: 0.022, twists: 0, wobble: 0.02, segments: 180, sides: 24)
        orbit.geometry?.materials = [chrome(diffuse: 0.55, roughness: 0.12)]
        orbit.addChildNode(heatStrip(radius: 1.58 * 0.97, pipe: 0.007))

        let rig = SCNNode()
        rig.addChildNode(assembly)
        rig.addChildNode(orbit)
        scene.rootNode.addChildNode(rig)

        // Chispa central: esfera emisiva + destello en cruz + luz naranja que ilumina el metal desde dentro.
        let sphere = SCNSphere(radius: 0.085)
        sparkMaterial.lightingModel = .constant
        sparkMaterial.diffuse.contents = UIColor.white
        sparkMaterial.emission.contents = UIColor(red: 1.0, green: 0.85, blue: 0.6, alpha: 1)
        sphere.materials = [sparkMaterial]
        sparkNode.geometry = sphere
        coreLight.type = .omni
        coreLight.color = UIColor(red: 1.0, green: 0.48, blue: 0.08, alpha: 1)
        coreLight.intensity = 800
        coreLight.attenuationStartDistance = 0.2
        coreLight.attenuationEndDistance = 3.2
        sparkNode.light = coreLight
        scene.rootNode.addChildNode(sparkNode)

        let flare = SCNPlane(width: 2.6, height: 2.6)
        flareMaterial.lightingModel = .constant
        flareMaterial.diffuse.contents = CoreEnvironment.flareTexture()
        flareMaterial.blendMode = .add
        flareMaterial.writesToDepthBuffer = false
        flareMaterial.isDoubleSided = true
        flare.materials = [flareMaterial]
        flareNode.geometry = flare
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        flareNode.constraints = [billboard]
        flareNode.opacity = 0.7
        scene.rootNode.addChildNode(flareNode)

        // Luces: clave fría desde arriba a la izquierda y contraluz cálido desde abajo a la derecha.
        let key = SCNNode()
        key.light = {
            let light = SCNLight()
            light.type = .directional
            light.color = UIColor(red: 0.85, green: 0.92, blue: 1.0, alpha: 1)
            light.intensity = 650
            return light
        }()
        key.eulerAngles = SCNVector3(-0.7, -0.6, 0)
        scene.rootNode.addChildNode(key)
        let warm = SCNNode()
        rimWarm.type = .directional
        rimWarm.color = UIColor(red: 1.0, green: 0.45, blue: 0.08, alpha: 1)
        rimWarm.intensity = 520
        warm.light = rimWarm
        warm.eulerAngles = SCNVector3(0.8, 2.4, 0)
        scene.rootNode.addChildNode(warm)

        // Cámara con bloom (resplandor de lo incandescente) y viñeta suave.
        camera.fieldOfView = 30
        camera.zNear = 0.1
        camera.zFar = 30
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = -0.15
        camera.bloomIntensity = 0.9
        camera.bloomThreshold = 0.7
        camera.bloomBlurRadius = 14
        camera.vignettingIntensity = 0.55
        camera.vignettingPower = 1.4
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 6.3)
        scene.rootNode.addChildNode(cameraNode)

        // Partículas (pensamiento) y red de herramientas (ejecución): ocultas hasta que su estado las necesita.
        for _ in 0..<22 {
            let dot = SCNNode(geometry: SCNSphere(radius: 0.02))
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor.black
            material.emission.contents = UIColor(red: 1.0, green: 0.6, blue: 0.2, alpha: 1)
            dot.geometry?.materials = [material]
            particleRoot.addChildNode(dot)
            particles.append(dot)
        }
        particleRoot.isHidden = true
        scene.rootNode.addChildNode(particleRoot)

        for _ in 0..<5 {
            let dot = SCNNode(geometry: SCNSphere(radius: 0.035))
            let line = SCNNode(geometry: SCNCylinder(radius: 0.005, height: 1))
            for node in [dot, line] {
                let material = SCNMaterial()
                material.lightingModel = .constant
                material.diffuse.contents = UIColor.black
                material.emission.contents = UIColor(red: 1.0, green: 0.55, blue: 0.12, alpha: 1)
                node.geometry?.materials = [material]
            }
            toolRoot.addChildNode(dot)
            toolRoot.addChildNode(line)
            toolDots.append(dot)
            toolLines.append(line)
        }
        toolRoot.isHidden = true
        scene.rootNode.addChildNode(toolRoot)
    }

    // MARK: Animación (hilo de render)

    private static func tint(for state: CoreVisualState) -> UIColor {
        switch state {
        case .error: return UIColor(red: 1.0, green: 0.27, blue: 0.36, alpha: 1)
        case .offline: return UIColor(red: 0.55, green: 0.58, blue: 0.64, alpha: 1)
        case .thinking: return UIColor(red: 1.0, green: 0.72, blue: 0.25, alpha: 1)
        default: return UIColor(red: 1.0, green: 0.42, blue: 0.0, alpha: 1)
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let input = currentInput()
        let dt: Float = lastTime == 0 ? 0 : Float(min(max(time - lastTime, 0), 0.1))
        lastTime = time
        let now = Date().timeIntervalSinceReferenceDate
        let since = Float(max(0, now - input.pulse))
        let clock = Float(time)
        let calm: Float = input.calm ? 0.25 : 1

        var targetEnergy: Float
        var targetSpeed: Float = 0.25
        var targetDeform: Float = 0
        switch input.state {
        case .idle:
            targetEnergy = 0.30 + 0.05 * sin(clock * 0.9)
        case .listening:
            targetEnergy = 0.55 + input.level * 0.9
            targetSpeed = 0.45
            targetDeform = input.level
        case .thinking:
            targetEnergy = 0.75 + 0.1 * sin(clock * 3)
            targetSpeed = 0.7
        case .speaking:
            targetEnergy = 0.55 + 0.45 * exp(-since * 5)
            targetSpeed = 0.5
            targetDeform = exp(-since * 4)
        case .executing:
            targetEnergy = 0.95
            targetSpeed = 1.05
        case .error:
            targetEnergy = sin(clock * 14) > 0 ? 0.95 : 0.45
            targetSpeed = 0.6
            targetDeform = sin(clock * 18) > 0 ? 0.6 : 0
        case .offline:
            targetEnergy = 0.08
            targetSpeed = 0.04
        }
        targetSpeed *= calm
        targetDeform *= calm

        energy += (targetEnergy - energy) * min(1, dt * 6)
        spinSpeed += (targetSpeed - spinSpeed) * min(1, dt * 3)
        deform += (targetDeform - deform) * min(1, dt * 10)
        phase += dt * spinSpeed

        // Movimiento: el conjunto gira sobre Y con cabeceo suave; cada eslabón rueda sobre su propio eje (el metal «fluye»).
        assembly.eulerAngles = SCNVector3(0.5 + 0.12 * sin(phase * 0.9), phase * 0.55, -0.25 + 0.08 * sin(phase * 0.6))
        spinA.eulerAngles.z = phase * 0.9                        // giro sobre el eje de simetría de cada eslabón:
        spinB.eulerAngles.z = phase * -0.8                       // no altera su posición, así que nunca rompe el enlace
        orbit.eulerAngles = SCNVector3(1.05 + 0.1 * sin(phase * 0.5), phase * -0.35, 0.45)

        let beat: Float = 1 + 0.06 * deform
        assembly.scale = SCNVector3(beat, beat, beat)
        let focus: Float = input.state == .thinking ? 0.9 : 1.0
        orbit.scale = SCNVector3(focus * beat, focus * beat, focus * beat)

        // Luz e incandescencia.
        let tint = Self.tint(for: input.state)
        for material in heatMaterials {
            material.emission.contents = tint
            material.emission.intensity = CGFloat(0.35 + 1.9 * energy)
        }
        sparkMaterial.emission.contents = input.state == .error ? tint : UIColor(red: 1.0, green: 0.86, blue: 0.62, alpha: 1)
        let sparkScale: Float = 0.6 + 0.9 * energy
        sparkNode.scale = SCNVector3(sparkScale, sparkScale, sparkScale)
        coreLight.color = tint
        coreLight.intensity = CGFloat(250 + 2200 * energy)
        rimWarm.intensity = CGFloat(260 + 520 * energy)
        flareNode.opacity = CGFloat(min(1, 0.25 + 0.75 * energy))
        let flareScale: Float = 0.55 + 0.55 * energy
        flareNode.scale = SCNVector3(flareScale, flareScale, flareScale)
        camera.bloomIntensity = CGFloat(0.45 + 1.1 * energy)

        updateParticles(visible: input.state == .thinking, time: clock, tint: tint)
        updateToolNetwork(visible: input.state == .executing, time: clock, tint: tint)
    }

    /// Pensamiento: partículas que entran en espiral hacia el centro.
    private func updateParticles(visible: Bool, time: Float, tint: UIColor) {
        particleRoot.isHidden = !visible
        guard visible else { return }
        for (index, dot) in particles.enumerated() {
            let p = (time * 0.3 + Float(index) * 0.618034).truncatingRemainder(dividingBy: 1)
            let r: Float = 1.9 * (1 - p) + 0.1
            let angle = Float(index) * 2.39996 + time * (0.8 + p)
            dot.position = SCNVector3(cos(angle) * r, sin(angle * 0.7 + Float(index)) * 0.55 * (1 - p), sin(angle) * r)
            let size = 0.5 + 0.8 * p
            dot.scale = SCNVector3(size, size, size)
            dot.opacity = CGFloat(0.25 + 0.75 * (1 - p))
            dot.geometry?.firstMaterial?.emission.contents = tint
        }
    }

    /// Ejecución de herramientas: nodos que orbitan y se conectan al centro con líneas que pulsan.
    private func updateToolNetwork(visible: Bool, time: Float, tint: UIColor) {
        toolRoot.isHidden = !visible
        guard visible else { return }
        let count = toolDots.count
        for index in 0..<count {
            let angle = phase * 1.4 + Float(index) * 2 * Float.pi / Float(count)
            let position = SIMD3<Float>(cos(angle) * 1.5, sin(angle * 2 + Float(index)) * 0.35, sin(angle) * 1.5)
            toolDots[index].position = SCNVector3(position.x, position.y, position.z)
            let length = simd_length(position)
            let line = toolLines[index]
            line.position = SCNVector3(position.x / 2, position.y / 2, position.z / 2)
            line.scale = SCNVector3(1, length, 1)
            if length > 0.001 {
                line.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: position / length)
            }
            let pulse = 0.35 + 0.65 * pow(sin(time * 5 + Float(index)), 2)
            line.opacity = CGFloat(pulse)
            toolDots[index].opacity = CGFloat(0.5 + 0.5 * pulse)
            toolDots[index].geometry?.firstMaterial?.emission.contents = tint
            line.geometry?.firstMaterial?.emission.contents = tint
        }
    }
}
