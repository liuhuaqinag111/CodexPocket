import Foundation
import CryptoKit

/// 走桥接的 HTTP 请求（取图 / 传图）。
///
/// **不能用 `URLSession.shared`**：直连 IP 时服务端是一张自签证书，
/// 系统信任链过不了，请求直接失败（取图会一直白框）。
/// 这里跟 WebSocket 用同一枚内置指纹，走同一套信任判断。
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
            if SecTrustEvaluateWithError(trust, nil) {
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
            if fp == WebSocketTransport.pinnedCertSHA256 {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
