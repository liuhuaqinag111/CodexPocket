import Foundation

protocol RepositoryConnection: AnyObject {
    var isReady: Bool { get }
    func reconnect()
}

typealias RepositoryResult = (Result<Any, Error>) -> Void

struct RepositoryError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
