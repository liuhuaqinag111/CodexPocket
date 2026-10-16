import Foundation

protocol RPCTransport: AnyObject {
    var state: WebSocketTransport.State { get }
    var endpointURL: URL? { get }
    var connectionIdentity: String { get }
    @discardableResult
    func rpc(_ method: String, _ params: JSONDict,
             done: ((Result<Any, Error>) -> Void)?) -> Int
    func reconnectNow()
}

extension RPCTransport {
    var state: WebSocketTransport.State { .ready }
    var endpointURL: URL? { nil }
    var connectionIdentity: String { endpointURL?.absoluteString ?? "" }
    func reconnectNow() {}
}

extension WebSocketTransport: RPCTransport {
    var endpointURL: URL? { url }
}
