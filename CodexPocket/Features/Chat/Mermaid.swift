import SwiftUI
import WebKit

/// Mermaid 图。
///
/// 为什么要 WebView：mermaid 是 JS 库，没有原生实现。这里**只留一个**
/// `WKWebView`（`MermaidRenderer.shared`）串行渲染所有图，渲染完
/// 导出 PDF 并栅格化成图片、缓存，再把图交给列表显示 ——
/// 每张图各开一个 WebView 的话，一屏几张图就是几百 MB，必被杀。
///
/// `mermaid.min.js` 打进包里（`Resources/`），不走 CDN：手机走隧道，
/// 依赖公网 CDN 会变成"图渲染不出来"这种查不清的故障。
enum Mermaid {
    /// 一段 ```mermaid 围栏。
    struct Diagram: Hashable {
        let code: String
    }

    /// 缓存键：代码 + 宽度 + 深浅色。宽度参与是因为换行位置跟宽度有关。
    struct Key: Hashable {
        let code: String
        let width: Int
        let dark: Bool
    }
}

@MainActor
final class MermaidRenderer: NSObject, WKNavigationDelegate {
    static let shared = MermaidRenderer()

    private var web: WKWebView?
    private var ready = false
    private var queue: [Mermaid.Key] = []
    private var callbacks: [Mermaid.Key: [(UIImage?) -> Void]] = [:]
    private var busy = false
    private var cache: [Mermaid.Key: UIImage] = [:]
    private var order: [Mermaid.Key] = []
    private(set) var cachedBytes = 0
    var cachedImageCount: Int { cache.count }
    private let cacheBudget: Int
    /// 正在等 WebView 装载完的请求。装载中来的请求排队，**不能丢**。
    private var waiters: [(WKWebView?) -> Void] = []
    private var loading = false
    private var jobID: UUID?
    private var activeDone: ((UIImage?) -> Void)?
    private var deadline: Task<Void, Never>?
    private let timeout: TimeInterval
    private let makeWebView: @MainActor () -> WKWebView

    init(timeout: TimeInterval = 45, cacheBudget: Int = 40 * 1024 * 1024,
         makeWebView: (@MainActor () -> WKWebView)? = nil) {
        self.timeout = timeout
        self.cacheBudget = max(0, cacheBudget)
        self.makeWebView = makeWebView ?? {
            WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        }
        super.init()
    }

    private let limit = 40

    private func cost(_ image: UIImage, _ key: Mermaid.Key) -> Int {
        (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0) + key.code.utf8.count
    }

    func cacheImage(_ image: UIImage, for key: Mermaid.Key) {
        let bytes = cost(image, key)
        guard bytes <= cacheBudget else { return }
        if let old = cache.removeValue(forKey: key) { cachedBytes -= cost(old, key) }
        order.removeAll { $0 == key }
        cache[key] = image; order.append(key); cachedBytes += bytes
        while cachedBytes > cacheBudget || order.count > limit {
            let oldKey = order.removeFirst()
            if let old = cache.removeValue(forKey: oldKey) { cachedBytes -= cost(old, oldKey) }
        }
    }

    func image(for key: Mermaid.Key, _ done: @escaping (UIImage?) -> Void) {
        if let hit = cache[key] { done(hit); return }
        if callbacks[key] != nil { callbacks[key]?.append(done); return }
        guard callbacks.count < 40, key.code.utf8.count <= 512 * 1024 else { done(nil); return }
        callbacks[key] = [done]
        queue.append(key)
        pump()
    }

