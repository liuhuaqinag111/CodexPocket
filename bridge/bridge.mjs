import http from 'node:http';
import { StdioWorker } from './stdio-worker.mjs';
import { WriterRouter } from './writer-router.mjs';
import { loadProviderCatalog } from './provider-catalog.mjs';
import { withProviderExecution } from './provider-execution.mjs';
import { withAllProviders } from './list-params.mjs';
import { withDesktopProjectless } from './desktop-projectless.mjs';
import { ListFast } from './list-fast.mjs';
import { RequestRoutes } from './request-routes.mjs';
import { SubmissionDedup } from './submission-dedup.mjs';
import { requestSocket } from './socket-request.mjs';
import { ApprovalRoutes } from './approval-routes.mjs';
import { restartIdleUpstream } from './upstream-maintenance.mjs';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import crypto from 'node:crypto';
import { WebSocket, WebSocketServer } from 'ws';
import { notifyConfigured, push } from './notify.mjs';

const TOKEN = fs.readFileSync(process.argv[2] || './ws-token.txt', 'utf8').trim();
const UPSTREAM = process.env.UPSTREAM || 'ws://127.0.0.1:62112';
const PORT = Number(process.env.PORT || 62113);
const BIND = process.env.BIND || '127.0.0.1';
const UI = new URL('./ui.html', import.meta.url);
const APP_SCHEME = process.env.APP_SCHEME || 'codexpocket';

function authed(req) {
  const u = new URL(req.url, 'http://x');
  if (u.searchParams.get('t') === TOKEN) return true;
  const c = req.headers.cookie || '';
  if (c.split(';').some((p) => p.trim() === 'cx=' + TOKEN)) return true;
  const a = req.headers.authorization || '';
  return a === 'Bearer ' + TOKEN;
}

function log(...a) { console.log(new Date().toISOString(), ...a); }

// MARK: - 常驻上游
//
// 只保留一条到 app-server 的连接，手机重连不重建它。
// 这样 1) 不再出现多条连接抢同一会话写入权（thread-store conflict），
// 2) 手机掉线期间正在跑的那一轮 delta 也不会丢，回来还能接着收。

const clients = new Set();
const approvals=new ApprovalRoutes({broadcast:message=>broadcast(JSON.stringify(message)),log});
const submissions = new SubmissionDedup({
  directory: process.env.SUBMISSION_DIR
    || `${process.env.CODEX_PHONE_DIR || process.env.HOME + '/.codex/phone'}/submissions`,
});
let up = null;
let upReady = false;
let upRetry = 1;
let upTimer = null;
let upInitialized = false;
const pending = [];
let activityEpoch=0;
let maintenance=null;
const turns = { replies: new Map(), names: new Map() };
const listMutations=new Set(['thread/archive','thread/unarchive','thread/delete',
 'thread/name/set','thread/metadata/update','thread/settings/update','thread/start','thread/fork']);
const listEvents=new Set(['thread/archived','thread/unarchived','thread/deleted',
 'thread/name/updated','thread/started','thread/status/changed','thread/settings/updated','turn/completed']);
const writerBinary = process.env.CODEX_BIN || [
 '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex',
 '/Applications/ChatGPT.app/Contents/Resources/codex',
 '/Applications/Codex.app/Contents/Resources/codex'
].find(path => fs.existsSync(path));
const writers = new WriterRouter({
 delay: Number(process.env.WRITER_RELEASE_MS ?? 1500),
 createWorker: callbacks => new StdioWorker({binary:writerBinary,spawnProcess:withProviderExecution(),log,...callbacks}),
 log,
 onNotification:(method,params) => {
  if(listEvents.has(method))listFast.invalidate();
  const raw=JSON.stringify({method,params});
  observeMessage(raw);
  if(method==='thread/tokenUsage/updated')saveUsage(params.threadId,params.tokenUsage);
  broadcast(raw);
 },
 onRequest:(id,method,params)=>approvals.register('writer',{id,method,params},
  reply=>writers.route(reply,()=>{})),
 onRequestClosed:id=>approvals.drop('writer',id)
});

// 每个会话最近一次的用量（`thread/tokenUsage/updated`）。
//
// 为什么要桥接来记：服务端**只在跑回合时推一次**这条事件，手机不在线
// 那一包就永远没了 —— 打开老会话的用量页永远是"这个会话还没跑过"。
// 桥接是常驻进程，替它记在磁盘上。
const USAGE_FILE = process.env.HOME + '/.codex/phone/usage.json';
let usage = {};
let usageWriteScheduled = false;
let usageWrite = Promise.resolve();
try { usage = JSON.parse(fs.readFileSync(USAGE_FILE, 'utf8')) || {}; } catch {}
function saveUsage(tid, u) {
  if (!tid || !u) return;
  usage[tid] = { usage: u, at: Date.now() };
  const keys = Object.keys(usage);
  if (keys.length > 200) {
    keys.sort((a, b) => (usage[b].at || 0) - (usage[a].at || 0))
        .slice(200).forEach((k) => delete usage[k]);
  }
  if (usageWriteScheduled) return;
  usageWriteScheduled = true;
  setTimeout(() => {
    usageWriteScheduled = false;
    usageWrite = usageWrite.then(async () => {
      await fs.promises.mkdir(process.env.HOME + '/.codex/phone', { recursive: true });
      await fs.promises.writeFile(USAGE_FILE, JSON.stringify(usage));
    }).catch(error => log('[usage] write failed', error.message));
  }, 50).unref?.();
}

