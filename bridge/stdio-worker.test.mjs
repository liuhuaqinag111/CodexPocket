import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { createInterface } from 'node:readline';
import { spawn } from 'node:child_process';
test('portable CLI uses default stdio transport when --stdio is unsupported', async () => {
 const f=fixture({env:{CODEX_APP_SERVER_STDIO:'default'}});
 assert.deepEqual(f.spawnArgs[1],['app-server']);
 f.child.emit('exit',0,null);await f.worker.exit;
});
import { StdioWorker } from './stdio-worker.mjs';

function fixture(options = {}) {
  const child = new EventEmitter();
  for (const name of ['stdin', 'stdout', 'stderr']) child[name] = new PassThrough();
  child.kill = signal => { child.killSignal = signal; return true; };
  const sent = [];
  createInterface({ input: child.stdin }).on('line', line => sent.push(JSON.parse(line))).on('error', () => {});
  let spawnArgs;
  const worker = new StdioWorker({
    binary: '/fixture/codex', cwd: '/fixture/workspace', env: { FIXTURE: '1' },
    spawnProcess: (...args) => { spawnArgs = args; return child; }, ...options,
  });
  return { worker, child, sent, spawnArgs,
    respond: message => child.stdout.write(JSON.stringify(message) + '\n') };
}

async function initialize(f) {
  f.respond({ id: f.sent[0].id, result: {} });
  await f.worker.ready;
}

test('JSON string line separators survive stdio framing and resolve the request',async()=>{
 const notifications=[];
 const f=fixture({onNotification:(...args)=>notifications.push(args)});
 await initialize(f);
 const text='before\u2028middle\u2029after';
 const raw=JSON.stringify({method:'item/agentMessage/delta',params:{delta:text}})+'\n';
 const split=raw.indexOf('middle');
 f.child.stdout.write(raw.slice(0,split));
 f.child.stdout.write(raw.slice(split));
 assert.deepEqual(notifications,[['item/agentMessage/delta',{delta:text}]]);
 const call=f.worker.request('thread/read');await Promise.resolve();
 f.respond({id:2,result:{text}});
 assert.equal(f.worker.pendingCount,0);
 assert.deepEqual(await call,{text});f.child.emit('exit',0,null);
});

test('synchronous stdin failure removes the request from pending',async()=>{
 const f=fixture();await initialize(f);
 f.child.stdin.write=()=>{throw Object.assign(new Error('pipe closed'),{code:'EPIPE'});};
 await assert.rejects(f.worker.request('thread/read'),{code:'EPIPE'});
 assert.equal(f.worker.pendingCount,0);
 await assert.rejects(f.worker.request('thread/read'),{code:'EPIPE'});
 f.child.emit('exit',0,null);
});

test('synchronous stdin failure preserves an unresolved approval request',async()=>{
 const f=fixture();await initialize(f);
 f.respond({id:77,method:'item/commandExecution/requestApproval',params:{}});
 f.child.stdin.write=()=>{throw Object.assign(new Error('pipe closed'),{code:'EPIPE'});};
 await assert.rejects(async()=>f.worker.reply(77,{decision:'decline'}),{code:'EPIPE'});
 assert.equal(f.worker.pendingCount,1);
 f.child.emit('exit',0,null);
});

test('approval waits for stdin flush and preserves its id on asynchronous write failure',async()=>{
 const f=fixture();await initialize(f);
 f.respond({id:77,method:'item/commandExecution/requestApproval',params:{}});
 let finish;f.child.stdin.write=(_raw,callback)=>{finish=callback;return true;};
 const response=Promise.resolve(f.worker.reply(77,{decision:'accept'}));
 const rejected=assert.rejects(response,{code:'EPIPE'});
 assert.equal(f.worker.pendingCount,1);
 finish(Object.assign(new Error('pipe failed'),{code:'EPIPE'}));
 await rejected;assert.equal(f.worker.serverRequests.has(77),true);
 f.child.emit('exit',1,null);
});

test('unsupported server requests preserve JSON-RPC error response',async()=>{
 const f=fixture();await initialize(f);
 f.respond({id:78,method:'future/request',params:{}});
 await f.worker.reply(78,undefined,{code:-32601,message:'unsupported'});
 assert.deepEqual(f.sent.at(-1),{id:78,error:{code:-32601,message:'unsupported'}});
 f.child.emit('exit',0,null);
});

test('native resolution releases pending approval so idle worker can close',async()=>{
 const f=fixture();await initialize(f);
 f.respond({id:77,method:'item/tool/requestUserInput',params:{}});
 assert.equal(f.worker.pendingCount,1);
 f.respond({method:'serverRequest/resolved',params:{requestId:77}});
 assert.equal(f.worker.pendingCount,0);
 f.child.emit('exit',0,null);
});

