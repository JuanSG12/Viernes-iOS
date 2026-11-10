import XCTest
import UIKit
import SwiftData
import CryptoKit
import ViernesCore
@testable import Viernes

/// Biblioteca de conocimiento sobre SwiftData cifrado (simulador): persistencia, cifrado en reposo, recuperación tras «reiniciar» y borrado.
final class KnowledgeStoreTests: XCTestCase {
    private func contract() -> ExtractedDocument {
        ExtractedDocument(name: "contrato.pdf", kind: .pdf, sections: [
            DocumentSection(page: 1, text: "Contrato de trabajo entre ACME S.A. y el empleado."),
            DocumentSection(page: 2, text: "Cláusula segunda: el salario mensual del empleado será de 4.500.000 pesos colombianos."),
            DocumentSection(page: 3, text: "Cláusula tercera: vigencia de doce meses. Firmado el 15 de marzo de 2023.")
        ], pageCount: 3)
    }

    private func source() -> IngestSource {
        IngestSource(sourceName: "contrato.pdf", contentHash: ContentHash.sha256Hex("contrato"), byteCount: 1_000)
    }

    func testDocumentSurvivesARestartAndIsEncryptedAtRest() async throws {
        let container = try ViernesStore.makeKnowledgeContainer(inMemory: true)
        let first = KnowledgeEngine(store: SwiftDataKnowledgeStore(modelContainer: container), embedder: LibraryEmbedder.make())
        guard case .indexed(let item) = try await first.ingest(contract(), source: source(), options: IngestOptions(tags: ["legal"])) else {
            return XCTFail("Debía indexarse")
        }
        XCTAssertEqual(item.status, .indexed)

        // En disco no hay texto en claro: ni en los fragmentos ni en los metadatos.
        let context = ModelContext(container)
        let chunkRecords = try context.fetch(FetchDescriptor<KnowledgeChunkRecord>())
        XCTAssertEqual(chunkRecords.count, item.chunkCount)
        for record in chunkRecords {
            XCTAssertNil(record.sealed.range(of: Data("salario".utf8)), "El texto del documento no debe estar en claro")
        }
        let itemRecords = try context.fetch(FetchDescriptor<KnowledgeItemRecord>())
        XCTAssertEqual(itemRecords.count, 1)
        XCTAssertNil(itemRecords[0].sealed.range(of: Data("contrato".utf8)), "Tampoco el título")

        // «Reinicio»: un motor nuevo sobre el mismo almacén recupera todo y busca igual.
        let second = KnowledgeEngine(store: SwiftDataKnowledgeStore(modelContainer: container), embedder: LibraryEmbedder.make())
        let hits = await second.search("¿Cuánto establece mi contrato como salario?")
        XCTAssertEqual(hits.first?.itemID, item.id)
        XCTAssertEqual(hits.first?.reference, "pág. 2")
        let recovered = await second.item(item.id)
        XCTAssertEqual(recovered?.tags, ["legal"])
        XCTAssertEqual(recovered?.status, .indexed)
        let dateHits = await second.search("15 de marzo de 2023")
        XCTAssertEqual(dateHits.first?.itemID, item.id)
    }

    func testDeletingRemovesEveryStoredRecordAndTheSearchHits() async throws {
        let container = try ViernesStore.makeKnowledgeContainer(inMemory: true)
        let engine = KnowledgeEngine(store: SwiftDataKnowledgeStore(modelContainer: container), embedder: LibraryEmbedder.make())
        guard case .indexed(let item) = try await engine.ingest(contract(), source: source()) else { return XCTFail() }
        try await engine.delete(item.id)
        let context = ModelContext(container)
        XCTAssertTrue(try context.fetch(FetchDescriptor<KnowledgeChunkRecord>()).isEmpty, "No quedan fragmentos guardados")
        XCTAssertTrue(try context.fetch(FetchDescriptor<KnowledgeItemRecord>()).isEmpty)
        let hits = await engine.search("salario mensual")
        XCTAssertTrue(hits.isEmpty, "Deja de aparecer en las búsquedas")
        let reopened = KnowledgeEngine(store: SwiftDataKnowledgeStore(modelContainer: container), embedder: LibraryEmbedder.make())
        let again = await reopened.search("salario mensual")
        XCTAssertTrue(again.isEmpty, "Y tampoco tras reiniciar")
    }