// MARK: - 空闲时释放会话写者锁
//
// 手机端 app-server 会把打开过的会话一直留在内存里（thread/loaded/list
// 实测只增不减），每个都占着 ~/.codex/thread-writer-locks/<threadId>.lock，
// 桌面端于是再也打不开这些会话（thread-store conflict）。
// 协议里没有"卸载会话"的客户端方法：thread/unsubscribe 只解订阅，
// 实测返回 notSubscribed 且锁不放；锁只在 app-server 进程退出时由内核释放。
// 所以手机空闲一段时间后，就让 supervise.sh 的看门狗把它重启一次。
const activeTurns = new Map();
/// 最近一次客户端请求的时间。放锁靠它判断"有没有人在用"。
let lastClientActivity = 0;
/// 最近一次真的放锁的时间（防抖）。
let lastReleaseAt = 0;
/// 最近 QUIET_MS 内有过请求就不放锁。
const RELEASE_QUIET_MS = 45_000;
/// 两次放锁至少隔这么久。
const RELEASE_COOLDOWN_MS = 60_000;
const IDLE_RESTART_MS = Number(process.env.IDLE_RESTART_MS ?? 600000);
const UPSTREAM_PORT = (String(UPSTREAM).match(/^ws:\/\/(?:127\.0\.0\.1|localhost):(\d+)/) || [])[1];
let idleTimer = null;
function cancelIdleRestart() {
  if (idleTimer) { clearTimeout(idleTimer); idleTimer = null; }
}

function armIdleRestart() {
  if (!IDLE_RESTART_MS || idleTimer) return;
  idleTimer = setTimeout(() => {
    idleTimer = null;
    // **不看 clients.size。**
    //
    // 手机 App 为了"一切后台就断联"故意保持长连接（保活），
    // 所以 clients.size 永远是 1 —— 拿它当判据等于这段释放逻辑
    // 永远不触发。实测手机端那个 app-server 连跑 5 小时 18 分一直占着
    // 写者锁，桌面端弹「已在另一个应用中打开」（用户截图）。
    //
    // 只看有没有回合在跑。客户端自己不看屏幕时会给 /release 信号（见下）。
    if (activeTurns.size) return;
    if (!UPSTREAM_PORT) return;                     // 上游不是本机，别乱杀
    void maintainUpstream().then(released=>{
      if(!released&&!clients.size)armIdleRestart();
    });
  }, IDLE_RESTART_MS);
}

function upstreamSend(text) {
  if (upReady && up && up.readyState === 1) { up.send(text); return true; }
  if (pending.length < 500) pending.push(text);
  else {
    let message;try{message=JSON.parse(text);}catch{}
    if(message?.id!==undefined)routes.deliver({id:message.id,error:{code:-32093,message:'待发队列已满，消息未发出'}});
  }
  return false;
}

function markUpstreamReady(sock) {
  if (up !== sock || sock.readyState !== 1 || upReady) return;
  upReady = true;
  clearTimeout(sock.__initTimer);
  sock.send(JSON.stringify({method:'initialized'}));
  upRetry = 1;
  log('[up] initialized; flushing', pending.length);
  while (pending.length && sock.readyState === 1) {
    const raw = pending.shift(); let m;
    try { m = JSON.parse(raw); } catch {}
    if (!m || routes.isPending(m)) sock.send(raw);
  }
  broadcast(JSON.stringify({ method: 'bridge/upstream', params: { connected: true } }));
  setTimeout(() => listFast.warm(), 500).unref?.();
}

const routes=new RequestRoutes({
 send:(client,m)=>{if(client.readyState===1)client.send(JSON.stringify(writers.decorate(m)));},
 onSettled:(method,id)=>{listFast.cancel(id);if(listMutations.has(method))listFast.invalidate();}
});

// 会话列表的快取 + 空结果重试（见 list-fast.mjs）。
const listFast = new ListFast({
  sendUpstream: (m) => {if(routes.isPending(m))upstreamSend(JSON.stringify(m));},
  sendClient: (m) => routes.deliver(structuredClone(m)),
  log: (m) => log(m),
  canUpstream: () => upReady,
});

// Writer workers hold the app-server's per-thread flock until their stdio
// process exits. A phone WebSocket is intentionally kept alive in background,
// so client disconnect is not a reliable idle signal. Recheck workers while
// the bridge remains connected, but never release during an active operation.
const writerReleaseMs = Number(process.env.WRITER_RELEASE_MS ?? 1500);
const writerReleaseTimer = setInterval(() => {
  if (activeTurns.size || routes.requests.size || approvals.pending.size || submissions.rows.size) return;
  void writers.releaseIdle();
}, Math.max(250, writerReleaseMs));
writerReleaseTimer.unref?.();

function broadcast(text) {
  for (const c of clients) if (c.readyState === 1) c.send(text);
}

function clip(s, n) {
  const t = String(s).replace(/\s+/g, ' ').trim();
  return t.length <= n ? t : t.slice(0, n - 1) + '…';
}

