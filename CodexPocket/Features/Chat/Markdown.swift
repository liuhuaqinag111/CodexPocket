import SwiftUI
import UIKit

/// 块级 Markdown 渲染。
///
/// `AttributedString(markdown:)` 只处理行内语法，标题/列表/代码围栏会糊成一片，
/// 所以这里按块切分、逐块给样式。解析结果按内容缓存 —— 流式时每 55ms 就会
/// 重新求值一次，不缓存的话主线程全被解析吃掉。
enum Markdown {

    enum Block {
        case heading(Int, String)
        case paragraph(String)
        case code(String, String)
        case bullet([String])
        case ordered([String])
        case quote(String)
        case rule
        case table(headers: [String], rows: [[String]])
        /// ```mermaid 围栏。mermaid 是 JS 库，交给 `MermaidBlock` 渲染。
        case mermaid(String)
        case image(alt: String, url: String)
    }

    static func parse(_ raw: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String] = []
        var fence: String?
        var bullets: [String] = []
        var ordered: [String] = []
        var tableLines: [String] = []

        func flushPara() {
            let t = para.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(contentsOf: imageParagraph(t)) }
            para.removeAll()
        }
        func flushLists() {
            if !bullets.isEmpty { out.append(.bullet(bullets)); bullets.removeAll() }
            if !ordered.isEmpty { out.append(.ordered(ordered)); ordered.removeAll() }
        }
        func flushFence() {
            guard let f = fence else { return }
            let body = code.joined(separator: "\n")
            code.removeAll()
            fence = nil
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            out.append(f.lowercased() == "mermaid" ? .mermaid(body) : .code(f, body))
        }
        func flushTable() {
            if tableLines.count >= 2 {
                if let tbl = parseTable(tableLines) {
                    out.append(tbl)
                } else {
                    for l in tableLines { out.append(.paragraph(l)) }
                }
            } else if !tableLines.isEmpty {
                for l in tableLines { out.append(.paragraph(l)) }
            }
            tableLines.removeAll()
        }
        func flushAll() { flushPara(); flushLists(); flushTable() }

        for line in raw.components(separatedBy: .newlines) {
            if fence != nil {
                if line.hasPrefix("```") { flushFence() }
                else { code.append(line) }
                continue
            }
            if line.hasPrefix("```") {
                flushAll()
                fence = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flushAll(); continue }
            if isTableLine(trimmed) {
                flushPara(); flushLists()
                tableLines.append(trimmed)
                continue
            } else {
                flushTable()
            }
            if let h = heading(line) { flushAll(); out.append(.heading(h.0, h.1)); continue }
            if line.hasPrefix("> ") { flushPara(); flushLists(); out.append(.quote(String(line.dropFirst(2)))); continue }
            if trimmed == "---" { flushAll(); out.append(.rule); continue }
            if let b = bullet(line) { flushPara(); ordered.isEmpty ? () : flushLists(); bullets.append(b); continue }
            if let o = orderedItem(line) { flushPara(); bullets.isEmpty ? () : flushLists(); ordered.append(o); continue }
            flushLists()
            para.append(line)
        }
        flushFence()
        flushAll()
        return out
    }

    private static let imagePattern = try! NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\((<[^>]+>|(?:[^()\n]|\([^()\n]*\))+)\)"#)

    private static func imageParagraph(_ text: String) -> [Block] {
        let ns = text as NSString
        let matches = imagePattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out: [Block] = [], offset = 0
        for match in matches {
            let prefix = ns.substring(to: match.range.location)
            if prefix.filter({ $0 == "`" }).count % 2 == 1 { continue }
            let before = ns.substring(with: NSRange(location: offset, length: match.range.location - offset))
            if !before.isEmpty { out.append(.paragraph(before)) }
            let url = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            out.append(.image(alt: ns.substring(with: match.range(at: 1)), url: url))
            offset = NSMaxRange(match.range)
        }
        if offset < ns.length { out.append(.paragraph(ns.substring(from: offset))) }
        return out
    }

    private static func heading(_ l: String) -> (Int, String)? {
        var n = 0
        for c in l { if c == "#" { n += 1 } else { break } }
        guard n > 0, n <= 6, l.dropFirst(n).hasPrefix(" ") else { return nil }
        return (n, String(l.dropFirst(n + 1)))
    }

    private static func bullet(_ l: String) -> String? {
        let t = l.drop(while: { $0 == " " })
        for mark in ["- ", "* ", "+ "] where t.hasPrefix(mark) { return String(t.dropFirst(2)) }
        return nil
    }

    private static func orderedItem(_ l: String) -> String? {
        let t = l.drop(while: { $0 == " " })
        guard let dot = t.firstIndex(of: "."), dot > t.startIndex else { return nil }
        let num = t[t.startIndex..<dot]
        guard !num.isEmpty, num.allSatisfy(\.isNumber) else { return nil }
        let rest = t[t.index(after: dot)...]
        guard rest.hasPrefix(" ") else { return nil }
        return String(rest.dropFirst())
    }

    private static func isTableLine(_ l: String) -> Bool {
        l.hasPrefix("|") && l.contains("|")
    }

    private static func parseTable(_ lines: [String]) -> Block? {
        guard lines.count >= 2 else { return nil }
        let splitRow: (String) -> [String] = { line in
            var cells = line.split(separator: "|", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            if cells.first?.isEmpty == true { cells.removeFirst() }
            if cells.last?.isEmpty == true { cells.removeLast() }
            return cells
        }
        let headers = splitRow(lines[0])
        let delimiter = splitRow(lines[1])
        guard !headers.isEmpty, delimiter.count == headers.count else { return nil }
        let isDelim = delimiter.allSatisfy { cell in
            cell.allSatisfy { $0 == "-" || $0 == ":" } && cell.contains("-")
        }
        guard isDelim else { return nil }
        var rows: [[String]] = []
        for l in lines.dropFirst(2) {
            let row = splitRow(l)
            if !row.isEmpty { rows.append(row) }
        }
        return .table(headers: headers, rows: rows)
    }
}

