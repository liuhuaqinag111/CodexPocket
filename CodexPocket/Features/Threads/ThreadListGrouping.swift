import Foundation

extension ThreadListModel {


    /// 搜索过滤后的分组。
    ///
    /// 顺序：当前会话所在项目 → 其它项目 → 无项目 → 已归档。
    /// 项目为空也要显示（跟桌面端一致），否则"新建到某项目"没有入口。
    /// 这条会话归到哪个项目：服务端给了 projectId 就用它，否则按目录前缀。
    func project(of t: Thread) -> Project? {
        // 旧目录项目也返回 projectId:null；只有字符串值才是明确归属。
        if let pid = t.projectId { return projects.first { $0.id == pid } }
        // 桌面明确无项目和手机明确移出都阻止目录回退；null 本身不能表示移出。
        if t.desktopProjectless || filed[t.id] == "" { return nil }
        // 本地表只用来兼容改动前归过的会话。
        if !t.hasProjectMetadata, let pid = filed[t.id] {
            return projects.first(where: { $0.id == pid })
        }
        return projects.compactMap { project -> (Project, Int)? in
            let length = project.roots.filter { root in
                ComputerPath.contains(t.cwd, in: root)
            }.map { ComputerPath.normalized($0).count }.max()
            return length.map { (project, $0) }
        }.max { $0.1 < $1.1 }?.0
    }

    var groups: [Group] {
        let q = query.trimmingCharacters(in: .whitespaces)
        func hit(_ t: Thread) -> Bool {
            q.isEmpty || t.displayTitle.localizedCaseInsensitiveContains(q)
        }
        var out: [Group] = []
        var taken = Set<String>()
        // 服务端搜出来的（正文命中）。放最前面 —— 用户搜东西时想看的是
        // "哪几条提到了"，不是按项目分组的那份。
        // 本地标题命中的会由下面的分组逻辑补进来。
        if !q.isEmpty {
            // **不能**再过一遍 `hit`（那是按标题过滤的）：服务端命中的是
            // 正文，标题里往往没有关键词 —— 过滤一遍就只剩一两条了
            // （实测：服务端返回 17 条，界面上只剩 1 条）。
            let hits = searchHits
            if !hits.isEmpty {
                hits.forEach { taken.insert($0.id) }
                out.append(Group(id: "__search__", title: "搜索结果", path: "",
                                 threads: hits, isProject: false, isSearch: true))
            }
        }
        for p in projects {
            let rows = threads.filter { project(of: $0)?.id == p.id && hit($0) }
            rows.forEach { taken.insert($0.id) }
            out.append(Group(id: p.id, title: p.name, path: p.roots.first ?? "",
                             threads: rows, isProject: true))
        }
        let rest = threads.filter { !taken.contains($0.id) && hit($0) }
        if !rest.isEmpty {
            out.append(Group(id: "__none__", title: "无项目", path: "",
                             threads: rest, isProject: false, isEmptyProject: true))
        }
        let arc = archived.filter(hit)
        if !arc.isEmpty {
            out.append(Group(id: "__archive__", title: "已归档", path: "",
                             threads: arc, isProject: true, isArchive: true))
        }
        return out
    }

