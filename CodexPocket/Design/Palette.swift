import SwiftUI
import UIKit

/// 深灰底色，浮层略亮；正文、辅助信息和控件保持清晰层次。
enum Palette {

    static func adaptive(_ light: UInt, _ dark: UInt) -> Color {
        Color(uiColor: UIColor { traits in
            let n = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((n >> 16) & 255) / 255,
                           green: CGFloat((n >> 8) & 255) / 255,
                           blue: CGFloat(n & 255) / 255, alpha: 1)
        })
    }
    static let bg = adaptive(0xF8F7F3, 0x141719)
    static let surface = adaptive(0xF0EFEB, 0x202527)
    static let surfaceHi = adaptive(0xE7E7E1, 0x2B3336)
    static let elevated = adaptive(0xFFFFFF, 0x242A2D)
    static let controlBg = surface
    static let accent = adaptive(0x285CC4, 0x9CB9FF)
    static let buttonBg = adaptive(0x285CC4, 0xADC5FF)
    static let userBubble = adaptive(0xE8EDF8, 0x242F43)
    static let inputBg = elevated
    static let fillAccent = accent

    /// 代码块**底色**。注意别拿它当文字颜色 —— 字体色见 `codeText`。
    /// 之前 CodeBlock 把 `Palette.code` 当成了文字色，而它和代码块底色
    /// `canvas` 是同一个值（都是 0x181918），深色字压深色底 = 一个字都看不见。
    // 代码块的底色/字色。原始值单独留一份：
    // `Color` 取不回数值，测试要靠它们算对比度（见 CodeBlockContrastTests）。
    // **这几条是单一来源**，颜色本身从这里生成，别在旁边再写一份字面量。
    static let codeHex: UInt = 0x181918
    static let codeTextHex: UInt = 0xF2F2F7

    static let code = Color(hex: codeHex)
    /// 代码块**文字**颜色。
    static let codeText = Color(hex: codeTextHex)
    static let quote = Color(uiColor: .tertiaryLabel)
    static let canvas = Color(hex: 0x181918)

    // 文字颜色
    static let text = adaptive(0x202A32, 0xEFF1F2)
    static let textSub = adaptive(0x55616B, 0xBBC3C9)
    static let textFaint = adaptive(0x59656F, 0xA0ABB4)
    static let placeholder = textFaint
    static let headerTitle = text
    static let accentText = accent

    // 状态与指示
    static let success = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemGreen
            : UIColor(red: 0.05, green: 0.40, blue: 0.20, alpha: 1)
    })
    static let warning = adaptive(0x885300, 0xFFBA60)
    static let danger = adaptive(0xB52B35, 0xFF8F96)
    static let swipeAccent = Color(hex: 0x285CC4)
    static let swipeDanger = Color(hex: 0xB52B35)
    static let swipeNeutral = Color(hex: 0x55616B)

    // 图标与控制
    static let controlIcon = text
    static let plusIcon = text
    static let micIcon = textSub
    static let iconInverted = adaptive(0xFFFFFF, 0x16233D)

    // 分隔线
    static let separator = Color(uiColor: .separator).opacity(0.7)
    static let separatorFaint = Color(uiColor: .separator).opacity(0.45)


    static let iconFaint = Color(uiColor: .secondaryLabel)
    static let textBot = text
    static let bodyLineSpacing: CGFloat = 4.0

    // 字号与间距
    static let bodySize: CGFloat = 17
    static let titleSize: CGFloat = 17
    static let noteSize: CGFloat = 12

    enum F {
        static let hero = Font.system(.largeTitle, design: .default).weight(.bold)
        static let section = Font.system(.title3, design: .default).weight(.semibold)
        static let row = Font.body.weight(.medium)

        static let title = Font.headline
        static let group = Font.subheadline.weight(.semibold)

        static let body = Font.body
        static let bodyBold = Font.body.weight(.semibold)
        static let composer = Font.body
        static let note = Font.subheadline
        static let caption = Font.caption
        static let mono = Font.system(.caption, design: .monospaced)
    }

    enum R {
        static let code: CGFloat = 10

        static let field: CGFloat = 10

        static let card: CGFloat = 16
        static let bubble: CGFloat = 12
        static let composer: CGFloat = 20
    }

    enum S {
        static let m: CGFloat = 8
        static let l: CGFloat = 12

        static let sm: CGFloat = 4
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 08) & 0xff) / 255,
            blue: Double((hex >> 00) & 0xff) / 255,
            opacity: alpha
        )
    }
}
