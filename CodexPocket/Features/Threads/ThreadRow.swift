import SwiftUI

/// 标题优先，状态与时间共用一条轻量元信息。
struct ThreadRow: View {
    let thread: Thread
    /// 左侧缩进（项目下的会话往里缩一档）。
    var indent: CGFloat = 0
    /// 服务端搜索命中的原文片段（只有搜索结果里才给）。
    /// 标题看不出为什么命中时，这一行就是答案。
    var snippet: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(thread.running || thread.unread ? Palette.accentText : Palette.separatorFaint)
                .frame(width: 3, height: 28)
                .padding(.top, 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(thread.displayTitle)
                    .font(Palette.F.row)
                    .foregroundStyle(Palette.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let sn = snippet, !sn.isEmpty {
                    Text(sn.replacingOccurrences(of: "\n", with: " "))
                        .font(Palette.F.caption)
                        .foregroundStyle(Palette.textSub)
                        .lineLimit(1)
                } else {
                    HStack(spacing: 8) {
                        if thread.running {
                            Text("进行中").foregroundStyle(Palette.accentText)
                        } else if thread.unread {
                            Text("新回复").foregroundStyle(Palette.accentText)
                        }
                        Text(Self.relative(thread.updatedAt)).foregroundStyle(Palette.textSub)
                    }
                    .font(Palette.F.caption)
                }
            }
            Spacer(minLength: 8)
            if thread.unread && !thread.running {
                Circle().fill(Palette.accentText).frame(width: 6, height: 6)
                    .padding(.top, 8).accessibilityHidden(true)
            }
        }
        .padding(.leading, 20 + indent)
        .padding(.trailing, 20)
        .padding(.vertical, 14)
        .frame(minHeight: 72)
        .contentShape(Rectangle())
        .accessibilityIdentifier("thread.row")
        .accessibilityValue(thread.running ? "正在运行" : thread.unread ? "有新回复" : "空闲")
    }

    /// 相对时间。超过一个月直接给日期。
    static func relative(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(Int(s / 60)) 分钟前" }
        if s < 86400 { return "\(Int(s / 3600)) 小时前" }
        if s < 86400 * 30 { return "\(Int(s / 86400)) 天前" }
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f.string(from: d)
    }
}
