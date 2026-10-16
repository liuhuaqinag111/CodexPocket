import XCTest
@testable import CodexPocket

final class WorkspaceTests: XCTestCase {
    func testPorcelainPreservesPathsAndWorktreeFlags() throws {
        let raw = "worktree /repo\u{0}HEAD abc\u{0}branch refs/heads/main\u{0}\u{0}"
            + "worktree /repo copy/line\nname\u{0}HEAD def\u{0}detached\u{0}locked maintenance\u{0}prunable missing\u{0}\u{0}"
        let trees = try WorkspaceWorktreeParser.parse(raw)
        XCTAssertEqual(trees.count, 2)
        let main = try XCTUnwrap(trees.first)
        XCTAssertEqual(main.branch, "main")
        let other = try XCTUnwrap(trees.last)
        XCTAssertEqual(other.path, "/repo copy/line\nname")
        XCTAssertTrue(other.isDetached)
        XCTAssertEqual(other.lockedReason, "maintenance")
        XCTAssertEqual(other.prunableReason, "missing")
    }

    func testPorcelainRejectsTruncatedCommandOutput() {
        XCTAssertThrowsError(try WorkspaceWorktreeParser.parse("worktree /repo\u{0}HEAD abc"))
    }
}
