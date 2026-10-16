import XCTest
import Security
@testable import CodexPocket

/// 桥接的 HTTP 地址拼装。
///
/// 传图和取图都走它。拼错的话表现是"图片上传失败"或图一直白框，
/// 而错误信息里看不出是地址的问题 —— 所以单独测。
@MainActor
final class BridgeURLTests: XCTestCase {
    private func pairing(_ changes: [String: Any] = [:]) throws -> String {
        var payload: [String: Any] = ["version": 1, "endpoint": "wss://pc.example/ws",
                                     "token": "test-token", "name": "Windows PC"]
        payload.merge(changes) { _, new in new }
        let encoded = try JSONSerialization.data(withJSONObject: payload).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "codexpocket://pair?data=" + encoded
    }

    func testPairingImportsPublicEndpointAndName() throws {
        let p = try PairingPayload.parse(pairing())
        XCTAssertEqual(p.endpoint.absoluteString, "wss://pc.example/ws")
        XCTAssertEqual(p.name, "Windows PC")
        XCTAssertEqual(p.token, "test-token")
    }

    func testPairingRejectsInvalidPayloadFields() throws {
        for change in [["version": 2], ["token": ""], ["token": "a\nb"],
                       ["name": ""], ["name": String(repeating: "a", count: 129)],
                       ["certificateSHA256": "bad"]] as [[String: Any]] {
            XCTAssertThrowsError(try PairingPayload.parse(pairing(change)))
        }
    }

    func testPairingRejectsAmbiguousAndUnsafeAddresses() throws {
        for endpoint in ["https://pc.example/ws", "file:///tmp/key", "wss://user:pass@pc.example/ws",
                         "wss://pc.example/ws?token=leak", "wss://pc.example/ws#fragment",
                         "wss://pc.example:65536/ws", "wss://pc.example/other"] {
            XCTAssertThrowsError(try PairingPayload.parse(pairing(["endpoint": endpoint])))
        }
        let valid = try pairing()
        XCTAssertThrowsError(try PairingPayload.parse(valid.replacingOccurrences(of: "codexpocket:", with: "https:")))
        XCTAssertThrowsError(try PairingPayload.parse(valid + "&data=duplicate"))
        XCTAssertThrowsError(try PairingPayload.parse(String(repeating: "a", count: 8193)))
    }

    func testOnlyExplicitThreadDeepLinksOpenThreads() {
        XCTAssertEqual(AppDeepLink.threadID(URL(string: "codexpocket://thread/thread-1")!), "thread-1")
        for input in ["https://thread/thread-1", "codexpocket://pair?data=abc",
                      "codexpocket://thread", "codexpocket://thread/a/b", "codexpocket://other/id"] {
            XCTAssertNil(AppDeepLink.threadID(URL(string: input)!))
        }
    }

    func testFreshPreferencesDoNotConnectToAnAuthorServer() throws {
        let suite = "PairingTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PreferencesModel(defaults: defaults, environment: [:], savedToken: "")
        XCTAssertEqual(settings.host, "")
        XCTAssertNil(settings.url)
        XCTAssertFalse(settings.isConfigured)
        defaults.set("wss://old.example/ws", forKey: "host")
        let existing = PreferencesModel(defaults: defaults, environment: [:], savedToken: "old-token")
        XCTAssertEqual(existing.host, "wss://old.example/ws")
        XCTAssertTrue(existing.isConfigured)
    }

    func testCertificatePinsAreScopedToEndpointAuthority() {
        XCTAssertEqual(EndpointTrust.key(host: "[::1]", port: 443),
                       EndpointTrust.key(host: "::1", port: 443))
        XCTAssertEqual(EndpointTrust.key(host: "PC.Example", port: 443),
                       EndpointTrust.key(host: "pc.example", port: 443))
        XCTAssertNotEqual(EndpointTrust.key(host: "pc.example", port: 443),
                          EndpointTrust.key(host: "other.example", port: 443))
        XCTAssertNotEqual(EndpointTrust.key(host: "pc.example", port: 443),
                          EndpointTrust.key(host: "pc.example", port: 8443))
    }

