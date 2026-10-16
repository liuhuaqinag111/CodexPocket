import SwiftUI
import UIKit

/// 会话里的一条。
///
/// 对齐 ChatGPT：助手回复**没有气泡**，正文直接铺在页面上；
/// 用户消息是右侧浅灰胶囊。
struct MessageRow: View, Equatable {
    let item: Item
    /// 正在流式输出的那一条。
    var live = false
    var failed = false
    /// 这条用户消息的发送状态（`.sending` / `.queued` / `.failed`）。
    var sendState: SendState?
    var onResend: (() -> Void)?
    /// 重新生成这一条。
    var onRegenerate: (() -> Void)?

    static func == (a: MessageRow, b: MessageRow) -> Bool {
        a.item == b.item && a.live == b.live && a.failed == b.failed
            && a.sendState == b.sendState
    }

    var body: some View {
        rows
            // 帧级日志：这一条真的被画到屏幕上了。
            // 跟 ChatEvents 的 FRAME 对时间戳，就能分清"帧没到"还是"到了没画"。
            .onAppear { FrameLog.mark("RENDER", "\(item.id) \(kindName)") }
    }

    private var kindName: String {
        switch item {
        case .user: return "user"
        case .agent: return "agent"
        case .reasoning: return "reasoning"
        case .command: return "cmd"
        case .tool: return "tool"
        case .fileChange: return "file"
        case .plan: return "plan"
        case .note: return "note"
        default: return "other"
        }
    }

    @ViewBuilder
    private var rows: some View {
        switch item {
        case .user(_, let text, let images):
            userBubble(text, images: images)

        case .agent(_, let text):
            VStack(alignment: .leading, spacing: 12) {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: 8) {
                        Rectangle().fill(Palette.accent).frame(width: 3, height: 14)
                        Text("Codex").font(Palette.F.caption.weight(.semibold))
                            .foregroundStyle(Palette.textSub)
                    }
                    .accessibilityHidden(true)
                }
                MarkdownView(raw: text)
                    .frame(maxWidth: .infinity, alignment: .leading)

            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.agent")

        case .reasoning(_, let text):
            FoldBlock(icon: "sparkles",
                      summary: live ? "思考中…" : "已思考",
                      identifier: "chat.reasoning") {
                AnyView(SelectableText(
                    attributed: Markdown.body(text, size: 14,
                                              color: UIColor(Palette.textSub)),
                    lineSpacing: 3))
            }

        case .command(_, let command, let output):
            FoldBlock(icon: "terminal",
                      summary: command.isEmpty ? "运行命令" : command,
                      identifier: "chat.command") {
                AnyView(SelectableText(
                    attributed: NSAttributedString(
                        string: output.isEmpty ? command : output,
                        attributes: [.font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                     .foregroundColor: UIColor(Palette.textSub)]),
                    lineSpacing: 2))
            }

        case .fileChange(_, let changes):
            FoldBlock(icon: "doc.text",
                      summary: changes.count == 1
                          ? (changes[0].path as NSString).lastPathComponent
                          : "\(changes.count) 个文件改动",
                      trailing: diffStat(changes),
                      identifier: "chat.fileChange") {
                AnyView(FileDiff(changes: changes))
            }

        case .tool(_, let server, let tool, let status, let args, let result, let ms):
            let kind = ToolKind.of(tool, server: server)
            FoldBlock(icon: kind.icon,
                      summary: server.isEmpty ? tool : "\(server) · \(tool)",
                      tint: status == "completed" ? Palette.accentText : Palette.warning,
                      trailing: ms > 0 ? TurnDivider.short(ms / 1000) : nil,
                      identifier: "chat.tool") {
                AnyView(ToolDetail(kind: kind, args: args, result: result))
            }

        case .compaction:
            Text("上下文已压缩，更早的内容被折叠")
                .font(Palette.F.caption)
                .foregroundStyle(Palette.textFaint)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .image(_, let url):
            HStack { ImageThumb(url: url); Spacer(minLength: 0) }

        case .plan(_, let steps):
            PlanBlock(steps: steps)

        case .question(_, let prompts):
            QuestionRow(prompts: prompts)

        case .note(_, let label, let detail):
            FoldBlock(icon: "circle.dashed",
                      summary: label,
                      identifier: "chat.note") {
                AnyView(SelectableText(
                    attributed: NSAttributedString(
                        string: detail,
                        attributes: [.font: UIFont.systemFont(ofSize: 13),
                                     .foregroundColor: UIColor(Palette.textFaint)]),
                    lineSpacing: 2))
            }

        case .turnBreak(_, let at, let duration):
            TurnDivider(at: at, duration: duration)
        }
    }
}

