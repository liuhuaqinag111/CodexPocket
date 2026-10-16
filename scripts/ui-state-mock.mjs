import http from 'node:http';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import { projects, threads, models, turns as previewTurns } from './fixtures/ui-data.mjs';

const require = createRequire(import.meta.url);
const { WebSocketServer } = require('ws');
const picture = '/tmp/ui-assistant.png';
const initialTurns = structuredClone(previewTurns);
// 真实长会话里会夹带 msg_ft/item 形式的空白 agent 占位；历史解析应丢掉，
// 不能在 UI 里留下只有「Codex」标题的空行。
initialTurns.at(-1).items.push(
  { id: 'blank-agent-1', type: 'agentMessage', text: ' ' },
  { id: 'blank-agent-2', type: 'agentMessage', text: '\n\u2028\t' },
  { id: 'blank-agent-3', type: 'agentMessage', text: '   ' }
);
initialTurns.at(-1).items.push({
  id: 'award-image', type: 'agentMessage', text: '界面截图，可点开查看。',
  result: { content: [{ type: 'image', url: picture }] }
});
let turns = structuredClone(initialTurns);
let responses = [];
let usage = null;
let imageState = 'ok';
const scrollThread = { ...threads[0], id: 'scroll-v709', name: '滚动回归长会话' };
let scrollTurns = [];
let scrollSequence = 0;
let scrollHistorySequence = 0;
let activeScrollTurn = null;
let resetSequence = 0;
const scrollText = index => Array.from({ length: 6 }, (_, line) =>
  `第 ${index} 轮第 ${line + 1} 段：这是隔离样例里的长消息，用于检查打开会话、发送消息和键盘收起时的滚动位置。`).join('\n\n');
const scrollNotify = (method, params) => ({ method,
  params: { threadId: scrollThread.id, turnId: activeScrollTurn?.id, ...params } });
function broadcast(frames) {
  for (const ws of wss.clients) if (ws.readyState === 1)
    for (const frame of frames) send(ws, frame);
}
const context = { threadId: 't1', turnId: 'award-turn', itemId: 'award-item' };
const send = (ws, message) => ws.send(JSON.stringify(message));
const notify = (method, params) => ({ method, params: { ...context, ...params } });

function messages(scenario) {
  if (scenario === 'approval-allow' || scenario === 'approval-deny') {
    return [{ id: 'award-' + scenario, method: 'item/commandExecution/requestApproval',
      params: { ...context, approvalId: scenario, command: 'swift test --filter LayoutTests',
        cwd: threads[0].cwd, reason: '验证本机界面布局' } }];
  }
  if (scenario === 'question') {
    return [{ id: 'award-question', method: 'item/tool/requestUserInput',
      params: { ...context, isBlocking: true, questions: [{
        id: 'approach', header: '检查顺序', question: '这次先检查哪一项？',
        options: [
          { label: '先检查布局', description: '核对间距、文字和触摸区域' },
          { label: '先检查动效', description: '核对打开与关闭的反馈' }
        ]
      }] } }];
  }
  return statusMessages(scenario);
}

function statusMessages(scenario) {
  if (scenario === 'plan' || scenario === 'plan-complete') {
    const plan = [
      { step: '读取设计规范', status: 'completed' },
      { step: '核对手机布局', status: scenario === 'plan' ? 'inProgress' : 'completed' }
    ];
    const user = { id: 'award-user', type: 'userMessage',
      content: [{ type: 'text', text: '按计划检查手机布局' }] };
    const turn = { id: 'award-turn', status: 'inProgress', items: [user,
      { id: 'plan-award-turn', type: 'plan', plan }] };
    const index = turns.findIndex(t => t.id === turn.id);
    if (index < 0) turns.push(turn); else turns[index] = turn;
    return [
      ...(scenario === 'plan' ? [notify('item/completed', { item: user }),
        notify('turn/started', { turn: { id: 'award-turn' } })] : []),
      notify('turn/plan/updated', { plan })
    ];
  }
  if (scenario === 'usage') {
    usage = { modelContextWindow: 96000, last: {
      totalTokens: 24000, inputTokens: 18000, outputTokens: 6000,
      cachedInputTokens: 4000, reasoningOutputTokens: 2000
    } };
    return [notify('thread/tokenUsage/updated', { tokenUsage: usage })];
  }
  return null;
}

function startScrollTurn(params) {
  if (params.threadId !== scrollThread.id) return {};
  const id = 'scroll-send-' + ++scrollSequence;
  const user = { id: id + '-user', type: 'userMessage',
    clientUserMessageId: params.clientUserMessageId, content: params.input };
  const agent = { id: id + '-agent', type: 'agentMessage', text: '合成回复开始。' };
  activeScrollTurn = { id, status: 'inProgress', startedAt: Date.now(), items: [user, agent] };
  scrollTurns.push(activeScrollTurn);
  setImmediate(() => broadcast([
    scrollNotify('turn/started', { turn: { id } }),
    scrollNotify('item/completed', { item: user }),
    scrollNotify('item/completed', { item: agent })
  ]));
  return { turn: { id, status: 'inProgress' } };
}