    func testAnUnreadableRecordIsSkippedInsteadOfBreakingTheLibrary() async throws {
        let container = try ViernesStore.makeKnowledgeContainer(inMemory: true)
        let engine = KnowledgeEngine(store: SwiftDataKnowledgeStore(modelContainer: container), embedder: nil)
        guard case .indexed(let good) = try await engine.ingest(contract(), source: source()) else { return XCTFail() }
        let context = ModelContext(container)
        context.insert(KnowledgeItemRecord(id: UUID(), updatedAt: Date(), sealed: Data("esto no está cifrado con la clave".utf8)))
        try context.save()
        let reopened = KnowledgeEngine(store: SwiftDataKnowledgeStore(modelContainer: container), embedder: nil)
        let items = await reopened.allItems()
        XCTAssertEqual(items.map { $0.id }, [good.id], "El registro dañado se omite; lo demás sigue ahí")
    }

    func testMemoryAndLibraryLiveInSeparateStores() async throws {
        let memoryContainer = try ViernesStore.makeContainer(inMemory: true)
        let knowledgeContainer = try ViernesStore.makeKnowledgeContainer(inMemory: true)
        let memory = SwiftDataMemoryStore(modelContainer: memoryContainer)
        _ = try await memory.remember(text: "Prefiero respuestas cortas", kind: .preference, source: .userExplicit, policy: .default, now: Date())
        let engine = KnowledgeEngine(store: SwiftDataKnowledgeStore(modelContainer: knowledgeContainer), embedder: nil)
        _ = try await engine.ingest(contract(), source: source())
        let memories = try await memory.all()
        XCTAssertEqual(memories.count, 1, "La biblioteca no añadió nada a la memoria personal")
        let libraryHits = await engine.search("respuestas cortas")
        XCTAssertTrue(libraryHits.filter { $0.isLexicalMatch }.isEmpty, "Los recuerdos no aparecen en la biblioteca")
        let memoryCount = try ModelContext(memoryContainer).fetchCount(FetchDescriptor<MemoryRecord>())
        let knowledgeCount = try ModelContext(knowledgeContainer).fetchCount(FetchDescriptor<KnowledgeItemRecord>())
        XCTAssertEqual(memoryCount, 1)
        XCTAssertEqual(knowledgeCount, 1)
    }

    func testCryptoKitAndCoreHashesAgree() {
        let data = Data("contrato de prueba con tildes: áéíóú ñ".utf8)
        let apple = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(apple, ContentHash.sha256Hex(data), "La app (CryptoKit) y el núcleo identifican igual los archivos")
    }

    func testTheLibraryEmbedderRelatesQuestionsToTheirDocuments() throws {
        let embedder = LibraryEmbedder.make()
        let document = try XCTUnwrap(embedder.embed("El contrato de trabajo fija el salario mensual del empleado."))
        let related = try XCTUnwrap(embedder.embed("¿Cuánto paga mi contrato de trabajo cada mes?"))
        let unrelated = try XCTUnwrap(embedder.embed("La receta del ajiaco lleva papa criolla, mazorca y guascas."))
        XCTAssertGreaterThan(Embedding.similarity(document, related), Embedding.similarity(document, unrelated),
                             "Modelo usado: \(embedder.id)")
        XCTAssertEqual(document.count, related.count)
    }
}

/// La biblioteca conectada al modelo de la app: guardar desde un adjunto, estados y borrado.
@MainActor
final class LibraryModelTests: XCTestCase {
    override func tearDown() async throws {
        AttachmentFiles.removeFolder()
    }

