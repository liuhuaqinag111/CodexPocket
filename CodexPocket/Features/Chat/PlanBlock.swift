import SwiftUI

/// 计划 / 待办。
///
/// 服务端会推 `thread/plan/updated` 和 `item/plan/delta`，agent 干活前
/// 列的那份清单就在这里。以前这两种条目**在界面上完全不存在**
/// （`Protocol_.item` 的 default 分支对无文本条目返回 nil，直接丢掉），
/// 用户看到的是"agent 说它列了个计划，但计划在哪？"。
struct PlanBlock: View {
    let steps: [PlanStep]

    private var done: Int { steps.filter { $0.isDone }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                LucideIcon("checklist")
                    .font(.system(size: 13, weight: .medium))
                Text("计划")
                    .font(Palette.F.note)
                Spacer(minLength: 0)
                Text("\(done)/\(steps.count)")
                    .font(Palette.F.caption)
                    .foregroundStyle(Palette.textFaint)
            }
            .foregroundStyle(Palette.textSub)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                    HStack(alignment: .top, spacing: 8) {
                        LucideIcon(icon(s))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(s.isDone ? Palette.success
                                             : (s.isActive ? Palette.accentText : Palette.textFaint))
                            .frame(width: 14)
                        Text(s.text)
                            .font(Palette.F.note)
                            .foregroundStyle(s.isDone ? Palette.textFaint : Palette.text)
                            .strikethrough(s.isDone, color: Palette.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(s.isDone ? "已完成" : s.isActive ? "进行中" : "待办")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Palette.R.code, style: .continuous)
            .fill(Palette.surface))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.plan")
    }

    private func icon(_ s: PlanStep) -> String {
        if s.isDone { return "checkmark.circle.fill" }
        if s.isActive { return "circle.inset.filled" }
        return "circle"
    }
}
