import Foundation
import ViernesCore

extension AppModel {
    /// SOLO para las pruebas de interfaz y las capturas del CI (`--uitest --uitest-demo-library`). Los textos son de ejemplo, pero
    /// pasan por EL MISMO pipeline real de la biblioteca (lectura, fragmentos con página, vectores, índice, verificación): los estados
    /// que se ven (indexado, resultados de búsqueda) los produce la app, no están dibujados a mano.
    func seedQALibrary() async {
        do {
            let project = try await knowledge.createCollection(name: "Trabajo", kind: .project)
            let contract = """
                CONTRATO DE TRABAJO A TÉRMINO FIJO
                Entre ACME S.A. y el empleado se celebra el presente contrato.

                Cláusula segunda. El salario mensual del empleado será de 4.500.000 pesos colombianos, pagaderos el último día hábil de cada mes.

                Cláusula tercera. La vigencia es de doce meses con renovación automática. Firmado el 15 de marzo de 2023.
                """
            let data = Data(contract.utf8)
            let processed = try AttachmentProcessing.process(name: "contrato.txt", data: data)
            if let document = processed.document {
                _ = try await knowledge.ingest(document, source: IngestSource(sourceName: "contrato.txt", contentHash: ContentHash.sha256Hex(data), byteCount: data.count),
                                               options: IngestOptions(collectionID: project.id, tags: ["trabajo", "legal"]))
            }
            let sheet = "producto,precio,stock\nCafé,12000,5\nTé,8000,9\n"
            let sheetData = Data(sheet.utf8)
            let table = try AttachmentProcessing.process(name: "ventas.csv", data: sheetData)
            if let document = table.document {
                _ = try await knowledge.ingest(document, source: IngestSource(sourceName: "ventas.csv", contentHash: ContentHash.sha256Hex(sheetData), byteCount: sheetData.count),
                                               options: IngestOptions(tags: ["ventas"]))
            }
            _ = try await knowledge.addNote(title: "Ideas del proyecto", text: "Comprar las licencias de la herramienta de diseño antes del viernes.", options: IngestOptions(collectionID: project.id))
        } catch {
            Diagnostics.shared.log("semilla de la biblioteca (solo pruebas): \(error.localizedDescription)")
        }
        await reloadLibrary()
    }
}
