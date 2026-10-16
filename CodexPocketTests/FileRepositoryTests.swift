import XCTest
@testable import CodexPocket

private final class FileTestTransport: RPCTransport {
    var text: String
    var reads = 0
    var writes = 0
    var writePath: String?
    var connectionIdentity = "server-a"
    var switchAfterRead = false
    init(text: String) { self.text = text }

    func rpc(_ method: String, _ params: JSONDict,
             done: ((Result<Any, Error>) -> Void)?) -> Int {
        switch method {
        case "fs/readFile":
            reads += 1
            done?(.success(["dataBase64": Data(text.utf8).base64EncodedString()]))
            if switchAfterRead { connectionIdentity = "server-b" }
        case "fs/writeFile":
            writes += 1
            writePath = params.str("path")
            text = FileText.decode(params) ?? "INVALID"
            done?(.success([:] as JSONDict))
        default: done?(.failure(NSError(domain: "Unexpected RPC", code: 1)))
        }
        return 1
    }
}

@MainActor
final class FileRepositoryTests: XCTestCase {
    func testOldDocumentCannotBeSavedToAnotherConnection() async throws {
        let transport = FileTestTransport(text: "original")
        let repository = FileRepository(transport: transport)
        let original = try await repository.readText(path: "/repo/a.txt")
        transport.connectionIdentity = "server-b"
        do {
            _ = try await repository.saveText(original, text: "draft")
            XCTFail("Old documents must never write to a different connection")
        } catch { }
        XCTAssertEqual(transport.writes, 0)
    }
    func testChangedRemoteContentNeverWrites() async throws {
        let transport = FileTestTransport(text: "changed on Mac")
        let repository = FileRepository(transport: transport)
        let original = FileDocument(path: "/repo/a.txt", text: "original")
        do {
            _ = try await repository.saveText(original, text: "local draft")
            XCTFail("A stale document must not overwrite remote changes")
        } catch FileRepositoryError.conflict(let remote) {
            XCTAssertEqual(remote.text, "changed on Mac")
        }
        XCTAssertEqual(transport.text, "changed on Mac")
        XCTAssertEqual(transport.writes, 0)
    }
    func testConnectionChangeDuringRecheckCannotWriteDraft() async throws {
        let transport = FileTestTransport(text: "original")
        let repository = FileRepository(transport: transport)
        let original = try await repository.readText(path: "/repo/a.txt")
        transport.switchAfterRead = true
        do {
            _ = try await repository.saveText(original, text: "draft")
            XCTFail("Switching after the preflight read must cancel the write")
        } catch { }
        XCTAssertEqual(transport.writes, 0)
        XCTAssertEqual(transport.text, "original")
    }
    func testUnchangedDocumentWritesUTF8AndReturnsNewBaseline() async throws {
        let transport = FileTestTransport(text: "original")
        let repository = FileRepository(transport: transport)
        let saved = try await repository.saveText(
            FileDocument(path: "/repo/a.txt", text: "original"), text: "你好\n")
        XCTAssertEqual(saved.text, "你好\n")
        XCTAssertEqual(transport.text, "你好\n")
        XCTAssertEqual(transport.writePath, "/repo/a.txt")
    }

    func testTooLargeProtocolPayloadIsRejected() async {
        let transport = FileTestTransport(text: String(repeating: "x", count: 3 * 1024 * 1024))
        do {
            _ = try await FileRepository(transport: transport).readText(path: "/large")
            XCTFail("Oversized files must not be opened")
        } catch FileRepositoryError.tooLarge {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(transport.reads, 1)
    }
}
