import XCTest
@testable import ViernesCore

final class MemoryTests: XCTestCase {
    func testRememberStoresAndTagsMemory() async throws {
        let store = InMemoryMemoryStore()
        let item = try await store.remember(text: "Prefiero respuestas cortas", kind: .preference, source: .userExplicit, policy: .default)
        let all = try await store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, item.id)
        XCTAssertTrue(item.tags.contains("cortas"))
    }

    func testDuplicatesAreMergedIgnoringCaseAndAccents() async throws {
        let store = InMemoryMemoryStore()
        _ = try await store.remember(text: "Mi canción favorita es Gaia", kind: .fact, source: .userExplicit, policy: .default)
        _ = try await store.remember(text: "mi CANCION favorita es gaia", kind: .fact, source: .userExplicit, policy: .default)
        let count = try await store.all().count
        XCTAssertEqual(count, 1)
    }

    func testPolicyBlocksDisabledKinds() async {
        let store = InMemoryMemoryStore()
        var policy = MemoryPolicy.default
        policy.allowProjects = false
        do {
            _ = try await store.remember(text: "Proyecto Atlas", kind: .project, source: .userExplicit, policy: policy)
            XCTFail("Debía lanzar disabledByPolicy")
        } catch let error as MemoryError {
            XCTAssertEqual(error, .disabledByPolicy(.project))
        } catch { XCTFail("Error inesperado \(error)") }
    }

    func testMasterSwitchBlocksEverything() async {
        let store = InMemoryMemoryStore()
        var policy = MemoryPolicy.default
        policy.enabled = false
        for kind in MemoryKind.allCases { XCTAssertFalse(policy.permits(kind)) }
        do {
            _ = try await store.remember(text: "algo", kind: .fact, source: .userExplicit, policy: policy)
            XCTFail("Debía bloquearse")
        } catch {}
    }

    func testSensitiveContentIsRefused() async {
        let store = InMemoryMemoryStore()
        for text in ["Mi contraseña es hunter2", "Mi tarjeta es 4111 1111 1111 1111", "Mi cédula es 1020304050"] {
            do {
                _ = try await store.remember(text: text, kind: .fact, source: .userExplicit, policy: .default)
                XCTFail("Debía rechazar: \(text)")
            } catch let error as MemoryError {
                if case .sensitiveContent = error {} else { XCTFail("Error equivocado para \(text)") }
            } catch { XCTFail("Error inesperado") }
        }
        let remaining = try? await store.all()
        XCTAssertEqual(remaining?.count, 0)
    }

    func testSearchRanksRelevantMemoryFirstAndUsesStems() async throws {
        let store = InMemoryMemoryStore()
        _ = try await store.remember(text: "Prefiero respuestas cortas", kind: .preference, source: .userExplicit, policy: .default)
        _ = try await store.remember(text: "Mi proyecto Atlas usa SwiftUI", kind: .project, source: .userExplicit, policy: .default)
        _ = try await store.remember(text: "Mi gato se llama Tigre", kind: .fact, source: .userExplicit, policy: .default)
        let hits = try await store.search("¿Cómo va el proyecto Atlas?")
        XCTAssertEqual(hits.first?.item.text, "Mi proyecto Atlas usa SwiftUI")
        let plural = try await store.search("proyectos")
        XCTAssertEqual(plural.first?.item.text, "Mi proyecto Atlas usa SwiftUI")
        let none = try await store.search("astronomía")
        XCTAssertTrue(none.isEmpty)
    }

    func testPendingSuggestionsAreExcludedFromSearchUntilApproved() async throws {
        let store = InMemoryMemoryStore()
        var pending = try await store.remember(text: "Trabaja en el proyecto Orión", kind: .project, source: .userApproved, policy: .default, pending: true)
        let beforeApproval = try await store.search("Orión")
        XCTAssertTrue(beforeApproval.isEmpty)
        let queue = try await store.pending()
        XCTAssertEqual(queue.count, 1)
        pending.isPending = false
        try await store.upsert(pending)
        let afterApproval = try await store.search("Orión")
        XCTAssertEqual(afterApproval.count, 1)
    }

    func testEditAndDelete() async throws {
        let store = InMemoryMemoryStore()
        var item = try await store.remember(text: "Vivo en Bogotá", kind: .fact, source: .userExplicit, policy: .default)
        item.text = "Vivo en Medellín"
        try await store.upsert(item)
        let edited = try await store.all()
        XCTAssertEqual(edited.first?.text, "Vivo en Medellín")
        try await store.delete(id: item.id)
        let afterDelete = try await store.all()
        XCTAssertTrue(afterDelete.isEmpty)
        do { try await store.delete(id: item.id); XCTFail("Debía lanzar notFound") }
        catch let error as MemoryError { XCTAssertEqual(error, .notFound) }
    }

    func testDeleteAllWipesEverything() async throws {
        let store = InMemoryMemoryStore()
        for i in 0..<5 { _ = try await store.remember(text: "dato \(i)", kind: .fact, source: .userExplicit, policy: .default) }
        try await store.deleteAll()
        let remaining = try await store.all().count
        XCTAssertEqual(remaining, 0)
    }

    func testPinnedMemoriesAlwaysEnterContext() {
        let pinned = MemoryItem(kind: .preference, text: "Háblame con ironía suave", source: .userExplicit, pinned: true)
        let other = MemoryItem(kind: .fact, text: "Mi gato se llama Tigre", source: .userExplicit)
        let context = MemoryRetriever.context(query: "clima de mañana", items: [pinned, other], limit: 5)
        XCTAssertEqual(context.map(\.id), [pinned.id])
    }

    func testOldMemoriesScoreLowerThanFreshOnes() {
        let now = Date()
        let old = MemoryItem(kind: .fact, text: "Proyecto Atlas", source: .userExplicit, createdAt: now.addingTimeInterval(-3 * 365 * 86_400))
        let fresh = MemoryItem(kind: .fact, text: "Proyecto Atlas", source: .userExplicit, createdAt: now)
        let ranked = MemoryRetriever.rank(query: "Atlas", items: [old, fresh], limit: 2, now: now)
        XCTAssertEqual(ranked.first?.item.id, fresh.id)
    }

    func testRetentionCutoffs() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(TranscriptRetention.forever.cutoff(from: now))
        XCTAssertEqual(TranscriptRetention.days7.cutoff(from: now), now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(TranscriptRetention.never.cutoff(from: now), now)
    }

    func testMemoryItemCodableRoundTrip() throws {
        let item = MemoryItem(kind: .project, text: "Proyecto Atlas", tags: ["atlas"], source: .userExplicit, pinned: true)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(MemoryItem.self, from: data)
        XCTAssertEqual(decoded, item)
    }

    func testMemoryCommandParsing() {
        XCTAssertEqual(MemoryCommand.parse("Recuerda que prefiero respuestas cortas"), .remember("prefiero respuestas cortas"))
        XCTAssertEqual(MemoryCommand.parse("recuerda: mi hermana se llama Ana"), .remember("mi hermana se llama Ana"))
        XCTAssertEqual(MemoryCommand.parse("Olvida lo de mi proyecto"), .forget("mi proyecto"))
        XCTAssertNil(MemoryCommand.parse("¿Recuerdas algo de ayer?"))
        XCTAssertNil(MemoryCommand.parse("Recuerda que "))
        XCTAssertEqual(MemoryCommand.classify("prefiero respuestas cortas"), .preference)
        XCTAssertEqual(MemoryCommand.classify("estoy construyendo una app de inventario"), .project)
        XCTAssertEqual(MemoryCommand.classify("mi gato se llama Tigre"), .fact)
    }

    func testSummarySuggestionParsingToleratesProseAndFiltersSecrets() {
        let raw = """
        Claro, aquí tienes:
        [{"kind":"preference","text":"Prefiere respuestas breves"},
         {"kind":"summary","text":"Trabaja en Atlas"},
         {"kind":"fact","text":"Su contraseña es hunter2"}]
        Espero que sirva.
        """
        let suggestions = ConversationSummarizer.parseSuggestions(raw)
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertEqual(suggestions[0], .init(kind: .preference, text: "Prefiere respuestas breves"))
        XCTAssertEqual(suggestions[1].kind, .fact)     // "summary" no es un tipo válido para sugerencias
        XCTAssertTrue(ConversationSummarizer.parseSuggestions("sin json").isEmpty)
    }
}
