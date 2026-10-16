import Foundation

struct PairingPayload {
    let endpoint: URL
    let token: String
    let name: String
    let certificateSHA256: String?

    private struct Wire: Decodable {
        let version: Int
        let endpoint: String
        let token: String
        let name: String
        let certificateSHA256: String?
    }

    enum Invalid: LocalizedError {
        case link, payload, endpoint
        var errorDescription: String? {
            switch self {
            case .link: return "这不是有效的配对链接，请重新扫描或粘贴电脑端提供的链接。"
            case .payload: return "连接信息不完整或版本不支持，请在电脑端重新生成。"
            case .endpoint: return "连接地址无效，请使用电脑端生成的 WebSocket 地址。"
            }
        }
    }

    static func parse(_ input: String) throws -> PairingPayload {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.utf8.count <= 8192,
              let c = URLComponents(string: raw), c.scheme == "codexpocket",
              c.host == "pair", c.path.isEmpty, c.user == nil, c.password == nil,
              c.port == nil, c.fragment == nil else { throw Invalid.link }
        guard let items = c.queryItems, items.count == 1, items[0].name == "data",
              let encoded = items[0].value, !encoded.isEmpty,
              encoded.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw Invalid.link }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), data.count <= 6144,
              let wire = try? JSONDecoder().decode(Wire.self, from: data), wire.version == 1,
              (1...4096).contains(wire.token.utf8.count),
              wire.token.utf8.allSatisfy({ (33...126).contains($0) }),
              !wire.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              wire.name.count <= 128, !wire.name.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { throw Invalid.payload }
        guard wire.endpoint.utf8.count <= 2048,
              !wire.endpoint.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
              }), let endpoint = URLComponents(string: wire.endpoint),
              let scheme = endpoint.scheme, ["ws", "wss"].contains(scheme),
              let host = endpoint.host, !host.isEmpty,
              endpoint.user == nil, endpoint.password == nil,
              endpoint.path == "/ws", endpoint.query == nil, endpoint.fragment == nil,
              endpoint.port.map({ (1...65535).contains($0) }) ?? true,
              let url = endpoint.url else { throw Invalid.endpoint }
        let pin = wire.certificateSHA256?.uppercased()
        if let pin {
            guard endpoint.scheme == "wss", pin.utf8.count == 64,
                  pin.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) })
            else { throw Invalid.payload }
        }
        return PairingPayload(endpoint: url, token: wire.token,
                              name: wire.name, certificateSHA256: pin)
    }
}

enum AppDeepLink {
    static func threadID(_ url: URL) -> String? {
        guard url.scheme == "codexpocket", url.host == "thread",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 1, let id = components.first,
              (1...128).contains(id.utf8.count), id.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 95
              }) else { return nil }
        return id
    }
}
