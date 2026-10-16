import Foundation
import XCTest
import SQLite3
#if !PERSISTENCE_STANDALONE
@testable import CodexPocket
#endif

final class PersistenceTests: XCTestCase {
    private var root: URL!
    private var directory: URL { root.appendingPathComponent("database") }
    private var legacy: URL { root.appendingPathComponent("chat") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func makeCache(_ host: String = "host-a", migrate: Bool = false) -> SnapshotCache {
        SnapshotCache(directory: directory, namespace: host, legacyDirectory: migrate ? legacy : nil)
    }

    func testRestartKeepsPayloadAndWriteTime() throws {
        let payload = Data("{\"items\":[]}".utf8)
        var cache: SnapshotCache? = makeCache()
        cache?.save("thread", payload)
        let written = try XCTUnwrap(cache?.modifiedAt("thread"))
        cache = nil
        let reopened = makeCache()
        XCTAssertEqual(reopened.load("thread"), payload)
        XCTAssertEqual(reopened.modifiedAt("thread"), written)
        XCTAssertFalse(reopened.isStale("thread", now: written.addingTimeInterval(600)))
        XCTAssertTrue(reopened.isStale("thread", now: written.addingTimeInterval(601)))
    }

    func testNamespacesSeparateSameThread() {
        let cache = makeCache()
        cache.save("same", Data("{\"host\":\"a\"}".utf8))
        cache.setNamespace("host-b")
        XCTAssertFalse(cache.has("same"))
        cache.save("same", Data("{\"host\":\"b\"}".utf8))
        cache.setNamespace("host-a")
        XCTAssertEqual(cache.load("same"), Data("{\"host\":\"a\"}".utf8))
    }

    func testObsoleteResponseNeverPopulatesSwitchedHost() {
        let cache = makeCache()
        let captured = cache.namespace
        cache.setNamespace("host-b")
        XCTAssertEqual(cache.namespace, "host-b")
        XCTAssertFalse(cache.save("late", Data("{}".utf8), namespace: captured))
        XCTAssertNil(cache.load("late"))
        XCTAssertTrue(cache.save("late", Data("[]".utf8), namespace: "host-b"))
        XCTAssertEqual(cache.load("late"), Data("[]".utf8))
        cache.setNamespace("host-a")
        XCTAssertNil(cache.load("late"))
    }

    func testUnboundNamespaceDoesNotReadOrWrite() {
        let cache = makeCache(" \n")
        cache.save("thread", Data("{}".utf8))
        XCTAssertNil(cache.load("thread"))
        XCTAssertNil(cache.modifiedAt("thread"))
        XCTAssertTrue(cache.isStale("thread"))
        cache.setNamespace("host-a")
        XCTAssertFalse(cache.has("thread"))
    }

    func testEvictionKeepsFortyMostRecentlyWrittenAcrossHosts() {
        let cache = makeCache()
        for index in 0..<45 {
            cache.setNamespace(index < 20 ? "host-a" : "host-b")
            cache.save("t-\(index)", Data("{}".utf8))
        }
        cache.setNamespace("host-a")
        XCTAssertFalse(cache.has("t-0"))
        XCTAssertFalse(cache.has("t-4"))
        XCTAssertTrue(cache.has("t-5"))
        cache.setNamespace("host-b")
        XCTAssertTrue(cache.has("t-44"))
    }

    func testDropAndClearAreScopedToBoundHost() {
        let cache = makeCache()
        cache.save("one", Data("{}".utf8))
        cache.save("two", Data("{}".utf8))
        cache.setNamespace("host-b")
        cache.save("one", Data("[]".utf8))
        cache.setNamespace("host-a")
        cache.drop("one")
        XCTAssertFalse(cache.has("one"))
        XCTAssertTrue(cache.has("two"))
        cache.clear()
        XCTAssertFalse(cache.has("two"))
        cache.setNamespace("host-b")
        XCTAssertEqual(cache.load("one"), Data("[]".utf8))
    }

    func testMalformedSaveDoesNotReplaceGoodSnapshot() {
        let cache = makeCache()
        cache.save("thread", Data("{}".utf8))
        let time = cache.modifiedAt("thread")
        cache.save("thread", Data("broken json".utf8))
        XCTAssertEqual(cache.load("thread"), Data("{}".utf8))
        XCTAssertEqual(cache.modifiedAt("thread"), time)
        cache.save("missing", Data("null".utf8))
        XCTAssertFalse(cache.has("missing"))
    }

    private func writeLegacy(_ id: String, payload: Data = Data("{}".utf8), at date: Date) throws -> URL {
        let file = legacy.appendingPathComponent(SnapshotCache.safe(id) + ".json")
        try payload.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        return file
    }

    func testLazyMigrationPreservesSourceAndOldFreshness() throws {
        let old = Date(timeIntervalSince1970: 1_500_000_000)
        let file = try writeLegacy("a/b", at: old)
        let cache = makeCache(migrate: true)
        XCTAssertTrue(cache.has("a/b"))
        XCTAssertEqual(cache.load("a/b"), Data("{}".utf8))
        XCTAssertEqual(cache.modifiedAt("a/b"), old)
        XCTAssertTrue(cache.isStale("a/b"))
        XCTAssertEqual(try Data(contentsOf: file), Data("{}".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, old)
    }

    func testMigrationIsOptInAndNeverReusedByAnotherHost() throws {
        _ = try writeLegacy("thread", at: Date())
        XCTAssertNil(makeCache().load("thread"))
        let cache = makeCache(migrate: true)
        cache.setNamespace("host-b")
        XCTAssertNil(cache.load("thread"))
        cache.setNamespace("host-a")
        XCTAssertNotNil(cache.load("thread"))
        XCTAssertNil(makeCache("host-b", migrate: true).load("thread"))
    }

    func testDeletedMigrationDoesNotResurrectAfterRestart() throws {
        _ = try writeLegacy("thread", at: Date())
        var cache: SnapshotCache? = makeCache(migrate: true)
        XCTAssertTrue(cache?.has("thread") == true)
        cache?.drop("thread")
        cache = nil
        XCTAssertNil(makeCache(migrate: true).load("thread"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("thread.json").path))
    }

    func testClearDisablesUntouchedLegacyFilesAfterRestart() throws {
        _ = try writeLegacy("untouched", at: Date())
        let cache = makeCache(migrate: true)
        cache.clear()
        XCTAssertNil(makeCache(migrate: true).load("untouched"))
    }

    func testCorruptLegacyFileIsIgnoredAndPreserved() throws {
        let file = try writeLegacy("broken", payload: Data("{broken".utf8), at: Date())
        let cache = makeCache(migrate: true)
        XCTAssertNil(cache.load("broken"))
        XCTAssertFalse(cache.has("broken"))
        XCTAssertNil(cache.modifiedAt("broken"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testThreadIdentifiersDoNotCollide() {
        let cache = makeCache()
        cache.save("a/b", Data("{}".utf8))
        cache.save("a_b", Data("[]".utf8))
        XCTAssertEqual(cache.load("a/b"), Data("{}".utf8))
        XCTAssertEqual(cache.load("a_b"), Data("[]".utf8))
        XCTAssertEqual(SnapshotCache.safe("a/b"), "a%2Fb")
        XCTAssertEqual(SnapshotCache.safe("a%2Fb"), "a%252Fb")
    }

    private func databaseSQL(_ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("snapshots.sqlite3").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    func testCorruptDatabasePayloadIsDiscarded() throws {
        let cache = makeCache()
        cache.save("thread", Data("{}".utf8))
        try databaseSQL("UPDATE snapshots SET payload=x'62726F6B656E' WHERE id='thread'")
        XCTAssertNil(cache.load("thread"))
        XCTAssertFalse(cache.has("thread"))
        XCTAssertNil(cache.modifiedAt("thread"))
        cache.save("thread", Data("[]".utf8))
        XCTAssertEqual(cache.load("thread"), Data("[]".utf8))
    }

    func testEmptyDatabasePayloadIsDiscarded() throws {
        let cache = makeCache()
        cache.save("thread", Data("{}".utf8))
        try databaseSQL("UPDATE snapshots SET payload=x'' WHERE id='thread'")
        XCTAssertNil(cache.load("thread"))
        try databaseSQL("CREATE TRIGGER reject_duplicates BEFORE INSERT ON snapshots WHEN EXISTS(SELECT 1 FROM snapshots WHERE id=NEW.id) BEGIN SELECT RAISE(ABORT, 'duplicate'); END")
        cache.save("thread", Data("[]".utf8))
        XCTAssertEqual(cache.load("thread"), Data("[]".utf8))
    }

    func testFailedEvictionRollsBackNewSnapshot() throws {
        let cache = makeCache()
        for index in 0..<40 { cache.save("t-\(index)", Data("{}".utf8)) }
        try databaseSQL("CREATE TRIGGER reject_deletes BEFORE DELETE ON snapshots BEGIN SELECT RAISE(ABORT, 'blocked'); END")
        cache.save("new", Data("[]".utf8))
        XCTAssertFalse(cache.has("new"))
        XCTAssertTrue(cache.has("t-0"))
        XCTAssertTrue(cache.has("t-39"))
    }

    func testConcurrentWritesPersistCompleteSnapshots() {
        let cache = makeCache()
        DispatchQueue.concurrentPerform(iterations: 25) { index in
            cache.save("t-\(index)", Data("{\"index\":\(index)}".utf8))
        }
        let reopened = makeCache()
        for index in 0..<25 {
            XCTAssertEqual(reopened.load("t-\(index)"), Data("{\"index\":\(index)}".utf8))
        }
    }

    func testUnsupportedDatabaseVersionIsNotRewritten() throws {
        let cache = makeCache()
        cache.save("thread", Data("{}".utf8))
        try databaseSQL("PRAGMA user_version=99")
        let future = makeCache()
        XCTAssertNil(future.load("thread"))
        future.save("new", Data("[]".utf8))
        try databaseSQL("PRAGMA user_version=1")
        let restored = makeCache()
        XCTAssertEqual(restored.load("thread"), Data("{}".utf8))
        XCTAssertNil(restored.load("new"))
    }

    func testBindingFirstHostAllowsMigrationButOtherHostsDoNot() throws {
        _ = try writeLegacy("thread", at: Date())
        let cache = makeCache("", migrate: true)
        XCTAssertNil(cache.load("thread"))
        cache.setNamespace("host-a")
        XCTAssertNotNil(cache.load("thread"))
        cache.setNamespace("host-b")
        XCTAssertNil(cache.load("thread"))
    }

    func testCorruptDatabaseFileIsPreserved() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("snapshots.sqlite3")
        let invalid = Data("not a sqlite database".utf8)
        try invalid.write(to: file)
        let cache = makeCache()
        cache.save("thread", Data("{}".utf8))
        XCTAssertNil(cache.load("thread"))
        XCTAssertEqual(try Data(contentsOf: file), invalid)
    }
}

#if PERSISTENCE_STANDALONE
@main
struct PersistenceTestRunner {
    static func main() {
        let suite = PersistenceTests.defaultTestSuite
        suite.run()
        exit(suite.testRun?.hasSucceeded == true ? 0 : 1)
    }
}
#endif
