import Foundation

extension ThreadListModel {
    func delete(_ t: Thread) {
        let connection = connectionGeneration
        let identity = repository.connectionIdentity
        invalidateListReads()
        let activeIndex = threads.firstIndex { $0.id == t.id }
        let archivedIndex = archived.firstIndex { $0.id == t.id }
        let selected = currentID
        let oldProject = filed[t.id]
        let pending = pendingNew.removeValue(forKey: t.id)
        // 归属记录跟着走，不然删掉的会话会在 filed 里越积越多。
        filed.removeValue(forKey: t.id)
        saveFiled()
        threads.removeAll { $0.id == t.id }
        archived.removeAll { $0.id == t.id }
        if currentID == t.id { currentID = nil }
        repository.perform(.delete(["threadId": t.id])) { [weak self] r in
            Task { @MainActor in
                guard let self else { return }
                guard self.connectionGeneration == connection,
                      self.repository.connectionIdentity == identity else { return }
                if case .failure(let e) = r {
                    self.pendingNew[t.id] = pending
                    if let index = activeIndex, !self.threads.contains(where: { $0.id == t.id }) {
                        self.threads.insert(t, at: min(index, self.threads.count))
                    }
                    if let index = archivedIndex, !self.archived.contains(where: { $0.id == t.id }) {
                        self.archived.insert(t, at: min(index, self.archived.count))
                    }
                    if selected == t.id && self.currentID == nil { self.currentID = t.id }
                    self.filed[t.id] = oldProject
                    self.saveFiled()
                    self.banner = e.localizedDescription
                    return
                }
                self.load()
            }
        }
    }

    /// 服务端说这个会话被归档 / 取消归档了（电脑端操作的）。
    ///
    /// 服务端广播的 `thread/archived` / `thread/unarchived` 只带 threadId
    /// （实测 payload 就是 `{"threadId":"..."}`），所以要靠本地已有的对象搬家。
    /// 不处理的话手机列表和电脑端会一直不一致。
    func markArchived(_ id: String, _ on: Bool) {
        invalidateListReads()
        if on { pendingNew.removeValue(forKey: id) }
        if on {
            guard let i = threads.firstIndex(where: { $0.id == id }) else { return }
            var t = threads.remove(at: i)
            t.archived = true
            if !archived.contains(where: { $0.id == id }) { archived.insert(t, at: 0) }
        } else {
            guard let i = archived.firstIndex(where: { $0.id == id }) else { return }
            var t = archived.remove(at: i)
            t.archived = false
            if !threads.contains(where: { $0.id == id }) { threads.insert(t, at: 0) }
        }
        if currentID == id, on { currentID = nil }
    }

    /// 服务端说这个会话被删了（电脑端删的）。
    ///
    /// 服务端会广播 `thread/deleted`，但以前客户端根本没处理 ——
    /// 电脑端删掉的会话在手机列表里**永远留着**，点进去报
    /// "thread not loaded"（实测）。
    /// 只做本地摘除，不再回调服务端（它已经删了）。
    /// 单元测试用的注入口（`threads` / `archived` 是 private(set)）。
    /// 只有测试会调；生产路径一律走 load()。
    /// 单元测试用的注入口（`models` 是 private(set)）。
    func __testSeedModels(_ rows: [ModelOption]) { models = rows }

    /// 单元测试用的注入口（`globalModel` / `globalEffort` 是 private(set)）。
    /// 单元测试用的注入口（`settings.defaultModel` 走 UserDefaults，测试要隔离）。
    func __testSeedDefault(model: String, effort: String) {
        settings.defaultModel = model
        settings.defaultEffort = effort
    }

    /// 单元测试用的注入口（`globalEfforts` 是 private(set)）。
    func __testSeedEfforts(_ rows: [String]) { globalEfforts = rows }

    func __testSeedGlobal(model: String, effort: String) {
        globalModel = model
        globalEffort = effort
    }

    func __testSeed(threads: [Thread], archived: [Thread]) {
        self.threads = threads
        self.archived = archived
    }

