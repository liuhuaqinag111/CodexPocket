import Foundation

/// app-server 的 JSON 是弱类型的，到处写 `as? [String: Any]` 会把代码淹掉。
/// 这里集中一层取值助手。
typealias JSONDict = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? { self[k] as? String }
    func int(_ k: String) -> Int? { (self[k] as? NSNumber)?.intValue }
    func dbl(_ k: String) -> Double? { (self[k] as? NSNumber)?.doubleValue }
    func bool(_ k: String) -> Bool? { self[k] as? Bool }
    func dict(_ k: String) -> JSONDict? { self[k] as? JSONDict }
    func arr(_ k: String) -> [Any]? { self[k] as? [Any] }
    func dicts(_ k: String) -> [JSONDict] { (self[k] as? [Any])?.compactMap { $0 as? JSONDict } ?? [] }
    func strs(_ k: String) -> [String] { (self[k] as? [Any])?.compactMap { $0 as? String } ?? [] }
}

/// 工具参数这种"半结构化文本"的解析助手。
///
/// 工具调用的 `arguments` 在协议里是**任意 JSON 值**，绝大多数时候是对象，
/// 但也见过纯字符串。两种情况都要能摆到界面上。
enum JSON {
    /// 解析成字典。不是对象就返回 nil。
    static func object(_ s: String) -> JSONDict? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{"), let d = t.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? JSONDict
    }

    /// 任意 JSON 值 → 界面上的一行文本。
    static func text(_ v: Any?) -> String {
        switch v {
        case nil, is NSNull: return ""
        case let s as String: return s
        case let n as NSNumber:
            return String(describing: n).hasSuffix(".0")
                ? String(n.intValue) : n.stringValue
        case let a as [Any]:
            return a.map { text($0) }.joined(separator: ", ")
        default:
            guard let d = try? JSONSerialization.data(withJSONObject: v as Any,
                                                      options: [.sortedKeys]),
                  let s = String(data: d, encoding: .utf8) else { return "" }
            return s
        }
    }

    /// 多行文本按行拆（待办、命令输出）。
    static func lines(_ s: String) -> [String] {
        s.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
