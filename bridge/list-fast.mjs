// `thread/list` 的快取 + 空结果重试。
//
// 两个实测问题（都在 app-server 自己那侧，桥接够不着，只能在这儿兜）：
//
//   1. **慢**。`limit:100` 一次要 10~20 秒（549 条会话的索引）。
//      列表页每次 onAppear 都重拉，用户看到的就是"转半天"。
//   2. **空结果**。同一组参数，前两次常常回 0 条（`data: []`，
//      连 `nextCursor` 都没有），第三次才对。用户看到的就是"会话全没了"。
//
// 所以这里做两件事：
//
//   - **先给旧快照，再去刷新**（stale-while-revalidate）。有缓存就立刻回，
//     同时后台重拉一次；只有缓存太老（`maxStale`）才不兜。
//     这样列表永远秒开，最新数据晚几秒到，跟 App 自己 20 秒一轮的
//     对账节奏不冲突。
//   - **空结果自动重试**。只对第一页（没带 `cursor` 的）重试 ——
//     翻页翻到底本来就是空的，重试纯属浪费。
//
// 首次空结果先重试；重试后仍为空才替换缓存，避免归档后旧会话重现。
export class ListFast {
  constructor({ sendUpstream, sendClient, log = () => {}, canUpstream = () => true,
                ttl = 15000, maxStale = 600000,
                retries = 3, retryDelay = 700, timeout = 120000,
                maxEntries = 24 } = {}) {
    Object.assign(this, { sendUpstream, sendClient, log, canUpstream, ttl, maxStale,
                          retries, retryDelay, timeout, maxEntries });
    this.cache = new Map();
    this.pending = new Map();
    this.refreshing = new Map();
    this.seq = 0;
    this.hits = 0;
    this.misses = 0;
    this.emptyRetries = 0;
    this.epoch = 0;
  }

  /// 参数归一化后的 key：字段顺序不影响命中。
  static key(params) {
    const p = params || {};
    return JSON.stringify(Object.keys(p).sort().map(k => [k, p[k]]));
  }

  /// 客户端请求。返回 true = 桥接自己回了，不用转发上游。
  handle(message) {
    if (!message || message.method !== 'thread/list') return false;
    const params = message.params || {};
    const key = ListFast.key(params);
    const hit = this.cache.get(key);
    const now = Date.now();
    if (hit && now - hit.at < this.maxStale) {
      this.hits++;
      this.cache.delete(key); this.cache.set(key, hit);
      this.sendClient({ id: message.id, result: hit.result });
      if (now - hit.at >= this.ttl) this.refresh(key, params);
      return true;
    }
    this.misses++;
    this.watch(message.id, key, params, !params.cursor);
    return false;
  }

  /// 上游回包。返回 'hold' = 扣下重试；'drop' = 后台刷新用的，别广播；'pass' = 照常。
  onUpstream(message) {
    if (!message) return 'pass';
    const bg = this.refreshing.get(message.id);
    const p = bg || this.pending.get(message.id);
    if (!p) return String(message.id).startsWith('list-bg-') ? 'drop' : 'pass';
    const verdict = bg ? 'drop' : 'pass';
    if (p.epoch !== this.epoch) {
      p.epoch = this.epoch; p.tries = 0;
      this.sendUpstream({id:p.id,method:'thread/list',params:p.params});
      return 'hold';
    }
    if (message.error) { this.forget(p); return verdict; }
    const rows = (message.result && message.result.data) || [];
    if (rows.length || !p.retryable || p.tries >= this.retries) {
      this.remember(p.key, message.result); this.forget(p); return verdict;
    }
    p.tries++; this.emptyRetries++;
    this.log('[list] 空结果，重试 ' + p.tries + '/' + this.retries);
    const t = setTimeout(() => {
      if (this.pending.get(p.id) !== p && this.refreshing.get(p.id) !== p) return;
      this.sendUpstream({ id: p.id, method: 'thread/list', params: p.params });
    }, this.retryDelay);
    t.unref?.();
    return 'hold';
  }

  /// 桥接启动/上游重连时先把两页热门参数烘进缓存，用户第一次打开就秒开。
  warm() {
    const base = { limit: 100, sortDirection: 'desc', modelProviders: [] };
    this.refresh(ListFast.key(base), base);
    const arch = { ...base, archived: true };
    this.refresh(ListFast.key(arch), arch);
  }

  refresh(key, params) {
    // 上游没连上就别刷 —— 刷了只会进 pending 队列，等它重连时一起涌过去。
    // 缓存兜着的那份照给，用户看到的是"数据旧一点"，不是"转半天"。
    if (!this.canUpstream()) return;
    if (this.refreshing.size && [...this.refreshing.values()].some(v => v.key === key)) return;
    const id = 'list-bg-' + (++this.seq);
    this.watch(id, key, params, !params.cursor, true);
    this.sendUpstream({ id, method: 'thread/list', params });
  }

  watch(id, key, params, retryable, background = false) {
    const target = background ? this.refreshing : this.pending;
    const old = target.get(id);
    if (old) clearTimeout(old.timer);
    const p = { id, key, params, retryable, tries: 0, epoch: this.epoch };
    p.timer = setTimeout(() => {
      if (target.get(id) === p) target.delete(id);
    }, this.timeout);
    p.timer.unref?.();
    target.set(id, p);
  }

  forget(p) { clearTimeout(p.timer); this.pending.delete(p.id); this.refreshing.delete(p.id); }

  invalidate() { this.epoch++; this.cache.clear(); }
  cancel(id) {
    const p=this.pending.get(id);if(p)this.forget(p);
  }

  remember(key, result) {
    if (!result) return;
    if (!Array.isArray(result.data)) return;
    this.cache.set(key, { at: Date.now(), result });
    while (this.cache.size > this.maxEntries) this.cache.delete(this.cache.keys().next().value);
  }

  cancelTimers() {
    for (const p of [...this.pending.values(), ...this.refreshing.values()]) clearTimeout(p.timer);
    this.pending.clear();
    this.refreshing.clear();
  }
}