    func dropped(_ id: String) {
        invalidateListReads()
        pendingNew.removeValue(forKey: id)
        filed.removeValue(forKey: id)
        saveFiled()
        threads.removeAll { $0.id == id }
        archived.removeAll { $0.id == id }
        if currentID == id { currentID = nil }
    }

    /// 把一个会话归到项目里。
    ///
    /// 真正的接口是 **`thread/metadata/update { threadId, projectId }`** ——
    /// 不是 `project/move`。之前试错了方法（`project/move` / `project/update`
    /// 传 threadIds 都回 `ok` 但不生效，库里 `project_id` 一直是 NULL），
    /// 于是错判成"服务端没有可写的接口"，退而求其次做了纯本地方案 ——
    /// 那样重装 App 就丢，电脑端也看不到。
    /// 现在写服务端：实测库里 `threads.project_id` 真的变了，回读也认。
    func move(_ t: Thread, to project: Project) {
        let connection = connectionGeneration
        let identity = repository.connectionIdentity
        let old = filed[t.id]
        filed[t.id] = project.id          // 乐观更新，界面立刻动
        setProject(t.id, project.id)
        saveFiled()
        objectWillChange.send()
        repository.perform(.metadata(["threadId": t.id, "projectId": project.id])) {
            [weak self] r in
            Task { @MainActor in
                guard let self else { return }
                guard self.connectionGeneration == connection,
                      self.repository.connectionIdentity == identity else { return }
                if case .failure(let e) = r {
                    // 失败就退回去，别让界面骗人。
                    if let old { self.filed[t.id] = old } else { self.filed.removeValue(forKey: t.id) }
                    self.setProject(t.id, t.projectId, hasMetadata: t.hasProjectMetadata)
                    self.saveFiled()
                    self.banner = "移不过去：" + e.localizedDescription
                }
                self.load()
            }
        }
    }

    /// 从项目里移出来（回到「最近」）。
    ///
    /// 服务端用**空字符串**表示"不属于任何项目"：传 `null` 会报
    /// "thread metadata update must include at least one field"（实测）。
    func unfile(_ t: Thread) {
        let connection = connectionGeneration
        let identity = repository.connectionIdentity
        let old = filed[t.id]
        filed[t.id] = ""
        setProject(t.id, nil)
        saveFiled()
        objectWillChange.send()
        repository.perform(.metadata(["threadId": t.id, "projectId": ""])) {
            [weak self] r in
            Task { @MainActor in
                guard let self else { return }
                guard self.connectionGeneration == connection,
                      self.repository.connectionIdentity == identity else { return }
                if case .failure(let e) = r {
                    self.filed[t.id] = old
                    self.setProject(t.id, t.projectId, hasMetadata: t.hasProjectMetadata)
                    self.saveFiled()
                    self.banner = "移不出来：" + e.localizedDescription
                }
                self.load()
            }
        }
    }

    func saveFiled() {
        d.set(filed, forKey: "filedProjects")
    }

    func setProject(_ id: String, _ projectID: String?, hasMetadata: Bool = true) {
        for i in threads.indices where threads[i].id == id {
            threads[i].projectId = projectID
            threads[i].hasProjectMetadata = hasMetadata
        }
        for i in archived.indices where archived[i].id == id {
            archived[i].projectId = projectID
            archived[i].hasProjectMetadata = hasMetadata
        }
        if let pending = pendingNew[id] {
            var updated = pending.0
            updated.projectId = projectID
            updated.hasProjectMetadata = hasMetadata
            pendingNew[id] = (updated, pending.1)
        }
    }

    /// 测试用：直接塞列表和项目，不走网络。
    func inject(threads: [Thread]? = nil, projects: [Project]? = nil) {
        if let threads { self.threads = threads }
        if let projects { self.projects = projects }
    }

    /// 测试用：清掉本地归属表。
    ///
    /// `filed` 存在 UserDefaults 里，测试之间会串（实测：上一个用例把
    /// T3 归到 B，下一个用例的前置断言就炸了）。
    func clearFiled() {
        filed = [:]
        saveFiled()
    }

