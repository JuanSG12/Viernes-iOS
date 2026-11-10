import Foundation

/// Lo que un cerebro (modelo + proveedor) puede hacer DE VERDAD con lo que se le envía. Cada valor sale de la documentación
/// del proveedor o de una política propia de Viernes (y se dice cuál en `note`); nada se supone.
public struct ModelCapabilities: Equatable, Sendable {
    public var text: Bool
    public var imageInput: Bool
    public var maxImages: Int
    /// El proveedor lee PDF por su API de chat. Ninguno de los integrados lo documenta: los PDF se leen en el teléfono.
    public var pdfNative: Bool
    public var audioInput: Bool
    /// Ventana de contexto en tokens, si el proveedor la publica.
    public var contextTokens: Int?
    public var tools: Bool
    public var streaming: Bool
    /// Texto de archivos que Viernes se permite enviar en una petición (política, no límite del proveedor).
    public var excerptBudgetChars: Int
    public var note: String

    public init(text: Bool = true, imageInput: Bool = false, maxImages: Int = 0, pdfNative: Bool = false, audioInput: Bool = false,
                contextTokens: Int? = nil, tools: Bool = true, streaming: Bool = true, excerptBudgetChars: Int, note: String) {
        self.text = text
        self.imageInput = imageInput
        self.maxImages = maxImages
        self.pdfNative = pdfNative
        self.audioInput = audioInput
        self.contextTokens = contextTokens
        self.tools = tools
        self.streaming = streaming
        self.excerptBudgetChars = excerptBudgetChars
        self.note = note
    }
}

/// Un cerebro concreto: el modelo activo o su variante de visión.
public struct BrainProfile: Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    /// `nil` para los modelos locales.
    public var providerID: String?
    public var model: String?
    public var isCloud: Bool
    /// Variante del mismo proveedor elegida solo para leer imágenes.
    public var isVisionVariant: Bool
    public var capabilities: ModelCapabilities

    public init(id: String, displayName: String, providerID: String?, model: String?, isCloud: Bool,
                isVisionVariant: Bool = false, capabilities: ModelCapabilities) {
        self.id = id
        self.displayName = displayName
        self.providerID = providerID
        self.model = model
        self.isCloud = isCloud
        self.isVisionVariant = isVisionVariant
        self.capabilities = capabilities
    }
}

/// Ajustes de adjuntos (opcionales en `AppSettings` para no invalidar ajustes guardados por versiones anteriores).
public struct AttachmentSettings: Codable, Equatable, Sendable {
    /// Pedir confirmación antes de enviar adjuntos a un proveedor en la nube. Activado por defecto.
    public var askBeforeCloud: Bool
    /// Modelo de visión elegido por proveedor (si falta, se usa el de la tabla de `CapabilityMatrix`).
    public var visionModels: [String: String]

    public static let `default` = AttachmentSettings(askBeforeCloud: true, visionModels: [:])

    public init(askBeforeCloud: Bool = true, visionModels: [String: String] = [:]) {
        self.askBeforeCloud = askBeforeCloud
        self.visionModels = visionModels
    }

    public func sanitized() -> AttachmentSettings {
        var copy = self
        copy.visionModels = [:]
        for (provider, model) in visionModels where CloudProviders.all.contains(where: { $0.id == provider }) {
            let cleaned = model.trimmingCharacters(in: .whitespacesAndNewlines)
            let valid = !cleaned.isEmpty && cleaned.count <= 100
                && !cleaned.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
            if valid { copy.visionModels[provider] = cleaned }
        }
        return copy
    }
}

public extension AppSettings {
    var attachmentSettings: AttachmentSettings { attachments ?? .default }
}

/// Matriz de capacidades por cerebro. Los valores de Groq y Gemini salen de sus documentos oficiales (noviembre de 2026);
/// los de los modelos locales, de una política conservadora.
public enum CapabilityMatrix {
    /// Modelo de visión de Groq según su documentación (vista previa): hasta 3 imágenes por petición.
    public static let groqDefaultVisionModel = "qwen/qwen3.8-27b"
    static let groqMaxImages = 3
    /// Política propia: Gemini admite muchas más imágenes, pero se limita el tamaño de la petición.
    static let geminiMaxImages = 8

