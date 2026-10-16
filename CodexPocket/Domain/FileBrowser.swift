import Foundation

/// 文件树里的一行。
///
/// 服务端 `fs/readDirectory` 给的是 `{fileName, isDirectory, isFile}`。
struct FileEntry: Identifiable, Hashable {
    let name: String
    let isDir: Bool
    let isSymlink: Bool

    var id: String { name }

    static func parse(_ json: JSONDict) -> [FileEntry] {
        let rows = json.dicts("entries").compactMap { e -> FileEntry? in
            guard let n = e.str("fileName"), !n.isEmpty else { return nil }
            return FileEntry(name: n,
                             isDir: (e["isDirectory"] as? Bool) ?? false,
                             isSymlink: (e["isSymlink"] as? Bool) ?? false)
        }
        // 目录在前，同类按名字排（大小写不敏感，稳一点）。
        return rows.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

/// 文件内容。
///
/// `fs/readFile` 回的是 `{dataBase64}` —— 整个文件塞进一条消息。
enum FileText {
    /// 超过这个大小不读。服务端会把整份 base64 发过来，
    /// 几十兆的文件会直接把 socket 和内存顶爆。
    static let maxBytes = 2 * 1024 * 1024

    static func isTooLarge(byteCount: Int) -> Bool { byteCount > maxBytes }

    /// base64 → 文本。**二进制返回 nil** —— 塞进 `Text` 会卡死并显示乱码。
    static func decode(_ json: JSONDict) -> String? {
        guard let b64 = json.str("dataBase64"),
              let data = Data(base64Encoded: b64) else { return nil }
        guard !isBinary(data) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 前 4KB 里出现 NUL 就认定是二进制。
    static func isBinary(_ d: Data) -> Bool {
        let head = d.prefix(4096)
        return head.contains(0)
    }
}

/// 路径拼接。结尾斜杠要吃掉，否则会拼出 `//`。
enum FileBrowser {
    static func join(_ dir: String, _ name: String) -> String {
        let base = ComputerPath.normalized(dir)
        let child = ComputerPath.isWindows(base) ? name.replacingOccurrences(of: "\\", with: "/") : name
        return base + (base.hasSuffix("/") ? "" : "/") + child
    }
}

/// 电脑路径按其自身格式处理，不使用 iPhone 的文件系统规则解释 Windows 路径。
enum ComputerPath {
    static func isWindows(_ path: String) -> Bool {
        let head = Array(path.utf8.prefix(3))
        let drive = head.count == 3 && ((65...90).contains(head[0]) || (97...122).contains(head[0]))
            && head[1] == 58 && (head[2] == 47 || head[2] == 92)
        return drive || path.hasPrefix("\\\\") || path.hasPrefix("//")
    }

    static func normalized(_ raw: String) -> String {
        var path = raw
        if raw.hasPrefix("file:"), let url = URL(string: raw), url.isFileURL {
            path = url.path
            if let host = url.host, !host.isEmpty, host.lowercased() != "localhost" { path = "//" + host + path }
            else if path.hasPrefix("/"), isWindows(String(path.dropFirst())) { path.removeFirst() }
        }
        if isWindows(path) { path = path.replacingOccurrences(of: "\\", with: "/") }
        while path.count > 1 && path.hasSuffix("/") {
            if isWindows(path), path.count == 3, path.dropFirst().hasPrefix(":/") { break }
            path.removeLast()
        }
        return path
    }

    static func comparisonKey(_ path: String) -> String {
        let normalized = normalized(path)
        return isWindows(normalized) ? normalized.lowercased() : normalized
    }

    static func contains(_ path: String, in root: String) -> Bool {
        let path = comparisonKey(path), root = comparisonKey(root)
        guard !path.isEmpty, !root.isEmpty else { return false }
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    static func isAbsolute(_ path: String) -> Bool {
        let normalized = normalized(path)
        return normalized.hasPrefix("/") || isWindows(normalized)
    }

    static func lastComponent(_ path: String) -> String {
        (normalized(path) as NSString).lastPathComponent
    }

    static func imageSource(_ raw: String) -> String {
        if raw.hasPrefix("file:") || isWindows(raw) { return normalized(raw) }
        return raw.hasPrefix("/") ? (raw.removingPercentEncoding ?? raw) : raw
    }

    static func isRemoteImage(_ raw: String) -> Bool {
        if let scheme = URL(string: raw)?.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            return true
        }
        let path = imageSource(raw)
        guard isAbsolute(path) else { return false }
        let phoneRoots = [NSHomeDirectory(), "/var/mobile", "/private/var/mobile"]
        return !phoneRoots.contains { contains(path, in: $0) }
    }
}
