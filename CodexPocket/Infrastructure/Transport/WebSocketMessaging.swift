import Foundation



extension WebSocketTransport {
    /// 出站请求计数，按方法名分。只给耗电诊断用（见 `Build.stamp` 探针）。
    ///
    /// 放着不动也耗电的根源就是"定时器一直在发请求" —— 得先能量出来
    /// 到底谁在发、发多少，不然只能猜。
    static var outbound: [String: Int] = [:]

    @discardableResult
    func rpc(_ method: String, _ params: JSONDict = [:],
             done: ((Result<Any, Error>) -> Void)? = nil) -> Int {
        WebSocketTransport.outbound[method, default: 0] += 1
        seq += 1
        let id = seq
        guard method == "initialize" || state.isReady else {
            done?(.failure(RPCError(message: "还没连上电脑，稍后再试")))
            return id
        }
        if let done { waiters[id] = done }
        // send 返回 false = socket 根本没就绪，这条**确定**没发出去。
        // 必须立刻回错，不能让调用方等 120 秒超时 —— 那段时间里
        // 界面一直显示"在发送"，最后还报成"超时"，分不清到底发没发。
        if !send(["id": id, "method": method, "params": params]) {
            if let w = waiters.removeValue(forKey: id) {
                w(.failure(RPCError(message: "还没连上电脑，稍后再试")))
            }
            return id
        }
        if done != nil {
            // 长任务（turns/list）回包慢，给足时间；真超时也要报错，
            // 不能让界面永远停在"加载中"。
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                guard let self, let w = self.waiters.removeValue(forKey: id) else { return }
                w(.failure(RPCError(message: "请求超时：\(method)")))
            }
        }
        return id
    }

    func reply(to id: Int, result: JSONDict) {
        send(["id": serverRequestIDs.removeValue(forKey: id) as Any? ?? id, "result": result])
    }

    @discardableResult
    func reply(to approval: Approval, result: JSONDict) -> Bool {
        let sent = send(["id": approval.requestID as Any? ?? approval.id, "result": result])
        if sent { serverRequestIDs.removeValue(forKey: approval.id) }
        return sent
    }

    @discardableResult
    func reply(to request: ServerQuestionRequest, answers: [String: [String]]) -> Bool {
        guard let result = request.result(answers: answers) else { return false }
        let sent = send(["id": request.requestID as Any? ?? request.id, "result": result])
        if sent { serverRequestIDs.removeValue(forKey: request.id) }
        return sent
    }

    /// 返回 false = 没交给 socket，这条消息确定没发出去。
    @discardableResult
    func send(_ obj: JSONDict) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return false }
        // socket 还没建起来（或刚断）时 `task` 是 nil —— 以前这里直接
        // 静默丢掉，请求永远等不到回包，界面就"点了没反应"。
        guard let t = task, t.state == .running else {
            onSendFailure?("还没连上电脑，稍后再试")
            return false
        }
        t.send(.string(s)) { [weak self] err in
            guard let err else { return }
            // 只报告，不拆链路。send 报错不代表 socket 死了，
            // 真死了 receive 会立刻失败并由那里重连 ——
            // 这里再拆一次等于把刚建好的链路又砍掉（自己制造断线）。
            DispatchQueue.main.async { [weak self] in
                guard let self, self.task === t else { return }
                if let id = obj.int("id"), obj["method"] != nil,
                   let waiter = self.waiters.removeValue(forKey: id) {
                    waiter(.failure(err))
                }
                if self.task === t { self.onSendFailure?(err.localizedDescription) }
            }
        }
        return true
    }

    func handle(_ text: String) {
        // 任何**收到的东西**都证明这条链路活着（服务端每 15s 发一次
        // `bridge/tick`）。以前只认 `bridge/pong`，服务端主动推的消息
        // 全都不算数，空闲会话里判活会误判成死链而重连。
        lastPong = Date()
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? JSONDict else { return }
        handleObject(obj)
    }

    /// JSON 已在 WebSocketTransport.incoming 串行队列解析；这里只处理协议
    /// 状态和回调，固定在主线程执行，保证 waiter/serverRequestIDs 顺序。
    func handleObject(_ obj: JSONDict) {
        lastPong = Date()
        let id = obj.int("id")
        let method = obj.str("method")
        let params = obj.dict("params") ?? [:]

        // 请求的回包。
        if let id, obj["result"] != nil || obj["error"] != nil {
            guard let w = waiters.removeValue(forKey: id) else { return }
            if let e = obj.dict("error") {
                w(.failure(RPCError(message: e.str("message") ?? "未知错误", code: e.int("code"))))
            } else {
                w(.success(obj["result"] ?? [:]))
            }
            return
        }
        // 服务端发来的请求（审批）。
        if let id, let method {
            handleServerRequest(id: id, method: method, params: params)
            return
        }
        if let wireID = obj.str("id"), let method {
            let localID: Int
            if let existing = serverRequestIDs.first(where: { $0.value == wireID }) {
                localID = existing.key
            } else {
                serverRequestSequence -= 1
                localID = serverRequestSequence
                serverRequestIDs[localID] = wireID
            }
            handleServerRequest(id: localID, method: method, params: params)
            return
        }
        if method == "bridge/pong" { lastPong = Date(); return }
        if let method { onNotification?(method, params) }
    }

    func handleServerRequest(id: Int, method: String, params: JSONDict) {
        let threadId = params.str("threadId") ?? params.str("conversationId")
        let itemId = params.str("itemId") ?? params.str("callId") ?? ""
        let requestID = serverRequestIDs[id]
        switch method {
        case "item/tool/requestUserInput":
            guard let request = ServerQuestionRequest(id: id, requestID: requestID, params: params) else {
                let error: JSONDict = ["code": -32602, "message": "Invalid user input request"]
                send(["id": serverRequestIDs.removeValue(forKey: id) as Any? ?? id, "error": error])
                return
            }
            onUserInput?(request)
        case "item/commandExecution/requestApproval", "execCommandApproval":
            onApproval?(Approval(id: id, itemId: itemId,
                                 title: "运行命令",
                                 detail: params.str("command") ?? (params["command"] as? [String])?.joined(separator: " ") ?? params.str("reason") ?? "",
                                 isCommand: true, threadId: threadId, requestID: requestID,
                                 approvalID: params.str("approvalId"), requestMethod: method))
        case "item/fileChange/requestApproval", "applyPatchApproval":
            onApproval?(Approval(id: id, itemId: itemId,
                                 title: "修改文件",
                                 detail: params.str("reason") ?? "",
                                 isCommand: false, threadId: threadId, requestID: requestID,
                                 requestMethod: method))
        default:
            let message = "手机版暂不支持此类交互：\(method)"
            onSendFailure?(message)
            let error: JSONDict = ["code": -32601, "message": message]
            send(["id": serverRequestIDs.removeValue(forKey: id) as Any? ?? id,
                  "error": error])
        }
    }
}

/// 这一版 App 的标记：设置页可见，同时随心跳报到电脑端日志。
enum Build {
    static let stamp = "2026-10-17 v0.1.0 开源版，支持 Windows、macOS 与 CC Switch"
}