    /// Modelo que se usa para leer imágenes con un proveedor.
    public static func visionModel(providerID: String, chatModel: String, overrides: [String: String]) -> String {
        if let custom = overrides[providerID], !custom.isEmpty { return custom }
        return providerID == CloudProviders.groq.id ? groqDefaultVisionModel : chatModel
    }

    public static func chatProfile(descriptor: ModelDescriptor, cloud: CloudBrainSettings, overrides: [String: String] = [:]) -> BrainProfile {
        switch descriptor.backend {
        case .appleFoundation:
            return BrainProfile(
                id: descriptor.id, displayName: descriptor.displayName, providerID: nil, model: nil, isCloud: false,
                capabilities: ModelCapabilities(excerptBudgetChars: 2_000,
                                                note: "Modelo del sistema: solo texto. Presupuesto conservador porque su contexto es pequeño."))
        case .mlx:
            return BrainProfile(
                id: descriptor.id, displayName: descriptor.displayName, providerID: nil, model: nil, isCloud: false,
                capabilities: ModelCapabilities(excerptBudgetChars: 2_500, note: "Modelo local pequeño: solo texto y poco contexto."))
        case .cloud:
            let settings = cloud.sanitized()
            let preset = settings.preset
            let vision = visionModel(providerID: preset.id, chatModel: settings.model, overrides: overrides)
            if preset.id == CloudProviders.groq.id {
                let sees = settings.model == vision
                let context: Int? = settings.model.lowercased().contains("gpt-oss") ? 131_072 : nil
                return BrainProfile(
                    id: "cloud:\(preset.id):\(settings.model)", displayName: "\(preset.displayName) · \(settings.model)",
                    providerID: preset.id, model: settings.model, isCloud: true,
                    capabilities: ModelCapabilities(imageInput: sees, maxImages: sees ? groqMaxImages : 0, contextTokens: context,
                                                    excerptBudgetChars: 5_000,
                                                    note: sees ? "Modelo de visión de Groq (vista previa)." : "Modelo de texto de Groq; para imágenes usa el modelo de visión de su documentación."))
            }
            let sees = settings.model.lowercased().hasPrefix("gemini")
            return BrainProfile(
                id: "cloud:\(preset.id):\(settings.model)", displayName: "\(preset.displayName) · \(settings.model)",
                providerID: preset.id, model: settings.model, isCloud: true,
                capabilities: ModelCapabilities(imageInput: sees, maxImages: sees ? geminiMaxImages : 0, audioInput: sees,
                                                excerptBudgetChars: 40_000,
                                                note: "Imágenes por la API compatible con OpenAI (base64). El PDF no está documentado en esa API: se lee en el teléfono."))
        }
    }

    /// Variante de visión de un proveedor (misma clave, otro modelo), o `nil` si el proveedor no tiene una documentada.
    public static func visionProfile(providerID: String, chatModel: String, overrides: [String: String] = [:]) -> BrainProfile? {
        guard let preset = CloudProviders.all.first(where: { $0.id == providerID }) else { return nil }
        let model = visionModel(providerID: providerID, chatModel: chatModel, overrides: overrides)
        let isGroq = preset.id == CloudProviders.groq.id
        return BrainProfile(
            id: "vision:\(preset.id):\(model)", displayName: "\(preset.displayName) · \(model) (visión)",
            providerID: preset.id, model: model, isCloud: true, isVisionVariant: true,
            capabilities: ModelCapabilities(imageInput: true, maxImages: isGroq ? groqMaxImages : geminiMaxImages, audioInput: !isGroq,
                                            excerptBudgetChars: isGroq ? 5_000 : 40_000,
                                            note: isGroq ? "Modelo de visión de Groq (vista previa); hasta 3 imágenes por mensaje." : "Gemini lee imágenes por la API compatible con OpenAI."))
    }
}

// MARK: Enrutador

