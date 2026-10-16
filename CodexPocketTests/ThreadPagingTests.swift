import XCTest
@testable import CodexPocket

/// 「归档里少了一大半会话」。
///
/// 服务端 `thread/list` 硬上限 100 行（实测 limit 传 200/500 也只回 100），
/// 回包里带 `nextCursor`。App 以前一律传 200 且**从不翻页** ——
/// 实测归档 230 个线程，App 只显示 66 个（服务端给 100 行，再去重）。
final class ThreadPagingTests: XCTestCase {

    /// 一页就是 100，别写成 200 假装能一次拉完。
    @MainActor
    func testListPageMatchesServerCap() {
        XCTAssertEqual(ThreadListModel.listPage, 100,
                       "服务端硬上限 100；写成 200 只是自欺，多出来的部分照样没有")
    }

    @MainActor
    func testReconcileOnlyReadsFirstPageAndPreservesOlderRows() async {
        let rpc = RecordingTransport()
        rpc.result = .success(["data": [["id": "new"]], "nextCursor": "more"] as JSONDict)
        let list = ThreadListModel(repository: ThreadRepository(transport: rpc), settings: PreferencesModel())
        list.threads = [Thread(json: ["id": "old"])!]
        list.fetchThreadsFirstPage()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(rpc.calls.count, 1, "周期对账仍只读第一页")
        XCTAssertEqual(list.threads.map(\.id), ["new", "old"])
    }
}
