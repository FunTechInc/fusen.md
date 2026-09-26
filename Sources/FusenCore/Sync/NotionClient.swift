import Foundation

// MARK: Values sent to Notion

/// A JSON value, for request bodies.
enum JSONValue: Encodable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

/// A page property value (reference/page-property-values). Only the types this app writes.
enum NotionPropertyValue: Equatable, Sendable {
    case title(String)
    case richText(String)
    case select(String)
    case date(Date)

    var json: JSONValue {
        func text(_ s: String) -> JSONValue {
            .array([.object(["type": .string("text"), "text": .object(["content": .string(s)])])])
        }
        switch self {
        case .title(let s): return .object(["title": text(s)])
        case .richText(let s): return .object(["rich_text": text(s)])
        case .select(let name): return .object(["select": .object(["name": .string(name)])])
        case .date(let d): return .object(["date": .object(["start": .string(d.formatted(.iso8601))])])
        }
    }
}

/// A data source property configuration (reference/property-object), for creating the database.
enum NotionPropertySchema: Equatable, Sendable {
    case title
    case richText
    case date
    /// Options as (name, color); colors are Notion's select colors ("yellow", "blue", …).
    case select([NotionSelectOption])

    var json: JSONValue {
        switch self {
        case .title: return .object(["title": .object([:])])
        case .richText: return .object(["rich_text": .object([:])])
        case .date: return .object(["date": .object([:])])
        case .select(let options):
            return .object(["select": .object(["options": .array(options.map {
                .object(["name": .string($0.name), "color": .string($0.color)])
            })])])
        }
    }
}

struct NotionSelectOption: Equatable, Sendable {
    let name: String
    let color: String
}

// MARK: Values received from Notion (decoded leniently: only ids are required)

struct NotionUser: Decodable, Sendable {
    struct Bot: Decodable, Sendable {
        let workspaceName: String?

        private enum CodingKeys: String, CodingKey { case workspaceName = "workspace_name" }
    }
    let id: String
    let name: String?
    let type: String?
    let bot: Bot?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        bot = try? c.decodeIfPresent(Bot.self, forKey: .bot) // `{}` for some tokens
    }

    init(id: String, name: String? = nil, workspaceName: String? = nil) {
        self.id = id
        self.name = name
        type = "bot"
        bot = Bot(workspaceName: workspaceName)
    }

    private enum CodingKeys: String, CodingKey { case id, name, type, bot }
}

struct NotionPage: Decodable, Sendable, Equatable {
    let id: String
    let url: String?
    let inTrash: Bool?

    init(id: String, url: String? = nil, inTrash: Bool? = nil) {
        self.id = id
        self.url = url
        self.inTrash = inTrash
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        inTrash = try? c.decodeIfPresent(Bool.self, forKey: .inTrash)
    }

    private enum CodingKeys: String, CodingKey {
        case id, url
        case inTrash = "in_trash"
    }
}

/// GET /v1/pages/{id}/markdown: a page's content as Notion-flavored Markdown.
struct NotionPageMarkdown: Decodable, Sendable, Equatable {
    let markdown: String
    /// Notion stopped part-way through a very long page.
    let truncated: Bool
    /// Blocks Notion could not include (shown as `<unknown …/>` in `markdown`).
    let unknownBlockIDs: [String]

    init(markdown: String, truncated: Bool = false, unknownBlockIDs: [String] = []) {
        self.markdown = markdown
        self.truncated = truncated
        self.unknownBlockIDs = unknownBlockIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        markdown = try c.decode(String.self, forKey: .markdown)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        unknownBlockIDs = try c.decodeIfPresent([String].self, forKey: .unknownBlockIDs) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case markdown, truncated
        case unknownBlockIDs = "unknown_block_ids"
    }
}

struct NotionDatabase: Decodable, Sendable, Equatable {
    struct DataSource: Decodable, Sendable, Equatable {
        let id: String
        let name: String?
    }
    let id: String
    let url: String?
    let dataSources: [DataSource]

    init(id: String, url: String? = nil, dataSources: [DataSource]) {
        self.id = id
        self.url = url
        self.dataSources = dataSources
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        dataSources = (try? c.decodeIfPresent([DataSource].self, forKey: .dataSources)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id, url
        case dataSources = "data_sources"
    }
}

/// A database block in a page (from its block children), for finding an existing mirror.
struct NotionChildDatabase: Sendable, Equatable {
    let id: String
    let title: String
}

private struct NotionQueryResponse: Decodable {
    let results: [NotionPage]
}

/// GET /v1/blocks/{id}/children, decoded leniently: only child_database blocks are kept.
private struct NotionBlockList: Decodable {
    struct Block: Decodable {
        struct Title: Decodable { let title: String? }
        let id: String
        let type: String?
        let childDatabase: Title?
        let inTrash: Bool?