/// Qué trae un mensaje con adjuntos (solo cantidades y nombres).
public struct AttachmentSummary: Equatable, Sendable {
    public var imageNames: [String]
    public var documentNames: [String]
    public init(imageNames: [String] = [], documentNames: [String] = []) {
        self.imageNames = imageNames
        self.documentNames = documentNames
    }
    public var imageCount: Int { imageNames.count }
    public var documentCount: Int { documentNames.count }
    public var isEmpty: Bool { imageNames.isEmpty && documentNames.isEmpty }

    /// «2 imágenes y el texto de contrato.pdf»
    public var humanDescription: String {
        var parts: [String] = []
        if imageCount == 1 { parts.append("1 imagen") } else if imageCount > 1 { parts.append("\(imageCount) imágenes") }
        if documentCount == 1 {
            parts.append("el texto de «\(UntrustedContent.safeLabel(documentNames[0], limit: 40))»")
        } else if documentCount > 1 {
            parts.append("el texto de \(documentCount) archivos")
        }
        return parts.joined(separator: " y ")
    }
}

public struct RoutingContext: Sendable {
    public var current: BrainProfile
    /// Proveedores en la nube con clave guardada.
    public var providersWithKey: Set<String>
    public var cloud: CloudBrainSettings
    public var visionOverrides: [String: String]
    public var online: Bool
    public var askBeforeCloud: Bool
    /// El dispositivo puede leer texto de imágenes localmente (Vision).
    public var canOCRLocally: Bool

    public init(current: BrainProfile, providersWithKey: Set<String>, cloud: CloudBrainSettings = .default,
                visionOverrides: [String: String] = [:], online: Bool = true, askBeforeCloud: Bool = true, canOCRLocally: Bool = true) {
        self.current = current
        self.providersWithKey = providersWithKey
        self.cloud = cloud
        self.visionOverrides = visionOverrides
        self.online = online
        self.askBeforeCloud = askBeforeCloud
        self.canOCRLocally = canOCRLocally
    }
}

public struct RoutePlan: Equatable, Sendable {
    public var brain: BrainProfile
    /// Las imágenes viajan al modelo.
    public var sendImages: Bool
    /// Las imágenes se leen con OCR local y solo se envía su texto.
    public var ocrImages: Bool
    /// El contenido sale del dispositivo hacia un servidor.
    public var leavesDevice: Bool
    public var notes: [String]
}

public struct RouteConsent: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var plan: RoutePlan
}

public struct RouteAlternative: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Usar otro cerebro SOLO para este mensaje (el usuario lo autoriza explícitamente).
        case useBrain(BrainProfile)
        case localOCR
        case removeImages
        case configure
    }
    public var label: String
    public var explanation: String
    public var action: Action
}

public struct RouteBlock: Equatable, Sendable {
    public var reason: String
    public var alternatives: [RouteAlternative]
}

public enum RouteDecision: Equatable, Sendable {
    case send(RoutePlan)
    case askConsent(RouteConsent)
    case cannot(RouteBlock)
}

