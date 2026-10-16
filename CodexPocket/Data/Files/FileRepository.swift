import Foundation

struct FileDocument: Identifiable, Equatable {
    let path: String
    let text: String
    let connectionIdentity: String
    var id: String { path }
    var byteCount: Int { text.utf8.count }

    init(path: String, text: String, connectionIdentity: String = "") {
        self.path = path
        self.text = text
        self.connectionIdentity = connectionIdentity
    }
}

@MainActor
protocol FileRepositoryProtocol {
    func readDirectory(path: String) async throws -> [FileEntry]
    func readText(path: String) async throws -> FileDocument
    func saveText(_ document: FileDocument, text: String) async throws -> FileDocument
}

enum FileRepositoryError: LocalizedError {
    case invalidResponse
    case tooLarge(Int)
    case unsupportedText
    case conflict(FileDocument)
    case connectionChanged

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "文件服务返回了无效数据"
        case .tooLarge: return "文件超过 2 MB，暂不支持打开"
        case .unsupportedText: return "此文件不是 UTF-8 文本"
        case .conflict: return "远端文件已更改，本地草稿尚未写入"
        case .connectionChanged: return "连接目标已变化，请重新打开文件后再保存"
        }
    }
}

@MainActor
final class FileRepository: FileRepositoryProtocol {
    private let transport: RPCTransport

    init(transport: RPCTransport) { self.transport = transport }

    func readDirectory(path: String) async throws -> [FileEntry] {
        let json = try await request("fs/readDirectory", ["path": path])
        guard json.arr("entries") != nil else { throw FileRepositoryError.invalidResponse }
        return FileEntry.parse(json)
    }

    func readText(path: String) async throws -> FileDocument {
        let identity = transport.connectionIdentity
        let json = try await request("fs/readFile", ["path": path])
        guard transport.connectionIdentity == identity else { throw FileRepositoryError.connectionChanged }
        guard let base64 = json.str("dataBase64") else {
            throw FileRepositoryError.invalidResponse
        }
        // fs/getMetadata has no size field in the v2 protocol. Reject an
        // obviously oversized payload before base64 decoding; the bridge also
        // enforces the host-side stat limit before forwarding this response.
        let maxBase64 = (FileText.maxBytes * 4) / 3 + 4
        guard base64.utf8.count <= maxBase64,
              let data = Data(base64Encoded: base64) else {
            if base64.utf8.count > maxBase64 { throw FileRepositoryError.tooLarge(FileText.maxBytes + 1) }
            throw FileRepositoryError.invalidResponse
        }
        guard !FileText.isTooLarge(byteCount: data.count) else {
            throw FileRepositoryError.tooLarge(data.count)
        }
        guard !FileText.isBinary(data), let text = String(data: data, encoding: .utf8) else {
            throw FileRepositoryError.unsupportedText
        }
        return FileDocument(path: path, text: text, connectionIdentity: identity)
    }

    func saveText(_ document: FileDocument, text: String) async throws -> FileDocument {
        let size = text.utf8.count
        guard !FileText.isTooLarge(byteCount: size) else { throw FileRepositoryError.tooLarge(size) }
        let identity = transport.connectionIdentity
        if !document.connectionIdentity.isEmpty, document.connectionIdentity != identity {
            throw FileRepositoryError.connectionChanged
        }
        let remote = try await readText(path: document.path)
        guard transport.connectionIdentity == identity,
              remote.connectionIdentity == identity else { throw FileRepositoryError.connectionChanged }
        guard remote.text == document.text else { throw FileRepositoryError.conflict(remote) }
        // The server has no conditional write; recheck content immediately before writing.
        guard transport.connectionIdentity == identity else { throw FileRepositoryError.connectionChanged }
        _ = try await request("fs/writeFile", ["path": document.path,
                                              "dataBase64": Data(text.utf8).base64EncodedString()])
        return FileDocument(path: document.path, text: text, connectionIdentity: identity)
    }

    private func request(_ method: String, _ params: JSONDict) async throws -> JSONDict {
        let value: Any = try await withCheckedThrowingContinuation { continuation in
            transport.rpc(method, params) { result in
                continuation.resume(with: result)
            }
        }
        guard let json = value as? JSONDict else { throw FileRepositoryError.invalidResponse }
        return json
    }
}
