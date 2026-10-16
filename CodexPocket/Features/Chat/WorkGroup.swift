import SwiftUI

/// 一个回合的中间过程（思考 / 命令 / 工具 / 改文件 / 计划），收起成一行。
///
/// 关键约束（照 Happy 的 `useGroupedMessages`）：
/// **展开之后跟流式时长得一模一样** —— 成员就是原来的 `MessageRow`，
/// 不另做一套样式。用户展开是为了看细节，不是看另一种排版。
struct WorkGroup: View {
    let items: [Item]
    let summary: String
    let duration: Double?
    @State private var open = false
    @Environment(\.holdChatPosition) private var holdPosition
    /// 已经铺出来多少条（见下面分窗的注释）。
    @State private var shown = Self.chunk

    /// 一次铺多少条。
    static let chunk = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                FreezeWatchdog.mark(open ? "workgroup-close" : "workgroup-open")
                holdPosition()
                withAnimation(Motion.quick) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    LucideIcon(open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.textFaint)
                        .frame(width: 10)
                    Text(summary)
                        .font(Palette.F.note)
                        .foregroundStyle(Palette.textSub)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if let d = duration {
                        Text(TurnDivider.short(d))
                            .font(Palette.F.caption)
                            .foregroundStyle(Palette.textFaint)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.workGroup")
            .accessibilityValue(open ? "已展开" : "已收起")

            if open {
                VStack(alignment: .leading, spacing: Palette.S.l) {
                    // **分窗渲染。**
                    //
                    // 一轮长任务能有 250+ 条过程条目（实测最长一轮 258 条：
                    // 161 命令 + 92 思考）。一次全建出来 = 250 多个
                    // `SelectableText`（每个都是真的 UITextView），
                    // 光 CoreText 排版就 2.4 秒（实测 253 条 = 2418ms），
                    // 主线程直接堵死 —— 用户报的"点一下思考过程就卡死"。
                    //
                    // 先铺 30 条（约两屏），要看更早的点一下再铺 30 条。
                    // 展开后每一条仍然是原来的 `MessageRow`，长得跟流式时
                    // 一模一样。
                    ForEach(items.prefix(shown)) { it in
                        MessageRow(item: it)
                    }
                    if items.count > shown {
                        Button {
                            FreezeWatchdog.mark("workgroup-more")
                            holdPosition()
                            shown = min(shown + Self.chunk, items.count)
                        } label: {
                            Text("显示其余 \(items.count - shown) 条")
                                .font(Palette.F.note)
                                .foregroundStyle(Palette.textSub)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.workGroup.more")
                    }
                }
                .padding(.leading, 2)
            }
        }
    }
}