test('a real subprocess receives EOF and exits cleanly without a signal', async () => {
  const script = `
    import { createInterface } from 'node:readline';
    createInterface({ input: process.stdin }).on('line', line => {
      const message = JSON.parse(line);
      if (message.id !== undefined) process.stdout.write(JSON.stringify({
        id: message.id, result: { received: message.method },
      }) + '\\n');
    });`;
  const worker = new StdioWorker({ binary: process.execPath,
    spawnProcess: (_binary, _args, options) => spawn(process.execPath,
      ['--input-type=module', '-e', script], options) });
  worker.child.kill = () => assert.fail('Worker must exit without a signal');
  assert.deepEqual(await worker.request('thread/read'), { received: 'thread/read' });
  assert.deepEqual(await worker.closeIdle(), { code: 0, signal: null });
  assert.equal(worker.child.exitCode, 0);
});

for (const stream of ['stdin', 'stdout', 'stderr']) test(`${stream} errors terminate transport without reporting an unconfirmed exit`, async () => {
  const exits = [];
  const f = fixture({ onExit: value => exits.push(value) });
  await initialize(f);
  const call = f.worker.request('thread/read');
  const rejected = assert.rejects(call, { code: 'EPIPE' });
  await Promise.resolve();
  assert.doesNotThrow(() => f.child[stream].emit('error', Object.assign(new Error('broken'), { code: 'EPIPE' })));
  await rejected;
  assert.equal(f.child.killSignal, 'SIGKILL');
  assert.equal(exits.length, 0);
  assert.equal(f.worker.pendingCount, 1);
  let closed = false;
  const closing = f.worker.closeIdle().then(() => { closed = true; });
  await Promise.resolve();
  assert.equal(closed, false);
  await assert.rejects(f.worker.request('thread/read'), { code: 'EPIPE' });
  f.child.emit('exit', null, 'SIGKILL');
  await closing;
  assert.equal(f.worker.pendingCount, 0);
  assert.equal(exits.length, 1);
});

test('a failed spawn rejects initialization and waits for confirmed process close', async () => {
  const exits = [];
  const f = fixture({ onExit: value => exits.push(value) });
  const rejected = assert.rejects(f.worker.ready, { code: 'ENOENT' });
  const error = Object.assign(new Error('PRIVATE_ERROR_PAYLOAD'), { code: 'ENOENT' });
  assert.doesNotThrow(() => f.child.emit('error', error));
  await rejected;
  assert.equal(exits.length, 0);
  f.child.emit('close', -2, null);
  assert.equal(exits.length, 1);
});

test('drains stderr and ignores malformed output without leaking payloads', async () => {
  const logs = [], notifications = [];
  const f = fixture({ log: (...args) => logs.push(args),
    onNotification: (...args) => notifications.push(args) });
  await initialize(f);
  assert.doesNotThrow(() => f.child.stdout.write('PRIVATE_INVALID_PAYLOAD\nnull\n'));
  f.child.stderr.write('PRIVATE_STDERR_PAYLOAD');
  f.child.stdout.write('{"method":"turn/com');
  f.child.stdout.write('pleted","params":{"threadId":"t"}}\n');
  assert.deepEqual(notifications, [['turn/completed', { threadId: 't' }]]);
  assert.equal(JSON.stringify(logs).includes('PRIVATE_'), false);
});

test('a close timeout rejects without reporting exit or allowing new requests', async t => {
  const exits = [];
  const f = fixture({ onExit: event => exits.push(event) });
  await initialize(f);
  let expire;
  t.mock.method(globalThis, 'setTimeout', (callback, ms) => {
    assert.equal(ms, 10000);
    expire = callback;
    return { unref() {} };
  });
  const close = f.worker.closeIdle();
  const rejected = assert.rejects(close, { code: 'ERR_WORKER_CLOSE_TIMEOUT' });
  assert.equal(typeof expire, 'function');
  expire();
  await rejected;
  assert.equal(exits.length, 0);
  await assert.rejects(f.worker.request('thread/read'), { code: 'ERR_WORKER_CLOSING' });
  await assert.rejects(f.worker.closeIdle(), { code: 'ERR_WORKER_CLOSE_TIMEOUT' });
  f.child.emit('exit', 0, null);
  assert.equal(exits.length, 1);
  await f.worker.closeIdle();
});

test('times out at 120 seconds without treating the server operation as idle', async t => {
  let expire;
  t.mock.method(globalThis, 'setTimeout', (callback, ms) => {
    assert.equal(ms, 120000);
    expire = callback;
    return { unref() {} };
  });
  const f = fixture();
  await initialize(f);
  const call = f.worker.request('thread/read');
  const rejected = assert.rejects(call, { code: 'ERR_WORKER_TIMEOUT' });
  await Promise.resolve();
  assert.equal(typeof expire, 'function');
  expire();
  await rejected;
  assert.equal(f.worker.pendingCount, 1);
  await assert.rejects(f.worker.closeIdle(), { code: 'ERR_WORKER_BUSY' });
  f.respond({ id: 2, result: {} });
  assert.equal(f.worker.pendingCount, 0);
});

