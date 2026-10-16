import Foundation

extension ThreadListModel {
    private func loadCatalog(models: Bool, current: @escaping () -> Bool,
                             failed: (() -> Void)? = nil,
                             done: @escaping ([JSONDict]) -> Void) {
        var all: [JSONDict] = []
        var seen = Set<String>()
        func page(_ cursor: String?) {
            guard current() else { return }
            var params: JSONDict = ["limit": 100]
            if let cursor { params["cursor"] = cursor }
            let op: ThreadOperation = models ? .modelPage(params) : .projectPage(params)
            repository.perform(op) { result in
                Task { @MainActor in
                    guard current() else { return }
                    guard case .success(let value) = result else { failed?(); return }
                    let payload = value as? JSONDict
                    guard let data = (payload?["data"] as? [JSONDict])
                        ?? (payload?[models ? "models" : "projects"] as? [JSONDict])
                        ?? (value as? [JSONDict]) else { failed?(); return }
                    all.append(contentsOf: data)
                    guard let next = payload?.str("nextCursor"), !next.isEmpty else {
                        done(all); return
                    }
                    guard seen.insert(next).inserted else { failed?(); return }
                    page(next)
                }
            }
        }
        page(nil)
    }

    func invalidateListReads() {
        activeListReadSeq += 1
        archivedListReadSeq += 1
        activeFullReadSeq = nil
        archivedFullReadSeq = nil
        loading = false
    }

    func load() {
        guard repository.isReady else { return }
        loading = true
        loadProjects()
        loadModels()
        refreshConfiguration(force: true)
        fetchThreads()
        fetchArchived()
    }

    /// 一页拉多少行。
    ///
    /// **服务端硬上限就是 100**（实测 limit 传 200/500 也只回 100），
    /// 回包里带 `nextCursor`，得靠它接着翻。以前一律传 200 且从不翻页 ——
    /// 于是超过 100 行的部分永远看不到（实测归档 230 个线程，App 只显示 66）。
    static let listPage = 100
    /// 把一个列表的所有页拉完，再交给 `done`。
    ///
    /// 串行翻页（下一页要上一页的 cursor），页与页之间不并发。
    func fetchAllPages(archived: Bool, maxPages: Int? = nil,
                               done: @escaping ([JSONDict], Bool) -> Void) {
        var acc: [JSONDict] = []
        var seen = Set<String>()
        let sequence = archived ? archivedListReadSeq : activeListReadSeq
        func current() -> Bool {
            sequence == (archived ? self.archivedListReadSeq : self.activeListReadSeq)
        }
        func stopRead() {
            if archived { self.archivedFullReadSeq = nil }
            else { self.activeFullReadSeq = nil; self.loading = false }
        }
        func step(_ cursor: String?, _ page: Int) {
            guard current() else { return }
            if let maxPages, page >= maxPages { done(acc, false); return }
            var params: JSONDict = ["limit": Self.listPage, "sortDirection": "desc", "sortKey": "updated_at"]
            if archived { params["archived"] = true }
            if let cursor, !cursor.isEmpty { params["cursor"] = cursor }
            repository.perform(.list(params)) { r in
                Task { @MainActor in
                    guard current() else { return }
                    guard case .success(let v) = r else {
                        stopRead()
                        if case .failure(let error) = r { self.banner = error.localizedDescription }
                        return
                    }
                    guard let d = v as? JSONDict, let rows = d["data"] as? [JSONDict],
                          rows.allSatisfy({ $0.str("id")?.isEmpty == false }) else {
                        stopRead()
                        self.banner = "会话列表返回了无效数据"
                        return
                    }
                    let next = d.str("nextCursor")
                    self.lastPageSizes.append((archived ? "A" : "a") + String(rows.count)
                        + ((next ?? "").isEmpty ? "." : "+"))
                    if archived { self.archivedPages += 1 } else { self.activePages += 1 }
                    acc.append(contentsOf: rows)
                    if let next, !next.isEmpty {
                        guard seen.insert(next).inserted else {
                            stopRead()
                            self.banner = "会话列表分页游标重复，请重试"
                            return
                        }
                        step(next, page + 1)
                    } else {
                        done(acc, true)
                    }
                }
            }
        }
        step(nil, 0)
    }

