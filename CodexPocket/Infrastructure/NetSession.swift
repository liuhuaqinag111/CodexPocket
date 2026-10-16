import Foundation
import CryptoKit
import Security

enum EndpointTrust {
    /// HTTP 与 WebSocket 的安全通道共享一个 host:port 作用域。
    static func key(host: String, port: Int) -> String {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let authority = "https://\(normalized):\(port)"
        let hash = SHA256.hash(data: Data(authority.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "certificateSHA256." + hash
    }

    static func pin(host: String, port: Int) -> String? {
        Keychain.get(key(host: host, port: port))
    }

    @discardableResult
    static func save(_ pin: String?, for endpoint: URL,
                     write: (String, String) -> OSStatus = Keychain.set) -> OSStatus {
        guard endpoint.scheme == "wss", let host = endpoint.host else { return errSecSuccess }
        return write(pin ?? "", key(host: host, port: endpoint.port ?? 443))
    }
}

/// HTTP 与 WebSocket 共用系统 TLS 信任及用户明确导入的端点证书。
enum NetSession {
    static let shared: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg, delegate: Pinner(), delegateQueue: nil)
    }()

    final class Pinner: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                      URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod
                    == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            guard let expected = EndpointTrust.pin(host: challenge.protectionSpace.host,
                                                 port: challenge.protectionSpace.port) else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first,
                  let der = SecCertificateCopyData(leaf) as Data? else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let fp = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
            if fp == expected {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