    private func makeModel() throws -> AppModel {
        AppModel(container: try ViernesStore.makeContainer(inMemory: true), knowledgeContainer: try ViernesStore.makeKnowledgeContainer(inMemory: true))
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    func testSavingAnAttachmentIndexesItAndItCanBeFoundAndDeleted() async throws {
        let model = try makeModel()
        await model.startLibrary()
        await model.attachments.addData(name: "contrato.txt", data: Data("Cláusula segunda: el salario mensual será de 4.500.000 pesos.".utf8))
        let draft = try XCTUnwrap(model.attachments.drafts.first)
        let outcome = await model.saveToLibrary(draftID: draft.id, collectionID: nil, tags: ["legal"])
        guard case .saved(let item) = outcome else { return XCTFail("Debía guardarse: \(outcome)") }
        XCTAssertEqual(item.status, .indexed)
        XCTAssertEqual(model.libraryItems.map { $0.id }, [item.id])
        XCTAssertEqual(model.attachments.drafts.first?.savedItemID, item.id, "El adjunto muestra que ya está en la biblioteca")

        let hits = await model.knowledge.search("salario mensual", onlyRelevant: true)
        XCTAssertEqual(hits.first?.itemID, item.id)

        // Guardar de nuevo lo mismo se detecta como duplicado.
        await model.attachments.addData(name: "contrato-copia.txt", data: Data("Cláusula segunda: el salario mensual será de 4.500.000 pesos.".utf8))
        let copy = try XCTUnwrap(model.attachments.drafts.last)
        guard case .duplicate(let existing, _) = await model.saveToLibrary(draftID: copy.id, collectionID: nil, tags: []) else { return XCTFail("Debía ser duplicado") }
        XCTAssertEqual(existing.id, item.id)
        XCTAssertEqual(model.libraryItems.count, 1)

        model.deleteLibraryItem(item.id)
        await waitUntil { model.libraryItems.isEmpty }
        XCTAssertTrue(model.libraryItems.isEmpty)
        let after = await model.knowledge.search("salario mensual")
        XCTAssertTrue(after.isEmpty)
    }

    func testAnImageWithTextIsSavedThroughOCRAndOneWithoutTextIsRefused() async throws {
        let model = try makeModel()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let withText = UIGraphicsImageRenderer(size: CGSize(width: 1_400, height: 600), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_400, height: 600))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 110), .foregroundColor: UIColor.black]
            ("FACTURA 12345" as NSString).draw(at: CGPoint(x: 60, y: 200), withAttributes: attributes)
        }
        await model.attachments.addData(name: "factura.jpg", data: try XCTUnwrap(withText.jpegData(compressionQuality: 0.9)))
        let draft = try XCTUnwrap(model.attachments.drafts.first)
        guard case .saved(let item) = await model.saveToLibrary(draftID: draft.id, collectionID: nil, tags: []) else { return XCTFail("OCR debía leer el texto") }
        XCTAssertEqual(item.kind, .image)
        XCTAssertTrue(item.recognizedByOCR)
        XCTAssertNotNil(item.thumbnail)

        let blank = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        await model.attachments.addData(name: "vacia.jpg", data: try XCTUnwrap(blank.jpegData(compressionQuality: 0.9)))
        let empty = try XCTUnwrap(model.attachments.drafts.last)
        guard case .failed(let reason) = await model.saveToLibrary(draftID: empty.id, collectionID: nil, tags: []) else { return XCTFail("Sin texto no se guarda") }
        XCTAssertTrue(reason.contains("No encontré texto"), reason)
        XCTAssertEqual(model.libraryItems.count, 1)
    }

    func testNotesAndEraseAll() async throws {
        let model = try makeModel()
        guard case .saved(let note) = await model.addLibraryNote(title: "Pendientes", text: "Renovar el seguro del carro en diciembre", kind: .note, collectionID: nil, tags: []) else {
            return XCTFail()
        }
        XCTAssertEqual(note.kind, .note)
        let found = await model.knowledge.search("seguro del carro")
        XCTAssertEqual(found.first?.title, "Pendientes")
        model.eraseAllData()
        await waitUntil { model.libraryItems.isEmpty }
        XCTAssertTrue(model.libraryItems.isEmpty, "«Borrar todos los datos» también vacía la biblioteca")
        let after = await model.knowledge.search("seguro del carro")
        XCTAssertTrue(after.isEmpty)
    }
}