    /// 只拉第一页（最新 100 条），跟已有的合并。
    ///
    /// 对账走这条。**不能每 8 秒把所有页翻一遍** —— 归档 230 条 = 3 页，
    /// 加上活跃页，一轮对账 4 个请求，每 8 秒一次 = 30 个/分钟。
    /// 实测列表页放着不动 60 秒发 39 个 `thread/list`（用户："太耗电了"）。
    ///
    /// 合并而不是替换：第一页只有最新 100 条，直接替换会把更老的会话
    /// 从列表里抹掉。第一页里没有的旧条目原样留在后面。
    static func mergeFirstPage(fresh: [Thread], existing: [Thread]) -> [Thread] {
        let ids = Set(fresh.map { $0.id })
        return fresh + existing.filter { !ids.contains($0.id) }
    }

    func fetchThreadsFirstPage() {
        guard activeFullReadSeq == nil else { return }
        activeListReadSeq += 1
        let sequence = activeListReadSeq
        fetchAllPages(archived: false, maxPages: 1) { [weak self] rows0, complete in
            Task { @MainActor in
                guard let self, sequence == self.activeListReadSeq else { return }
                self.fetchedOnce = true
                let fresh = Protocol_.threads(from: ["data": rows0])
                self.applyThreads(complete ? fresh : Self.mergeFirstPage(fresh: fresh, existing: self.threads),
                                  dropPendingMissing: true)
            }
        }
    }

    func fetchArchivedFirstPage() {
        guard archivedFullReadSeq == nil else { return }
        archivedListReadSeq += 1
        let sequence = archivedListReadSeq
        fetchAllPages(archived: true, maxPages: 1) { [weak self] rows, complete in
            Task { @MainActor in
                guard let self, sequence == self.archivedListReadSeq else { return }
                let fresh = Protocol_.threads(from: ["data": rows])
                self.archived = complete ? fresh : Self.mergeFirstPage(fresh: fresh, existing: self.archived)
            }
        }
    }

    /// 把服务端结果落到 `threads`（补回还没落盘的新建会话 + 触发预取）。
    func applyThreads(_ rows0: [Thread], dropPendingMissing: Bool) {
        var rows = rows0.map { row in
            guard configurationWrites[row.id] != nil
                    || (row.id == currentID && row.id == confirmedConfigurationID),
                  let local = thread(row.id) else { return row }
            var merged = row
            merged.model = local.model
            merged.effort = local.effort
            return merged
        }
        if dropPendingMissing {
            let ids = Set(rows.map { $0.id })
            for (k, p) in pendingNew
            where ids.contains(k) || Date().timeIntervalSince(p.1) > 120 {
                pendingNew.removeValue(forKey: k)
            }
            rows.insert(contentsOf: pendingNew.values
                .sorted { $0.0.updatedAt > $1.0.updatedAt }
                .map { $0.0 }, at: 0)
        }
        if threads != rows { threads = rows }
        onLoaded?(rows.prefix(8).map { $0.id })
    }

    func fetchThreads() {
        activeListReadSeq += 1
        let sequence = activeListReadSeq
        activeFullReadSeq = sequence
        loading = true
        fetchAllPages(archived: false) { [weak self] rows0, _ in
            Task { @MainActor in
                guard let self, sequence == self.activeListReadSeq else { return }
                self.activeFullReadSeq = nil
                self.loading = false
                self.fetchedOnce = true
                let rows = Protocol_.threads(from: ["data": rows0])
                self.applyThreads(rows, dropPendingMissing: true)
            }
        }
    }

    /// 归档是另一份列表：默认列表里不含归档。
    func fetchArchived() {
        archivedListReadSeq += 1
        let sequence = archivedListReadSeq
        archivedFullReadSeq = sequence
        fetchAllPages(archived: true) { [weak self] rows, _ in
            Task { @MainActor in
                guard let self, sequence == self.archivedListReadSeq else { return }
                self.archivedFullReadSeq = nil
                self.archived = Protocol_.threads(from: ["data": rows])
            }
        }
    }

