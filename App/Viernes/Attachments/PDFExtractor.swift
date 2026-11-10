import PDFKit
import UIKit
import ViernesCore

/// Lee un PDF con PDFKit. Las páginas sin texto (escaneos, fotos) se reconocen con OCR local de Vision, hasta un máximo.
enum PDFExtractor {
    static func extract(name: String, data: Data) throws -> ExtractedDocument {
        guard let pdf = PDFDocument(data: data) else {
            throw AttachmentError.corrupt(name: name, reason: "el PDF está dañado o no se puede abrir.")
        }
        if pdf.isEncrypted, pdf.isLocked, !pdf.unlock(withPassword: "") { throw AttachmentError.encrypted(name: name) }
        let total = pdf.pageCount
        guard total > 0 else { throw AttachmentError.noReadableText(name: name) }

        let readable = min(total, AttachmentLimits.maxPDFPages)
        var pages: [String] = []
        var warnings: [String] = []
        var recognized = false
        var ocrDone = 0
        var ocrSkipped = 0
        for index in 0..<readable {
            guard let page = pdf.page(at: index) else { pages.append(""); continue }
            var text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
                if ocrDone < AttachmentLimits.maxOCRPages {
                    if let ocr = try? ocrText(of: page), !ocr.isEmpty {
                        text = ocr
                        recognized = true
                    }
                    ocrDone += 1
                } else {
                    ocrSkipped += 1
                }
            }
            pages.append(text)
        }
        if total > readable { warnings.append("Solo se leyeron las primeras \(readable) de \(total) páginas.") }
        if ocrSkipped > 0 { warnings.append("Hay \(ocrSkipped) páginas escaneadas más que no se leyeron (el OCR se limita a las primeras \(AttachmentLimits.maxOCRPages)).") }

        var document = DocumentBuilders.pdf(name: name, pages: pages, recognizedByOCR: recognized, extraWarnings: warnings)
        guard document.hasText else { throw AttachmentError.noReadableText(name: name) }
        document.pageCount = total
        return document
    }

    /// Primera página como miniatura para el chip del adjunto.
    static func thumbnail(of data: Data) -> UIImage? {
        PDFDocument(data: data)?.page(at: 0)?.thumbnail(of: CGSize(width: 160, height: 200), for: .mediaBox)
    }

    /// Dibuja la página (≈ 2 200 px de lado mayor) y la pasa por el reconocimiento de texto.
    private static func ocrText(of page: PDFPage) throws -> String {
        let bounds = page.bounds(for: .mediaBox)
        let longSide = max(bounds.width, bounds.height)
        guard longSide > 0 else { return "" }
        let scale = min(3, 2_200 / longSide)
        let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let cgImage = image.cgImage else { return "" }
        return try TextRecognizer.recognize(cgImage)
    }

    /// Une las páginas escaneadas en un PDF (cada página reducida y comprimida para no pasar de los límites).
    static func makePDF(from pages: [UIImage]) -> Data? {
        let document = PDFDocument()
        for (index, image) in pages.prefix(AttachmentLimits.maxOCRPages).enumerated() {
            let longest = max(image.size.width, image.size.height) * image.scale
            let factor = min(1, 2_000 / max(longest, 1))
            let size = CGSize(width: image.size.width * image.scale * factor, height: image.size.height * image.scale * factor)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            guard let jpeg = resized.jpegData(compressionQuality: 0.7), let compressed = UIImage(data: jpeg),
                  let pdfPage = PDFPage(image: compressed) else { continue }
            document.insert(pdfPage, at: index)
        }
        return document.pageCount > 0 ? document.dataRepresentation() : nil
    }
}