function buildBody(reply, secs) {
  const cost = secs > 0 ? (secs < 60 ? `${Math.round(secs)}s` : `${Math.round(secs / 60)}m`) : '';
  if (!reply) return cost ? `已完成 · ${cost}` : '已完成';
  const clean = reply
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/^#{1,6}\s*/gm, '')
    .replace(/[*_`>]/g, '')
    .replace(/\[(.*?)\]\(.*?\)/g, '$1')
    .split('\n').map((l) => l.trim()).filter(Boolean).join(' ');
  const head = clip(clean || reply, 90);
  return cost ? `${head}\n· ${cost}` : head;
}

function lookupName(tid) {
  const sock=up;
  return requestSocket(sock,'thread/read',{threadId:tid,includeTurns:false},{timeout:4000})
    .then(result=>result?.thread?.name||result?.thread?.preview||'');
}

/// 拉最新一个回合的助手正文（full 视图）。
///
/// 为什么需要：`observe()` 靠 `item/agentMessage/delta` 攒回复，但 delta
/// 只发给**发起该回合的连接**。电脑端自己发起的回合，桥接这条常驻连接
/// 也收不到 —— 于是通知正文永远是空的，只剩 `已完成 · 12m`。
/// 用户报的"40 次已完成 · Xm 没内容"就是这个。
function fetchLastReply(tid, turnId) {
  const sock=up;
  return requestSocket(sock,'thread/turns/list',{threadId:tid,limit:8,
    sortDirection:'desc',itemsView:'full'}).then(result=>{
      const rows=result?.data||[],turn=rows.find(row=>!turnId||row?.id===turnId);
      if(!turn)return null;
      return {id:turn.id,status:turn.status,text:(turn.items||[])
        .filter(i=>i?.type==='agentMessage'&&typeof i.text==='string')
        .map(i=>i.text).join('\n').trim()};
    });
}

/// 两种完成事件按回合身份去重，不压掉相邻完成的另一轮。
/// `turn/completed` 和 `thread/status/changed` 两条路都可能报同一轮结束
/// （手机自己发起的回合两条都会到），不去重就是双份通知。
const lastAnnounced = new Map();

async function announce(tid, reply, secs, turnId) {
  if (!notifyConfigured()) return;
  if (!reply || !turnId) {
    const fetched = await fetchLastReply(tid, turnId);
    if(!turnId&&(!fetched||!['completed','failed','interrupted'].includes(fetched.status?.type||fetched.status)))return;
    if(fetched){reply=reply||fetched.text;turnId=turnId||fetched.id;}
  }
  if(!turnId)return;
  const key = tid + ':' + turnId;
  if (lastAnnounced.has(key)) return;
  lastAnnounced.set(key, Date.now());
  if(lastAnnounced.size>2000)lastAnnounced.delete(lastAnnounced.keys().next().value);
  let name = turns.names.get(tid);
  if (!name) {
    name = await lookupName(tid);
    if (name) turns.names.set(tid, name);
  }
  const title = clip(name || 'Codex', 24);
  const body = buildBody(reply, secs);
  const url = `${APP_SCHEME}://thread/${tid}`;
  try {
    const st = await push({ title, body, url });
    log('[notify]', JSON.stringify(st), '|', title, '|', body.slice(0, 36));
  } catch (e) {
    console.error('[notify] failed', e.message);
  }
}

/// 在常驻上游上盯回合：app-server 只把 turn/* 发给发起该回合的连接，
/// 这条连接常驻，所以手机掉线也能接住完成事件，通知照发。
function observe(sock) {
  sock.on('message', raw => { if (sock === up) observeMessage(raw); });
}

function observeMessage(raw) {
    let m;
    try { m = JSON.parse(String(raw)); } catch { return; }
    if(m.method)activityEpoch++;
    const p = m.params || {};
    const tid = p.threadId;
    if (!tid) return;
    if (m.method === 'item/agentMessage/delta' && typeof p.delta === 'string') {
      // 以前只留最后 400 字符 —— 长回复的通知正文是从中间断的。
      // 通知正文只截 90 字，但去掉 markdown 之后可能不够，留 2000。
      turns.replies.set(tid, ((turns.replies.get(tid) || '') + p.delta).slice(-2000));
      return;
    }
    if (m.method === 'turn/started') {
      activeTurns.set(tid, p.turn?.id || p.turnId || null); return;
    }
    // 回合结束的另一条路：`thread/status/changed`。
    //
    // `turn/completed` 只发给**发起该回合的连接**（实测）。电脑端自己发起的
    // 回合，桥接这条常驻连接收不到 —— 于是电脑端跑完**根本不发通知**。
    // `thread/status/changed` 是广播的（所有连接都收到，实测），
    // 所以用它兜住：active → 别的状态就算一轮结束。
    if (m.method === 'thread/status/changed') {
      const type = (p.status && p.status.type) || '';
      if (type === 'active') { activeTurns.set(tid, p.turn?.id || p.turnId || activeTurns.get(tid) || null); return; }
      if (activeTurns.has(tid) && ['idle', 'completed', 'systemError', 'interrupted'].includes(type)) {
        const turnId = activeTurns.get(tid); activeTurns.delete(tid);
        const reply = (turns.replies.get(tid) || '').trim();
        turns.replies.delete(tid);
        announce(tid, reply, 0, turnId).catch((error) => log('[notify] announce failed', error.message));
      }
      return;
    }
    if (m.method === 'turn/completed') {
      const completed=p.turn?.id||p.turnId;
      if(completed&&activeTurns.get(tid)&&activeTurns.get(tid)!==completed)return;
      const turnId = p.turn?.id || p.turnId || activeTurns.get(tid); activeTurns.delete(tid);
      const reply = (turns.replies.get(tid) || '').trim();
      turns.replies.delete(tid);
      announce(tid, reply, (p.turn?.durationMs || 0) / 1000, turnId)
        .catch((error) => log('[notify] announce failed', error.message));
    }
}

function connectUpstream() {
  upTimer = null;
  if (up && (up.readyState === 0 || up.readyState === 1)) return;
  const t0 = Date.now();
  log('[up] connecting', UPSTREAM);
  const sock = new WebSocket(UPSTREAM, { headers: { Authorization: `Bearer ${TOKEN}` } });
  up = sock;
  observe(sock);

  sock.on('open', () => {
    upReady = false;
    // **上游的 initialize 由桥接自己发**，不再借手机的第一次握手去发。
    //
    // 为什么：以前是"第一个客户端的 initialize 转发给上游"，上游没就绪
    // 就进 pending 队列 —— 手机那头就卡在握手，10 秒看门狗一响就重连，
    // 重连又转发一次，来回死循环。表现就是"十几秒断一次"。
    // app-server 每次重启都会把 upInitialized 清成 false，
    // 而它被看门狗/空闲回收重启过 47 次，这个坑就一直在踩。
    try {
      sock.send(JSON.stringify({
        id: 'up-init', method: 'initialize',
        params: { clientInfo: { name: 'codex-bridge', title: 'bridge', version: '1' },
                  capabilities: { experimentalApi: true } },
      }));
    } catch {}
    log('[up] open in', Date.now() - t0, 'ms; waiting initialize');
    sock.__initTimer=setTimeout(()=>{if(up===sock&&!upReady)sock.terminate();},10000);
    sock.__initTimer.unref?.();
  });

  sock.on('message', (d, isBinary) => {
    if (up !== sock) return;
    sock.__lastUp = Date.now();
    let message;
    if(!isBinary){try{message=JSON.parse(String(d));}catch{}}
    if(message?.method&&message.id!==undefined){
      approvals.register(sock,message,reply=>{
        if(up===sock&&sock.readyState===1)sock.send(JSON.stringify(reply));
      });
      return;
    }
    if(message?.method==='serverRequest/resolved')approvals.drop(sock,message.params?.requestId);
    if(message&&listEvents.has(message.method))listFast.invalidate();
    // 心跳的回包（服务端不认 bridge/ping，会回一个错误帧）不要转发给手机。
    if (message?.id === 'up-init') {
      if (message.error) { log('[up] initialize failed', message.error.message || ''); try { sock.terminate(); } catch {} return; }
      markUpstreamReady(sock); return;
    }
    if(message&&String(message.id).startsWith('up-hb-'))return;
    // 用量顺手抄一份到磁盘。只对含 tokenUsage 的包做 JSON.parse ——
    // 流式 delta 一秒几十条，不能每条都解析。
    if(message?.method==='thread/tokenUsage/updated'){
      saveUsage(message.params?.threadId,message.params?.tokenUsage);
    }
    // 会话列表的包要过一道：空结果扣下重试、后台刷新的别广播。
    // 平时 `pending` 是空的，这一整段直接跳过（流式 delta 一秒几十条，
    // 不能每条都去 parse）。
    if (!isBinary && (listFast.pending.size || listFast.refreshing.size)) {
      const raw = String(d);
      if (raw.includes('"id":')) {
        let lm = null;
        try { lm = JSON.parse(raw); } catch {}
        if (lm) {
          const verdict = listFast.onUpstream(lm);
          if (verdict === 'hold' || verdict === 'drop') return;
        }
      }
    }
    if(!isBinary && String(d).includes('"id":')){
      let m;try{m=JSON.parse(String(d));}catch{}
      if(m&&!m.method&&m.id!==undefined){routes.deliver(m);return;}
    }
    if (clients.size) {
      let outgoing=isBinary?d:d.toString();
      if(!isBinary){try{outgoing=JSON.stringify(writers.decorate(JSON.parse(outgoing)));}catch{}}
      broadcast(outgoing);
    }
  });

  sock.on('close', (code, reason) => {
    clearInterval(sock.__hb);
    clearTimeout(sock.__initTimer);
    approvals.drop(sock);
    if (up !== sock) return;
    upReady = false;
    upInitialized = false;
    routes.failAll();
    pending.length = 0;
    listFast.cancelTimers();
    broadcast(JSON.stringify({ method: 'bridge/upstream', params: { connected: false } }));
    log('[up] closed', code, String(reason || '').slice(0, 60), 'after', Date.now() - t0, 'ms');
    scheduleUpstream();
  });

  sock.on('error', (e) => { log('[up] error', e.message); });

  // 上游心跳 + 半死检测。
  //
  // 踩过的坑（2026-09-26）：app-server 在 05:53 被看门狗重启过，
  // 桥接这条上游 socket 从此变成"半开"——readyState 还是 1，send 也不报错，
  // 但发出去的请求永远没有回包。手机端看到的是"已连接"，实际
  // thread/list 返回 0 条、project/list 回 "Not initialized"，所有功能全废。
  // 只有应用层心跳能发现：发 bridge/ping 要 bridge/pong 回来。
  clearInterval(sock.__hb);
  sock.__lastUp = Date.now();
  sock.__hb = setInterval(() => {
    if (sock.readyState !== 1) { clearInterval(sock.__hb); return; }
    if (Date.now() - sock.__lastUp > 30000) {
      log('[up] 30s 没有回包，判定半死，重建上游');
      clearInterval(sock.__hb);
      resetUpstream();
      return;
    }
    try {
      sock.send(JSON.stringify({ id: 'up-hb-' + Date.now(),
                                 method: 'bridge/ping', params: {} }));
    } catch {}
  }, 10000);
}

/// app-server 被重启之后，桥接这条上游连的是**旧进程**，必然半死。
/// supervise.sh 的看门狗每次重启都调这个，强制重建。
export function resetUpstream() {
  routes.failAll();
  pending.length = 0;
  listFast.cancelTimers();
  if (up) { try { up.terminate(); } catch {} }
  up = null; upReady = false; upInitialized = false;
  scheduleUpstream();
}

function scheduleUpstream() {
  if (upTimer) return;
  const delay = upRetry;
  upRetry = Math.min(upRetry * 2, 10);
  log('[up] retry in', delay, 's');
  upTimer = setTimeout(() => { connectUpstream(); }, delay * 1000);
}

function signalOwnedUpstream() {
  const file=process.env.UPSTREAM_PID_FILE,parent=Number(process.env.SUPERVISOR_PID);
  if(!file||!parent||!UPSTREAM_PORT)return false;
  const pid=Number(fs.readFileSync(file,'utf8').trim());
  if(!Number.isInteger(pid)||pid<=1)return false;
  const row=execFileSync('ps',['-o','ppid=,command=','-p',String(pid)],{encoding:'utf8'}).trim();
  const match=row.match(/^(\d+)\s+(.+)$/);
  if(Number(match?.[1])!==parent||!match[2].includes(' app-server --listen ws://0.0.0.0:'+UPSTREAM_PORT+' '))return false;
  process.kill(pid,'SIGTERM');resetUpstream();return true;
}

function maintainUpstream() {
  if(maintenance)return maintenance;
  const sock=up;
  maintenance=restartIdleUpstream({
    snapshot:()=>({epoch:activityEpoch,busy:!upReady||up!==sock||activeTurns.size>0||
      routes.requests.size>0||pending.length>0||approvals.pending.size>0||submissions.rows.size>0}),
    request:(method,params)=>requestSocket(sock,method,params,{timeout:4000}),
    restart:signalOwnedUpstream,
  }).finally(()=>{maintenance=null;});
  return maintenance;
}


const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/healthz') { res.writeHead(200).end('ok'); return; }
  // 桥接自己的状态，**不需要令牌** —— 就是给看门狗和"到底哪儿断了"
  // 这种排查用的。上游连不上时 /healthz 照样回 ok，看不出问题。
  //
  // 2026-10-06 就是靠这个发现：桥接在连 62112（早就没有的端口），
  // 而 app-server 在 62115 —— 手机"连上了但一个会话都加载不出来"。
  if (u.pathname === '/status') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({
      ok: upReady,
      upstream: UPSTREAM,
      upstreamPort: UPSTREAM_PORT,
      upstreamReady: !!upReady,
      upstreamState: up ? up.readyState : -1,
      clients: wss ? wss.clients.size : 0,
      retries: upRetry,
      writerMode: "per-thread-process",
      writerWorkers: writers.entries.size,
      deploymentId: process.env.DEPLOYMENT_ID || null,
    }));
    return;
  }
  // 只回收确认空闲的 per-thread worker，不重启共享 app-server。
  // 手机手动释放锁走这里，避免旧的 /release 为了放锁重启上游、丢掉在途请求。
  if (u.pathname === '/release-writers') {
    if (!authed(req)) { res.writeHead(401).end('unauthorized'); return; }
    void writers.releaseIdle({threadId:u.searchParams.get('threadId')||undefined}).then(result => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(result));
    }).catch(error => {
      res.writeHead(500, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ released: false, error: error.message }));
    });
    return;
  }
  // 看门狗重启 app-server 之后调这个，强制重建上游连接。
  if (u.pathname === '/reset-upstream') {
    if (!authed(req)) { res.writeHead(401).end('unauthorized'); return; }
    resetUpstream();
    res.writeHead(200).end('ok');
    return;
  }
  if (!authed(req)) {
    res.writeHead(401, { 'content-type': 'text/plain; charset=utf-8' }).end('unauthorized');
    return;
  }
  if (u.searchParams.get('t')) {
    res.setHeader('set-cookie', `cx=${TOKEN}; Path=/; Max-Age=2592000; SameSite=Lax`);
  }
  // 装包直链。微信的文件通道发不出去（sendMediaItems: -2），
  // 手机开这个地址就能直接下载 IPA。
  // 维护重启前检查活动回合、在途请求、审批、队列和后台终端。
  if (u.pathname === '/release' || u.pathname === '/maintenance') {
    const now=Date.now();
    if(now-lastReleaseAt<RELEASE_COOLDOWN_MS){
      res.writeHead(200,{'content-type':'application/json'});
      res.end(JSON.stringify({released:false,reason:'cooldown'}));return;
    }
    void maintainUpstream().then(async released=>{
      if(released&&u.pathname==='/release')await writers.releaseIdle();
      if(released){cancelIdleRestart();lastReleaseAt=now;}
      res.writeHead(200,{'content-type':'application/json'});
      res.end(JSON.stringify({released,reason:released?'':'busy-or-unverified',activeTurns:activeTurns.size}));
    }).catch(()=>res.writeHead(500).end('maintenance failed'));
    return;
  }
  // 当前可供下载的版本。App 拿它跟自己的 build 比，决定要不要提示升级。
  //
  // 版本号取自 IPA 文件本身（ship.sh 写一份 .version 在旁边），不是进程里
  // 的常量 —— 桥接可能比 IPA 早/晚重启，读文件才是真值。
  if (u.pathname === '/version') {
    const ipa = process.env.IPA_PATH || (process.env.HOME + '/Desktop/CodexPocket.ipa');
    let build = '';
    let mtime = 0;
    try {
      build = fs.readFileSync(ipa + '.version', 'utf8').trim();
      mtime = fs.statSync(ipa).mtimeMs;
    } catch {}
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({
      build,
      mtime,
      size: (() => { try { return fs.statSync(ipa).size; } catch { return 0; } })(),
      url: 'http://' + (req.headers.host || '') + '/ipa?t=' + TOKEN,
    }));
    return;
  }
  // `itms-services` 的清单（plist）。iOS 只认 HTTPS 上的清单，
  // 而且只肯装**已签名**、且描述文件里含本机 UDID 的包。
  //
  // 未签名时点进去 iOS 会报"无法安装"—— 所以 App 那边只在包是签名的
  // 时候才给这个链接。这里先把端点备好，签名链路一通就能用。
  if (u.pathname === '/manifest') {
    const ipa = u.searchParams.get('ipa') || '';
    const bundle = u.searchParams.get('bundle') || 'com.liuhuaqiang.codexpocket';
    const ver = u.searchParams.get('version') || '1.0';
    const title = u.searchParams.get('title') || 'CodexPocket';
    if (!ipa.startsWith('https://')) {
      res.writeHead(400, { 'content-type': 'text/plain' })
         .end('ipa must be https (iOS refuses http manifests)');
      return;
    }
    const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
<key>assets</key><array><dict>
<key>kind</key><string>software-package</string>
<key>url</key><string>${ipa}</string>
</dict></array>
<key>metadata</key><dict>
<key>bundle-identifier</key><string>${bundle}</string>
<key>bundle-version</key><string>${ver}</string>
<key>kind</key><string>software</string>
<key>title</key><string>${title}</string>
</dict></dict></array></dict></plist>`;
    res.writeHead(200, { 'content-type': 'application/xml' });
    res.end(plist);
    return;
  }
  if (u.pathname === '/ipa' || u.pathname === '/CodexPocket.ipa') {
    const f = process.env.IPA_PATH || (process.env.HOME + '/Desktop/CodexPocket.ipa');
    fs.stat(f, (e, st) => {
      if (e) { res.writeHead(404).end('ipa not found'); return; }
      res.writeHead(200, {
        'content-type': 'application/octet-stream',
        'content-length': st.size,
        'content-disposition': 'attachment; filename="CodexPocket.ipa"',
        'x-codex-deployment': process.env.DEPLOYMENT_ID || 'legacy',
      });
      fs.createReadStream(f).pipe(res);
    });
    return;
  }
  // 取电脑上的图片。会话里的 imageView 给的是本地路径（如 /tmp/scr.png），
  // 手机读不到，只能让桥接代读。
  //
  // 只放行图片扩展名：这个路由带着令牌，但它不该变成一个通用的
  // "读电脑上任意文件"的口子。
  // 手机传图。**必须走 HTTP，不能走 JSON-RPC**：
  // app-server 那条 WebSocket 一断（用户网络下十几秒就抖一次），
  // 在途的 base64 大包整个丢，界面就报"图片上传失败：连接已断开"。
  // 这里用独立的 HTTP 请求收原始字节，跟 WebSocket 互不影响，
  // 而且不用 base64（少 33% 体积）。
  if (u.pathname === '/upload' && req.method === 'POST') {
    const name = (u.searchParams.get('name') || 'image.jpg')
      .replace(/[^A-Za-z0-9._-]/g, '').slice(-60) || 'image.jpg';
    const dir = '/tmp/codex-pocket';
    const chunks = [];
    let tooLarge = false;
    let n = 0;
    req.on('data', (c) => {
      n += c.length;
      if (n > 24 * 1024 * 1024) { tooLarge = true; return; }
      chunks.push(c);
    });
    req.on('end', async () => {
      if (tooLarge) {
        res.writeHead(413, { 'content-type': 'application/json', connection: 'close' });
        res.end(JSON.stringify({ error: 'upload too large', maxBytes: 24 * 1024 * 1024 }));
        return;
      }
      try {
        await fs.promises.mkdir(dir, { recursive: true });
        const file = dir + '/' + Date.now().toString(36) + '-' + crypto.randomUUID() + '-' + name;
        await fs.promises.writeFile(file, Buffer.concat(chunks));
        log('[upload]', file, n, 'bytes');
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ path: file, bytes: n }));
      } catch (e) {
        res.writeHead(500, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: String(e && e.message || e) }));
      }
    });
    return;
  }
  // 某个会话最近一次的用量。App 打开会话时来拉一次 ——
  // 服务端没有"查历史用量"的方法（thread/read、turns/list、resume
  // 都拿不到，实测），只能由常驻的桥接替它记下来。
  if (u.pathname === '/usage') {
    const tid = u.searchParams.get('threadId') || '';
    const row = (tid && usage[tid]) || null;
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(row || {}));
    return;
  }
  // 手机把帧级日志传上来，方便在电脑上直接看。
  if (u.pathname === '/framelog' && req.method === 'POST') {
    const chunks = [];
    let tooLarge = false;
    let n = 0;
    req.on('data', (c) => { n += c.length; if (n <= 8 * 1024 * 1024) chunks.push(c); else tooLarge = true; });
    req.on('end', async () => {
      const f = process.env.HOME + '/.codex/phone/frames.log';
      const buf = Buffer.concat(chunks);
      if (tooLarge) {
        res.writeHead(413, { 'content-type': 'application/json', connection: 'close' });
        res.end(JSON.stringify({ error: 'frame log too large', maxBytes: 8 * 1024 * 1024 }));
        return;
      }
      try {
        await fs.promises.mkdir(process.env.HOME + '/.codex/phone', { recursive: true });
        await fs.promises.writeFile(f, buf);
      } catch(error) {
        res.writeHead(500, { 'content-type': 'application/json' });
        res.end(JSON.stringify({error:'frame log could not be saved'}));
        return;
      }
      log('[framelog]', f, n, 'bytes');
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ path: f, bytes: buf.length }));
    });
    return;
  }
  if (u.pathname === '/file') {
    const p = u.searchParams.get('path') || '';
    const ext = (p.split('.').pop() || '').toLowerCase();
    const ok = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'heic', 'bmp'].includes(ext);
    if (!ok) { res.writeHead(403).end('not an image'); return; }
    fs.stat(p, (e, st) => {
      if (e || !st.isFile()) { res.writeHead(404).end('not found'); return; }
      const mime = ext === 'png' ? 'image/png'
        : (ext === 'gif' ? 'image/gif'
          : (ext === 'webp' ? 'image/webp' : 'image/jpeg'));
      res.writeHead(200, { 'content-type': mime, 'content-length': st.size,
                           'cache-control': 'private, max-age=600' });
      fs.createReadStream(p).pipe(res);
    });
    return;
  }

  fs.readFile(UI, (e, buf) => {
    if (e) { res.writeHead(500).end('ui missing'); return; }
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' }).end(buf);
  });
});

const wss = new WebSocketServer({ server, path: '/ws' });

wss.on('connection', (client, req) => {
  if (!authed(req)) { client.close(4401, 'unauthorized'); return; }
  const t0 = Date.now();
  const who = req.headers['cf-connecting-ip'] || req.socket.remoteAddress || '?';
  clients.add(client);
  approvals.replay(message=>client.send(JSON.stringify(message)));
  cancelIdleRestart();
  log('[ws] +client', who, 'total', clients.size);
  // 手机的系统版本藏在 URLSession 的 User-Agent 里（Darwin/23.x = iOS 17）。
  // 排查"某个交互在真机上不灵"时，这是最省事的一条证据。
  log('[ws] client UA =', String(req.headers['user-agent'] || '?').slice(0, 120));
  connectUpstream();
  if (!upReady) client.send(JSON.stringify({ method: 'bridge/upstream', params: { connected: false } }));

  const handleClientMessage = async (d, isBinary) => {
    client.__lastData = Date.now();
    activityEpoch++;
    lastClientActivity = Date.now();
    const s = isBinary ? d.toString() : d.toString();
    // 注意：iOS 的 JSONSerialization 会把 / 转义成 \/，
    // 所以这里必须解析 JSON，不能拿字符串去 includes。
    let m = null;
    if (!isBinary) { try { m = JSON.parse(s); } catch {} }

    // 应用层心跳：数据帧，能穿过任何空闲超时，并证明整条链路通。
    if (m && m.method === 'bridge/ping') {
      // 这条心跳只有新版 App 会发。打一行日志，就能一眼看出
      // 手机上装的是哪一版（旧版只发 WS 控制帧 ping）。
      if (!client.__hb) { client.__hb = true; log('[ws] client is NEW build (app-level heartbeat)'); }
      // App 会把自己的版本标记塞进心跳里。手机上装的是哪一版，
      // 看日志这一行就够了。
      if (m.params && m.params.build && client.__build !== m.params.build) {
        client.__build = m.params.build;
        log('[ws] client build =', m.params.build);
      }
      // 断线诊断：App 每次心跳带上"累计掉线数 / 连上过几次 / 最近一次断的原因"。
      // 日志里只有 close code=1006，分不清是对端掐的还是 App 自己探活误判拆的。
      if (m.params && (m.params.drops !== client.__drops
                       || m.params.why !== client.__why)) {
        client.__drops = m.params.drops;
        client.__why = m.params.why;
        log('[ws] client drops =', m.params.drops,
            'connects =', m.params.connects, 'lastDrop =', m.params.why);
      }
      client.send(JSON.stringify({ method: 'bridge/pong', params: { ts: Date.now() } }));
      return;
    }
    // 上游常驻且已 initialize；再转一次会回 "Already initialized"，
    // 手机端会把它当成握手失败而反复重连。这里直接本地应答。
    // 客户端的 initialize **一律本地应答**，跟上游在不在无关。
    // 上游的握手是桥接自己的事（见 connectUpstream）。
    // 上游没连上时靠 bridge/upstream 通知 + pending 队列兜着，
    // 不能让手机卡在"握手永远回不来 → 看门狗重连"的循环里。
    if (m && m.method === 'initialize') {
      client.send(JSON.stringify({ id: m.id, result: {} }));
      return;
    }
    if(m&&!m.method&&m.id!==undefined){await approvals.reply(m);return;}
    if(m?.method==='fs/readFile'&&typeof m.params?.path==='string'){
      let stat;try{stat=await fs.promises.stat(m.params.path);}catch{}
      if(stat?.size>2*1024*1024){
        if(client.readyState===1)client.send(JSON.stringify({id:m.id,error:{
          code:-32094,message:'文本文件超过 2 MiB，未读取',
        }}));
        return;
      }
    }
    const mutation=m&&listMutations.has(m.method);
    const original=m;
    const sendResponse=response=>{
      if(client.readyState===1)client.send(JSON.stringify(writers.decorate(
        withDesktopProjectless(response,original?.method))));
    };
    if(m?.method==='bridge/provider/models'){
      sendResponse({id:m.id,result:await loadProviderCatalog()});
      return;
    }
    if(m?.method==='bridge/submission/status'){
      try{sendResponse({id:m.id,result:await submissions.status(m.params)});}
      catch{sendResponse({id:m.id,error:{code:-32602,message:'threadId and clientUserMessageId are required'}});}
      return;
    }
    const deduplicated=submissions.key(m);
    if (deduplicated) {
      const state = await submissions.begin(m, sendResponse);
      if (state.duplicate) return;
    }
    const respond=response=>{
      if(deduplicated)void submissions.settle(original,response).catch(error=>{
        log('[submission] settlement failed',error.message);
        sendResponse({id:original.id,error:{code:-32091,message:'提交结果未知，请先查询会话历史或队列'}});
      });
      else sendResponse(response);
    };
    if(mutation)listFast.invalidate();
    if (m && await writers.route(m, response => {
      if(mutation)listFast.invalidate();
      respond(response);
    })) return;
    // `thread/list` 补 `modelProviders: []`。
    //
    // 上游 app-server 的 `thread/list` **默认只回当前 config 的
    // `model_provider`**（config.toml 里是 `custom`）的那些会话 ——
    // 别的 provider 建的会话一条都不给。手机端拿到的列表因此只剩两条
    // （01a125fa / 01a0bb40，恰好是 custom 的），用户在电脑上看得见的
    // 会话在手机上一片空白。
    //
    // 实测（同一个上游，只差这一个字段）：
    //   {limit:100,sortDirection:'desc'}                 -> 2 条
    //   {limit:100,sortDirection:'desc',modelProviders:[]} -> 16 条
    // 空数组 = 不过滤。App 那侧不用改、也不用重装。
    //
    // 只在**没写**这个字段时补，App 将来自己指定了就照它说的走。
    let out = s;
    if (m) {
      try { m = routes.register(client,withAllProviders(m),respond); out = JSON.stringify(m); } catch {}
      // 缓存里有就直接回，不打扰上游（一次 10~20 秒，用户看到的是"转半天"）。
      if (listFast.handle(m)) return;
    }
    if (!upstreamSend(out)) log('[ws] queued (upstream down)');
  };
  client.on('message', (d, isBinary) => {
    void handleClientMessage(d,isBinary).catch(error=>{
      log('[ws] request failed',error.message);
      let message;try{message=JSON.parse(String(d));}catch{}
      if(message?.id!==undefined&&client.readyState===1)client.send(JSON.stringify({
        id:message.id,error:{code:-32091,message:'请求结果未知，请先核对会话状态'},
      }));
    });
  });

  // 关闭码是判断"谁断的、为什么断"的唯一硬证据：
  // 1000/1005 = 对端正常关（App 主动重连、被系统回收）；
  // 1006 = 链路异常（网络切换、被中间层掐断、进程被挂起）；
  // 4401 = 令牌不对。
  const bye = (why) => (code, reason) => {
    clients.delete(client);
    for(const id of routes.drop(client))listFast.cancel(id);
    if (!clients.size) armIdleRestart();
    const r = reason ? reason.toString().slice(0, 80) : '';
    // 空转多久才断的：0 = 刚发过东西就被掐（中间层），
    // 大数 = 长时间没数据（空闲超时）。这是判断断链根因的关键一列。
    const quiet = Math.round((Date.now() - (client.__lastData || t0)) / 1000);
    log('[ws] -client', who, why, 'code=' + (code ?? '-'), r,
        'after', Date.now() - t0, 'ms; quiet', quiet + 's; total', clients.size);
  };
  // 服务端也要发心跳。
  // 之前只有手机单向往上打 `bridge/ping`：CF 边缘看这条 WS 是"半开"的，
  // 空闲计时器按**下行**算，于是手机明明在心跳还是被掐（日志里
  // 大量 code=1006、连接只活十几秒）。双向都发数据帧就稳了。
  client.__hb = client.__hb || null;
  const srv = setInterval(() => {
    if (client.readyState !== 1) { clearInterval(srv); return; }
    try {
      client.ping();
      client.send(JSON.stringify({ method: 'bridge/tick', params: { ts: Date.now() } }));
    } catch { clearInterval(srv); }
  }, 15000);
  client.on('close', () => clearInterval(srv));

  client.on('close', bye('close'));
  client.on('error', bye('error'));
});

server.listen(PORT, BIND, () => {
  log(`bridge http://${BIND}:${PORT} -> ${UPSTREAM} (persistent upstream)`);
  log('notify:', notifyConfigured() ? 'enabled' : 'disabled (no notify.json)');
  connectUpstream();
});

process.on('SIGTERM', () => { try { up?.close(); } catch {} process.exit(0); });