    func archive(_ t: Thread, _ on: Bool) {
        let connection = connectionGeneration
        let identity = repository.connectionIdentity
        let selected = currentID
        let pending = pendingNew[t.id]
        markArchived(t.id, on)
        repository.perform(.archive(["threadId": t.id], on)) { [weak self] r in
            Task { @MainActor in
                guard let self else { return }
                guard self.connectionGeneration == connection,
                      self.repository.connectionIdentity == identity else { return }
                switch r {
                case .failure(let e):
                    // 失败就退回去，别让界面骗人。
                    self.markArchived(t.id, !on)
                    self.pendingNew[t.id] = pending
                    if selected == t.id, self.currentID == nil { self.currentID = t.id }
                    self.banner = e.localizedDescription
                    self.load()
                case .success:
                    // 延迟一拍再重拉：等 rollout 落盘，否则拿到的是旧列表。
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard self.connectionGeneration == connection,
                          self.repository.connectionIdentity == identity else { return }
                    self.load()
                }
            }
        }
    }

    func rename(_ t: Thread, to name: String) {
        let connection = connectionGeneration
        let identity = repository.connectionIdentity
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        // 已经有会话叫这个名字就加个序号。
        //
        // 服务端**允许重名**，列表里两行一模一样的标题，用户根本分不清
        // 哪条是哪条（他报的就是"名字相同会覆盖"）。这里只是显示层去重，
        // 服务端那份名字照旧 —— 序号只在本地这一份上加。
        let unique = uniqueName(n, excluding: t.id)
        repository.perform(.rename(["threadId": t.id, "name": unique])) { [weak self] r in
            Task { @MainActor in
                guard let self else { return }
                guard self.connectionGeneration == connection,
                      self.repository.connectionIdentity == identity else { return }
                if case .failure(let e) = r { self.banner = e.localizedDescription; return }
                self.setName(t.id, unique)
            }
        }
    }

    /// 这条错误是不是"根本没发出去"。
    ///
    /// 用户报的"新会话有时候建不出来"就是它：手机网络十几秒抖一次
    /// （桥接日志里 465 次 code=1006），点在新会话那一刻，
    /// `WebSocketTransport.send` 发现 socket 没就绪就直接回错，请求压根没上路。
    /// 这种错误**重发是安全的**，所以要自动等连接恢复。
    static func isOffline(_ m: String) -> Bool {
        m.contains("还没连上电脑")
    }

