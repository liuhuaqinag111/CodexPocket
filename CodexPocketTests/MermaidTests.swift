import XCTest
import WebKit
@testable import CodexPocket

final class MermaidTests: XCTestCase {
    @MainActor
    func testBitmapCacheEvictsByActualBytesAndSkipsOversizedImages() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).image { _ in UIColor.red.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 16, height: 16)) }
        let cg = try XCTUnwrap(image.cgImage), bytes = cg.bytesPerRow * cg.height
        let renderer = MermaidRenderer(cacheBudget: bytes * 2 + 16)
        for code in ["a", "b", "c"] { renderer.cacheImage(image, for: .init(code: code, width: 16, dark: true)) }
        XCTAssertEqual(renderer.cachedImageCount, 2)
        XCTAssertEqual(renderer.cachedBytes, (bytes + 1) * 2)
        var cached: UIImage?
        renderer.image(for: .init(code: "c", width: 16, dark: true)) { cached = $0 }
        XCTAssertNotNil(cached)
        let large = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { _ in }
        renderer.cacheImage(large, for: .init(code: "oversized", width: 64, dark: true))
        XCTAssertEqual(renderer.cachedImageCount, 2)
        XCTAssertLessThanOrEqual(renderer.cachedBytes, bytes * 2 + 16)
        renderer.cacheImage(image, for: .init(code: "c", width: 16, dark: true))
        XCTAssertEqual(renderer.cachedBytes, (bytes + 1) * 2)
    }

    @MainActor
    func testDuplicateDiagramsShareOneRenderAndQueueIsBounded() async {
        let web = SilentMermaidWebView()
        var creations = 0
        let renderer = MermaidRenderer(timeout: 0.01, makeWebView: { @MainActor in
            creations += 1; return web
        })
        let completed = expectation(description: "all bounded jobs settle")
        completed.expectedFulfillmentCount = 52
        for _ in 0..<2 {
            renderer.image(for: .init(code: "same", width: 300, dark: true)) { _ in completed.fulfill() }
        }
        for n in 0..<50 {
            renderer.image(for: .init(code: "job-\(n)", width: 300, dark: true)) { _ in completed.fulfill() }
        }
        await fulfillment(of: [completed], timeout: 4)
        XCTAssertEqual(creations, 40)
    }

    @MainActor
    func testNavigationAndProcessFailuresFinishOnceAndContinue() async {
        var webs: [SilentMermaidWebView] = []
        let renderer = MermaidRenderer(timeout: 1, makeWebView: { @MainActor in
            let web = SilentMermaidWebView(); webs.append(web); return web
        })
        var callbacks = 0
        for code in ["first", "second"] {
            renderer.image(for: .init(code: code, width: 300, dark: true)) { _ in callbacks += 1 }
        }
        let error = NSError(domain: "test", code: 1)
        renderer.webView(webs[0], didFailProvisionalNavigation: nil, withError: error)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(webs.count, 2)
        renderer.webView(webs[0], didFail: nil, withError: error)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(callbacks, 1)
        renderer.webViewWebContentProcessDidTerminate(webs[1])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(callbacks, 2)
        webs[1].pending?(true, nil)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(callbacks, 2)
    }

    @MainActor
    func testMissingWebKitCallbackTimesOutAndContinuesQueue() async {
        var webs: [SilentMermaidWebView] = []
        let renderer = MermaidRenderer(timeout: 0.03, makeWebView: { @MainActor in
            let web = SilentMermaidWebView()
            webs.append(web)
            return web
        })
        let completed = expectation(description: "both jobs terminate")
        completed.expectedFulfillmentCount = 2
        var callbacks = 0
        for code in ["first", "second"] {
            renderer.image(for: .init(code: code, width: 300, dark: true)) { image in
                XCTAssertNil(image)
                callbacks += 1
                completed.fulfill()
            }
        }
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(webs.count, 2)
        webs[0].pending?(true, nil)
        webs[0].pending?(true, nil)
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(callbacks, 2)
    }

    /// ```mermaid 围栏必须变成 `.mermaid` 块，不能当普通代码块。
    func testMermaidFenceBecomesDiagram() {
        let md = """
        看这张图：

        ```mermaid
        graph TD
          A[开始] --> B[结束]
        ```
        """
        let blocks = Markdown.parse(md)
        let diagrams = blocks.compactMap { b -> String? in
            if case .mermaid(let c) = b { return c }
            return nil
        }
        XCTAssertEqual(diagrams.count, 1, "mermaid 围栏没被识别")
        XCTAssertTrue(diagrams[0].contains("graph TD"))
    }

    /// 普通代码块不能被误判成图。
    func testPlainFenceStaysCode() {
        let md = "```swift\nlet a = 1\n```"
        for b in Markdown.parse(md) {
            if case .mermaid = b { return XCTFail("swift 代码块被当成了 mermaid") }
        }
    }

    /// mermaid.min.js 必须真的在包里。
    /// 打包脚本一改就可能漏掉它，漏了图就永远画不出来 —— 这条守着。
    func testMermaidJSIsBundled() {
        XCTAssertNotNil(Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
                        "mermaid.min.js 没打进 app 包（看 work/gen_pbx.py 的 RES）")
    }

    /// 端到端：真跑一遍 WebView → mermaid → 截图，必须出图。
    ///
    /// 这条是**唯一**能证明"图真的能画出来"的测试 ——
    /// 光测解析（上面那条）挡不住"库没进包 / JS 报错 / 截图为空"。
    @MainActor
    func testRendererProducesImage() async throws {
        let key = Mermaid.Key(code: "graph TD\n  A[开始] --> B[结束]",
                              width: 320, dark: true)
        let img: UIImage? = await withCheckedContinuation { c in
            MermaidRenderer.shared.image(for: key) { c.resume(returning: $0) }
        }
        XCTAssertNotNil(img, "mermaid 渲染没出图")
        XCTAssertGreaterThan(img?.size.width ?? 0, 20, "出图了但宽度是 0")
        XCTAssertGreaterThan(img?.size.height ?? 0, 20, "出图了但高度是 0")
    }

    /// 一屏里**同时**出现两张图时，第二张不许被丢掉。
    ///
    /// 以前 `load()` 里写的是 `if web != nil { done(nil) }` —— 装载中来的
    /// 请求直接判失败。列表里两张图一起 `onAppear` 就必现（实测复现过）：
    /// 第二张显示"图画不出来"。这条守着它。
    @MainActor
    func testConcurrentDiagramsBothRender() async throws {
        let box = MermaidBox()
        let imgs: [UIImage?] = await withCheckedContinuation {
            (c: CheckedContinuation<[UIImage?], Never>) in
            for code in ["graph LR\n A-->B", "graph TD\n C-->D"] {
                MermaidRenderer.shared.image(
                    for: .init(code: code, width: 300, dark: true)
                ) { img in
                    box.add(img)
                    if box.count == 2 { c.resume(returning: box.items) }
                }
            }
        }
        XCTAssertEqual(imgs.count, 2, "两次请求没有都回来")
        XCTAssertNotNil(imgs.first ?? nil, "第一张没出图")
        XCTAssertNotNil(imgs.last ?? nil, "第二张被丢了 —— 装载中的请求没有排队")
    }
}

/// 收并发渲染的结果。`@MainActor` 保证跟渲染回调同一条线程。
@MainActor
private final class MermaidBox {
    var items: [UIImage?] = []
    var count: Int { items.count }
    func add(_ i: UIImage?) { items.append(i) }
}

@MainActor
private final class SilentMermaidWebView: WKWebView {
    var pending: ((Any?, Error?) -> Void)?
    override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? { nil }
    override func evaluateJavaScript(_ javaScriptString: String,
                                     completionHandler: ((Any?, Error?) -> Void)? = nil) {
        pending = completionHandler
    }
}
