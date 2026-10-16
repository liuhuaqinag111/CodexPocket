import XCTest
@testable import CodexPocket

/// 列表去重：**同名同目录的不同会话必须都留着**。
///
/// 用户报的「会话名字相同会覆盖」就是这里：以前去重键是「标题 + 目录」，
/// 而真实列表里 `"新会话|/Users/test"` 有 **10 个不同的 id** ——
/// 全是用户自己新建的会话，按标题去重等于把 9 个抹掉。
final class ThreadDedupeTests: XCTestCase {

    private func row(_ id: String, _ name: String, cwd: String = "/Users/test",
                     at: Double = 0, forkedFrom: String? = nil) -> CodexPocket.Thread {
        var json: JSONDict = ["id": id, "name": name, "cwd": cwd, "updatedAt": at]
        if let forkedFrom { json["forkedFromId"] = forkedFrom }
        return CodexPocket.Thread(json: json)!
    }

    /// 三个都叫「新会话」、目录也一样 —— 必须全部留下。
    func testSameNameDifferentIDsAllKept() {
        let rows = [row("a", "新会话", at: 3),
                    row("b", "新会话", at: 2),
                    row("c", "新会话", at: 1)]
        let out = Protocol_.dedupe(rows)
        XCTAssertEqual(out.count, 3, "同名会话被吞了 —— 用户会看到'会话被覆盖'")
        XCTAssertEqual(Set(out.map(\.id)), ["a", "b", "c"])
    }

    /// 同一个 id 出现多行（服务端重复条目）→ 只留最新的那条。
    func testSameIDKeepsNewest() {
        let rows = [row("x", "会话", at: 100), row("x", "会话", at: 300), row("x", "会话", at: 200)]
        let out = Protocol_.dedupe(rows)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.updatedAt.timeIntervalSince1970, 300)
    }

    /// fork 出来的副本（id 不同、标题相同）也不能被吞掉。
    func testForkCopyIsKept() {
        let rows = [row("orig", "同一个标题", at: 10),
                    row("fork", "同一个标题", at: 20, forkedFrom: "orig")]
        XCTAssertEqual(Protocol_.dedupe(rows).count, 2, "fork 副本被当成重复删了")
    }

    /// 结果按更新时间倒序。
    func testSortedByUpdatedAtDesc() {
        let out = Protocol_.dedupe([row("a", "A", at: 1), row("b", "B", at: 9), row("c", "C", at: 5)])
        XCTAssertEqual(out.map(\.id), ["b", "c", "a"])
    }
}
