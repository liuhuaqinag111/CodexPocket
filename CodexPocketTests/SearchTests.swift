import XCTest
@testable import CodexPocket

/// 服务端全文搜索的解析。
///
/// `thread/search` 的回包结构和 `thread/list` **不一样**：
///   {"data":[{"thread":{...},"snippet":"命中的原文"}]}
/// thread 嵌在 `thread` 字段里。直接套 `threads(from:)` 会一条都解析不出来
/// （它只认 `data[].id`，而这里是 `data[].thread.id`）。
final class SearchTests: XCTestCase {

    @MainActor
    func testVisibleSearchIncludesBodyHitsWithoutDuplicateIDs() {
        let model = ThreadListModel(repository: ThreadRepository(transport: RecordingTransport()), settings: PreferencesModel())
        let titleHit = Thread(json: ["id": "title", "name": "needle title"])!
        let bodyHit = Thread(json: ["id": "body", "name": "Other title"])!
        model.threads = [titleHit, bodyHit]
        model.query = "needle"
        defer { model.searchTimer?.invalidate() }
        model.searchHits = [bodyHit, titleHit]
        XCTAssertEqual(Set(model.allMatching.map(\.id)), ["title", "body"])
        XCTAssertEqual(model.allMatching.count, 2)
    }

    @MainActor
    func testChangingQueryImmediatelyRejectsOldSearchResponse() async {
        let transport = RecordingTransport()
        transport.deferResponse = true
        let model = ThreadListModel(repository: ThreadRepository(transport: transport), settings: PreferencesModel())
        model.query = "old"
        model.runSearch("old")
        let oldResponse = transport.pending
        model.query = "new"
        defer { model.searchTimer?.invalidate() }
        oldResponse?(.success(["data": [["thread": ["id": "old", "name": "Old result"]]]] as JSONDict))
        for _ in 0..<12 { await Task.yield() }
        XCTAssertTrue(model.searchHits.isEmpty)
    }

    private let payload: JSONDict = [
        "data": [
            [
                "thread": ["id": "s1", "name": "竞彩复盘", "cwd": "/Users/test/竞彩",
                           "updatedAt": 1_700_000_100, "status": ["type": "notLoaded"]],
                "snippet": "今天竞彩的让球是 -1",
            ],
            [
                "thread": ["id": "s2", "preview": "帮我看看竞彩", "cwd": "/tmp",
                           "updatedAt": 1_700_000_200],
                "snippet": "",
            ],
        ],
    ]

    func testParsesNestedThreadObjects() {
        let r = Protocol_.searchHits(from: payload)
        XCTAssertEqual(r.hits.count, 2, "嵌套的 thread 没解析出来")
        XCTAssertEqual(r.hits.map { $0.id }.sorted(), ["s1", "s2"])
    }

    func testKeepsSnippet() {
        let r = Protocol_.searchHits(from: payload)
        XCTAssertEqual(r.snippets["s1"], "今天竞彩的让球是 -1")
        XCTAssertNil(r.snippets["s2"], "空片段不该塞进来")
    }

    /// 没有 snippet 字段、或 data 为空，都不能崩。
    func testHandlesEmptyAndMissingSnippet() {
        XCTAssertEqual(Protocol_.searchHits(from: ["data": []]).hits.count, 0)
        XCTAssertEqual(Protocol_.searchHits(from: [:]).hits.count, 0)
        let noSnip: JSONDict = ["data": [["thread": ["id": "z1", "cwd": "/tmp"]]]]
        let r = Protocol_.searchHits(from: noSnip)
        XCTAssertEqual(r.hits.count, 1)
        XCTAssertTrue(r.snippets.isEmpty)
    }
}
