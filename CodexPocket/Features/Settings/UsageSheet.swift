import SwiftUI

/// 本会话用量。
///
/// 服务端每轮推 `thread/tokenUsage/updated`，里面是分开计的
/// 输入 / 输出 / 缓存命中 / 推理，加一个模型上下文窗口。
///
/// 注意**没有**“账号剩余额度”：`account/usage/read` 走 API-key 认证时
/// 服务端直接回 "chatgpt authentication required to read token usage"
/// （实测），拿不到。所以这里只显示这个会话自己的账，不编造额度。
struct UsageSheet: View {
    @EnvironmentObject var store: AppCoordinator
    @EnvironmentObject private var chat: ConversationModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    private var u: TokenUsage? { chat.usage }

    /// 这个用量是什么时候记下的（本地缓存）。
    private var cachedAt: Date? {
        guard let id = store.list.currentID else { return nil }
        return UsageCache.load(id)?.at
    }

    private func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: d)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let u {
                        head(u)
                        bar(u)
                        rows(u)
                        // 说清楚这个数字是哪来的：服务端**没有**查历史用量的方法
                        // （实测 thread/read、turns/list、resume 都拿不到），
                        // 只在跑回合时推一次。所以这里显示的是**上次**记下的值。
                        Text(cachedAt.map { "更新于 \(stamp($0))，显示最近一次运行的数据。" }
                             ?? "会话运行后自动更新用量。")
                            .font(Palette.F.caption)
                            .foregroundStyle(Palette.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            LucideIcon("chart-no-axes-combined", size: 32)
                                .foregroundStyle(Palette.accentText).padding(.bottom, 12)
                            Text("还没有这个会话的用量记录。")
                                .font(Palette.F.body)
                                .foregroundStyle(Palette.text)
                            Text("发送消息并完成一轮对话后，这里会显示输入、输出与上下文用量。")
                                .font(Palette.F.caption)
                                .foregroundStyle(Palette.textFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 24)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Palette.bg)
            .tint(Palette.accentText)
            .toolbarBackground(Palette.bg, for: .navigationBar)
            .navigationTitle("用量")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            } }
        }
        .accessibilityIdentifier("usage.sheet")
    }

    private func head(_ u: TokenUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("累计 TOKEN").font(Palette.F.caption.weight(.semibold)).foregroundStyle(Palette.textSub)
            Text(fmt(u.total))
                .font(.largeTitle.weight(.semibold)).monospacedDigit()
                .foregroundStyle(Palette.text)
            Text(u.percent >= 0 ? "上下文占用 \(u.percent)%" : "总 token")
                .font(Palette.F.note)
                .foregroundStyle(Palette.textSub)
        }
        .padding(.vertical, 12)
    }

    /// 一条占比条：输入 / 输出 / 缓存 三段。
    private func bar(_ u: TokenUsage) -> some View {
        let total = max(1, u.total)
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    seg(CGFloat(u.input - u.cached) / CGFloat(total), Palette.accentText, max(0, g.size.width - 4))
                    seg(CGFloat(u.cached) / CGFloat(total), Palette.success, max(0, g.size.width - 4))
                    seg(CGFloat(u.output) / CGFloat(total), Palette.warning, max(0, g.size.width - 4))
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            .accessibilityHidden(true)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { legends }
            } else {
                HStack(spacing: 14) { legends }
            }
        }
    }

    private var legends: some View {
        Group {
            legend("输入", Palette.accentText)
            legend("缓存命中", Palette.success)
            legend("输出", Palette.warning)
        }
    }

    private func seg(_ f: CGFloat, _ c: Color, _ w: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5).fill(c)
            .frame(width: max(0, w * min(1, max(0, f))))
    }

    private func legend(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10).accessibilityHidden(true)
            Text(t).font(Palette.F.caption).foregroundStyle(Palette.textSub)
        }
    }

    private func rows(_ u: TokenUsage) -> some View {
        VStack(spacing: 0) {
            row("输入", u.input)
            row("其中缓存命中", u.cached)
            row("输出", u.output)
            row("其中推理", u.reasoning)
            if u.contextWindow > 0 { row("上下文窗口", u.contextWindow) }
        }
        .background(RoundedRectangle(cornerRadius: Palette.R.card).fill(Palette.elevated))
    }

    private func row(_ k: String, _ v: Int) -> some View {
        HStack {
            Text(k).font(Palette.F.note).foregroundStyle(Palette.textSub)
            Spacer(minLength: 0)
            Text(fmt(v)).font(Palette.F.note.weight(.medium)).monospacedDigit().foregroundStyle(Palette.text)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.separatorFaint).frame(height: 0.5).padding(.leading, 16)
        }
    }

    private func fmt(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}