// MARK: - 用户气泡

extension MessageRow {
    /// 右侧浅灰胶囊。宽度上限 = 屏宽 − 88。
    /// 长按交给 UITextView 的选择，单击展开「重新发送」。
    func userBubble(_ text: String, images: [String]) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, u in
                ImageThumb(url: u)
            }
            if !text.isEmpty {
                HStack {
                    Spacer(minLength: 40)
                    SelectableText(
                        attributed: NSAttributedString(
                            string: text,
                            attributes: [.font: UIFont.systemFont(ofSize: Palette.bodySize),
                                         .foregroundColor: UIColor(Palette.text)]),
                        id: "chat.user",
                        fill: false)
                        // 内边距跟随自然文本宽度，长按仍使用系统选区。
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 16,
                                                     style: .continuous)
                            .fill(failed ? Palette.danger.opacity(0.12) : Palette.userBubble))
                        .frame(maxWidth: 420, alignment: .trailing)
                        // 这里**不能**挂 `.contextMenu`：它会吃掉长按，
                        // 自己发的消息就再也选不了字了（用户要的就是能选）。
                        // 拷贝用系统自带的文本选择菜单，重试挂在下面的提示上。
                }
            }
            // 状态行：气泡下面一行小字。
            //
            // **结构必须两种状态都一样**（Happy 踩过的坑：只在某一态存在的
            // wrapper 会让 React/SwiftUI 重建整棵子树，发送成功那一刻
            // 界面会闪一下）。所以这里永远是同一个 HStack，
            // 只换里面文字的内容和颜色。
            //
            // 空闲发送 1 秒内不显示（快就该无感）；排队和失败立刻显示。
            if showsStatus {
                Button {
                    if isFailed { onResend?() }
                } label: {
                    Text(statusText)
                        .font(Palette.F.caption)
                        .foregroundStyle(isFailed ? Palette.danger : Palette.textFaint)
                }
                .buttonStyle(.plain)
                .disabled(!isFailed)
                .accessibilityIdentifier(isFailed ? "chat.resend" : "chat.sendState")
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = sendState { return true }
        return failed
    }

    /// 状态行显示与否。宽限期靠 `sendState.since` 算，不用定时器：
    /// 每次 body 求值都会重算，而流式/状态变化本来就会触发重算。
    private var showsStatus: Bool {
        if isFailed { return true }
        return SendStatusLine.shouldShow(sendState)
    }

    private var statusText: String {
        if case .failed(let why) = sendState { return "没发出去：\(why) · 点这里重试" }
        if let s = sendState { return SendStatusLine.text(s) }
        return "没发出去 · 点这里重试"
    }

    func diffStat(_ changes: [FileChange]) -> String? {
        let a = changes.reduce(0) { $0 + $1.added }
        let r = changes.reduce(0) { $0 + $1.removed }
        guard a > 0 || r > 0 else { return nil }
        return "+\(a) −\(r)"
    }
}

