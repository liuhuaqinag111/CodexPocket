import Foundation
import Combine
import Security

/// 连接参数与本地偏好。
@MainActor
final class PreferencesModel: ObservableObject {
    @Published var host: String {
        didSet { d.set(host, forKey: "host") }
    }
    @Published var port: String {
        didSet { d.set(port, forKey: "port") }
    }
    @Published var token: String {
        didSet { if !applyingPairing { _ = secureWrite(token, "token") } }
    }
    /// 切后台用无声音频保活。
    @Published var keepAlive: Bool {
        didSet { d.set(keepAlive, forKey: "keepAlive") }
    }
    /// 默认模型与推理强度（新建会话时用）。
    @Published var defaultModel: String {
        didSet { d.set(defaultModel, forKey: "defaultModel") }
    }
    /// 新建会话用的工作目录。
    @Published var defaultCwd: String {
        didSet { d.set(defaultCwd, forKey: "defaultCwd") }
    }
    @Published var defaultEffort: String {
        didSet { d.set(defaultEffort, forKey: "defaultEffort") }
    }
    /// 展开的项目分组，重启保持。
    @Published var openProjects: Set<String> {
        didSet { d.set(Array(openProjects), forKey: "openProjects") }
    }
    /// **收起**的项目分组。
    ///
    /// 默认全展开（用户："看不到项目里的会话" —— 之前默认全收起，
    /// 项目又排在无项目会话后面，得一直往下滑才找得到）。
    /// 存"收起"的名单，新项目天然是展开的。
    @Published var closedProjects: Set<String> {
        didSet { d.set(Array(closedProjects), forKey: "closedProjects") }
    }

    private let d: UserDefaults
    private let secureRead: (String) -> String?
    private let secureWrite: (String, String) -> OSStatus
    private var applyingPairing = false

    init(defaults: UserDefaults = .standard,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         savedToken: String? = nil,
         secureRead: @escaping (String) -> String? = Keychain.get,
         secureWrite: @escaping (String, String) -> OSStatus = Keychain.set) {
        d = defaults
        self.secureRead = secureRead
        self.secureWrite = secureWrite
        let env = environment
        host = env["CODEX_PHONE_HOST"] ?? d.string(forKey: "host") ?? ""
        port = env["CODEX_PHONE_PORT"] ?? d.string(forKey: "port") ?? "443"
        token = env["CODEX_PHONE_TOKEN"] ?? savedToken ?? secureRead("token") ?? ""
        keepAlive = d.object(forKey: "keepAlive") as? Bool ?? true
        defaultModel = d.string(forKey: "defaultModel") ?? ""
        defaultEffort = d.string(forKey: "defaultEffort") ?? ""
        // 新会话的工作目录。留空表示"沿用最近一个会话的目录"。
        // 注意别用 NSHomeDirectory() —— 在 App 里那是沙盒容器路径，
        // 传给电脑端等于一个不存在的目录。
        defaultCwd = d.string(forKey: "defaultCwd") ?? ""
        openProjects = Set(d.stringArray(forKey: "openProjects") ?? [])
        closedProjects = Set(d.stringArray(forKey: "closedProjects") ?? [])
        // 测试/调试用：允许环境变量直接注入令牌并记住。
        if let t = env["CODEX_PHONE_TOKEN"], !t.isEmpty { _ = secureWrite(t, "token") }
    }

    /// 新建会话实际用的工作目录。
    ///
    /// 空 → `~`：实测服务端会把 `~` 展开成 `/Users/<user>`。
    /// **不能沿用上一个会话的 cwd** —— 用户报"打开新会话是旧工作目录"，
    /// 新会话会掉进旧项目分组、被当成那个项目的会话。
    /// 也不能不传：不带 cwd 的 `thread/start` 会被服务端兜成 `/`，等于扫全盘。
    var newThreadCwd: String {
        let t = defaultCwd.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "~" : t
    }

    /// 把用户填的域名/端口拼成 WebSocket 地址。
    ///
    /// 允许直接粘完整地址（`wss://域名/ws`），也允许只填域名。
    /// 端口 443 不写进 URL —— 走隧道时它是默认端口，写上去反而多一层。
    var url: URL? {
        let s = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let explicitScheme = s.contains("://")
        guard var c = URLComponents(string: explicitScheme ? s : "wss://" + s),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil else { return nil }
        switch c.scheme?.lowercased() {
        case "https", "wss": c.scheme = "wss"
        case "http", "ws": c.scheme = "ws"
        default: return nil
        }
        if !explicitScheme {
            c.scheme = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) ? "ws" : "wss"
            let p = port.trimmingCharacters(in: .whitespacesAndNewlines)
            if c.port == nil, !p.isEmpty, p != "443" {
                guard let n = Int(p), (1...65535).contains(n) else { return nil }
                c.port = n
            }
        }
        if let p = c.port, !(1...65535).contains(p) { return nil }
        if c.path.isEmpty || c.path == "/" { c.path = "/ws" }
        c.fragment = nil
        return c.url
    }

    /// 走域名时端口已经在 URL 里，443 不用写。
    var displayHost: String { port == "443" ? host : "\(host):\(port)" }

    var isConfigured: Bool { url != nil && !token.isEmpty }

    var computerName: String { d.string(forKey: "computerName") ?? "" }

    /// 只在用户确认连接对象之后调用。
    func savePairing(_ pairing: PairingPayload) throws {
        let previousPin = pairing.endpoint.host.flatMap {
            secureRead(EndpointTrust.key(host: $0, port: pairing.endpoint.port ?? 443))
        }
        let pinStatus = EndpointTrust.save(pairing.certificateSHA256, for: pairing.endpoint, write: secureWrite)
        guard pinStatus == errSecSuccess else { throw PairingStorageError(status: pinStatus) }
        let tokenStatus = secureWrite(pairing.token, "token")
        guard tokenStatus == errSecSuccess else {
            EndpointTrust.save(previousPin, for: pairing.endpoint, write: secureWrite)
            throw PairingStorageError(status: tokenStatus)
        }
        applyingPairing = true
        host = pairing.endpoint.absoluteString
        port = String(pairing.endpoint.port ?? (pairing.endpoint.scheme == "wss" ? 443 : 80))
        token = pairing.token
        applyingPairing = false
        d.set(pairing.name, forKey: "computerName")
    }

    struct PairingStorageError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "连接信息没能保存到钥匙串（错误 \(status)）。原来的连接保持不变，请重试。"
        }
    }

    /// 桥接的 HTTP 基地址（取图 / 传图用）。
    ///
    /// 跟 WebSocket 同一条链路、同一份证书，只是把 ws→http。
    /// 传图**必须**走 HTTP，不能走 JSON-RPC：那条 WebSocket 一断，
    /// 在途的 base64 大包就整个丢了（用户报的"图片上传失败：连接已断开"）。
    /// HTTP 请求是独立连接，跟 WebSocket 的抖动互不影响。
    func bridge(path: String, query: [URLQueryItem] = []) -> URL? {
        guard let ws = url, let h = ws.host else { return nil }
        var c = URLComponents()
        c.scheme = ws.scheme == "wss" ? "https" : "http"
        c.host = h
        if let p = ws.port, p != (c.scheme == "https" ? 443 : 80) { c.port = p }
        c.path = path
        c.queryItems = query + [URLQueryItem(name: "t", value: token)]
        return c.url
    }
}