// MARK: - 解析缓存

extension Markdown {
    private static let limit = 400
    private static var cache: [String: [Block]] = [:]
    private static var order: [String] = []
    static let blockCacheBudget = 4 * 1024 * 1024
    private(set) static var blockCacheCost = 0

    private static func cacheBlocks(_ raw: String, _ blocks: [Block]) {
        let cost = raw.utf8.count * 2
        guard cost <= blockCacheBudget else { return }
        cache[raw] = blocks
        blockCacheCost += cost
        order.append(raw)
        while order.count > limit || blockCacheCost > blockCacheBudget {
            let old = order.removeFirst()
            cache.removeValue(forKey: old)
            blockCacheCost -= old.utf8.count * 2
        }
    }

    /// 流式前缀复用的一格。
    ///
    /// 空行是这个解析器里唯一的"块边界"（`flushAll()` 就在空行上调用），
    /// 所以「到最后一个空行之前」的那一段，单独解析的结果跟整篇解析的前缀
    /// 完全一样。流式时正文每次只长一点点，真正需要重排的只有最后一个空行
    /// 之后的那几十个字。
    ///
    /// 实测：10658 字的思考，266 次流式刷新从头解析要 **1458ms**。
    private struct Live {
        var prefix: String      // 上次解析过的原文（整篇）
        var stable: [Block]     // 上面那篇里"到最后一个空行"为止的解析结果
        var stableLen: Int      // 稳定前缀的字数
        var fenceOpen: Bool     // 稳定前缀的末尾是不是还在 ``` 围栏里
    }
    private static var live: [Live] = []
    private static let liveLimit = 4