    private func pump() {
        guard !busy, !queue.isEmpty else { return }
        let key = queue.removeFirst()
        let done: (UIImage?) -> Void = { [weak self] image in
            let waiting = self?.callbacks.removeValue(forKey: key) ?? []
            waiting.forEach { $0(image) }
        }
        busy = true
        let id = UUID()
        jobID = id
        activeDone = { [weak self] img in self?.finish(key, img, id, done) }
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64((self?.timeout ?? 45) * 1_000_000_000)) }
            catch { return }
            guard let self, self.jobID == id else { return }
            self.activeDone?(nil)
        }
        load { [weak self] web in
            guard let self, self.jobID == id else { return }
            guard let web else { self.activeDone?(nil); return }
            self.draw(web, key) { [weak self] img in
                guard let self, self.jobID == id else { return }
                self.activeDone?(img)
            }
        }
    }

    private func finish(_ key: Mermaid.Key, _ img: UIImage?, _ id: UUID, _ done: (UIImage?) -> Void) {
        guard jobID == id else { return }
        jobID = nil
        activeDone = nil
        deadline?.cancel()
        deadline = nil
        if let img {
            cacheImage(img, for: key)
        } else {
            web?.navigationDelegate = nil
            web?.stopLoading()
            web = nil
            ready = false
            loading = false
            waiters.removeAll()
        }
        busy = false
        done(img)
        pump()
    }

    /// 建一次 WebView，把 mermaid 库和页面壳装进去。
    private func load(_ done: @escaping (WKWebView?) -> Void) {
        if let web, ready { done(web); return }
        // 装载中：**排队等**，不能直接放弃。
        // 以前这里是 `if web != nil { done(nil) }` —— 一屏里两张图同时出现时，
        // 第二张会被丢掉，界面显示"图画不出来"（实测：单元测试里复现）。
        waiters.append(done)
        guard !loading else { return }
        loading = true

        let w = makeWebView()
        w.navigationDelegate = self
        w.isOpaque = false
        w.backgroundColor = .clear
        w.scrollView.isScrollEnabled = false
        web = w

        guard let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else {
            settle(nil)
            return
        }
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
          html,body{margin:0;padding:0;background:transparent;}
          #d{display:inline-block;}
          .err{color:#FF453A;font:12px -apple-system;white-space:pre-wrap;}
        </style></head><body><div id="d"></div>
        <script>\(js)</script>
        <script>
          mermaid.initialize({startOnLoad:false, securityLevel:'strict',
                              theme:'dark', fontFamily:'-apple-system'});
          window.__render = async function(code, dark) {
            mermaid.initialize({startOnLoad:false, securityLevel:'strict',
                                theme:dark ? 'dark' : 'default', fontFamily:'-apple-system'});
            const d = document.getElementById('d');
            d.innerHTML = '';
            try {
              const r = await mermaid.render('g' + Math.random().toString(36).slice(2), code);
              d.innerHTML = r.svg;
              const svg = d.querySelector('svg');
              if (svg) { svg.removeAttribute('height'); svg.style.maxWidth = '100%'; }
              const t = d.querySelector('.err'); if (t) t.remove();
            } catch (e) {
              d.innerHTML = '<div class="err">Mermaid 语法错误\\n' +
                            String(e && e.message || e) + '</div>';
            }
            const r2 = d.getBoundingClientRect();
            return [Math.ceil(r2.width), Math.ceil(r2.height)];
          };
        </script></body></html>
        """
        w.loadHTMLString(html, baseURL: nil)
        // 库有 3.3MB，解析要一会儿。等它真能跑了再放行。
        waitReady(w, 0)
    }

    /// 装载结束（成功或失败）：一次性唤醒**所有**排队的请求。
    private func settle(_ w: WKWebView?) {
        loading = false
        ready = (w != nil)
        let all = waiters
        waiters.removeAll()
        for cb in all { cb(w) }
    }

    private func waitReady(_ w: WKWebView, _ n: Int) {
        guard web === w, loading, let id = jobID else { return }
        // 上限 40 秒。以前是 10 秒 —— mermaid.min.js 有 3.3MB，机器忙的时候
        // 解析要 9.9 秒，测试就会时绿时红（实测：同一个测试 2.1s 过、9.9s 挂）。
        guard n < 400 else { settle(nil); return }
        w.evaluateJavaScript("typeof mermaid !== 'undefined' && !!window.__render") { [weak self] v, _ in
            Task { @MainActor in
                guard let self, self.web === w, self.jobID == id, self.loading else { return }
                if (v as? Bool) == true { self.settle(w) }
                else {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    self.waitReady(w, n + 1)
                }
            }
        }
    }

    private func draw(_ w: WKWebView, _ key: Mermaid.Key, _ done: @escaping (UIImage?) -> Void) {
        guard let id = jobID else { return }
        w.frame = CGRect(x: 0, y: 0, width: CGFloat(key.width), height: 100)
        // **必须用 `callAsyncJavaScript`**：`__render` 是 async 函数，
        // 返回的是 Promise，而 `evaluateJavaScript` 不等 Promise ——
        // 它拿到的永远是 nil（实测：渲染静默失败，图一直画不出来）。
        w.callAsyncJavaScript("return await window.__render(code, dark);",
                              arguments: ["code": key.code, "dark": key.dark],
                              in: nil, in: .page) { r in
            Task { @MainActor in
                guard self.web === w, self.jobID == id else { return }
                guard case .success(let v) = r, let pair = v as? [NSNumber], pair.count == 2 else {
                    done(nil); return
                }
                let h = max(40, min(2000, CGFloat(truncating: pair[1])))
                w.frame = CGRect(x: 0, y: 0, width: CGFloat(key.width), height: h)
                // 尺寸改完要等一帧再截，否则截到的是旧高度。
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard self.web === w, self.jobID == id else { return }
                self.snap(w, done)
            }
        }
    }

    private func snap(_ w: WKWebView, _ done: @escaping (UIImage?) -> Void) {
        // 离屏 WKWebView 的 takeSnapshot 依赖 GPU 进程；全量测试里 GPU
        // 进程超时/退出时它随机回 nil。打印成 PDF 后在 CoreGraphics
        // 栅格化，不依赖截图进程，也保留 SVG 的文字/线条。
        let cfg = WKPDFConfiguration()
        cfg.rect = CGRect(x: 0, y: 0, width: w.frame.width, height: w.frame.height)
        w.createPDF(configuration: cfg) { result in
            let image: UIImage? = {
                guard case .success(let data) = result,
                      let provider = CGDataProvider(data: data as CFData),
                      let document = CGPDFDocument(provider),
                      let page = document.page(at: 1) else { return nil }
                let size = page.getBoxRect(.mediaBox).size
                guard size.width > 0, size.height > 0 else { return nil }
                let format = UIGraphicsImageRendererFormat()
                format.scale = min(UIScreen.main.scale, 2)
                return UIGraphicsImageRenderer(size: size, format: format).image { context in
                    context.cgContext.translateBy(x: 0, y: size.height)
                    context.cgContext.scaleBy(x: 1, y: -1)
                    context.cgContext.drawPDFPage(page)
                }
            }()
            Task { @MainActor in done(image) }
        }
    }
    private func fail(_ w: WKWebView) {
        guard web === w else { return }
        if let activeDone { activeDone(nil) }
        else {
            w.navigationDelegate = nil
            web = nil
            ready = false
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in self?.fail(webView) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in self?.fail(webView) }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor [weak self] in self?.fail(webView) }
    }
}


/// 一张 Mermaid 图。
///
/// 渲染是异步的（要过 WebView），所以先占位、好了再换成图。
/// 渲染失败就把源码摊开 —— 总比留一片空白强。
struct MermaidBlock: View {
    let code: String

    @Environment(\.colorScheme) private var scheme
    @State private var image: UIImage?
    @State private var failed = false
    @State private var requested: Mermaid.Key?

    /// 渲染宽度：屏宽扣掉两侧留白和卡片内边距。
    private var width: Int {
        Int(max(180, UIScreen.main.bounds.width - UI.gutter * 2 - 24))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if failed {
                VStack(alignment: .leading, spacing: 6) {
                    LucideLabel("图画不出来，下面是源码", "exclamationmark.triangle")
                        .font(Palette.F.caption)
                        .foregroundStyle(Palette.warning)
                    CodeBlock(language: "mermaid", code: code)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在画图…")
                        .font(Palette.F.caption)
                        .foregroundStyle(Palette.textFaint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 56)
            }
        }
        .onAppear(perform: render)
        .onChange(of: code) { _ in render() }
        .onChange(of: scheme) { _ in render() }
    }

    private func render() {
        let key = Mermaid.Key(code: code, width: width, dark: scheme == .dark)
        guard requested != key else { return }
        requested = key
        image = nil
        failed = false
        // 必须跳一次 Task：`onAppear` 是同步的非隔离上下文，
        // 而 `MermaidRenderer` 是 @MainActor（Xcode 14.3 会直接报错）。
        Task { @MainActor in
            guard requested == key else { return }
            MermaidRenderer.shared.image(for: key) { img in
                guard requested == key else { return }
                if let img { image = img } else { failed = true }
            }
        }
    }
}