    /// 「最近」里平铺的会话：**没有项目的那些**。
    ///
    /// 有项目的会话要留在各自项目下面 —— 之前我把「最近」拍平成全部会话，
    /// 项目分组头又只在入口里，结果项目里的会话一个都看不到（用户报的）。
    var recent: [Thread] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return threads.filter { t in
            project(of: t) == nil
                && (q.isEmpty || t.displayTitle.localizedCaseInsensitiveContains(q))
        }
    }

    /// 平铺的全部会话（搜索时用，不分组）。
    ///
    /// 实机截图里 ChatGPT 的「最近」就是一条条平铺，**不分组**；
    /// 项目是通过上面那个「项目」入口进的。之前我把项目分组头塞进
    /// 「最近」里，看着像两层列表，不是它的样子。
    var allMatching: [Thread] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return threads }
        let activeHits = searchHits.filter { hit in
            !hit.archived && !archived.contains { $0.id == hit.id }
        }
        let local = threads.filter { $0.displayTitle.localizedCaseInsensitiveContains(q) }
        var seen = Set<String>()
        return (activeHits + local).filter { seen.insert($0.id).inserted }
    }

    /// 项目里各有多少会话（「项目」页显示用）。
    func count(in p: Project) -> Int {
        threads.filter { project(of: $0)?.id == p.id }.count
    }

    /// 「已归档」默认收起。
    var isOpenArchive: Bool { settings.openProjects.contains("__archive__") }

    func toggleArchive() {
        if isOpenArchive { settings.openProjects.remove("__archive__") }
        else { settings.openProjects.insert("__archive__") }
    }

    /// 项目默认收起，只展开用户明确打开的分组。
    func isOpen(_ g: Group) -> Bool {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if g.isArchive { return settings.openProjects.contains(g.id) }
        if !g.isProject { return true }
        return settings.openProjects.contains(g.id) && !settings.closedProjects.contains(g.id)
    }

    /// 一次展开 / 收起全部项目（列表页「项目」入口用）。
    func toggleAllProjects() {
        let ids = Set(projects.map(\.id))
        if ids.isSubset(of: settings.openProjects) {
            settings.openProjects.subtract(ids)
        } else {
            settings.openProjects.formUnion(ids)
            settings.closedProjects.subtract(ids)
        }
    }

    func toggle(_ g: Group) {
        if isOpen(g) {
            settings.openProjects.remove(g.id)
            if g.threads.contains(where: { $0.id == currentID }) {
                settings.closedProjects.insert(g.id)
            }
        }
        else {
            settings.openProjects.insert(g.id)
            settings.closedProjects.remove(g.id)
        }
    }



    /// 打开列表页时开始对账。
    func startReconcile() {
        reconcileWanted = true
        reconcileMisses = 0
        guard reconcileTimer == nil else { return }
        // `[weak self]` 必须写在 **Task 的捕获列表**里，不能写在 Timer 的
        // block 上：Timer 的 block 是 @Sendable 的，在它里面捕获 weak self
        // 再交给 Task，编译器报 "reference to captured var 'self' in
        // concurrently-executing code"。
        reconcileTimer = Timer.scheduledTimer(
            withTimeInterval: reconcileInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
    }

    /// 列表页收起 / App 进后台就停 —— 没人看的时候不用一直拉。
    /// 列表页收起了：**不要**再对账。
    func stopReconcile() {
        reconcileWanted = false
        haltReconcile()
    }

    /// 临时停表，但保留"列表页还开着"这个意愿。
    ///
    /// 跟 `stopReconcile` 分开是必须的：切后台用的是这个。
    /// 早先切后台直接调 `stopReconcile()`，它把意愿也清了 ——
    /// 回前台就再也不对账，表现是"列表不刷新了"
    /// （单元测试 `testForegroundResumesReconcileOnlyIfWanted` 抓到）。
    func suspendReconcile() {
        haltReconcile()
    }

    func haltReconcile() {
        reconcileTimer?.invalidate()
        reconcileTimer = nil
    }

    /// 回前台时把对账接回去 —— 但只在列表页本来就开着的时候。
    ///
    /// 无条件接回去的话，用户在会话页切一次后台，列表的定时器就白白跑起来，
    /// 而那个页面根本没人看。
    func resumeReconcileIfWanted() {
        guard reconcileWanted, reconcileTimer == nil else { return }
        startReconcile()
    }

    func reconcile() {
        // 只统计**失败**次数。以前每轮都 +1，于是不管成没成功，
        // 三轮之后定时器自己停了 —— 用户开着列表页等电脑端的改动，
        // 等到的是"再也不刷新了"。
        guard repository.isReady else {
            reconcileMisses += 1
            if reconcileMisses > reconcileGiveUp { stopReconcile() }
            return
        }
        reconcileMisses = 0
        // 平时只拉首屏，每两分钟补旧页，避免漏广播后归档/删除永久残留。
        refreshConfiguration()
        reconcilePass += 1
        if reconcilePass % 6 == 0 {
            fetchThreads()
            fetchArchived()
        } else {
            fetchThreadsFirstPage()
            fetchArchivedFirstPage()
        }
    }
}