    /// 扫一遍 `s`，找出最后一个"稳定边界"（空行末尾，且不在围栏里）。
    ///
    /// 返回边界处的**字数**和那时的围栏状态。`s` 通常只有几十到几千字。
    private static func stableBoundary(_ s: String) -> (len: Int, fence: Bool) {
        var fence = false
        var best = 0
        var count = 0
        var lineStart = s.startIndex
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\n" {
                let line = s[lineStart..<i]
                if line.hasPrefix("```") { fence.toggle() }
                if !fence, line.isEmpty { best = count + 1 }
                lineStart = s.index(after: i)
            }
            i = s.index(after: i)
            count += 1
        }
        let last = s[lineStart..<s.endIndex]
        if last.hasPrefix("```") { fence.toggle() }
        return (best, fence)
    }

    private static func remember(_ raw: String) {
        guard raw.utf8.count * 2 <= blockCacheBudget else { return }
        let (len, fence) = stableBoundary(raw)
        let stable = len > 0 ? parse(String(raw.prefix(len))) : []
        live.insert(Live(prefix: raw, stable: stable, stableLen: len, fenceOpen: fence), at: 0)
        if live.count > liveLimit { live.removeLast() }
    }

    static func blocks(_ raw: String) -> [Block] {
        if let hit = cache[raw] { return hit }
        // 流式快路径：`raw` 是从某个已解析过的前缀长出来的。
        // 先看最近几篇里有没有谁正好是 `raw` 的前缀。`hasPrefix` 是 O(n)，
        // 但 n 只有几千字，比重新排版便宜几个数量级；判不中就直接走整篇解析。
        for (idx, entry) in live.enumerated() where !entry.fenceOpen
            && entry.stableLen > 0 && raw.hasPrefix(entry.prefix) {
            // **从 `stableLen` 开始，不是 `prefix.count`。**
            //
            // `entry.stable` 只覆盖到 `stableLen`（最后一个空行），
            // 而 `prefix` 是整篇原文 —— 按 prefix.count 切会把
            // stableLen..prefix.count 那一段整个丢掉（实测漏块）。
            let seg = String(raw.dropFirst(entry.stableLen))
            let (len, fence) = stableBoundary(seg)
            var stable = entry.stable
            stable.append(contentsOf: parse(String(seg.prefix(len))))
            var v = stable
            v.append(contentsOf: parse(String(seg.dropFirst(len))))
            if raw.utf8.count * 2 <= blockCacheBudget {
                live[idx] = Live(prefix: raw, stable: stable,
                                 stableLen: entry.stableLen + len, fenceOpen: fence)
                live.swapAt(0, idx)
            } else { live.remove(at: idx) }
            cacheBlocks(raw, v)
            return v
        }
        let v = parse(raw)
        remember(raw)
        cacheBlocks(raw, v)
        return v
    }

    /// 行内样式（加粗、斜体、行内代码）→ NSAttributedString。
    /// 行内样式的缓存。
    ///
    /// `AttributedString(markdown:)` 很贵：实测真实会话里 132 段正文
    /// 走一轮要 **57.6ms**。而这个函数是在 `body` 里调的 ——
    /// 滑动时 `ScrollSensor` 每秒往 @State 写十几次，每次写都让
    /// `ChatView.body` 重算，于是每帧都在重新解析同一批文字。
    /// 用户报的「上下滑好卡」主因就是这里。
    ///
    /// 正文在滚动期间不会变（变了是新字符串，自然 miss），所以按内容缓存即可。
    private static let bodyLimit = 600
    private static var bodyCache: [String: NSAttributedString] = [:]
    private static var bodyOrder: [String] = []
    static let bodyCacheBudget = 8 * 1024 * 1024
    private(set) static var bodyCacheCost = 0

    private static func bodyKey(_ text: String, _ size: CGFloat,
                                _ color: UIColor, _ weight: UIFont.Weight) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return "\(size)|\(weight.rawValue)|\(r),\(g),\(b),\(a)|\(text)"
    }

    static func body(_ text: String, size: CGFloat = Palette.bodySize,
                     color: UIColor = UIColor(Palette.textBot),
                     weight: UIFont.Weight = .regular) -> NSAttributedString {
        let k = bodyKey(text, size, color, weight)
        if let hit = bodyCache[k] { return hit }
        let v = render(text, size: size, color: color, weight: weight)
        let cost = k.utf8.count + v.length * 2
        guard cost <= bodyCacheBudget else { return v }
        bodyCache[k] = v
        bodyCacheCost += cost
        bodyOrder.append(k)
        while bodyOrder.count > bodyLimit || bodyCacheCost > bodyCacheBudget {
            let old = bodyOrder.removeFirst()
            if let removed = bodyCache.removeValue(forKey: old) {
                bodyCacheCost -= old.utf8.count + removed.length * 2
            }
        }
        return v
    }

    private static func render(_ text: String, size: CGFloat,
                               color: UIColor,
                               weight: UIFont.Weight) -> NSAttributedString {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let mono = UIFont.monospacedSystemFont(ofSize: size - 0.5, weight: .regular)
        let a = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let out = NSMutableAttributedString()
        for run in a.runs {
            var f = base
            var c = color
            var bg: UIColor?
            if let it = run.inlinePresentationIntent {
                if it.contains(.code) {
                    f = mono
                    c = UIColor(Palette.textSub)
                    bg = UIColor(Palette.surface)
                } else if it.contains(.stronglyEmphasized) {
                    f = .systemFont(ofSize: size, weight: .semibold)
                } else if it.contains(.emphasized) {
                    f = .italicSystemFont(ofSize: size)
                }
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: c]
            if let bg { attrs[.backgroundColor] = bg }
            if let link = run.link { attrs[.link] = link }
            out.append(NSAttributedString(string: String(a[run.range].characters),
                                          attributes: attrs))
        }
        return out
    }
}