/// Decide a qué cerebro van los adjuntos según lo que ese cerebro puede leer, la privacidad y la configuración.
/// Nunca cambia a OTRO proveedor externo sin que el usuario lo autorice, y explica por qué cuando algo no es posible.
public enum AttachmentRouter {
    public static func decide(_ attachments: AttachmentSummary, context: RoutingContext) -> RouteDecision {
        let current = context.current
        if attachments.isEmpty {
            return .send(RoutePlan(brain: current, sendImages: false, ocrImages: false, leavesDevice: false, notes: []))
        }

        var brain = current
        var notes: [String] = []
        let needsVision = attachments.imageCount > 0

        if needsVision {
            if current.capabilities.imageInput {
                brain = current
            } else if current.isCloud, let providerID = current.providerID,
                      let vision = CapabilityMatrix.visionProfile(providerID: providerID, chatModel: context.cloud.model, overrides: context.visionOverrides) {
                brain = vision
                notes.append("Para leer la imagen usé el modelo de visión «\(vision.model ?? "")» de \(providerName(providerID)); el resto de la conversación sigue con tu cerebro de siempre.")
            } else {
                return .cannot(blockedForImages(current: current, context: context))
            }
            if attachments.imageCount > brain.capabilities.maxImages {
                return .cannot(RouteBlock(
                    reason: "\(brain.displayName) acepta como máximo \(brain.capabilities.maxImages) imágenes por mensaje y adjuntaste \(attachments.imageCount).",
                    alternatives: [RouteAlternative(label: "Quitar imágenes", explanation: "Elige cuáles enviar.", action: .removeImages)]))
            }
        }

        if brain.isCloud {
            if !context.online {
                return .cannot(RouteBlock(
                    reason: "No hay conexión y \(brain.displayName) la necesita para leer tus adjuntos.",
                    alternatives: [RouteAlternative(label: "Usar el modelo local", explanation: "Cambia a un modelo del teléfono en Ajustes › Modelo local; leerá los documentos (las imágenes solo con OCR).", action: .configure)]))
            }
            let plan = RoutePlan(brain: brain, sendImages: needsVision, ocrImages: false, leavesDevice: true, notes: notes)
            guard context.askBeforeCloud else { return .send(plan) }
            let provider = brain.providerID.map(providerName) ?? "el proveedor"
            let detail = "Se enviará \(attachments.humanDescription) a \(provider) (modelo \(brain.model ?? "—")) para responderte. "
                + "Sale de tu iPhone solo para esta respuesta; lo que el proveedor haga con ello depende de sus términos."
            return .askConsent(RouteConsent(title: "Enviar adjuntos a \(provider)", detail: detail, plan: plan))
        }

        return .send(RoutePlan(brain: brain, sendImages: false, ocrImages: false, leavesDevice: false, notes: notes))
    }

    /// El cerebro actual no puede ver imágenes y no hay variante de visión del mismo proveedor: se explican las opciones.
    static func blockedForImages(current: BrainProfile, context: RoutingContext) -> RouteBlock {
        var alternatives: [RouteAlternative] = []
        for preset in CloudProviders.all where context.providersWithKey.contains(preset.id) && preset.id != current.providerID {
            guard let vision = CapabilityMatrix.visionProfile(providerID: preset.id, chatModel: preset.defaultModel, overrides: context.visionOverrides) else { continue }
            alternatives.append(RouteAlternative(
                label: "Usar \(preset.displayName) solo para este mensaje",
                explanation: "La imagen saldría de tu iPhone hacia \(preset.displayName) (modelo \(vision.model ?? "—")). La conversación sigue con tu cerebro actual.",
                action: .useBrain(vision)))
        }
        if context.canOCRLocally {
            alternatives.append(RouteAlternative(
                label: "Leer solo el texto de la imagen",
                explanation: "Se reconoce el texto en tu iPhone (no sale nada) y trabajo con ese texto. Sirve si la imagen tiene texto; no describe fotos.",
                action: .localOCR))
        }
        alternatives.append(RouteAlternative(label: "Quitar la imagen", explanation: "Envía el mensaje sin ella.", action: .removeImages))
        return RouteBlock(reason: "\(current.displayName) solo lee texto: no puede ver imágenes.", alternatives: alternatives)
    }

    /// Plan para una alternativa que el usuario eligió (la propia elección es su autorización).
    public static func plan(for alternative: RouteAlternative, context: RoutingContext) -> RoutePlan? {
        switch alternative.action {
        case .useBrain(let brain):
            let provider = brain.providerID.map(providerName) ?? "otro proveedor"
            return RoutePlan(brain: brain, sendImages: true, ocrImages: false, leavesDevice: true,
                             notes: ["Usé \(provider) solo para este mensaje porque lo autorizaste."])
        case .localOCR:
            return RoutePlan(brain: context.current, sendImages: false, ocrImages: true, leavesDevice: context.current.isCloud,
                             notes: ["Leí el texto de la imagen en el teléfono; no puedo describir su aspecto."])
        case .removeImages, .configure:
            return nil
        }
    }

    static func providerName(_ id: String) -> String {
        CloudProviders.all.first(where: { $0.id == id })?.displayName ?? id
    }
}
