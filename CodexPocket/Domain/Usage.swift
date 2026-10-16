import Foundation

/// 一个会话烧了多少 token。
///
/// 服务端每轮结束推 `thread/tokenUsage/updated`，里面是
/// `tokenUsage.{totalTokens,inputTokens,cachedInputTokens,outputTokens,reasoningOutputTokens}`
/// 加一个 `modelContextWindow`（这个模型装得下多少）。
/// 之前 App 把这个事件整个丢掉了 —— 用户："token 用量、剩余额度看不到"。
struct TokenUsage: Equatable {
    let total: Int
    let input: Int
    let output: Int
    let cached: Int
    let reasoning: Int
    /// 模型的上下文窗口。未知时 0。
    let contextWindow: Int

    init?(json: JSONDict) {
        // 服务端推的真实形态（实测抓包）：
        //   {"tokenUsage":{"total":{...},"last":{...},"modelContextWindow":475000}}
        // 以前直接读 `tokenUsage.totalTokens` —— 嵌套了一层，**每一包都解析
        // 失败**，于是用量页永远是"这个会话还没跑过"。
        // 取 `last`（这一轮请求的上下文占用）而不是 `total`（整个会话累计，
        // 会远大于窗口，百分比永远是 100%）。
        var u = json.dict("tokenUsage") ?? json.dict("lastTokenUsage") ?? json
        if let last = u.dict("last") { u = last }
        else if let tot = u.dict("total") { u = tot }
        guard let t = u.int("totalTokens") else { return nil }
        total = t
        input = u.int("inputTokens") ?? 0
        output = u.int("outputTokens") ?? 0
        cached = u.int("cachedInputTokens") ?? 0
        reasoning = u.int("reasoningOutputTokens") ?? 0
        // 窗口在**外层**（`tokenUsage.modelContextWindow`），取 last 之后就丢了，
        // 所以必须从原包读。
        let outer = json.dict("tokenUsage") ?? json
        contextWindow = outer.int("modelContextWindow")
            ?? outer.int("model_context_window")
            ?? json.int("modelContextWindow")
            ?? json.int("model_context_window")
            ?? u.int("modelContextWindow")
            ?? 0
    }

    /// 上下文占用百分比。窗口未知返回 -1（别显示假的 0%）。
    var percent: Int {
        guard contextWindow > 0 else { return -1 }
        return min(100, Int((Double(total) / Double(contextWindow) * 100).rounded()))
    }

    /// 顶栏那一小行：`38% · 104.2k`。
    var short: String {
        let n = total >= 1000 ? String(format: "%.1fk", Double(total) / 1000) : "\(total)"
        return percent >= 0 ? "\(percent)% · \(n)" : n
    }
}

// MARK: - 持久化

extension TokenUsage {
    /// 存下来用的形态。
    var stored: JSONDict {
        ["totalTokens": total, "inputTokens": input, "outputTokens": output,
         "cachedInputTokens": cached, "reasoningOutputTokens": reasoning,
         "modelContextWindow": contextWindow]
    }

    init?(stored d: JSONDict) {
        guard let t = d.int("totalTokens") else { return nil }
        self.total = t
        self.input = d.int("inputTokens") ?? 0
        self.output = d.int("outputTokens") ?? 0
        self.cached = d.int("cachedInputTokens") ?? 0
        self.reasoning = d.int("reasoningOutputTokens") ?? 0
        self.contextWindow = d.int("modelContextWindow") ?? 0
    }
}

