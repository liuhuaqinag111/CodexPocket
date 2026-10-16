import XCTest
@testable import CodexPocket

/// 代码块的字色必须在底色上看得到。
///
/// 用户报的：「代码区域啥也看不见」。
/// 真因：CodeBlock 拿 `Palette.code`（0x181918）当**文字**颜色，
/// 而它的底色是 `Palette.canvas`（也是 0x181918）—— 同色，
/// 一个字都渲染不出来，只有一个空黑框。
///
/// 这类 bug 肉眼审代码很难发现（两个常量名字不同、值相同），
/// 所以用对比度断言挡死。
final class CodeBlockContrastTests: XCTestCase {

    /// WCAG 相对亮度。
    private func luminance(_ hex: UInt) -> Double {
        func channel(_ c: UInt) -> Double {
            let v = Double(c) / 255.0
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = channel((hex >> 16) & 0xFF)
        let g = channel((hex >> 8) & 0xFF)
        let b = channel(hex & 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// 对比度。1 = 完全相同（等于看不见），21 = 黑白。
    private func ratio(_ a: UInt, _ b: UInt) -> Double {
        let la = luminance(a), lb = luminance(b)
        let hi = max(la, lb), lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    func testCodeTextIsReadableOnCodeBackground() {
        let r = ratio(Palette.codeTextHex, Palette.codeHex)
        XCTAssertGreaterThanOrEqual(r, 4.5,
            "代码块字色和底色对比度只有 \(String(format: "%.2f", r))，看不清")
    }

    /// 直接点名那个具体写法：字色不许等于底色。
    func testCodeTextIsNotSameAsBackground() {
        XCTAssertNotEqual(Palette.codeTextHex, Palette.codeHex,
            "代码块字色和底色是同一个值 —— 会渲染成空框")
    }
}