    /// 新建会话。返回新 id（失败返回 nil）。
    func create(cwd: String?, model: String, effort: String,
                first message: String?, retry: Int = 0, net: Int = 0,
                connection: Int? = nil,
                connectionIdentity: String? = nil,
                done: @escaping (String?) -> Void) {
        let connection = connection ?? connectionGeneration
        let identity = connectionIdentity ?? repository.connectionIdentity
        guard self.connectionGeneration == connection,
              repository.connectionIdentity == identity else { done(nil); return }
        var params: JSONDict = [:]
        if let cwd, !cwd.isEmpty { params["cwd"] = cwd }
        if !model.isEmpty { params["model"] = model }
        if !effort.isEmpty { params["config"] = ["model_reasoning_effort": effort] }
        repository.perform(.create(params)) { [weak self] r in
            Task { @MainActor in
                guard let self else { return }
                guard self.connectionGeneration == connection,
                      self.repository.connectionIdentity == identity else { done(nil); return }
                switch r {
                case .success(let v):
                    // 之前可能挂着"正在建新会话…"（重试过几次），建成了就撤掉。
                    if self.banner == "正在建新会话…" { self.banner = nil }
                    let id = (v as? JSONDict)?.dict("thread")?.str("id")
                        ?? (v as? JSONDict)?.str("threadId")
                    // 立刻把新会话插进列表。服务端 thread/list 有落盘延迟，
                    // 等它回来再查会查不到 —— 表现就是"新会话创建不了"：
                    // 铅笔点了没反应，因为回调里按 id 找不到这个会话。
                    if let id, let th = Thread(json: [
                        "id": id,
                        "name": "",
                        "model": model,
                        "reasoningEffort": effort,
                        // 用服务端回的真实目录（`~` 会被它展开成家目录），
                        // 不然本地这一行会挂着 "~"，分组判断也跟着不准。
                        "cwd": (v as? JSONDict)?.dict("thread")?.str("cwd") ?? cwd ?? "",
                        "updatedAt": Date().timeIntervalSince1970 * 1000,
                    ]) {
                        self.lastCreatedCwd = th.cwd
                        self.pendingNew[id] = (th, Date())
                        if !self.threads.contains(where: { $0.id == id }) {
                            self.threads.insert(th, at: 0)
                        }
                    }
                    self.load()
                    done(id)
                    guard self.connectionGeneration == connection,
                          self.repository.connectionIdentity == identity else { return }
                    if let id, let message, !message.isEmpty { self.onFirstMessage?(id, message) }
                case .failure(let e):
                    let why = e.localizedDescription
                    // 连接抖动：这条**确定**没发出去，自动等连接恢复再发。
                    // 不重试的话，用户点在那十几秒的窗口里就"什么都没发生"。
                    if Self.isOffline(why), net < 8 {
                        self.banner = "正在建新会话…"
                        self.repository.reconnect()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.create(cwd: cwd, model: model, effort: effort,
                                        first: message, retry: retry, net: net + 1,
                                        connection: connection,
                                        connectionIdentity: identity,
                                        done: done)
                        }
                        return
                    }
                    if Self.isOffline(why) {
                        self.banner = "连不上电脑，新会话没建成"
                        done(nil)
                        return
                    }
                    // 服务端在排空（重启中 / 长跑后卡住）：等一秒重试一次。
                    // 直接报错给用户的话，表现就是"新会话创建不了"，
                    // 而其实等一会儿就好了。
                    if why.contains("draining"), retry < 3 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.create(cwd: cwd, model: model, effort: effort,
                                        first: message, retry: retry + 1, net: net,
                                        connection: connection,
                                        connectionIdentity: identity,
                                        done: done)
                        }
                        return
                    }
                    let uncertain = why.contains("请求超时") || why.contains("连接已断开")
                        || why.contains("连接中断")
                    self.banner = uncertain ? "新会话结果还没确认，请刷新列表查看"
                        : "建不了新会话：" + why
                    if uncertain { self.fetchThreadsFirstPage() }
                    done(nil)
                }
            }
        }
    }

    /// 服务端广播：会话开始/停止运行。跑完且不是当前会话就标未读。
    func setRunning(_ id: String, _ running: Bool) {
        for i in threads.indices where threads[i].id == id {
            let wasRunning = threads[i].running
            threads[i].running = running
            if wasRunning && !running && currentID != id { threads[i].unread = true }
        }
        for i in archived.indices where archived[i].id == id {
            archived[i].running = running
        }
    }

    func markSeen(_ id: String) {
        if let i = threads.firstIndex(where: { $0.id == id }) { threads[i].unread = false }
        if let i = archived.firstIndex(where: { $0.id == id }) { archived[i].unread = false }
    }

    func setName(_ id: String, _ name: String) {
        if let i = threads.firstIndex(where: { $0.id == id }) {
            threads[i].title = name
            threads[i].named = true
        }
        if let i = archived.firstIndex(where: { $0.id == id }) {
            archived[i].title = name
            archived[i].named = true
        }
        if let pending = pendingNew[id] {
            var updated = pending.0
            updated.title = name
            updated.named = true
            pendingNew[id] = (updated, pending.1)
        }
    }

    func thread(_ id: String) -> Thread? {
        threads.first { $0.id == id } ?? archived.first { $0.id == id }
    }
}

extension ThreadListModel {
    /// 会话内切模型（对后续回合生效）。
    /// 改这个会话的推理强度。改完立刻生效，不用重开会话。

}

extension ThreadListModel {
    /// 同名会话在显示层加序号：`名字` / `名字 2` / `名字 3`…
    ///
    /// 服务端不管重名，界面上两行一模一样的标题就分不清谁是谁。
    /// `excluding` 是自己那条，改名时不跟自己比。
    func uniqueName(_ base: String, excluding id: String) -> String {
        let taken = Set((threads + archived)
            .filter { $0.id != id }
            .map { $0.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") && n < 999 { n += 1 }
        return "\(base) \(n)"
    }
}