const handlers = {
  initialize: () => ({ userAgent: 'isolated-award-state' }),
  'project/list': () => ({ data: projects }),
  'model/list': () => ({ data: models }),
  'bridge/provider/models': () => ({ available: false, models: [] }),
  'config/read': () => ({ config: { model: 'gpt-5.5', model_reasoning_effort: 'high' } }),
  'thread/list': p => ({ data: p.archived || p.ancestorThreadId ? []
    : [...threads, ...(scrollTurns.length ? [scrollThread] : [])], nextCursor: null }),
  'thread/read': p => ({ thread: [...threads, scrollThread].find(t => t.id === p.threadId) }),
  'thread/resume': p => ({ thread: [...threads, scrollThread].find(t => t.id === p.threadId) }),
  'thread/turns/list': p => {
    const source = p.threadId === threads[0].id ? turns : p.threadId === scrollThread.id ? scrollTurns : [];
    return { data: (p.sortDirection === 'desc' ? [...source].reverse() : source)
      .slice(0, p.limit || source.length) };
  },
  'turn/start': startScrollTurn,
  'thread/queue/list': () => ({ data: [] })
};

function json(res, value, status = 200) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(value));
}

function scrollScenario(action) {
  if (action === 'process') {
    const result = scrollScenario('history');
    scrollTurns.at(-1).items = [
      { id: 'process-user', type: 'userMessage', content: [{ type: 'text', text: '查看过程' }] },
      { id: 'process-reason', type: 'reasoning', summary: [{ type: 'summary_text', text: scrollText(30) }] },
      { id: 'process-agent', type: 'agentMessage', text: '检查已完成。' }
    ];
    scrollTurns.at(-1).durationMs = 3000;
    return result;
  }
  if (action === 'history') {
    scrollThread.id = 'scroll-v709-' + Date.now() + '-' + ++scrollHistorySequence;
    scrollSequence = 0; activeScrollTurn = null;
    scrollTurns = Array.from({ length: 10 }, (_, index) => ({
      id: 'scroll-history-' + index, status: 'completed', startedAt: 1700000000000 + index * 1000, items: [
        { id: 'scroll-user-' + index, type: 'userMessage', content: [
          { type: 'text', text: `检查第 ${index + 1} 轮滚动位置` }] },
        { id: 'scroll-agent-' + index, type: 'agentMessage', text: scrollText(index + 1) }
      ]
    }));
    return { threadId: scrollThread.id, turns: scrollTurns.length };
  }
  if (!activeScrollTurn) return null;
  const agent = activeScrollTurn.items.at(-1);
  if (action === 'grow') {
    const delta = '\n\n' + scrollText(++scrollSequence);
    agent.text += delta;
    broadcast([scrollNotify('item/agentMessage/delta', { itemId: agent.id, delta })]);
    return { characters: agent.text.length };
  }
  return completeScrollTurn(action, agent);
}

function completeScrollTurn(action, agent) {
  if (action !== 'complete') return null;
  activeScrollTurn.status = 'completed';
  broadcast([scrollNotify('item/completed', { item: agent }),
    scrollNotify('turn/completed', { turn: activeScrollTurn })]);
  activeScrollTurn = null;
  return { completed: true };
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1:18182');
  if (url.pathname.startsWith('/scroll/') && req.method === 'POST') {
    const result = scrollScenario(url.pathname.slice(8));
    return json(res, result || { error: 'Unknown scroll action or no active turn' }, result ? 200 : 409);
  }
  if (url.pathname === '/file' && url.searchParams.get('path') === picture) {
    if (imageState === 'fail') return json(res, { error: 'image unavailable' }, 503);
    res.writeHead(200, { 'content-type': 'image/png', 'cache-control': 'no-store' });
    const finish = () => res.end(fs.readFileSync(new URL('./fixtures/assistant.png', import.meta.url)));
    if (imageState === 'slow') return setTimeout(finish, 2500);
    return finish();
  }
  if (url.pathname.startsWith('/image/') && req.method === 'POST') {
    imageState = url.pathname.slice(7);
    return json(res, { imageState });
  }
  if (url.pathname === '/reset' && req.method === 'POST') {
    threads[0].id = 'ui-fixture-' + Date.now() + '-' + ++resetSequence;
    context.threadId = threads[0].id;
    turns = structuredClone(initialTurns); responses = []; usage = null; imageState = 'ok';
    scrollTurns = []; scrollSequence = 0; activeScrollTurn = null;
    return json(res, { reset: true, threadId: threads[0].id });
  }
  if (url.pathname === '/responses') return json(res, { responses });
  if (url.pathname === '/usage') return json(res, { usage });
  if (url.pathname === '/health') return json(res, { clients: wss.clients.size });
  if (url.pathname.startsWith('/emit/') && req.method === 'POST') {
    return emit(url.pathname.slice(6), res);
  }
  json(res, { error: 'Unknown fixture endpoint' }, 404);
});

function emit(scenario, res) {
  const frames = messages(scenario);
  if (!frames) return json(res, { error: 'Unknown scenario' }, 404);
  const clients = [...wss.clients].filter(ws => ws.readyState === 1);
  if (!clients.length) return json(res, { error: 'No connected test app' }, 409);
  for (const ws of clients) for (const frame of frames) send(ws, frame);
  json(res, { scenario, clients: clients.length, frames: frames.length });
}

const wss = new WebSocketServer({ server, path: '/ws' });
wss.on('connection', ws => ws.on('message', raw => {
  const message = JSON.parse(raw);
  if (message.method === 'bridge/ping') {
    return send(ws, { method: 'bridge/pong', params: message.params });
  }
  if (message.id === undefined) return;
  if (!message.method) {
    responses.push(message);
    const resolved = notify('bridge/approvalResolved', { requestId: message.id });
    for (const client of wss.clients) if (client.readyState === 1) send(client, resolved);
    return;
  }
  send(ws, { id: message.id, result: handlers[message.method]?.(message.params || {}) || {} });
}));
server.listen(18182, '127.0.0.1', () => console.log('isolated award state mock :18182'));
