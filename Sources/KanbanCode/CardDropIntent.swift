import KanbanCodeCore

enum CardDropIntent: Equatable {
    case move
    case start
    case resume
    case archive
    case invalid(String)

    var isAllowed: Bool {
        if case .invalid = self {
            return false
        }
        return true
    }

    static func resolve(_ card: KanbanCodeCard, to column: KanbanCodeColumn) -> CardDropIntent {
        // Fork de Paulo: el Estado de las tarjetas de Notion se cambia en Notion.
        // Lo único que se permite es retomar su sesión arrastrándola a En progreso.
        if card.link.notionLink != nil {
            if column == .inProgress, card.link.sessionLink != nil, card.link.tmuxLink == nil {
                return .resume
            }
            return .invalid("El Estado de esta tarjeta se cambia en Notion")
        }
        switch column {
        case .inProgress:
            if card.link.tmuxLink != nil {
                return .invalid("Session is already running - card moves to In Progress automatically when Claude is actively working")
            }
            if card.column == .backlog && card.link.sessionLink == nil {
                return .start
            }
            if card.link.sessionLink != nil {
                return .resume
            }
            return .move

        case .inReview:
            if card.link.prLinks.isEmpty {
                return .invalid("Cannot move to In Review - card has no pull request")
            }
            return .move

        case .done:
            let hasMergedPR = card.link.prLinks.contains { $0.status == .merged }
            if !hasMergedPR {
                return .invalid("Cannot move to Done - no merged pull request")
            }
            return .move

        case .allSessions:
            return .archive

        case .backlog, .waiting:
            return .move
        }
    }
}
