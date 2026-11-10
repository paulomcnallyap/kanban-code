import Foundation

/// Fork de Paulo: arma los cambios del tablero a partir de las tareas de Notion.
///
/// - Una tarea con «Sesión Claude» cuya sesión ya es una tarjeta del tablero
///   se pega a esa tarjeta (una sola tarjeta: la de la sesión, con el título
///   y el Estado de Notion), así se mueve en tiempo real con la sesión.
/// - Una tarea sin sesión (o con una sesión que el tablero no conoce) es una
///   tarjeta propia (`source == .notion`) que se ubica solo por su Estado.
/// - Una tarea que ya no viene en la consulta desaparece: la tarjeta propia se
///   borra y la de sesión vuelve a ser una sesión suelta.
public enum NotionBoardSync {

    public struct Plan: Sendable {
        public var upserts: [Link]
        public var removedIds: [String]
    }

    public static func plan(
        tasks: [NotionTask],
        links: [String: Link],
        activityMap: [String: ActivityState]
    ) -> Plan {
        var desired = links
        let tasksByPage = Dictionary(tasks.map { ($0.pageId, $0) }, uniquingKeysWith: { a, _ in a })

        // Índice de tarjetas por sesión (solo tarjetas que no son de Notion puro).
        var cardBySession: [String: String] = [:]
        for (id, link) in links where link.source != .notion && !link.isTombstone {
            if let sid = link.sessionLink?.sessionId.lowercased() { cardBySession[sid] = id }
        }

        // 1. Soltar los vínculos de Notion de las tarjetas de sesión; se vuelven a pegar abajo.
        for (id, link) in desired where link.source != .notion && link.notionLink != nil {
            var l = link
            l.notionLink = nil
            desired[id] = l
        }

        // 2. Pegar cada tarea a su sesión o a su tarjeta propia.
        var removed: [String] = []
        for task in tasks {
            let notion = NotionLink(
                pageId: task.pageId, url: task.url, title: task.title,
                estado: task.estado, sessionId: task.sessionId
            )
            let standaloneId = desired.first { $0.value.source == .notion && $0.value.notionLink?.pageId == task.pageId }?.key

            if let sid = task.sessionId, let cardId = cardBySession[sid], var card = desired[cardId] {
                card.notionLink = notion
                card.name = task.title
                card.manuallyArchived = false
                card.column = AssignColumn.assignNotion(
                    notion, activityState: card.sessionLink.flatMap { activityMap[$0.sessionId] }
                )
                desired[cardId] = card
                if let standaloneId {
                    desired.removeValue(forKey: standaloneId)
                    removed.append(standaloneId)
                }
            } else if let standaloneId, var card = desired[standaloneId] {
                card.notionLink = notion
                card.name = task.title
                card.column = AssignColumn.assignNotion(notion, activityState: nil)
                desired[standaloneId] = card
            } else {
                let card = Link(
                    name: task.title,
                    column: AssignColumn.assignNotion(notion, activityState: nil),
                    source: .notion
                )
                var c = card
                c.notionLink = notion
                desired[c.id] = c
            }
        }

        // 3. Borrar tarjetas propias de tareas que ya no vienen.
        for (id, link) in desired where link.source == .notion {
            guard let pageId = link.notionLink?.pageId else { continue }
            if tasksByPage[pageId] == nil {
                desired.removeValue(forKey: id)
                removed.append(id)
            }
        }

        // 4. Las tarjetas de sesión que perdieron su tarea vuelven a la regla normal.
        var upserts: [Link] = []
        for (id, link) in desired {
            var l = link
            if let old = links[id], old.notionLink != nil, l.notionLink == nil, l.source != .notion {
                let sid = l.sessionLink?.sessionId
                l.column = AssignColumn.assign(
                    link: l, activityState: sid.flatMap { activityMap[$0] },
                    hasPR: !l.prLinks.isEmpty, allPRsDone: l.allPRsDone
                )
            }
            if links[id] != l {
                if links[id] != nil { l.updatedAt = .now }
                upserts.append(l)
            }
        }
        return Plan(upserts: upserts, removedIds: removed)
    }
}
