import Foundation

protocol InputRepositoryProtocol: RepositoryConnection {
    var endpointURL: URL? { get }
    func searchFiles(query: String, roots: [String], done: @escaping RepositoryResult)
}

final class InputRepository: InputRepositoryProtocol {
    private let transport: RPCTransport
    var isReady: Bool { transport.state.isReady }
    var endpointURL: URL? { transport.endpointURL }
    init(transport: RPCTransport) { self.transport = transport }
    func reconnect() { transport.reconnectNow() }
    func searchFiles(query: String, roots: [String], done: @escaping RepositoryResult) {
        transport.rpc("fuzzyFileSearch", ["query": query, "roots": roots], done: done)
    }
}

extension InputRepositoryProtocol {
    var endpointURL: URL? { nil }
}
