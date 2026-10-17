// app-server 健康检查：卡在 draining 就退出码 1，交给 supervise.sh 重启。
//
// 为什么要专测 thread/start：实测 app-server 长跑后会进入 draining，
// 那时 thread/start / thread/resume / thread/delete 全部返回
// "Server is draining"，而 thread/list、model/list 一切正常。
// 只探 readyz 或只拉列表都会漏判 —— 手机端的表现就是"新会话建不了、
// 点了没反应"，但界面看起来是"已连接"。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { WebSocket } from 'ws';

const port = process.argv[2] || '62115';
const tok = fs.readFileSync(process.env.TOKEN_FILE ||
  path.join(os.homedir(),'.codex','phone-token'), 'utf8').trim();

const ws = new WebSocket(`ws://127.0.0.1:${port}`, {
  headers: { Authorization: `Bearer ${tok}` },
});
let seq = 0;
const waiters = new Map();
function call(method, params) {
  const id = ++seq;
  return new Promise((res) => {
    waiters.set(id, res);
    ws.send(JSON.stringify({ id, method, params: params || {} }));
  });
}
ws.on('message', (d) => {
  let m; try { m = JSON.parse(d.toString()); } catch { return; }
  const w = waiters.get(m.id);
  if (w) { waiters.delete(m.id); w(m); }
});
const done = (code, msg) => { console.log(msg); try { ws.close(); } catch {} process.exit(code); };
const timer = setTimeout(() => done(1, 'TIMEOUT'), 20000);
ws.on('error', (e) => { clearTimeout(timer); done(1, 'ERR ' + e.message); });
ws.on('open', async () => {
  await call('initialize', { clientInfo: { name: 'wd', title: 'wd', version: '1' },
                             capabilities: { experimentalApi: true } });
  const r = await call('thread/start', { cwd: '~' });
  clearTimeout(timer);
  if (r.error) return done(1, 'DRAINING ' + String(r.error.message).slice(0, 70));
  const id = r.result && r.result.thread && r.result.thread.id;
  if (id) await call('thread/delete', { threadId: id });
  done(0, 'OK');
});
