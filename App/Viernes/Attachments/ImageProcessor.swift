import UIKit
import ImageIO
import Vision
import ViernesCore

/// Lee una imagen (JPEG, PNG, HEIC o WebP) con ImageIO, la reduce y la codifica en JPEG para enviarla a un modelo con visión.
/// Las reglas de tamaño y compresión viven en `ImagePolicy` (núcleo, con pruebas); aquí solo se ejecutan.
enum ImageProcessor {
    struct Output {
        let part: ImagePart
        /// El JPEG que se enviará (y que se muestra en la vista previa: es exactamente lo que sale del teléfono).
        let jpeg: Data
        let thumbnail: UIImage
        let width: Int
        let height: Int
    }

    static func process(name: String, data: Data) throws -> Output {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw AttachmentError.unreadableImage(name: name) }
        try ImagePolicy.checkPixels(name: name, width: width, height: height)

        var cache: [Int: UIImage] = [:]
        for step in ImagePolicy.encodingSteps(width: width, height: height) {
            let image: UIImage
            if let cached = cache[step.longSide] {
                image = cached
            } else {
                guard let scaled = scaledImage(source, longSide: step.longSide, originalLongSide: max(width, height)) else {
                    throw AttachmentError.unreadableImage(name: name)
                }
                cache[step.longSide] = scaled
                image = scaled
            }
            guard let jpeg = image.jpegData(compressionQuality: CGFloat(step.quality)) else { continue }
            if jpeg.count <= ImagePolicy.maxPayloadBytes {
                let thumbnail = scaledImage(source, longSide: 240, originalLongSide: max(width, height)) ?? image
                return Output(part: ImagePart(mimeType: "image/jpeg", base64: jpeg.base64EncodedString(), name: name),
                              jpeg: jpeg, thumbnail: thumbnail, width: Int(image.size.width), height: Int(image.size.height))
            }
        }
        throw AttachmentError.imageTooLarge(name: name)
    }

    /// Miniatura con la orientación EXIF ya aplicada y el fondo transparente sustituido por blanco (JPEG no tiene transparencia).
    private static func scaledImage(_ source: CGImageSource, longSide: Int, originalLongSide: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longSide, originalLongSide),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// OCR local con Vision: el texto se reconoce en el iPhone, sin enviar nada fuera.
enum TextRecognizer {
    static func recognize(_ cgImage: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let wanted = ["es-ES", "en-US"].filter { supported.contains($0) }
        if !wanted.isEmpty { request.recognitionLanguages = wanted }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func recognize(jpeg: Data) throws -> String {
        guard let image = UIImage(data: jpeg), let cgImage = image.cgImage else { return "" }
        return try recognize(cgImage)
    }
}
