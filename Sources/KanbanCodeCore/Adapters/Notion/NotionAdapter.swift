import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fork de Paulo: lee el Backlog de Notion (solo lectura) para alimentar el tablero.
///
/// Configuración en `~/.kanban-code/notion.json`:
/// ```json
/// { "databaseId": "…", "userId": "…", "clientId": "…", "doneDays": 14 }
/// ```
/// El token OAuth vive en el Keychain (`notion-kanban-token`, lo deja
/// `Scripts/notion-login.py`) y el Client Secret en `notion-kanban-oauth`.
public struct NotionTask: Sendable, Equatable {
    public let pageId: String
    public let url: String
    public let title: String
    public let estado: String?
    public let sessionId: String?
}

public struct NotionConfig: Codable, Sendable {
    public var databaseId: String
    public var userId: String
    public var clientId: String?
    /// Cuántos días mostrar en «Terminadas» desde su última edición.
    public var doneDays: Int?
    /// Cada cuántos segundos consultar Notion.
    public var pollSeconds: Int?

    public static var path: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/notion.json")
    }

    public static func load() -> NotionConfig? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(NotionConfig.self, from: data)
    }
}

public enum NotionAdapterError: Error, LocalizedError {
    case missingToken
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "Notion: falta el acceso. Corre Scripts/notion-login.py."
        case .http(let code, let body):
            "Notion HTTP \(code): \(body.prefix(200))"
        }
    }
}

public actor NotionAdapter {
    static let tokenService = "notion-kanban-token"
    static let secretService = "notion-kanban-oauth"
    static let notionVersion = "2022-06-28"

    let config: NotionConfig

    public init(config: NotionConfig) {
        self.config = config
    }

    // MARK: - Consulta

    public func fetchTasks() async throws -> [NotionTask] {
        guard var token = try await loadToken() else { throw NotionAdapterError.missingToken }
        do {
            return try await queryAll(accessToken: token.accessToken)
        } catch NotionAdapterError.http(401, _) {
            // Token vencido: renovar una vez con el refresh token.
            token = try await refresh(token)
            return try await queryAll(accessToken: token.accessToken)
        }
    }

    private func queryAll(accessToken: String) async throws -> [NotionTask] {
        let doneDays = config.doneDays ?? 14
        let since = Calendar.current.date(byAdding: .day, value: -doneDays, to: .now) ?? .now
        let sinceISO = ISO8601DateFormatter().string(from: since)
        let filter: [String: Any] = [
            "and": [
                ["property": "Responsable", "people": ["contains": config.userId]],
                ["or": [
                    ["property": "Estado", "select": ["does_not_equal": "Terminado"]],
                    ["property": "Estado", "select": ["is_empty": true]],
                    ["timestamp": "last_edited_time", "last_edited_time": ["on_or_after": sinceISO]],
                ]],
            ],
        ]
        var tasks: [NotionTask] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["filter": filter, "page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            let json = try await post(
                "https://api.notion.com/v1/databases/\(config.databaseId)/query",
                body: body, bearer: accessToken
            )
            for page in (json["results"] as? [[String: Any]]) ?? [] {
                if let task = Self.parse(page) { tasks.append(task) }
            }
            cursor = (json["has_more"] as? Bool) == true ? json["next_cursor"] as? String : nil
        } while cursor != nil
        return tasks
    }

    static func parse(_ page: [String: Any]) -> NotionTask? {
        guard let id = page["id"] as? String,
              let props = page["properties"] as? [String: Any] else { return nil }
        let url = (page["url"] as? String) ?? "https://www.notion.so/\(id.replacingOccurrences(of: "-", with: ""))"
        var title = ""
        var estado: String?
        var sessionText = ""
        for (name, raw) in props {
            guard let prop = raw as? [String: Any], let type = prop["type"] as? String else { continue }
            if type == "title" {
                title = plain(prop["title"])
            } else if name == "Estado" {
                estado = ((prop["select"] ?? prop["status"]) as? [String: Any])?["name"] as? String
            } else if name == "Sesión Claude" {
                sessionText = plain(prop["rich_text"])
            }
        }
        return NotionTask(
            pageId: id, url: url,
            title: title.isEmpty ? "(sin título)" : title,
            estado: estado,
            sessionId: extractSessionId(sessionText)
        )
    }

    static func plain(_ value: Any?) -> String {
        ((value as? [[String: Any]]) ?? []).compactMap { $0["plain_text"] as? String }.joined()
    }

    /// Saca el UUID de textos como «nombre (id 0b1c…)» o del `claude --resume <id>`.
    static func extractSessionId(_ text: String) -> String? {
        let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range]).lowercased()
    }

    // MARK: - HTTP

    private func post(_ url: String, body: [String: Any], bearer: String? = nil, basic: String? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.notionVersion, forHTTPHeaderField: "Notion-Version")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let basic { req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw NotionAdapterError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Token (Keychain vía `security`, sin pedir permisos a la app)

    struct Token {
        var accessToken: String
        var raw: [String: Any]
    }

    private func loadToken() async throws -> Token? {
        guard let text = await Self.keychainRead(Self.tokenService),
              let data = text.data(using: .utf8),
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = raw["access_token"] as? String else { return nil }
        return Token(accessToken: access, raw: raw)
    }

    private func refresh(_ token: Token) async throws -> Token {
        guard let refreshToken = token.raw["refresh_token"] as? String,
              let clientId = config.clientId,
              let secret = await Self.keychainRead(Self.secretService) else {
            throw NotionAdapterError.missingToken
        }
        let basic = Data("\(clientId):\(secret)".utf8).base64EncodedString()
        let json = try await post(
            "https://api.notion.com/v1/oauth/token",
            body: ["grant_type": "refresh_token", "refresh_token": refreshToken],
            basic: basic
        )
        guard let access = json["access_token"] as? String else { throw NotionAdapterError.missingToken }
        var merged = token.raw
        for (k, v) in json { merged[k] = v }
        if let data = try? JSONSerialization.data(withJSONObject: merged),
           let text = String(data: data, encoding: .utf8) {
            await Self.keychainWrite(Self.tokenService, text)
        }
        return Token(accessToken: access, raw: merged)
    }

    static func keychainRead(_ service: String) async -> String? {
        guard let result = try? await ShellCommand.run(
            "/usr/bin/security", arguments: ["find-generic-password", "-s", service, "-w"], timeout: 10
        ), result.succeeded else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func keychainWrite(_ service: String, _ value: String) async {
        _ = try? await ShellCommand.run(
            "/usr/bin/security",
            arguments: ["add-generic-password", "-U", "-a", NSUserName(), "-s", service, "-w", value],
            timeout: 10
        )
    }
}