test('closes stdin with EOF and waits for actual process exit', async () => {
  const f = fixture();
  await initialize(f);
  let eof = false, closed = false;
  f.child.stdin.on('end', () => { eof = true; });
  const close = f.worker.closeIdle().then(result => { closed = true; return result; });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(eof, true);
  assert.equal(closed, false);
  await assert.rejects(f.worker.request('thread/read'), { code: 'ERR_WORKER_CLOSING' });
  f.child.emit('exit', 0, null);
  assert.deepEqual(await close, { code: 0, signal: null });
  assert.deepEqual(await f.worker.closeIdle(), { code: 0, signal: null });
});

test('refuses EOF while initialization, a client RPC, or approval is pending', async () => {
  const f = fixture();
  await assert.rejects(f.worker.closeIdle(), { code: 'ERR_WORKER_BUSY' });
  await initialize(f);
  const call = f.worker.request('thread/read');
  await assert.rejects(f.worker.closeIdle(), { code: 'ERR_WORKER_BUSY' });
  f.respond({ id: 2, result: {} });
  await call;
  f.respond({ id: 'approval', method: 'item/requestApproval', params: {} });
  await assert.rejects(f.worker.closeIdle(), { code: 'ERR_WORKER_BUSY' });
  assert.equal(f.child.stdin.writableEnded, false);
  await f.worker.reply('approval', { decision: 'decline' });
  assert.equal(f.worker.pendingCount, 0);
});

test('rejects pending calls on exit and reports the exit once', async () => {
  const exits = [];
  const f = fixture({ onExit: (...args) => exits.push(args) });
  await initialize(f);
  const call = f.worker.request('thread/read');
  const failed = assert.rejects(call, { code: 'ERR_WORKER_EXITED' });
  await Promise.resolve();
  f.child.emit('exit', 7, null);
  f.child.emit('close', 7, null);
  assert.equal(f.worker.pendingCount, 0);
  assert.equal(exits.length, 1);
  await failed;
  await assert.rejects(f.worker.request('thread/read'), { code: 'ERR_WORKER_EXITED' });
});

test('dispatches server requests even when their IDs match client RPCs', async () => {
  const notifications = [], requests = [];
  const f = fixture({ onNotification: (...args) => notifications.push(args),
    onRequest: (...args) => requests.push(args) });
  await initialize(f);
  const call = f.worker.request('thread/read');
  await Promise.resolve();
  f.respond({ method: 'turn/completed', params: { threadId: 't' } });
  f.respond({ id: 2, method: 'item/commandExecution/requestApproval', params: { threadId: 't' } });
  assert.deepEqual(notifications, [['turn/completed', { threadId: 't' }]]);
  assert.deepEqual(requests, [[2, 'item/commandExecution/requestApproval', { threadId: 't' }]]);
  assert.equal(f.worker.pendingCount, 2);
  await f.worker.reply(2, { decision: 'decline' });
  assert.deepEqual(f.sent.at(-1), { id: 2, result: { decision: 'decline' } });
  f.respond({ id: 2, result: {} });
  await call;
  assert.equal(f.worker.pendingCount, 0);
});

test('correlates out-of-order replies and preserves RPC error codes', async () => {
  const f = fixture();
  await initialize(f);
  const first = f.worker.request('thread/read');
  const second = f.worker.request('thread/resume');
  const rejected = assert.rejects(second, { message: 'Writer busy', code: -32004 });
  await Promise.resolve();
  f.respond({ id: f.sent[3].id, error: { code: -32004, message: 'Writer busy' } });
  f.respond({ id: f.sent[2].id, result: { thread: { id: 'first' } } });
  assert.deepEqual(await first, { thread: { id: 'first' } });
  await rejected;
});

test('initializes the stdio peer before sending business RPCs', async () => {
  const f = fixture();
  assert.deepEqual(f.spawnArgs, ['/fixture/codex', ['app-server', '--stdio'], {
    cwd: '/fixture/workspace', env: { FIXTURE: '1' }, stdio: ['pipe', 'pipe', 'pipe'],
  }]);
  assert.deepEqual(f.sent[0], { id: 1, method: 'initialize', params: {
    clientInfo: { name: 'codex-phone-worker', version: '1' },
    capabilities: { experimentalApi: true },
  } });
  const call = f.worker.request('thread/read', { threadId: 't' });
  assert.equal(f.sent.length, 1);
  await initialize(f);
  assert.deepEqual(f.sent[1], { method: 'initialized' });
  assert.deepEqual(f.sent[2], { id: 2, method: 'thread/read', params: { threadId: 't' } });
  f.respond({ id: 2, result: { thread: { id: 't' } } });
  assert.deepEqual(await call, { thread: { id: 't' } });
});
