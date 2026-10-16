import Foundation

/// 输入框里的 `/` 命令和 `@` 文件补全。
///
/// 对齐 ChatGPT/Happy：在输入框里打 `/` 弹出命令，打 `@` 弹出文件。
/// 只用**最后一个词**判定，选中后用替换而不是追加 —— 否则
/// `/comp` 会被拼成 `/compact/compact`。
enum Suggestions {

    enum Kind { case none, command, file }

    struct Item: Identifiable, Equatable {
        let id: String
        /// 插进输入框的原文（不含前缀符号）。
        let insert: String
        let title: String
        /// 右侧的灰字说明。
        let detail: String

        static func == (a: Item, b: Item) -> Bool { a.id == b.id }
    }

    /// 内置命令。`server` 为真的走服务端 RPC，假的在本地处理。
    static let commands: [Item] = [
        Item(id: "cmd.compact", insert: "compact", title: "压缩上下文",
             detail: "把更早的内容折叠起来，腾出上下文"),
        Item(id: "cmd.revert", insert: "revert", title: "回退上一轮",
             detail: "把会话历史退回到上一轮之前（不动文件）"),
        Item(id: "cmd.new", insert: "new", title: "新建会话",
             detail: "用默认目录开一个新会话"),
        Item(id: "cmd.model", insert: "model", title: "模型与推理强度",
             detail: "换模型 / 调强度"),
        Item(id: "cmd.usage", insert: "usage", title: "本会话用量",
             detail: "这个会话烧了多少 token"),
        Item(id: "cmd.help", insert: "help", title: "命令说明",
             detail: "列出所有可用命令"),
    ]

    /// 光标处正在输入的那个词。
    ///
    /// 返回它在字符串里的区间 —— 选中补全时是**替换**这个词，
    /// 不是往后追加（追加会拼出 `/compact/compact`）。
    static func pending(_ text: String)
        -> (kind: Kind, token: String, range: Range<String.Index>)? {
        // 末尾那段不含空白的内容就是"正在输入的那个词"。
        var i = text.endIndex
        while i > text.startIndex {
            let p = text.index(before: i)
            if text[p] == " " || text[p] == "\n" || text[p] == "\t" { break }
            i = p
        }
        let word = text[i...]
        guard let first = word.first else { return nil }
        if first == "@" {
            return (.file, String(word.dropFirst()), i..<text.endIndex)
        }
        if first == "/" {
            // `/` 只在**行首**才算命令：正文里的 "TCP/IP" 不该弹面板。
            guard i == text.startIndex || text[text.index(before: i)] == "\n" else {
                return nil
            }
            return (.command, String(word.dropFirst()), i..<text.endIndex)
        }
        return nil
    }

    static func matchCommands(_ token: String) -> [Item] {
        guard !token.isEmpty else { return commands }
        let q = token.lowercased()
        return commands.filter {
            $0.insert.lowercased().hasPrefix(q) || $0.title.contains(token)
        }
    }
}
