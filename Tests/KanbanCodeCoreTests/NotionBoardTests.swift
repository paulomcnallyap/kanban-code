import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Notion board (fork de Paulo)")
struct NotionBoardTests {

    func notion(_ estado: String?, session: String? = nil) -> NotionLink {
        NotionLink(pageId: "p1", url: "https://notion.so/p1", title: "Tarea", estado: estado, sessionId: session)
    }

    @Test("Sin sesión manda el Estado de Notion")
    func estadoSinSesion() {
        #expect(AssignColumn.assignNotion(notion("Backlog"), activityState: nil) == .backlog)
        #expect(AssignColumn.assignNotion(notion(nil), activityState: nil) == .backlog)
        #expect(AssignColumn.assignNotion(notion("Bloqueado"), activityState: nil) == .inReview)
        #expect(AssignColumn.assignNotion(notion("En proceso"), activityState: nil) == .inProgress)
        #expect(AssignColumn.assignNotion(notion("En revisión"), activityState: nil) == .waiting)
        #expect(AssignColumn.assignNotion(notion("Terminado"), activityState: nil) == .done)
    }

    @Test("La sesión trabajando o esperando le gana a Notion; cerrada, vuelve a Notion")
    func sesionLeGana() {
        #expect(AssignColumn.assignNotion(notion("Bloqueado"), activityState: .activelyWorking) == .inProgress)
        #expect(AssignColumn.assignNotion(notion("Backlog"), activityState: .needsAttention) == .waiting)
        #expect(AssignColumn.assignNotion(notion("Terminado"), activityState: .ended) == .done)
        #expect(AssignColumn.assignNotion(notion("Terminado"), activityState: .needsAttention) == .done)
        #expect(AssignColumn.assignNotion(notion("Terminado"), activityState: .activelyWorking) == .done)
    }

    @Test("Una sesión suelta con PR va a Esperando, no a Bloqueadas")
    func prSueltoNoBloquea() {
        let link = Link(column: .waiting, sessionLink: SessionLink(sessionId: "s1"))
        #expect(AssignColumn.assign(link: link, activityState: .needsAttention, hasPR: true) == .waiting)
    }

    @Test("Saca el id de sesión del texto de «Sesión Claude»")
    func extraeSesion() {
        let id = NotionAdapter.extractSessionId("beauty_fix_20261110 (id 0B1C2D3E-1111-2222-3333-444455556666)")
        #expect(id == "0b1c2d3e-1111-2222-3333-444455556666")
        #expect(NotionAdapter.extractSessionId("") == nil)
    }

    @Test("Tarea sin sesión crea tarjeta propia; con sesión conocida se pega a esa tarjeta")
    func planPegaASesion() {
        let sid = "0b1c2d3e-1111-2222-3333-444455556666"
        let sessionCard = Link(id: "card_s", column: .waiting, sessionLink: SessionLink(sessionId: sid))
        let tasks = [
            NotionTask(pageId: "a", url: "u", title: "Sin sesión", estado: "Backlog", sessionId: nil),
            NotionTask(pageId: "b", url: "u", title: "Con sesión", estado: "Bloqueado", sessionId: sid),
        ]
        let plan = NotionBoardSync.plan(
            tasks: tasks, links: ["card_s": sessionCard], activityMap: [sid: .activelyWorking]
        )
        let pegada = plan.upserts.first { $0.id == "card_s" }
        #expect(pegada?.notionLink?.pageId == "b")
        #expect(pegada?.name == "Con sesión")
        #expect(pegada?.column == .inProgress)
        let propia = plan.upserts.first { $0.notionLink?.pageId == "a" }
        #expect(propia?.source == .notion)
        #expect(propia?.column == .backlog)
    }

    @Test("Tarea que ya no viene: la tarjeta propia se borra y la de sesión se suelta")
    func planQuitaTareas() {
        var propia = Link(id: "card_n", column: .backlog, source: .notion)
        propia.notionLink = NotionLink(pageId: "a", url: "u", title: "x", estado: "Backlog", sessionId: nil)
        var deSesion = Link(id: "card_s", column: .inReview, sessionLink: SessionLink(sessionId: "s1"))
        deSesion.notionLink = NotionLink(pageId: "b", url: "u", title: "y", estado: "Bloqueado", sessionId: "s1")
        let plan = NotionBoardSync.plan(
            tasks: [], links: ["card_n": propia, "card_s": deSesion], activityMap: ["s1": .needsAttention]
        )
        #expect(plan.removedIds == ["card_n"])
        let suelta = plan.upserts.first { $0.id == "card_s" }
        #expect(suelta?.notionLink == nil)
        #expect(suelta?.column == .waiting)
    }

    @Test("Sin cambios no hay nada que escribir")
    func planIdempotente() {
        let tasks = [NotionTask(pageId: "a", url: "u", title: "T", estado: "Backlog", sessionId: nil)]
        let first = NotionBoardSync.plan(tasks: tasks, links: [:], activityMap: [:])
        let links = Dictionary(uniqueKeysWithValues: first.upserts.map { ($0.id, $0) })
        let second = NotionBoardSync.plan(tasks: tasks, links: links, activityMap: [:])
        #expect(second.upserts.isEmpty)
        #expect(second.removedIds.isEmpty)
    }
}