    func testSelfSignedPinAndPrivateNetworkPairing() throws {
        let pin = String(repeating: "ab", count: 32)
        let secure = try PairingPayload.parse(pairing(["certificateSHA256": pin]))
        XCTAssertEqual(secure.certificateSHA256, pin.uppercased())
        let privateLink = try pairing(["endpoint": "ws://203.0.113.10:62113/ws"])
        XCTAssertEqual(try PairingPayload.parse(privateLink).endpoint.scheme, "ws")
        XCTAssertThrowsError(try PairingPayload.parse(pairing([
            "endpoint": "ws://203.0.113.10:62113/ws", "certificateSHA256": pin])))
    }

    func testSavedPinCannotTrustAnotherAddressOrPort() throws {
        let host = UUID().uuidString.lowercased() + ".example"
        let endpoint = try XCTUnwrap(URL(string: "wss://\(host)/ws"))
        let pin = String(repeating: "A", count: 64)
        defer { EndpointTrust.save(nil, for: endpoint) }
        let status = EndpointTrust.save(pin, for: endpoint)
        #if targetEnvironment(simulator)
        try XCTSkipIf(status == errSecMissingEntitlement || status == errSecNotAvailable,
                      "模拟器 Keychain 不可用，SecItem 写入状态：\(status)")
        #endif
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertEqual(Keychain.read(EndpointTrust.key(host: host, port: 443)).status, errSecSuccess)
        XCTAssertEqual(EndpointTrust.pin(host: host, port: 443), pin)
        XCTAssertNil(EndpointTrust.pin(host: host, port: 8443))
        XCTAssertNil(EndpointTrust.pin(host: "other-" + host, port: 443))
    }

    func testConfirmingPairingPersistsTheSelectedComputer() throws {
        let suite = "PairingTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var secureValues: [String: String] = [:]
        let settings = PreferencesModel(defaults: defaults, environment: [:], savedToken: "",
            secureRead: { secureValues[$0] }, secureWrite: { value, key in
                secureValues[key] = value.isEmpty ? nil : value
                return errSecSuccess
            })
        let candidate = try PairingPayload.parse(pairing())
        XCTAssertFalse(settings.isConfigured, "预览连接不能写入现有配置")
        try settings.savePairing(candidate)
        XCTAssertEqual(settings.host, "wss://pc.example/ws")
        XCTAssertEqual(settings.token, "test-token")
        XCTAssertEqual(secureValues["token"], "test-token")
        XCTAssertEqual(settings.computerName, "Windows PC")
        XCTAssertTrue(settings.isConfigured)
        XCTAssertNil(defaults.string(forKey: "token"), "令牌只能保存在钥匙串")
    }

