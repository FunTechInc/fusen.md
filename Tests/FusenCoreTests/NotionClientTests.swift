import Foundation
import Synchronization
import Testing
@testable import FusenCore

/// A fake api.notion.com, one per test (tests run in parallel): each stub server has its own host
/// name, and StubURLProtocol answers requests for that host from the server's queue. Nothing
/// leaves the process.
final class StubServer: Sendable {
    struct Reply: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = "{}"
    }

    struct Request {
        let method: String
        let path: String
        let query: String?
        let headers: [String: String]
        /// Decoded JSON; only read by the test that sent it.
        let body: [String: Any]?
    }

    let host = "stub-\(UUID().uuidString.lowercased()).invalid"
    private let state = Mutex<(replies: [Reply], requests: [Request])>(([], []))

    init(_ replies: [Reply]) {
        state.withLock { $0.replies = replies }
        StubURLProtocol.servers.withLock { $0[host] = self }
    }

    var baseURL: URL { URL(string: "https://\(host)")! }
    var requests: [Request] { state.withLock { $0.requests } }

    func reply(to request: URLRequest) -> Reply {
        var body: [String: Any]?
        if let data = request.httpBody ?? request.httpBodyStream.map(Self.read) {
            body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        let recorded = Request(method: request.httpMethod ?? "", path: request.url?.path ?? "", query: request.url?.query,
                               headers: request.allHTTPHeaderFields ?? [:], body: body)
        return state.withLock {
            $0.requests.append(recorded)
            return $0.replies.isEmpty ? Reply(status: 200) : $0.replies.removeFirst()
        }
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

extension StubServer.Request: @unchecked Sendable {}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let servers = Mutex<[String: StubServer]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let server = Self.servers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let reply = server.reply(to: request)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Records the client's waits instead of sleeping.
actor SleepRecorder {
    private(set) var waits: [Duration] = []
    func record(_ duration: Duration) { waits.append(duration) }
}

struct NotionClientTests {
    let recorder = SleepRecorder()

    private func client(_ server: StubServer) -> NotionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let recorder = recorder
        return NotionClient(token: "test-token", baseURL: server.baseURL, configuration: configuration,
                            sleep: { await recorder.record($0) })
    }

    private static func error(_ status: Int, _ code: String, _ extra: String = "") -> String {
        #"{"object":"error","status":\#(status),"code":"\#(code)","message":"m"\#(extra)}"#
    }

    @Test func sendsTheDocumentedHeadersAndBodies() async throws {
        let server = StubServer([
            .init(status: 200, body: #"{"object":"page","id":"p1","url":"https://www.notion.so/p1","in_trash":false}"#),
            .init(status: 200, body: #"{"object":"page_markdown","id":"p1","markdown":"x"}"#),
            .init(status: 200, body: #"{"object":"list","results":[{"object":"page","id":"p2"}],"has_more":false}"#),
            .init(status: 200, body: #"{"object":"database","id":"db","data_sources":[{"id":"ds","name":"fusen.md"}]}"#),
        ])
        let api = client(server)
        let page = try await api.createPage(dataSourceID: "ds", properties: ["名前": .title("見出し"), "色": .select("ブルー")],
                                            markdown: "# 見出し\n- [ ] \\$5")
        #expect(page == NotionPage(id: "p1", url: "https://www.notion.so/p1", inTrash: false))
        try await api.replaceContent(pageID: "p1", markdown: "新しい本文")
        let found = try await api.queryPages(dataSourceID: "ds", property: "メモID", equals: "abc")
        #expect(found.map(\.id) == ["p2"])
        let database = try await api.createDatabase(parentPageID: "parent", title: "fusen.md", properties: NotionSync.schema)
        #expect(database.dataSources.first?.id == "ds")

        let requests = server.requests
        #expect(requests.map(\.method) == ["POST", "PATCH", "POST", "POST"])
        #expect(requests.map(\.path) == ["/v1/pages", "/v1/pages/p1/markdown", "/v1/data_sources/ds/query", "/v1/databases"])
        for request in requests {
            #expect(request.headers["Authorization"] == "Bearer test-token")
            #expect(request.headers["Notion-Version"] == "2026-03-11")
            #expect(request.headers["Content-Type"] == "application/json")
        }
        let create = try #require(requests[0].body)
        #expect((create["parent"] as? [String: String]) == ["type": "data_source_id", "data_source_id": "ds"])
        #expect(create["markdown"] as? String == "# 見出し\n- [ ] \\$5")
        #expect(create["markdown_version"] as? String == "v2") // next to `markdown`
        let properties = try #require(create["properties"] as? [String: Any])
        let title = (properties["名前"] as? [String: Any])?["title"] as? [[String: Any]]
        #expect((title?.first?["text"] as? [String: String]) == ["content": "見出し"])
        #expect(((properties["色"] as? [String: Any])?["select"] as? [String: String]) == ["name": "ブルー"])

        let replace = try #require(requests[1].body)
        #expect(replace["type"] as? String == "replace_content")
        #expect((replace["replace_content"] as? [String: String]) == ["new_str": "新しい本文"])
        #expect(replace["markdown_version"] as? String == "v2") // at the top level, not in the command
        #expect(Set(replace.keys) == ["type", "replace_content", "markdown_version"])

        // The requests that neither carry nor return Markdown do not name a version (Notion refuses
        // `markdown_version` without `markdown`).
        #expect(requests[2].body?["markdown_version"] == nil)
        #expect(requests[3].body?["markdown_version"] == nil)

        let query = try #require(requests[2].body)
        let filter = query["filter"] as? [String: Any]
        #expect(filter?["property"] as? String == "メモID")
        #expect((filter?["rich_text"] as? [String: String]) == ["equals": "abc"])

        let db = try #require(requests[3].body)
        #expect((db["parent"] as? [String: String]) == ["type": "page_id", "page_id": "parent"])
        let schema = (db["initial_data_source"] as? [String: Any])?["properties"] as? [String: Any]
        #expect(Set(schema?.keys.map { $0 } ?? []) == ["名前", "メモID", "色", "状態", "更新日時"])
        let status = ((schema?["状態"] as? [String: Any])?["select"] as? [String: Any])?["options"] as? [[String: String]]
        #expect(status?.map { $0["name"] } == ["使用中", "削除済み"])
    }

    @Test func readsAPageAsMarkdown() async throws {
        let server = StubServer([
            .init(status: 200, body: ##"{"object":"page_markdown","id":"p1","markdown":"# 見出し\n- [ ] a","truncated":true,"unknown_block_ids":["b1"]}"##),
            .init(status: 200, body: #"{"object":"page_markdown","id":"p2","markdown":"本文"}"#),
        ])
        let api = client(server)
        let first = try await api.retrieveMarkdown(pageID: "p1")
        #expect(first == NotionPageMarkdown(markdown: "# 見出し\n- [ ] a", truncated: true, unknownBlockIDs: ["b1"]))
        let second = try await api.retrieveMarkdown(pageID: "p2")
        #expect(second == NotionPageMarkdown(markdown: "本文"))
        #expect(server.requests.map(\.method) == ["GET", "GET"])
        #expect(server.requests.map(\.path) == ["/v1/pages/p1/markdown", "/v1/pages/p2/markdown"])
        // On a GET the Markdown version is a query parameter; the API version is the same as before.
        #expect(server.requests.map(\.query) == ["markdown_version=v2", "markdown_version=v2"])
        #expect(server.requests.first?.headers["Notion-Version"] == "2026-03-11")
    }

    @Test func aReplaceThatNotionAnswersWithWarningsStillSucceeds() async throws {
        // Notion saved the page, but its parser changed or ignored some of the Markdown.
        let body = ##"{"object":"page_markdown","id":"p1","markdown":"x","truncated":false,"unknown_block_ids":[],"warnings":[{"code":"unsupported_tag","message":"<foo> was saved as text"},{"code":"deprecated_tag","message":"m"}]}"##
        let server = StubServer([.init(status: 200, body: body), .init(status: 200, body: "not json")])
        let api = client(server)
        try await api.replaceContent(pageID: "p1", markdown: "本文")
        try await api.replaceContent(pageID: "p1", markdown: "本文") // an answer it cannot read is no failure either
        #expect(server.requests.count == 2)
        // Only the kinds of warning are read (a message may quote the note).
        #expect(NotionMarkdownWarnings.codes(in: Data(body.utf8)) == ["unsupported_tag", "deprecated_tag"])
        #expect(NotionMarkdownWarnings.codes(in: Data(#"{"object":"page_markdown","id":"p1","markdown":"x"}"#.utf8)).isEmpty)
        #expect(NotionMarkdownWarnings.codes(in: Data("not json".utf8)).isEmpty)
    }

    @Test func aNoteNotionCannotParseIsAValidationError() async {
        // What the older format saved as literal text, this one refuses: 400, never retried.
        let server = StubServer([.init(status: 400, body: #"{"object":"error","status":400,"code":"validation_error","message":"Markdown errors blocked parsing: an image must be its own block"}"#),
                                 .init(status: 200)])
        await #expect(throws: NotionError.validation(message: "Markdown errors blocked parsing: an image must be its own block")) {
            try await client(server).replaceContent(pageID: "p1", markdown: "x")
        }
        #expect(server.requests.count == 1)
    }

    @Test func rateLimitWaitsForRetryAfterThenRetries() async throws {
        let server = StubServer([
            .init(status: 429, headers: ["Retry-After": "2"], body: Self.error(429, "rate_limited")),
            .init(status: 200, body: #"{"object":"user","id":"bot","type":"bot","bot":{"workspace_name":"FunTech"}}"#),
        ])
        let user = try await client(server).retrieveMe()
        #expect(user.bot?.workspaceName == "FunTech")
        #expect(server.requests.count == 2)
        let waits = await recorder.waits
        #expect(waits.count == 1)
        #expect(waits.allSatisfy { $0 >= .milliseconds(1_900) && $0 <= .milliseconds(2_300) })
    }

    @Test func retryAfterInTheBodyAndBackoffWithoutAny() async throws {
        let server = StubServer([
            .init(status: 529, body: Self.error(529, "service_overload", #","additional_data":{"retry_after":"7"}"#)),
            .init(status: 503, body: Self.error(503, "service_unavailable")), // GET: idempotent, retried
            .init(status: 200, body: #"{"object":"page","id":"p"}"#),
        ])
        _ = try await client(server).retrievePage(id: "p")
        #expect(server.requests.count == 3)
        let waits = await recorder.waits
        #expect(waits.count == 2)
        #expect(waits.first.map { $0 >= .milliseconds(6_900) && $0 <= .milliseconds(7_300) } == true)
        #expect(waits.last.map { $0 >= .milliseconds(1_900) && $0 <= .milliseconds(2_300) } == true) // 2^1 s
    }

    @Test func givesUpAfterFiveRetries() async {
        let server = StubServer(Array(repeating: .init(status: 429, headers: ["Retry-After": "1"],
                                                       body: Self.error(429, "rate_limited")), count: 10))
        await #expect(throws: NotionError.rateLimited) { try await client(server).retrieveMe() }
        #expect(server.requests.count == 6)
    }

    @Test func clientErrorsAreNeverRetried() async {
        let cases: [(StubServer.Reply, NotionError)] = [
            (.init(status: 400, body: Self.error(400, "validation_error")), .validation(message: "m")),
            (.init(status: 401, body: Self.error(401, "unauthorized")), .unauthorized),
            (.init(status: 403, body: Self.error(403, "restricted_resource")), .forbidden(message: "m", blockLimit: false)),
            (.init(status: 403, body: Self.error(403, "restricted_resource", #","additional_data":{"block_limit":"block_creation"}"#)),
             .forbidden(message: "m", blockLimit: true)),
            (.init(status: 404, body: Self.error(404, "object_not_found")), .notFound(message: "m")),
            (.init(status: 429, body: Self.error(429, "rate_limited", #","additional_data":{"rate_limit_reason":"public_api_request_blocked"}"#)),
             .forbidden(message: "m", blockLimit: false)),
        ]
        for (reply, expected) in cases {
            let server = StubServer([reply, .init(status: 200, body: #"{"object":"page","id":"p"}"#)])
            await #expect(throws: expected) { try await client(server).retrievePage(id: "p") }
            #expect(server.requests.count == 1)
        }
    }

    @Test func pageCreationIsNotRetriedOnServerErrors() async {
        // The page may have been saved anyway; the sync looks it up by メモID next time instead.
        let server = StubServer([.init(status: 503, body: Self.error(503, "service_unavailable")),
                                 .init(status: 200, body: #"{"object":"page","id":"p"}"#)])
        await #expect(throws: NotionError.server(status: 503)) {
            try await client(server).createPage(dataSourceID: "ds", properties: [:], markdown: "x")
        }
        #expect(server.requests.count == 1)
    }

    @Test func aCreateSavedDespiteA503ReportsTheNewID() async {
        let server = StubServer([.init(status: 503, body: Self.error(503, "service_unavailable",
            #","additional_data":{"retry_guidance":["Do not repeat the write."],"committed_resource_id":"p-new"}"#))])
        await #expect(throws: NotionError.server(status: 503, committedResourceID: "p-new")) {
            try await client(server).createPage(dataSourceID: "ds", properties: [:], markdown: "x")
        }
        #expect(server.requests.count == 1)
    }

    @Test func databasesInAPageAreListedPageByPage() async throws {
        let server = StubServer([
            .init(status: 200, body: #"{"object":"list","results":[{"object":"block","id":"b1","type":"paragraph","paragraph":{}},{"object":"block","id":"d1","type":"child_database","child_database":{"title":"fusen.md"},"in_trash":false}],"has_more":true,"next_cursor":"c2"}"#),
            .init(status: 200, body: #"{"object":"list","results":[{"object":"block","id":"d2","type":"child_database","child_database":{"title":"別の表"}},{"object":"block","id":"d3","type":"child_database","child_database":{"title":"fusen.md"},"in_trash":true}],"has_more":false,"next_cursor":null}"#),
            .init(status: 200, body: #"{"object":"database","id":"d1","url":"https://www.notion.so/d1","data_sources":[{"id":"ds1","name":"fusen.md"}]}"#),
        ])
        let api = client(server)
        let found = try await api.childDatabases(pageID: "parent")
        #expect(found == [NotionChildDatabase(id: "d1", title: "fusen.md"), NotionChildDatabase(id: "d2", title: "別の表")])
        let database = try await api.retrieveDatabase(id: "d1")
        #expect(database.dataSources.first?.id == "ds1")
        let requests = server.requests
        #expect(requests.map(\.method) == ["GET", "GET", "GET"])
        #expect(requests.map(\.path) == ["/v1/blocks/parent/children", "/v1/blocks/parent/children", "/v1/databases/d1"])
        #expect(requests.map(\.query) == ["page_size=100", "page_size=100&start_cursor=c2", nil])
    }

    @Test func offlineIsANetworkError() async {
        // No stub server for this host: the stub protocol fails the request like a lost connection.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = NotionClient(token: "test-token", baseURL: URL(string: "https://nowhere.invalid")!,
                               configuration: configuration, sleep: { _ in })
        await #expect { try await api.retrieveMe() } throws: { error in
            if case NotionError.network = error { true } else { false }
        }
    }
}