/// 文件改动：等宽 diff，增删行带底色。
struct FileDiff: View {
    let changes: [FileChange]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(changes.enumerated()), id: \.offset) { _, c in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(c.path)
                            .font(Palette.F.mono)
                            .foregroundStyle(Palette.textSub)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text("+\(c.added) −\(c.removed)")
                            .font(Palette.F.caption)
                            .foregroundStyle(Palette.textFaint)
                    }
                    if !c.diff.isEmpty {
                        ScrollView([.horizontal, .vertical], showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(lines(c).enumerated()), id: \.offset) { _, l in
                                    Text(l.text)
                                        .font(Palette.F.mono)
                                        .foregroundStyle(color(l))
                                        .padding(.horizontal, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(bg(l))
                                }
                            }
                            .frame(minWidth: UIScreen.main.bounds.width - 40, alignment: .leading)
                        }
                        .frame(height: min(260, CGFloat(lines(c).count) * 16 + 8))
                        .accessibilityIdentifier("chat.diff.content")
                    }
                }
            }
        }
    }

    private struct Line { let text: String; let kind: Int }   // 0 上下文 1 增 2 删

    private func lines(_ c: FileChange) -> [Line] {
        // 新增文件的 diff 就是正文（没有 + 前缀），按 kind 分开处理。
        if c.kind == "add" && !c.diff.contains("\n+") && !c.diff.hasPrefix("+") {
            return c.diff.components(separatedBy: .newlines).map { Line(text: $0, kind: 1) }
        }
        return c.diff.components(separatedBy: .newlines).map { l in
            if l.hasPrefix("+++") || l.hasPrefix("---") { return Line(text: l, kind: 0) }
            if l.hasPrefix("+") { return Line(text: l, kind: 1) }
            if l.hasPrefix("-") { return Line(text: l, kind: 2) }
            return Line(text: l, kind: 0)
        }
    }

    private func color(_ l: Line) -> Color {
        switch l.kind {
        case 1: return Palette.success
        case 2: return Palette.danger
        default: return Palette.textSub
        }
    }

    private func bg(_ l: Line) -> Color {
        switch l.kind {
        case 1: return Palette.success.opacity(0.10)
        case 2: return Palette.danger.opacity(0.10)
        default: return .clear
        }
    }
}

/// 工具调用的参数与结果。

/// 工具调用详情：按种类换形状，而不是一坨 JSON。
struct ToolDetail: View {
    let kind: ToolKind
    let args: String
    let result: String

    /// args 是 JSON 文本；能解析出对象就按 `键` 分行列，解析不出就直接显示。
    private var argRows: [(String, String)] {
        guard let d = JSON.object(args) else {
            return args.isEmpty ? [] : [("参数", args)]
        }
        return d.keys.sorted().map { ($0, JSON.text(d[$0])) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if kind == .todo { checklist }
            else if !argRows.isEmpty { rows }
            if !result.isEmpty { block("结果", result) }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(argRows, id: \.0) { k, v in
                HStack(alignment: .top, spacing: 8) {
                    Text(k)
                        .font(Palette.F.mono.weight(.medium))
                        .foregroundStyle(Palette.textFaint)
                        .frame(width: 84, alignment: .leading)
                    Text(v)
                        .font(.system(.caption, design: kind.mono ? .monospaced : .default))
                        .foregroundStyle(Palette.textSub)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// 待办类：把 `[x] / [ ]` 或 status 渲染成勾选行。
    private var checklist: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(JSON.lines(args).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 7) {
                    LucideIcon(done(line) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(done(line) ? Palette.success : Palette.textFaint)
                    Text(strip(line))
                        .font(Palette.F.caption)
                        .foregroundStyle(done(line) ? Palette.textFaint : Palette.textSub)
                        .strikethrough(done(line), color: Palette.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func done(_ s: String) -> Bool {
        let t = s.lowercased()
        return t.contains("[x]") || t.contains("completed") || t.contains("\"done\"")
    }

    private func strip(_ s: String) -> String {
        s.replacingOccurrences(of: "[x]", with: "")
            .replacingOccurrences(of: "[ ]", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private func block(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Palette.F.caption).foregroundStyle(Palette.textFaint)
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                SelectableText(
                    attributed: NSAttributedString(
                        string: body,
                        attributes: [.font: UIFont.monospacedSystemFont(ofSize: 11.5,
                                                                        weight: .regular),
                                     .foregroundColor: UIColor(Palette.textSub)]),
                    lineSpacing: 2)
            }
            .frame(maxHeight: 220)
            .accessibilityIdentifier("chat.tool.content")
        }
    }
}

// MARK: - 引用按钮
