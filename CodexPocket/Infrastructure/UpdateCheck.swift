import Foundation
import SwiftUI

/// 在线升级。
///
/// 服务端（桥接）在 `/version` 报当前可下载的包版本；App 拿它跟自己的
/// `Build.stamp` 比，有新的就在设置页显示「有新版本 · 立即升级」。
///
/// **为什么不能做到 App AppCoordinator 那种"点一下自动装完"**：
/// 这个包是**未签名**的，iOS 不认。真正的静默/一键安装要么走
/// `itms-services://`（需要**已签名**的包 + 该设备的描述文件），
/// 要么靠设备上的自签工具（Sideloadly / AltStore / TrollStore）。
/// 所以这里做的是"**帮你把包拉到手**"这一步：点一下就把 IPA 下到
/// 「文件」，然后引导你去装。省掉的是"开浏览器、找地址、等下载"。
@MainActor
enum UpdateCheck {

    struct Info: Equatable {
        var build: String
        var size: Int
        var url: URL
        /// 有没有比当前这个包新的版本。
        var isNewer: Bool
    }

    /// 当前 App 的版本标记（跟桥接报的同一个格式）。
    nonisolated static var current: String { Build.stamp }

    /// 拉一次 `/version`。失败就返回 nil（不打扰用户）。
    static func fetch(_ settings: PreferencesModel) async -> Info? {
        guard let url = settings.bridge(path: "/version") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, response) = try? await NetSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? JSONDict,
              let build = obj.str("build"), !build.isEmpty,
              let link = obj.str("url"), let ipa = URL(string: link) else { return nil }
        let size = obj.int("size") ?? 0
        return Info(build: build, size: size, url: ipa,
                    isNewer: isNewer(remote: build, local: current))
    }

    /// 远端版本是不是比本地新。
    ///
    /// 版本标记形如 `2026-10-07 v61 不再抢桌面端的会话锁`。取其中的
    /// **日期 + v 号**比大小；解析不出来就一律当成"有新版"——
    /// 宁可多提示一次，也别让人卡在旧版上（用户就是靠这个发现自己装的是旧的）。
    nonisolated static func isNewer(remote: String, local: String) -> Bool {
        guard let a = versionKey(remote), let b = versionKey(local) else {
            return remote != local
        }
        return a > b
    }

    /// `2026-10-07 v61 …` → `20261007.61`
    nonisolated static func versionKey(_ s: String) -> String? {
        let parts = s.split(separator: " ")
        guard let day = parts.first else { return nil }
        let d = day.split(separator: "-")
        guard d.count == 3, let y = Int(d[0]), let m = Int(d[1]), let dd = Int(d[2]) else { return nil }
        // 版本号支持 `v69` 和小版本 `v69.1` 两种写法。
        //
        // 以前只认 `Int(p.dropFirst())`，`"69.1"` 解析出来是 nil → v 归 0，
        // 于是「v69.1」被判成比「v64」还旧，App 的在线升级永远不提示
        // （实测：`v69.1` 的 key 是 `20261008.0`，v64 是 `20261008.64`）。
        //
        // 编码成 `主 * 100 + 次` 并**补零到四位**：位数固定才能直接按字符串
        // 比大小（"0700" < "6900" < "7000"，对应 v7 < v69 < v70）。
        var v = 0
        for p in parts.dropFirst() where p.hasPrefix("v") {
            let bits = p.dropFirst().split(separator: ".")
            guard let first = bits.first, let major = Int(first) else { return nil }
            if major >= 0 {
                let minor = bits.count > 1 ? (Int(bits[1]) ?? 0) : 0
                v = major * 100 + minor
                break
            }
        }
        return String(format: "%04d%02d%02d.%04d", y, m, dd, v)
    }

    /// 下载 IPA 到「文件」。
    ///
    /// 存到 App 自己的 Documents 目录 —— 它出现在「文件」App 的
    /// "我的 iPhone → CodexPocket" 里，Sideloadly 那边也能直接选。
    /// 用 App 内的 URLSession 下载而不是打开浏览器：**能拿到进度**，
    /// 而且不会被 Safari 的"是否下载"拦一道。
    static func download(_ info: Info,
                         progress: @escaping (Double) -> Void) async -> URL? {
        var req = URLRequest(url: info.url)
        req.timeoutInterval = 120
        guard let (tmp, response) = try? await NetSession.shared.download(for: req) else { return nil }
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard validPackage(at: tmp, response: response) else { return nil }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dst = dir.appendingPathComponent("CodexPocket-\(info.build.prefix(10)).ipa")
        try? FileManager.default.removeItem(at: dst)
        guard (try? FileManager.default.moveItem(at: tmp, to: dst)) != nil else { return nil }
        progress(1)
        return dst
    }

    /// 装包引导页的地址（`itms-services` 一旦包是签名的就能直接装）。
    ///
    /// 未签名时点它 iOS 会报"无法安装" —— 所以界面上要写清楚，
    /// 别让人以为是 App 坏了。
    static func installURL(_ settings: PreferencesModel, ipa: URL) -> URL? {
        guard let manifest = settings.bridge(path: "/manifest", query: [
            URLQueryItem(name: "ipa", value: ipa.absoluteString),
        ]) else { return nil }
        var c = URLComponents()
        c.scheme = "itms-services"
        c.host = ""
        c.queryItems = [URLQueryItem(name: "action", value: "download-manifest"),
                        URLQueryItem(name: "url", value: manifest.absoluteString)]
        return c.url
    }

    nonisolated static func validPackage(at file: URL, response: URLResponse) -> Bool {
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x50, 0x4b, 0x03, 0x04])
    }
}
