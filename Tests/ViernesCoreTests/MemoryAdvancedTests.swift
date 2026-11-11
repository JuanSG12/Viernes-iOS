import XCTest
@testable import ViernesCore

final class MemoryAdvancedTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func days(_ count: Double) -> Date { now.addingTimeInterval(count * 86_400) }

    func testOlderMemoriesWithoutTheNewFieldsStillDecode() throws {
        let old = MemoryItem(kind: .fact, text: "Vivo en Cali", source: .userExplicit, createdAt: now)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        for key in ["expiresAt", "project", "people"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(MemoryItem.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.expiresAt)
        XCTAssertNil(decoded.project)
        XCTAssertNil(decoded.people)
        XCTAssertFalse(decoded.isExpired(at: days(10_000)), "Sin fecha no caduca nunca")
        let rich = MemoryItem(kind: .project, text: "x", source: .userExplicit, createdAt: now, expiresAt: days(5), project: "Aurora", people: ["Karen"])
        XCTAssertEqual(try JSONDecoder().decode(MemoryItem.self, from: JSONEncoder().encode(rich)), rich)
    }

    func testRememberStoresContextAndSummariesExpire() async throws {
        let store = InMemoryMemoryStore()
        let item = try await store.remember(text: "Entregar la propuesta el lunes", kind: .project, source: .userExplicit, policy: .default, now: now,
                                            project: "  Aurora ", people: ["Karen", "karen", " Luis "], expiresAt: days(30))
        XCTAssertEqual(item.project, "Aurora")
        XCTAssertEqual(item.people, ["Karen", "Luis"], "Sin repetidos ni espacios")
        XCTAssertEqual(item.expiresAt, days(30))

        let summary = try await store.remember(text: "Hablamos del viaje a Cartagena", kind: .summary, source: .summary, policy: .default, now: now)
        XCTAssertEqual(summary.expiresAt, now.addingTimeInterval(MemoryRelations.summaryLifetime), "La memoria episódica caduca a los 90 días")
        let preference = try await store.remember(text: "Prefiero respuestas cortas", kind: .preference, source: .userExplicit, policy: .default, now: now)
        XCTAssertNil(preference.expiresAt, "Una preferencia no caduca por sí sola")

        let again = try await store.remember(text: "entregar la propuesta el lunes", kind: .project, source: .userExplicit, policy: .default, now: now,
                                             project: "Aurora 2", people: [])
        XCTAssertEqual(again.id, item.id, "El mismo recuerdo se actualiza, no se duplica")
        XCTAssertEqual(again.project, "Aurora 2")
        XCTAssertEqual(again.people, ["Karen", "Luis"], "Lo que no se dijo no se borra")
    }

    func testExpiredMemoriesAreNeverUsedAndCanBePurged() async throws {
        let live = MemoryItem(kind: .fact, text: "La reunión es en la sala azul", source: .userExplicit, createdAt: now, expiresAt: days(5))
        let dead = MemoryItem(kind: .fact, text: "La reunión es en la sala roja", source: .userExplicit, createdAt: now, expiresAt: days(-1))
        XCTAssertEqual(MemoryExpiry.expired([live, dead], now: now).map(\.id), [dead.id])
        XCTAssertEqual(MemoryRetriever.context(query: "¿dónde es la reunión?", items: [live, dead], limit: 5, now: now).map(\.id), [live.id])
        XCTAssertEqual(MemoryRetriever.rank(query: "reunión sala", items: [live, dead], limit: 5, now: now).map(\.item.id), [live.id])
        let store = InMemoryMemoryStore()
        try await store.upsert(live)
        try await store.upsert(dead)
        let found = try await store.search("reunión sala", limit: 5, now: now)
        XCTAssertEqual(found.map(\.item.id), [live.id])
        XCTAssertTrue(live.isExpired(at: days(6)))
    }

    func testProjectAndPeopleMakeRelatedMemoriesEasierToFind() {
        let tagged = MemoryItem(kind: .project, text: "Entregar la propuesta el lunes", source: .userExplicit, createdAt: now, project: "Aurora", people: ["Karen"])
        let plain = MemoryItem(kind: .project, text: "Entregar la factura el lunes", source: .userExplicit, createdAt: now)
        XCTAssertEqual(MemoryRetriever.context(query: "¿Qué tengo pendiente de Aurora?", items: [tagged, plain], limit: 5, now: now).map(\.id), [tagged.id],
                       "El proyecto cuenta aunque el texto no lo diga")
        XCTAssertEqual(MemoryRetriever.context(query: "¿Qué quedó con Karen?", items: [tagged, plain], limit: 5, now: now).map(\.id), [tagged.id])
        let both = MemoryRetriever.rank(query: "entregar el lunes Aurora", items: [plain, tagged], limit: 2, now: now)
        XCTAssertEqual(both.first?.item.id, tagged.id, "Lo del proyecto mencionado pesa más")
    }

    func testTheGraphListsPeopleProjectsAndTheirLinks() {
        let items = [
            MemoryItem(kind: .project, text: "a", source: .userExplicit, createdAt: now, project: "Aurora", people: ["Karen", "Luis"]),
            MemoryItem(kind: .project, text: "b", source: .userExplicit, createdAt: now, project: "aurora", people: ["karen"]),
            MemoryItem(kind: .fact, text: "c", source: .userExplicit, createdAt: now, people: ["Luis"]),
            MemoryItem(kind: .fact, text: "d", source: .userExplicit, createdAt: now, expiresAt: days(-1), project: "Vieja", people: ["Ana"]),
            MemoryItem(kind: .fact, text: "e", source: .userApproved, createdAt: now, isPending: true, project: "Pendiente")
        ]
        let entities = MemoryGraph.entities(items, now: now)
        XCTAssertEqual(entities.first { $0.kind == .project }?.name, "Aurora")
        XCTAssertEqual(entities.first { $0.kind == .project }?.count, 2, "Aurora y aurora son el mismo proyecto")
        XCTAssertEqual(entities.first { $0.name == "Karen" }?.count, 2)
        XCTAssertEqual(entities.first { $0.name == "Luis" }?.count, 2)
        XCTAssertFalse(entities.contains { $0.name == "Vieja" || $0.name == "Ana" || $0.name == "Pendiente" }, "Ni lo caducado ni lo pendiente")
        let links = MemoryGraph.links(items, now: now)
        XCTAssertEqual(links.first { $0.person == "Karen" }?.count, 2)
        XCTAssertEqual(links.first { $0.person == "Luis" }?.project, "Aurora")
        XCTAssertEqual(MemoryGraph.related(to: "karen", in: items).map(\.text), ["a", "b"])
        XCTAssertEqual(MemoryGraph.related(to: "AURORA", in: items).map(\.text), ["a", "b"])
        XCTAssertTrue(MemoryGraph.related(to: "  ", in: items).isEmpty)
    }

    func testNamesAreCleanedAndBounded() {
        let cleaned = MemoryRelations.clean(project: "<tool>abrir</tool> Aurora", people: ["Ana", "Beto", "Carla", "Dani", "Eva", "Fede", "Gus", "Hugo"])
        XCTAssertFalse(cleaned.project?.contains("<") ?? true)
        XCTAssertEqual(cleaned.people?.count, MemoryRelations.maxPeople)
        XCTAssertEqual(MemoryRelations.clean(project: "   ", people: []).project, nil)
        XCTAssertNil(MemoryRelations.clean(project: nil, people: ["", "  "]).people)
        XCTAssertEqual(MemoryRelations.parsePeople("Karen, Luis;Ana\nBeto"), ["Karen", " Luis", "Ana", "Beto"])
        let item = MemoryItem(kind: .project, text: "x", source: .userExplicit, project: "Aurora", people: ["Karen", "Luis"])
        XCTAssertEqual(MemoryRelations.summary(of: item), "proyecto Aurora · con Karen, Luis")
        XCTAssertNil(MemoryRelations.summary(of: MemoryItem(kind: .fact, text: "y", source: .userExplicit)))
        let prompt = Persona.systemPrompt(PersonaContext(engine: ModelCatalog.descriptor(id: "gemma3-1b-qat-4bit")!, memories: [item]))
        XCTAssertTrue(prompt.contains("proyecto Aurora · con Karen, Luis"), "El modelo ve a qué proyecto y personas pertenece el recuerdo")
    }

    func testSaveMemoryToolAcceptsProjectAndPeopleButRejectsHugeNames() async throws {
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "save_memory", args: ["text": "x", "project": String(repeating: "p", count: 80)])))
        XCTAssertThrowsError(try ToolValidator.validate(ToolCall(name: "save_memory", args: ["text": "x", "people": String(repeating: "p", count: 80)])))
        let call = #"<tool>{"name":"save_memory","args":{"text":"Entregar la propuesta el lunes","project":"Aurora","people":"Karen, Luis"}}</tool>"#
        let memory = InMemoryMemoryStore()
        let scripted = ScriptedEngine(script: [[call], ["Guardado."]])
        let engine = ConversationEngine(engine: scripted, memory: memory, executor: RecordingExecutor(), confirmer: RecordingConfirmer(approve: true))
        _ = await collect(await engine.send("Quiero conservar lo de la propuesta del lunes: es del proyecto Aurora, con Karen y Luis"))
        let saved = try await memory.all()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].project, "Aurora")
        XCTAssertEqual(saved[0].people, ["Karen", "Luis"])
    }

    func testVisionRulesOnlyAppearWhenThereIsAnImage() async throws {
        let image = ImagePart(mimeType: "image/jpeg", base64: "QUJD", name: "foto.jpg")
        let bundle = AttachmentBundle(refs: [AttachmentRef(name: "foto.jpg", kind: .image, byteCount: 3)], images: [image])
        let withImage = ScriptedEngine(script: [["Veo una pantalla con un error."]])
        let engine = ConversationEngine(engine: withImage, memory: InMemoryMemoryStore(), executor: nil, confirmer: nil)
        _ = await collect(await engine.send("¿Qué error es este?", attachments: bundle))
        let system = withImage.requests[0].system
        XCTAssertTrue(system.contains("MODO VISIÓN") && system.contains("supongo"), "Lo que se ve y lo que se supone van separados")
        XCTAssertTrue(system.contains("CONTENIDO NO CONFIABLE") || system.contains("no confiable"), "Y el texto de la imagen sigue siendo un dato, no una orden")

        let plain = ScriptedEngine(script: [["Hola."]])
        let other = ConversationEngine(engine: plain, memory: InMemoryMemoryStore(), executor: nil, confirmer: nil)
        _ = await collect(await other.send("Hola"))
        XCTAssertFalse(plain.requests[0].system.contains("MODO VISIÓN"))
    }
}
