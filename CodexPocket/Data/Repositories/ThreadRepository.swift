import Foundation

enum ThreadOperation {
    case list(JSONDict), read(JSONDict), search(JSONDict), projects, models, config
    case projectPage(JSONDict), modelPage(JSONDict), providerModels
    case delete(JSONDict), metadata(JSONDict), archive(JSONDict, Bool)
    case rename(JSONDict), create(JSONDict), start(JSONDict), settings(JSONDict)
}

protocol ThreadRepositoryProtocol: RepositoryConnection {
    var connectionIdentity: String { get }
    func perform(_ operation: ThreadOperation, done: RepositoryResult?)
    func readThread(_ id: String, done: @escaping (Result<Thread, Error>) -> Void)
}

final class ThreadRepository: ThreadRepositoryProtocol {
    private let transport: RPCTransport
    var isReady: Bool { transport.state.isReady }
    var connectionIdentity: String { transport.connectionIdentity }
    init(transport: RPCTransport) { self.transport = transport }
    func reconnect() { transport.reconnectNow() }

    static func request(_ op: ThreadOperation) -> (String, JSONDict) {
        switch op {
        case .list(let p): return ("thread/list", p)
        case .read(let p): return ("thread/read", p)
        case .search(let p): return ("thread/search", p)
        case .projects: return ("project/list", [:])
        case .models: return ("model/list", [:])
        case .projectPage(let p): return ("project/list", p)
        case .modelPage(let p): return ("model/list", p)
        case .providerModels: return ("bridge/provider/models", [:])
        case .config: return ("config/read", [:])
        case .delete(let p): return ("thread/delete", p)
        case .metadata(let p): return ("thread/metadata/update", p)
        case .archive(let p, let on):
            return (on ? "thread/archive" : "thread/unarchive", p)
        case .rename(let p): return ("thread/name/set", p)
        case .create(let p): return ("thread/start", p)
        case .start(let p): return ("turn/start", p)
        case .settings(let p): return ("thread/settings/update", p)
        }
    }

    func perform(_ operation: ThreadOperation, done: RepositoryResult? = nil) {
        let request = Self.request(operation)
        transport.rpc(request.0, request.1, done: done)
    }
}

extension ThreadRepositoryProtocol {
    var connectionIdentity: String { "" }
    func perform(_ op: ThreadOperation) { perform(op, done: nil) }

    func readThread(_ id: String, done: @escaping (Result<Thread, Error>) -> Void) {
        perform(.read(["threadId": id, "includeTurns": false])) { result in
            done(result.flatMap { value in
                guard let raw = (value as? JSONDict)?.dict("thread"),
                      let thread = Thread(json: raw), thread.id == id else {
                    return .failure(RepositoryError(message: "会话元信息无效"))
                }
                return .success(thread)
            })
        }
    }
}