    /// 输入停下来再发请求（每敲一个字就查一次太费）。
    func scheduleSearch() {
        searchTimer?.invalidate()
        searchSeq += 1
        searchHits = []
        searchSnippets = [:]
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            return
        }
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) {
            [weak self] _ in
            Task { @MainActor in self?.runSearch(q) }
        }
    }

    func runSearch(_ q: String) {
        guard repository.isReady else { return }
        searchSeq += 1
        let seq = searchSeq
        repository.perform(.search(["searchTerm": q])) { [weak self] r in
            Task { @MainActor in
                guard let self, seq == self.searchSeq else { return }
                guard case .success(let v) = r else { return }
                let parsed = Protocol_.searchHits(from: v)
                self.searchHits = parsed.hits
                self.searchSnippets = parsed.snippets
            }
        }
    }

    func loadProjects() {
        projectReadSeq += 1
        let sequence = projectReadSeq
        loadCatalog(models: false, current: { self.projectReadSeq == sequence }) { rows in
            self.projects = rows.compactMap { Project(json: $0) }
        }
    }

    func loadModels(force: Bool = true) {
        guard repository.isReady else { return }
        if !force, let last = modelCatalogRead, last.connection == connectionGeneration,
           Date().timeIntervalSince(last.at) < reconcileInterval { return }
        modelReadSeq += 1
        let sequence = modelReadSeq
        let connection = connectionGeneration
        let identity = repository.connectionIdentity
        modelCatalogRead = (connection, Date())
        func current() -> Bool {
            self.modelReadSeq == sequence && self.connectionGeneration == connection
                && self.repository.connectionIdentity == identity
        }
        func legacyCatalog() {
            self.models = []
            self.modelProviderFingerprint = nil
            self.loadCatalog(models: true, current: current, failed: {
                self.failModelCatalog("模型目录加载失败，请重试", sequence: sequence)
            }) { rows in
                self.models = rows.compactMap { ModelOption(json: $0) }
                if self.banner == self.modelCatalogError { self.banner = nil }
                self.modelCatalogError = nil
            }
        }
        repository.perform(.providerModels) { [weak self] result in
            Task { @MainActor in
                guard let self, current() else { return }
                switch result {
                case .success(let value):
                    if !self.applyProviderCatalog(value, sequence: sequence) { legacyCatalog() }
                case .failure(let error):
                    let message = error.localizedDescription.lowercased()
                    if (error as NSError).code == -32601 || message.contains("unknown method")
                        || message.contains("method not found") { legacyCatalog() }
                    else { self.failModelCatalog("模型目录加载失败，请重试", sequence: sequence) }
                }
            }
        }
    }

    /// 返回 false 表示没有 CC Switch，继续使用 app-server 的目录。
    @discardableResult
    func applyProviderCatalog(_ value: Any, sequence: Int) -> Bool {
        guard sequence == modelReadSeq else { return true }
        guard let payload = value as? JSONDict, let available = payload["available"] as? Bool else {
            failModelCatalog("模型目录返回了无效数据，请重试", sequence: sequence)
            return true
        }
        guard available else {
            modelProviderFingerprint = nil
            if banner == modelCatalogError { banner = nil }
            modelCatalogError = nil
            models = []
            return false
        }
        modelProviderFingerprint = payload.dict("provider")?.str("fingerprint")
        if let error = payload.str("error"), !error.isEmpty {
            failModelCatalog("模型目录加载失败，请重试：" + error, sequence: sequence)
            return true
        }
        guard modelProviderFingerprint?.isEmpty == false,
              let rows = payload["models"] as? [JSONDict] else {
            failModelCatalog("模型目录返回了无效数据，请重试", sequence: sequence)
            return true
        }
        let options = rows.compactMap { row -> ModelOption? in
            guard row.str("id")?.isEmpty == false else { return nil }
            var normalized = row
            normalized["displayName"] = row.str("name") ?? row.str("displayName")
            normalized["description"] = row.str("detail") ?? row.str("description")
            return ModelOption(json: normalized)
        }
        guard options.count == rows.count else {
            failModelCatalog("模型目录返回了无效数据，请重试", sequence: sequence)
            return true
        }
        models = options
        if banner == modelCatalogError { banner = nil }
        modelCatalogError = nil
        return true
    }

    private func failModelCatalog(_ message: String, sequence: Int) {
        guard sequence == modelReadSeq else { return }
        models = []
        modelCatalogRead = nil
        modelCatalogError = message
        banner = message
    }

    /// 归档 / 取消归档。
    ///
    /// 除了重拉列表，还要**本地立刻摘掉这一条**：`thread/list` 有延迟
    /// （服务端要等 rollout 落盘），只等它回来界面会像"点了没反应"。
    /// 从电脑上删掉这个会话（不可恢复）。归档只是挪走，这个是真删。

}
