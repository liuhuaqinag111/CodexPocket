import SwiftUI
import UIKit

/// 可选正文：UIKit 的 UITextView，而不是 SwiftUI 的 Text。
///
/// 为什么不用 `.textSelection(.enabled)`：模拟器上一切正常，
/// 但 iOS 16 真机上长按**不出任何选区**（实测，用户报的"长按没用"）。
/// UIKit 的选择是系统原生的，和「信息」「备忘录」完全一致；
/// 命中区就是视图边界，铺满整行后按在文字右侧空白也能起选区。
struct SelectableText: UIViewRepresentable {
    @Environment(\.quoteSelection) private var quoteSelection
    @Environment(\.dynamicTypeSize) private var typeSize
    let attributed: NSAttributedString
    var lineSpacing: CGFloat = Palette.bodyLineSpacing
    /// 无障碍标记（测试按它查元素）。
    var id: String = ""
    /// 单击回调（用户气泡用：展开「重新发送」）。
    var onTap: (() -> Void)?
    /// 长按回调（助手回复用：弹出操作菜单）。
    var onLongPress: (() -> Void)?
    /// 要不要铺满可用宽度。
    ///
    /// 助手正文必须铺满（`true`）；用户气泡必须**紧贴文字**（`false`）——
    /// 铺满的话「老曹」两个字的气泡会被撑到 270pt 宽（用户："气泡为什么这么大"）。
    var fill: Bool = true
    /// 不折行：一行源代码永远渲染成一行，宽度不够就靠外层横向滚动。
    ///
    /// 代码块用。以前没这个开关，横向 ScrollView 里宽度提案不是 nil 时
    /// 文本会被按容器宽度折行 —— 用户截图里 `print("hello, world")`
    /// 被折成 `print("hell` / `o, world")`。
    var nowrap: Bool = false

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.delegate = context.coordinator
        v.isEditable = false
        v.isSelectable = true
        // 关掉自身滚动：滚动交给外层，否则长按拖动会被文本框吃掉。
        v.isScrollEnabled = false
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        if nowrap { v.textContainer.widthTracksTextView = false }
        v.dataDetectorTypes = []
        if onTap != nil {
            let g = UITapGestureRecognizer(target: context.coordinator,
                                           action: #selector(Coordinator.tap))
            g.cancelsTouchesInView = false
            v.addGestureRecognizer(g)
        }
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.quoteSelection = quoteSelection
        v.accessibilityIdentifier = id
        // **内容没换就直接返回。**
        //
        // 这里每次都做「整份 attributed 深拷贝 + 给全文加段落样式 +
        // `v.attributedText != s` 全量比较」。`Markdown.body` 现在返回的是
        // 同一个缓存对象，所以滚动进屏时 `attributed` 通常是**同一个实例**；
        // 再走一遍上面的流程纯属白烧 —— 一条 1.5 万字的正文，那个全量比较
        // 就是几毫秒，而滚动时每秒会触发十几次。
        // 用户报的「上下滑好卡」有一份在这里。
        let co = context.coordinator
        if co.applied === attributed, co.appliedSpacing == lineSpacing,
           co.appliedNowrap == nowrap, co.appliedType == typeSize, v.attributedText != nil {
            return
        }
        // 长正文的 CoreText 排版（`sizeThatFits`）要几十毫秒，
        // 谁在什么时候排的一眼看不出来。打上阶段标记，卡住时能对上号。
        if attributed.length > 2000 { FreezeWatchdog.mark("text-layout") }
        let s = NSMutableAttributedString(attributedString: attributed)
        s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length)) { value, range, _ in
            if let font = value as? UIFont {
                s.addAttribute(.font, value: UIFontMetrics(forTextStyle: .body)
                    .scaledFont(for: font, compatibleWith: v.traitCollection), range: range)
            }
        }
        let full = NSRange(location: 0, length: s.length)
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineSpacing
        s.addAttribute(.paragraphStyle, value: p, range: full)
        v.attributedText = s
        co.applied = attributed
        co.appliedSpacing = lineSpacing
        co.appliedNowrap = nowrap
        co.appliedType = typeSize
        co.sizedFor = nil
        if nowrap {
            let n = Self.naturalSize(s)
            v.textContainer.size = n
        }
    }

    /// 高度由文本自己决定，宽度跟外层。
    ///
    /// 宽度还没量到时返回**上一次的高度**，不要返回 nil：
    /// nil 会让 SwiftUI 退回用 intrinsic 尺寸，而 UITextView 那种情况下的
    /// 高度是错的（内容总高先冲高再落回），底部跟随会被拽下去又弹回来。
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: UITextView,
                      context: Context) -> CGSize? {
        if nowrap {
            let size = Self.naturalSize(uiView.attributedText ?? NSAttributedString())
            context.coordinator.last = size
            return size
        }
        let w = proposal.width ?? uiView.bounds.width
        if !(w > 0 && w.isFinite) {
            // **横向 ScrollView 里宽度提案是 nil**（它给的是无限宽）。
            // 以前这里直接返回上一次的尺寸，而第一次是 `.zero` ——
            // 于是整个代码块**塌成 0 高**，只剩上面那行 "bash / 复制"。
            // 用无限宽去量，让块自己撑开。
            let size = Self.intrinsic(uiView)
            context.coordinator.last = size
            return size
        }

        // 宽度必须先定下来，再拿它量高度。
        //
        // 关键：**不能**用 `sizeThatFits(CGSize(width: w, ...)).width` 当文字宽度 ——
        // UITextView 在给定宽度下会直接把这个宽度还回来（它要填满），
        // 结果 `fill: false` 也不起作用，气泡还是撑满（用户："气泡还是没修好"）。
        // 要量"文字自然多宽"，必须给它**无限宽**去量。
        // 同一个对象 + 同一个宽度 → 高度一定一样，不必再排一遍版。
        //
        // 滚动进屏时这两个条件几乎总是成立（`Markdown.body` 返回缓存对象，
        // 宽度就是屏幕宽），而 CoreText 排版一条长正文要几毫秒。
        let oid = ObjectIdentifier(attributed)
        let co = context.coordinator
        // 行距 / 是否折行也会改变高度，必须一起当判据。
        if co.sizedFor == oid, abs(co.sizedWidth - w) < 0.5, co.sizedHeight > 0,
           co.sizedSpacing == lineSpacing, co.sizedFill == fill {
            let cached = CGSize(width: co.sizedContentWidth, height: co.sizedHeight)
            co.last = cached
            return cached
        }

        var width = w
        if !fill {
            let natural = uiView.sizeThatFits(
                CGSize(width: CGFloat.greatestFiniteMagnitude,
                       height: CGFloat.greatestFiniteMagnitude))
            width = min(w, max(1, ceil(natural.width)))
        }
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let size = CGSize(width: width, height: ceil(fit.height))
        co.last = size
        co.sizedFor = oid
        co.sizedWidth = w
        co.sizedContentWidth = width
        co.sizedHeight = size.height
        co.sizedSpacing = lineSpacing
        co.sizedFill = fill
        return size
    }

    /// 用「无限宽」量出的一段文字的自然尺寸。
    ///
    /// `nowrap` 用它当布局尺寸：宽度 = 最长那一行，高度 = 行数 × 行高。
    /// 纯函数（只吃 NSAttributedString），所以能直接单测 ——
    /// 折行 bug 的判据就是"长行的自然高度 == 短行的自然高度"。
    static func naturalSize(_ s: NSAttributedString) -> CGSize {
        guard s.length > 0 else { return .zero }
        let r = s.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude,
                         height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil)
        return CGSize(width: ceil(r.width) + 1, height: ceil(r.height) + 1)
    }

    /// 宽度未知时用"无限宽"量出的自然尺寸。
    ///
    /// 抽成 static 是为了能直接单测：这个分支以前返回 `.zero`，
    /// 代码块在横向 ScrollView 里整个塌掉（只剩标题行）。
    static func intrinsic(_ v: UITextView) -> CGSize {
        let fit = v.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,
                                        height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: ceil(fit.width), height: ceil(fit.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextViewDelegate {
        var quoteSelection: ((String) -> Void)?
        var onTap: (() -> Void)?
        var last: CGSize = .zero
        /// 上一次真的写进 `attributedText` 的那个对象（身份比较，不是内容比较）。
        var applied: NSAttributedString?
        var appliedSpacing: CGFloat = -1
        var appliedNowrap = false
        var appliedType: DynamicTypeSize?
        /// 上一次量出来的高度，按 (对象身份, 宽度) 记 —— 滚动时宽度不变，
        /// 直接复用，省掉一遍 CoreText 排版。
        var sizedFor: ObjectIdentifier?
        var sizedWidth: CGFloat = -1
        var sizedHeight: CGFloat = 0
        var sizedContentWidth: CGFloat = 0
        var sizedSpacing: CGFloat = -1
        var sizedFill = true
        @objc func tap() { onTap?() }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let quoteSelection, range.length > 0,
                  let selection = textView.selectedTextRange,
                  let selected = textView.text(in: selection) else {
                return UIMenu(children: suggestedActions)
            }
            let quote = UIAction(title: "引用", image: LucideIcon.uiImage("quote.bubble")) { _ in
                quoteSelection(selected)
                textView.resignFirstResponder()
            }
            return UIMenu(children: [quote] + suggestedActions)
        }

    }
}

private struct QuoteSelectionKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}
extension EnvironmentValues {
    var quoteSelection: ((String) -> Void)? {
        get { self[QuoteSelectionKey.self] }
        set { self[QuoteSelectionKey.self] = newValue }
    }
}