        private enum CodingKeys: String, CodingKey {
            case id, type
            case childDatabase = "child_database"
            case inTrash = "in_trash"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            childDatabase = try? c.decodeIfPresent(Title.self, forKey: .childDatabase)
            inTrash = try? c.decodeIfPresent(Bool.self, forKey: .inTrash)
        }
    }
    let results: [Block]
    let hasMore: Bool?
    let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case results
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }
}

/// The error object: {"object": "error", "status", "code", "message", "additional_data"}.
struct NotionErrorBody: Decodable, Sendable {
    let status: Int?
    let code: String?
    let message: String?
    /// Values are strings or arrays of strings; only the strings are kept.
    let additionalData: [String: String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try? c.decodeIfPresent(Int.self, forKey: .status)
        code = try? c.decodeIfPresent(String.self, forKey: .code)
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        let raw = (try? c.decodeIfPresent([String: StringOrList].self, forKey: .additionalData)) ?? [:]
        additionalData = raw.compactMapValues(\.string)
    }

    private enum CodingKeys: String, CodingKey {
        case status, code, message
        case additionalData = "additional_data"
    }

    private enum StringOrList: Decodable {
        case string(String)
        case list([String])
        case other

        var string: String? { if case .string(let s) = self { s } else { nil } }

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                self = .string(s)
            } else if let l = try? c.decode([String].self) {
                self = .list(l)
            } else {
                self = .other
            }
        }
    }
}

// MARK: Errors

enum NotionError: Error, Equatable, Sendable {
    /// 401: the token is invalid, expired or revoked.
    case unauthorized
    /// 403 `restricted_resource`: missing capability or page access, or (`blockLimit`) the Free
    /// workspace block limit.
    case forbidden(message: String, blockLimit: Bool)
    /// 404: the page / database does not exist or is not shared with the connection.
    case notFound(message: String)
    /// 400: the request was rejected; retrying the same body fails the same way.
    case validation(message: String)
    /// 429 / 529 still failing after the retries.
    case rateLimited
    /// 5xx still failing after the retries (or a non-idempotent write that was not retried).
    /// `committedResourceID`: a create that was saved although Notion answered 503 (the ID of the new
    /// page or database, from `additional_data.committed_resource_id`).
    case server(status: Int, committedResourceID: String? = nil)
    /// No response (offline, DNS, TLS, timeout …).
    case network(message: String)
    /// A 2xx response the app could not read.
    case invalidResponse

    /// For the status line in the settings window.
    var japaneseDescription: String {
        switch self {
        case .unauthorized:
            "トークンが無効です。設定で新しいトークンを入力して、もう一度接続してください。"
        case .forbidden(_, blockLimit: true):
            "Notion のワークスペースがブロック数の上限に達したため、ページを追加・更新できません。ワークスペースのオーナーに確認してください。"
        case .forbidden:
            "Notion のページにアクセスする権限がありません。コネクションの機能（コンテンツの読み取り・挿入・更新）と、親ページの共有（••• > 接続）を確認してください。"
        case .notFound:
            "Notion のページまたはデータベースが見つかりません。親ページがコネクションと共有されているか確認してください。"
        case .validation(let message):
            "Notion がこの内容を受け付けませんでした（\(message)）"
        case .rateLimited:
            "Notion へのリクエストが多すぎるため、少し待ってから再試行します。"
        case .server(let status, _):
            "Notion が一時的に利用できません（\(status)）。あとで再試行します。"
        case .network:
            "Notion に接続できません。オフラインの可能性があります。あとで再試行します。"
        case .invalidResponse:
            "Notion から予期しない応答がありました。あとで再試行します。"
        }
    }
}

// MARK: API

/// The Notion API calls the sync needs (a protocol so tests can use a mock).
protocol NotionAPI: Sendable {
    /// GET /v1/users/me — checks the token.
    func retrieveMe() async throws -> NotionUser
    /// GET /v1/pages/{id} — checks access to the parent page, and whether a page is in the trash.
    func retrievePage(id: String) async throws -> NotionPage
    /// GET /v1/databases/{id} — a database and its data sources.
    func retrieveDatabase(id: String) async throws -> NotionDatabase
    /// GET /v1/blocks/{id}/children — the databases directly in a page (not in the trash).
    func childDatabases(pageID: String) async throws -> [NotionChildDatabase]
    /// POST /v1/databases under a page, with the schema of its initial data source.
    func createDatabase(parentPageID: String, title: String,
                        properties: [String: NotionPropertySchema]) async throws -> NotionDatabase
    /// POST /v1/pages in a data source, with properties and Notion-flavored Markdown content.
    func createPage(dataSourceID: String, properties: [String: NotionPropertyValue],
                    markdown: String) async throws -> NotionPage
    /// GET /v1/pages/{id}/markdown — a page's content (for 「Notion の内容を取り込む」).
    func retrieveMarkdown(pageID: String) async throws -> NotionPageMarkdown
    /// PATCH /v1/pages/{id}/markdown with `replace_content`.
    func replaceContent(pageID: String, markdown: String) async throws
    /// PATCH /v1/pages/{id} with property values.
    func updateProperties(pageID: String, properties: [String: NotionPropertyValue]) async throws
    /// POST /v1/data_sources/{id}/query: pages whose rich text `property` equals `value`.
    func queryPages(dataSourceID: String, property: String, equals value: String) async throws -> [NotionPage]
}

