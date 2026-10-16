import UIKit
import Foundation



extension ComposerModel {
    /// 现在该弹什么面板。`text` 一变就重算（很便宜，纯字符串操作）。
    func refreshSuggestions() {
        fileSearchSeq &+= 1
        guard let p = Suggestions.pending(text) else {
            suggestions = []
            suggestionKind = .none
            pendingRange = nil
            pendingToken = ""
            return
        }
        pendingToken = p.token
        pendingRange = p.range
        suggestionKind = p.kind
        switch p.kind {
        case .command: suggestions = Suggestions.matchCommands(p.token)
        case .file: searchFiles(p.token)
        case .none: suggestions = []
        }
    }

    /// 选中一条：把正在输入的那个词换成它，光标后面补一个空格。
    func accept(_ item: Suggestions.Item) {
        guard let r = pendingRange, r.upperBound <= text.endIndex else { return }
        let head = text[..<r.lowerBound]
        text = head + item.insert + " "
        suggestions = []
        suggestionKind = .none
        pendingRange = nil
        pendingToken = ""
    }

    func dismissSuggestions() {
        fileSearchSeq &+= 1
        suggestions = []
        suggestionKind = .none
        pendingRange = nil
    }

    func searchFiles(_ q: String) {
        // 空查询不查 —— 目录一大就是几千条，没必要。
        guard q.count >= 1 else { suggestions = []; return }
        let roots = fileRoots()
        guard !roots.isEmpty, repository.isReady else { suggestions = []; return }
        let seq = fileSearchSeq &+ 1
        fileSearchSeq = seq
        repository.searchFiles(query: q, roots: roots) { [weak self] r in
            Task { @MainActor in
                guard let self, seq == self.fileSearchSeq,
                      case .success(let v) = r else { return }
                let rows = (v as? JSONDict)?.dicts("files") ?? []
                // 路径展开成"相对 cwd 的短路径"，只显示前 20 条。
                let base = roots[0]
                self.suggestions = rows.prefix(20).compactMap { d in
                    guard let rel = d.str("path") else { return nil }
                    let shown = FileBrowser.join(base, rel)
                    return Suggestions.Item(id: abs(shown.hashValue) > 0 ? shown : rel,
                                            insert: "@" + shown,
                                            title: ComputerPath.lastComponent(shown),
                                            detail: rel)
                }
            }
        }
    }

    /// `@` 文件搜索的根目录：当前会话的 cwd；没有就用设置里的默认目录。
    func fileRoots() -> [String] {
        let cwd = chat.current?.cwd ?? ""
        if !cwd.isEmpty, ComputerPath.isAbsolute(cwd) { return [cwd] }
        let d = settings.newThreadCwd
        return ComputerPath.isAbsolute(d) ? [d] : []
    }
}

// MARK: - `/` 命令

extension ComposerModel {
    /// 跑一条 `/` 命令。`raw` 不带前导斜杠。
    ///
    /// 返回 true = 这条命令吃掉了输入（要清空输入框）。
    func runCommand(_ raw: String) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        switch name {
        case "compact":
            chat.compact()
            bannerNote("正在压缩上下文…")
        case "revert":
            chat.revertLast()
        case "new":
            newThread()
        case "model":
            onCommand?("model")
        case "usage":
            onCommand?("usage")
        case "help":
            onCommand?("help")
        default:
            bannerNote("没有这个命令：/\(name)")
            return false
        }
        return true
    }

    func bannerNote(_ s: String) {
        chat.banner = s
    }
}

// MARK: - 粘贴

extension ComposerModel {
    /// 把剪贴板里的图片贴进待发区。
    ///
    /// 截图（`UIPasteboard`）里同时有 image 和 string 两种表示，
    /// 优先取图片 —— 用户按「粘贴图片」要的就是图。
    func pasteImage() {
        let pb = UIPasteboard.general
        guard let img = pb.image else {
            uploadError = "剪贴板里没有图片"
            return
        }
        guard let path = Self.writeTemp(img) else {
            uploadError = "存不下这张图"
            return
        }
        uploadError = nil
        upload(path)
    }

    /// 写进临时目录，返回文件路径。
    static func writeTemp(_ img: UIImage) -> String? {
        guard let data = img.jpegData(compressionQuality: 0.85) else { return nil }
        let dir = NSTemporaryDirectory() + "paste"
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        let path = dir + "/" + UUID().uuidString + ".jpg"
        guard (try? data.write(to: URL(fileURLWithPath: path))) != nil else { return nil }
        return path
    }
}
