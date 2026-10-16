import Foundation

enum ConversationOperation {
    case submissionStatus(JSONDict)
    case turns(JSONDict), resume(JSONDict), start(JSONDict), steer(JSONDict)
    case interrupt(JSONDict), compact(JSONDict), fork(JSONDict), revert(JSONDict)
    case queueAdd(JSONDict), queueList(JSONDict), queueDelete(JSONDict), queueStart(JSONDict)
}

protocol ConversationRepositoryProtocol: RepositoryConnection {
    var cache: SnapshotCache { get }
    func perform(_ operation: ConversationOperation, done: RepositoryResult?)
    func cachedItems(_ id: String) -> [Item]
    func cachedItems(_ id: String, done: @escaping ([Item]) -> Void)
    func refreshSnapshot(_ id: String, limit: Int, done: @escaping (Result<[Item], Error>) -> Void)
}

final class ConversationRepository: ConversationRepositoryProtocol {
    private let transport: RPCTransport
    private let snapshots = DispatchQueue(label: "CodexPocket.ConversationSnapshots", qos: .userInitiated)
    let cache: SnapshotCache
    var isReady: Bool { transport.state.isReady }

    init(transport: RPCTransport, cache: SnapshotCache) {
        self.transport = transport
        self.cache = cache
    }

    func reconnect() { transport.reconnectNow() }

    func cachedItems(_ id: String) -> [Item] {
        guard let data = cache.load(id), let raw = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return Protocol_.items(fromTurns: raw)
    }

    func cachedItems(_ id: String, done: @escaping ([Item]) -> Void) {
        let namespace = cache.namespace
        snapshots.async { [cache] in
            let data = cache.load(id, namespace: namespace)
            let raw = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            let items = raw.map { Protocol_.items(fromTurns: $0) } ?? []
            DispatchQueue.main.async { done(cache.namespace == namespace ? items : []) }
        }
    }

    func refreshSnapshot(_ id: String, limit: Int, done: @escaping (Result<[Item], Error>) -> Void) {
        let namespace = cache.namespace
        perform(.turns(["threadId": id, "limit": limit, "sortDirection": "desc", "itemsView": "full"])) { [cache, snapshots] result in
            snapshots.async {
                let parsed = result.flatMap { payload -> Result<[Item], Error> in
                    guard cache.namespace == namespace,
                          JSONSerialization.isValidJSONObject(payload),
                          let data = try? JSONSerialization.data(withJSONObject: payload) else {
                        return .failure(RepositoryError(message: "快照未写入，连接目标已变化或数据无效"))
                    }
                    _ = cache.save(id, data, namespace: namespace)
                    guard cache.namespace == namespace else {
                        return .failure(RepositoryError(message: "连接目标已变化"))
                    }
                    return .success(Protocol_.items(fromTurns: payload))
                }
                DispatchQueue.main.async {
                    guard cache.namespace == namespace else {
                        done(.failure(RepositoryError(message: "连接目标已变化"))); return
                    }
                    done(parsed)
                }
            }
        }
    }

    static func request(_ op: ConversationOperation) -> (String, JSONDict) {
        switch op {
        case .submissionStatus(let p): return ("bridge/submission/status", p)
        case .turns(let p): return ("thread/turns/list", p)
        case .resume(let p): return ("thread/resume", p)
        case .start(let p): return ("turn/start", p)
        case .steer(let p): return ("turn/steer", p)
        case .interrupt(let p): return ("turn/interrupt", p)
        case .compact(let p): return ("thread/compact/start", p)
        case .fork(let p): return ("thread/fork", p)
        case .revert(let p): return ("thread/revert", p)
        case .queueAdd(let p): return ("thread/queue/add", p)
        case .queueList(let p): return ("thread/queue/list", p)
        case .queueDelete(let p): return ("thread/queue/delete", p)
        case .queueStart(let p): return ("thread/queue/start", p)
        }
    }

    func perform(_ operation: ConversationOperation, done: RepositoryResult? = nil) {
        let request = Self.request(operation)
        guard case .turns = operation, let id = request.1.str("threadId"), let done else {
            transport.rpc(request.0, request.1, done: done)
            return
        }
        transport.rpc(request.0, request.1) { result in
            // 新会话在首条用户消息前还没有历史文件；这是一页正常空历史。
            if case .failure(let error) = result,
               error.localizedDescription == "thread \(id) is not materialized yet; thread/turns/list is unavailable before first user message" {
                done(.success(["data": []] as JSONDict))
            } else {
                done(result)
            }
        }
    }
}

extension ConversationRepositoryProtocol {
    func cachedItems(_ id: String, done: @escaping ([Item]) -> Void) { done(cachedItems(id)) }
    func perform(_ op: ConversationOperation) { perform(op, done: nil) }
}