/// REST client for api.notion.com (version 2026-03-11).
///
/// Requests go out one at a time through a token bucket (about 2.5 per second, below the 3 per
/// second that the smallest plans allow). 429 and 529 are retried after `Retry-After` (header, else
/// `additional_data.retry_after`, else exponential backoff up to 30 s), up to 5 times; while waiting,
/// no other request is sent. 5xx and 409 are retried only for idempotent requests: a create that
/// failed may still have been saved, and the sync finds such a page by its note ID instead of
/// creating it twice; a create that Notion saved although it answered 503 reports the new ID
/// (`NotionError.server(committedResourceID:)`). 400/401/403/404 are never retried. The request
/// timeout is longer than Notion's own 60 s limit, so Notion's 503 (with its guidance) arrives first.
///
/// The token is only ever put in the Authorization header. It is never logged, and errors never
/// include the request.
actor NotionClient: NotionAPI {
    static let apiVersion = "2026-03-11"
    static let defaultBaseURL = URL(string: "https://api.notion.com")!

    private let token: String
    private let baseURL: URL
    private let session: URLSession
    private let sleep: @Sendable (Duration) async throws -> Void
    private let maxRetries = 5
    private let rate = 2.5
    private let burst = 3.0
    private var tokens = 3.0
    private var lastRefill = ContinuousClock.now
    private var pausedUntil: ContinuousClock.Instant?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// `configuration` and `sleep` are for tests (a stub URLProtocol, no real waiting).
    init(token: String, baseURL: URL = NotionClient.defaultBaseURL,
         configuration: URLSessionConfiguration = .ephemeral,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.token = token
        self.baseURL = baseURL
        configuration.timeoutIntervalForRequest = 90
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        self.sleep = sleep
    }

    // MARK: Calls

    func retrieveMe() async throws -> NotionUser {
        try decode(NotionUser.self, from: await send("GET", "v1/users/me", idempotent: true))
    }

    func retrievePage(id: String) async throws -> NotionPage {
        try decode(NotionPage.self, from: await send("GET", "v1/pages/\(id)", idempotent: true))
    }

    func retrieveDatabase(id: String) async throws -> NotionDatabase {
        try decode(NotionDatabase.self, from: await send("GET", "v1/databases/\(id)", idempotent: true))
    }

    func childDatabases(pageID: String) async throws -> [NotionChildDatabase] {
        var found: [NotionChildDatabase] = []
        var cursor: String?
        for _ in 0..<10 { // at most 1000 blocks: the mirror is created at the end of the page
            var query = [URLQueryItem(name: "page_size", value: "100")]
            if let cursor { query.append(URLQueryItem(name: "start_cursor", value: cursor)) }
            let list = try decode(NotionBlockList.self,
                                  from: await send("GET", "v1/blocks/\(pageID)/children", query: query, idempotent: true))
            found += list.results.compactMap { block in
                guard block.type == "child_database", block.inTrash != true else { return nil }
                return NotionChildDatabase(id: block.id, title: block.childDatabase?.title ?? "")
            }
            guard list.hasMore == true, let next = list.nextCursor else { break }
            cursor = next
        }
        return found
    }

    func createDatabase(parentPageID: String, title: String,
                        properties: [String: NotionPropertySchema]) async throws -> NotionDatabase {
        let body: JSONValue = .object([
            "parent": .object(["type": .string("page_id"), "page_id": .string(parentPageID)]),
            "title": .array([.object(["type": .string("text"), "text": .object(["content": .string(title)])])]),
            "initial_data_source": .object(["properties": .object(properties.mapValues(\.json))]),
        ])
        return try decode(NotionDatabase.self, from: await send("POST", "v1/databases", body: body, idempotent: false))
    }

    func createPage(dataSourceID: String, properties: [String: NotionPropertyValue],
                    markdown: String) async throws -> NotionPage {
        let body: JSONValue = .object([
            "parent": .object(["type": .string("data_source_id"), "data_source_id": .string(dataSourceID)]),
            "properties": .object(properties.mapValues(\.json)),
            "markdown": .string(markdown),
        ])
        return try decode(NotionPage.self, from: await send("POST", "v1/pages", body: body, idempotent: false))
    }

    func retrieveMarkdown(pageID: String) async throws -> NotionPageMarkdown {
        try decode(NotionPageMarkdown.self, from: await send("GET", "v1/pages/\(pageID)/markdown", idempotent: true))
    }

    func replaceContent(pageID: String, markdown: String) async throws {
        let body: JSONValue = .object([
            "type": .string("replace_content"),
            "replace_content": .object(["new_str": .string(markdown)]),
        ])
        // Replacing the whole content with the same text twice gives the same page.
        _ = try await send("PATCH", "v1/pages/\(pageID)/markdown", body: body, idempotent: true)
    }

    func updateProperties(pageID: String, properties: [String: NotionPropertyValue]) async throws {
        let body: JSONValue = .object(["properties": .object(properties.mapValues(\.json))])
        _ = try await send("PATCH", "v1/pages/\(pageID)", body: body, idempotent: true)
    }

    func queryPages(dataSourceID: String, property: String, equals value: String) async throws -> [NotionPage] {
        let body: JSONValue = .object([
            "filter": .object(["property": .string(property), "rich_text": .object(["equals": .string(value)])]),
            "page_size": .int(10),
        ])
        let data = try await send("POST", "v1/data_sources/\(dataSourceID)/query", body: body, idempotent: true)
        return try decode(NotionQueryResponse.self, from: data).results
    }

    // MARK: Transport

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil,
                      idempotent: Bool) async throws -> Data {
        await acquire()
        defer { release() }
        var url = baseURL.appendingPathComponent(path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            request.httpBody = try encoder.encode(body)
        }

        var attempt = 0
        while true {
            try await waitForSlot()
            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw NotionError.network(message: (error as? URLError)?.code.rawValue.description ?? "\(type(of: error))")
            }
            guard let http = response as? HTTPURLResponse else { throw NotionError.invalidResponse }
            let status = http.statusCode
            if (200..<300).contains(status) { return data }

            let error = try? JSONDecoder().decode(NotionErrorBody.self, from: data)
            let blocked = error?.additionalData["rate_limit_reason"] == "public_api_request_blocked"
            let retryable = ((status == 429 || status == 529) && !blocked)
                || (idempotent && [409, 500, 502, 503, 504].contains(status))
            guard retryable, attempt < maxRetries else {
                throw Self.error(status: status, body: error)
            }
            let fallback = min(pow(2, Double(attempt)), 30)
            let seconds = Self.seconds(http.value(forHTTPHeaderField: "Retry-After"))
                ?? Self.seconds(error?.additionalData["retry_after"])
                ?? fallback
            // The retry (and every request after it) waits in waitForSlot.
            pausedUntil = ContinuousClock.now + .seconds(seconds) + .milliseconds(Int.random(in: 0...250))
            attempt += 1
        }
    }

    private static func seconds(_ value: String?) -> Double? {
        guard let value, let seconds = Double(value.trimmingCharacters(in: .whitespaces)), seconds >= 0 else { return nil }
        return seconds
    }

    private static func error(status: Int, body: NotionErrorBody?) -> NotionError {
        let message = body?.message ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch status {
        case 401:
            return .unauthorized
        case 403:
            return .forbidden(message: message, blockLimit: body?.additionalData["block_limit"] != nil)
        case 404:
            return .notFound(message: message)
        case 429 where body?.additionalData["rate_limit_reason"] == "public_api_request_blocked":
            return .forbidden(message: message, blockLimit: false) // retrying won't help
        case 429, 529:
            return .rateLimited
        case 400..<500 where status != 409:
            return .validation(message: message)
        default:
            return .server(status: status, committedResourceID: body?.additionalData["committed_resource_id"])
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw NotionError.invalidResponse
        }
    }

    // MARK: Pacing

    /// One request at a time, in order.
    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Token bucket: `burst` requests at once, then `rate` per second. Also honours a Retry-After pause.
    private func waitForSlot() async throws {
        let now = ContinuousClock.now
        let elapsed = now - lastRefill
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        tokens = min(burst, tokens + seconds * rate)
        lastRefill = now
        var wait = Duration.zero
        if tokens < 1 { wait = .seconds((1 - tokens) / rate) }
        if let pausedUntil, pausedUntil > now { wait = max(wait, pausedUntil - now) }
        tokens -= 1
        if wait > .zero { try await sleep(wait) }
    }
}
