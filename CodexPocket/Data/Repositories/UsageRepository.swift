import Foundation

/// Last observed token usage and bridge fallback.

///
/// 为什么要本地记：服务端**没有**"查一个已有会话用了多少 token"的方法
/// （实测：`thread/read` 里没有任何带 token 的字段，
/// `thread/turns/list` 的 turn 只有 id/status/durationMs，
/// `thread/resume` 既不回 usage 也不补发事件）。
/// 用量只在跑回合时通过 `thread/tokenUsage/updated` **推一次**。
/// 所以打开一个早就跑完的会话，界面只能说"没跑过" —— 用户看到的就是
/// 一个空白的用量页（截图里那句"这个会话还没跑过"）。
/// 本地把上次的值记下来，至少能显示"上次是多少"。
enum UsageCache {
    private static let key = "usageCache.v1"
    private static let limit = 60

    static func save(_ id: String, _ u: TokenUsage, at: Date = Date()) {
        guard !id.isEmpty else { return }
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: JSONDict] ?? [:]
        var row = u.stored
        row["at"] = at.timeIntervalSince1970
        all[id] = row
        // 只留最近 limit 个（按时间）。
        if all.count > limit {
            let sorted = all.sorted { a, b in
                ((a.value["at"] as? Double) ?? 0) > ((b.value["at"] as? Double) ?? 0)
            }
            all = Dictionary(uniqueKeysWithValues: sorted.prefix(limit).map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(all, forKey: key)
    }

    static func load(_ id: String) -> (usage: TokenUsage, at: Date)? {
        guard !id.isEmpty,
              let all = UserDefaults.standard.dictionary(forKey: key) as? [String: JSONDict],
              let row = all[id],
              let u = TokenUsage(stored: row) else { return nil }
        let at = (row["at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
        return (u, at)
    }

    static func drop(_ id: String) {
        guard var all = UserDefaults.standard.dictionary(forKey: key) as? [String: JSONDict]
        else { return }
        all.removeValue(forKey: id)
        UserDefaults.standard.set(all, forKey: key)
    }
}

// MARK: - 从桥接补拉

/// 问**常驻的桥接**要"这个会话最近一次的用量"。
///
/// 服务端没有查历史用量的方法（实测 `thread/read`、`thread/turns/list`、
/// `thread/resume` 都拿不到），而 `thread/tokenUsage/updated` 只在跑回合时
/// 推一次 —— 手机不在线那一包就永远没了，打开老会话的用量页一直是
/// "这个会话还没跑过"。桥接 24 小时挂着，把每轮的用量记在磁盘上，
/// App 打开会话时来补一次（`GET /usage?threadId=`）。
enum UsageFetch {
    @MainActor
    static func load(_ settings: PreferencesModel, _ id: String) async -> TokenUsage? {
        guard !id.isEmpty,
              let url = settings.bridge(path: "/usage",
                                        query: [URLQueryItem(name: "threadId", value: id)])
        else { return nil }
        // 拆开写：`try? await` 和后面几条 `let` 绑在同一个 guard 条件列表里，
        // Xcode 14.3 的编译器会报 "expression is 'async' but is not marked
        // with 'await'"（实测）。
        let got = try? await NetSession.shared.data(from: url)
        guard let (d, resp) = got,
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = (try? JSONSerialization.jsonObject(with: d)) as? JSONDict,
              let u = o.dict("usage") else { return nil }
        return TokenUsage(json: ["tokenUsage": u])
    }
}
