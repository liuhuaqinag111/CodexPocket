import XCTest
@testable import CodexPocket

/// `fetchAllPages` 收完页之后是 `["data": [JSONDict]]` 这样交回给
/// `Protocol_.threads` 的。这个往返要是转不过去，归档列表就整个空掉
/// （实测 `ar=0`）。
final class PageCastTests: XCTestCase {
    func testRowsRoundTripThroughDict() {
        let rows: [JSONDict] = [
            ["id": "t1", "name": "甲", "cwd": "/tmp", "updatedAt": 100],
            ["id": "t2", "name": "乙", "cwd": "/tmp", "updatedAt": 200],
        ]
        let out = Protocol_.threads(from: ["data": rows])
        XCTAssertEqual(out.count, 2, "[JSONDict] 塞进 JSONDict 再取出来丢了")
        XCTAssertEqual(Set(out.map { $0.id }), ["t1", "t2"])
    }

    /// 空数组也不能崩。
    func testEmptyRows() {
        let out = Protocol_.threads(from: ["data": [JSONDict]()])
        XCTAssertTrue(out.isEmpty)
    }
}
