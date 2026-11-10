import Foundation

/// The columns on the Kanban board, in display order.
public enum KanbanCodeColumn: String, Codable, CaseIterable, Sendable {
    case backlog
    case inProgress = "in_progress"
    case waiting = "requires_attention"
    case inReview = "in_review"
    case done
    case allSessions = "all_sessions"

    public var displayName: String {
        switch self {
        // Fork de Paulo: columnas del Backlog de Notion. `inReview` se reutiliza
        // como «Bloqueadas» (Estado = Bloqueado en Notion).
        case .backlog: "Backlog"
        case .inProgress: "En progreso"
        case .waiting: "Esperando"
        case .inReview: "Bloqueadas"
        case .done: "Terminadas"
        case .allSessions: "Todas las sesiones"
        }
    }

    public var allowsBoardTaskCreation: Bool {
        self != .allSessions
    }
}