    func testPairingPersistenceFailureKeepsThePreviousConnectionAndPreview() throws {
        let suite = "PairingTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://previous.example/ws", forKey: "host")
        let settings = PreferencesModel(defaults: defaults, environment: [:], savedToken: "previous-token",
                                       secureWrite: { _, _ in errSecNotAvailable })
        let store = AppCoordinator(preferences: settings)
        store.rpc.want = true
        defer { store.rpc.disconnect() }
        store.showPairing = true
        store.previewPairing(try pairing())
        XCTAssertFalse(store.confirmPairing())
        XCTAssertEqual(settings.host, "wss://previous.example/ws")
        XCTAssertEqual(settings.token, "previous-token")
        XCTAssertTrue(store.rpc.want, "保存失败不能断开原来的连接")
        XCTAssertTrue(store.showPairing)
        XCTAssertNotNil(store.pairingCandidate)
        XCTAssertTrue(store.pairingError?.contains("钥匙串") == true)
    }

    func testFailedTokenWriteRestoresThePreviousPin() throws {
        let suite = "PairingTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("wss://previous.example/ws", forKey: "host")
        let key = EndpointTrust.key(host: "pc.example", port: 443)
        let oldPin = String(repeating: "B", count: 64)
        var secureValues = [key: oldPin, "token": "previous-token"]
        let settings = PreferencesModel(defaults: defaults, environment: [:], savedToken: "previous-token",
            secureRead: { secureValues[$0] }, secureWrite: { value, key in
                if key == "token" { return errSecAuthFailed }
                secureValues[key] = value.isEmpty ? nil : value
                return errSecSuccess
            })
        let candidate = try PairingPayload.parse(pairing(["certificateSHA256": String(repeating: "A", count: 64)]))
        XCTAssertThrowsError(try settings.savePairing(candidate))
        XCTAssertEqual(secureValues[key], oldPin)
        XCTAssertEqual(secureValues["token"], "previous-token")
        XCTAssertEqual(settings.host, "wss://previous.example/ws")
        XCTAssertEqual(settings.token, "previous-token")
    }

    /// 直连 IP（IP 里没有点号以外的字符，443 不写进 URL）。
    func testIPHostOmits443() {
        let s = PreferencesModel()
        s.host = "203.0.113.10"
        s.port = "443"
        s.token = "abc"
        let u = s.bridge(path: "/upload")
        XCTAssertEqual(u?.scheme, "https")
        XCTAssertEqual(u?.host, "203.0.113.10")
        XCTAssertNil(u?.port, "443 不该写进 URL")
        XCTAssertEqual(u?.path, "/upload")
        XCTAssertTrue(u?.query?.contains("t=abc") ?? false, "少了令牌，桥接会回 401")
    }

    /// 本机调试：ws://127.0.0.1:62113 → http://127.0.0.1:62113。
    func testLocalUsesHTTP() throws {
        let s = PreferencesModel()
        s.host = "127.0.0.1"
        s.port = "62113"
        s.token = "abc"
        let u = s.bridge(path: "/file", query: [URLQueryItem(name: "path", value: "/tmp/a.png")])
        XCTAssertEqual(u?.scheme, "http")
        XCTAssertEqual(u?.port, 62113)
        let items = URLComponents(url: try XCTUnwrap(u), resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        XCTAssertTrue(items.contains(URLQueryItem(name: "path", value: "/tmp/a.png")),
                      "取图少了 path 参数：\(String(describing: u))")
    }

    /// 走域名时也要能拼出来（备用通道）。
    func testDomainHost() {
        let s = PreferencesModel()
        s.host = "relay.example"
        s.port = "443"
        s.token = "abc"
        let u = s.bridge(path: "/upload")
        XCTAssertEqual(u?.scheme, "https")
        XCTAssertEqual(u?.host, "relay.example")
        XCTAssertNil(u?.port)
    }

    func testHTTPSPasteKeepsMediaEncrypted() {
        let s = PreferencesModel()
        let host = s.host, port = s.port
        defer { s.host = host; s.port = port }
        s.host = "https://example.invalid:8443"
        XCTAssertEqual(s.url?.scheme, "wss")
        XCTAssertEqual(s.url?.path, "/ws")
        XCTAssertEqual(s.bridge(path: "/upload")?.scheme, "https")
        XCTAssertEqual(s.bridge(path: "/upload")?.port, 8443)
    }

    func testNonWebSocketSchemesCannotBecomeHTTPUploads() {
        let s = PreferencesModel()
        let host = s.host
        defer { s.host = host }
        for invalid in ["ftp://example.invalid", "file:///tmp/key", "wss://user:secret@example.invalid"] {
            s.host = invalid
            XCTAssertNil(s.url)
            XCTAssertNil(s.bridge(path: "/upload"))
        }
    }

    func testBareHostAndPortAreParsedAsAuthority() {
        let s = PreferencesModel()
        let host = s.host
        defer { s.host = host }
        s.host = "localhost:62113"
        XCTAssertEqual(s.url?.scheme, "ws")
        XCTAssertEqual(s.url?.host, "localhost")
        XCTAssertEqual(s.url?.port, 62113)
    }
}