// MARK: - 渲染

/// 一条助手回复：块级排版，正文可直接划选。
struct MarkdownView: View, Equatable {
    let raw: String

    static func == (a: MarkdownView, b: MarkdownView) -> Bool { a.raw == b.raw }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(Markdown.blocks(raw).enumerated()), id: \.offset) { _, b in
                blockView(b)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ b: Markdown.Block) -> some View {
        switch b {
        case .heading(let level, let text):
            HeadingBlock(level: level, text: text)
        case .paragraph(let text):
            SelectableText(attributed: Markdown.body(text))
        case .code(let lang, let body):
            CodeBlock(language: lang, code: body)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(Palette.textFaint)
                            .frame(width: 4, height: 4).padding(.top, 8)
                        SelectableText(attributed: Markdown.body(it), lineSpacing: 3)
                    }
                }
            }
        case .ordered(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(i + 1).")
                            .font(.system(size: 15))
                            .foregroundStyle(Palette.textSub)
                            .monospacedDigit()
                            .frame(minWidth: 18, alignment: .trailing)
                        SelectableText(attributed: Markdown.body(it), lineSpacing: 3)
                    }
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(Palette.quote).frame(width: 2)
                SelectableText(attributed: Markdown.body(
                    text, color: UIColor(Palette.textSub)), lineSpacing: 3)
            }
        case .rule:
            Rectangle().fill(Palette.separatorFaint).frame(height: 0.5)
                .padding(.vertical, 4)
        case .table(let headers, let rows):
            TableBlock(headers: headers, rows: rows)
        case .mermaid(let code):
            MermaidBlock(code: code)
        case .image(let alt, let url):
            ImageThumb(url: url)
                .accessibilityLabel(alt.isEmpty ? "回复图片" : alt)
        }
    }
}
/// 标题块。抽成独立视图：ViewBuilder 里带 `let` + 三元的链式调用
/// 在 Swift 5.8 会报 buildExpression 不匹配（实测），拆开就干净。
private struct HeadingBlock: View {
    let level: Int
    let text: String

    private var size: CGFloat { level == 1 ? 20 : (level == 2 ? 18 : 16.5) }

    var body: some View {
        SelectableText(attributed: Markdown.body(text, size: size, weight: .semibold))
    }
}

/// 真表格：外框圆角 + 列间发丝线 + 表头底色 + 横向可滚
private struct TableBlock: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // 表头
                HStack(spacing: 0) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { i, h in
                        cell(h, isHeader: true)
                        if i < headers.count - 1 {
                            Rectangle().fill(Palette.separatorFaint).frame(width: 0.5)
                        }
                    }
                }
                .background(Palette.surfaceHi)

                Rectangle().fill(Palette.separatorFaint).frame(height: 0.5)

                // 表行
                ForEach(Array(rows.enumerated()), id: \.offset) { rIdx, row in
                    HStack(spacing: 0) {
                        ForEach(0..<headers.count, id: \.self) { cIdx in
                            let text = cIdx < row.count ? row[cIdx] : ""
                            cell(text, isHeader: false)
                            if cIdx < headers.count - 1 {
                                Rectangle().fill(Palette.separatorFaint).frame(width: 0.5)
                            }
                        }
                    }
                    if rIdx < rows.count - 1 {
                        Rectangle().fill(Palette.separatorFaint).frame(height: 0.5)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Palette.separatorFaint, lineWidth: 0.5)
            )
        }
        .padding(.vertical, 4)
    }

    private func cell(_ text: String, isHeader: Bool) -> some View {
        SelectableText(
            attributed: Markdown.body(text, size: isHeader ? 14 : 13.5,
                                      color: isHeader ? UIColor(Palette.text) : UIColor(Palette.textBot),
                                      weight: isHeader ? .semibold : .regular),
            lineSpacing: 2
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 80, alignment: .leading)
    }
}
