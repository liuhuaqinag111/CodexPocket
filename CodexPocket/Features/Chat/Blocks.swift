import SwiftUI
import UIKit

/// 代码块：深一档的整块底 + 圆角 12，长代码横向滚动并支持系统文字选择。
struct CodeBlock: View {
    let language: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "代码" : language)
                    .font(Palette.F.caption)
                    .foregroundStyle(Palette.codeText.opacity(0.75))
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                SelectableText(
                    attributed: NSAttributedString(
                        string: code,
                        attributes: [.font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                     .foregroundColor: UIColor(Palette.codeText)]),
                    lineSpacing: 3,
                    nowrap: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(RoundedRectangle(cornerRadius: Palette.R.code, style: .continuous)
            .fill(Palette.canvas))
    }
}

/// 折叠块：默认一行，点开看全文。
///
/// 思考过程、命令输出、diff、工具调用都用它 —— 视觉一致，
/// 而且不用给每种块单独写一遍展开逻辑。
struct FoldBlock: View {
    let icon: String
    let summary: String
    var tint: Color = Palette.iconFaint
    /// 右侧的补充信息（耗时、+N −N）。
    var trailing: String?
    var identifier: String = "fold"
    var content: () -> AnyView

    @State private var open = false
    @Environment(\.holdChatPosition) private var holdPosition

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                FreezeWatchdog.mark(open ? "fold-close" : "fold-open")
                holdPosition()
                withAnimation(Motion.quick) { open.toggle() }
            } label: {
                HStack(spacing: 12) {
                    LucideIcon(icon, size: 16)
                        .foregroundStyle(tint)
                        .frame(width: 16)
                    Text(summary)
                        .font(Palette.F.note)
                        .foregroundStyle(Palette.textSub)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if let trailing {
                        Text(trailing)
                            .font(Palette.F.caption)
                            .foregroundStyle(Palette.textFaint)
                    }
                    LucideIcon("chevron-right", size: 14)
                        .foregroundStyle(Palette.textFaint)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
            .accessibilityValue(open ? "已展开" : "已收起")

            if open {
                content()
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 回合分隔线：一条 0.5pt 线 + 时间戳 + 用时。
struct TurnDivider: View {
    let at: Date
    let duration: Double?

    /// 用时。ChatGPT 不在消息之间放时间分隔线 ——
    /// 之前我做的是整行居中的「13:33 2分46秒」，那是自创的。
    /// 这里保留时长（用户要求看得见），但降级成右侧一行很轻的灰字。
    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if let d = duration, d >= 1 {
                Text(TurnDivider.short(d))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textFaint)
                    .monospacedDigit()
            }
        }
        .frame(height: 14)
        .accessibilityIdentifier("turn.divider")
    }

    static func short(_ s: Double) -> String {
        if s < 1 { return String(format: "%.1f 秒", s) }
        if s < 60 { return "\(Int(s.rounded())) 秒" }
        let m = Int(s) / 60, r = Int(s) % 60
        return r == 0 ? "\(m) 分" : "\(m) 分 \(r) 秒"
    }
}
