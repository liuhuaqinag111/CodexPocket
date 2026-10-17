import { spawn } from 'node:child_process';
import { StringDecoder } from 'node:string_decoder';

const failure = (message, code) => Object.assign(new Error(message), { code });

export class StdioWorker {
  constructor({ binary, env = process.env, cwd, log = () => {},
    onNotification = () => {}, onRequest = () => {}, onExit = () => {},
    spawnProcess = spawn }) {
    this.log = log;
    this.onNotification = onNotification;
    this.onRequest = onRequest;
    this.onExit = onExit;
    this.pending = new Map();
    this.serverRequests = new Set();
    this.sequence = 0;
    this.queued = 0;
    const args=env.CODEX_APP_SERVER_STDIO==='default'?['app-server']:['app-server','--stdio'];
    this.child = spawnProcess(binary, args, {
      cwd, env, stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.exit = new Promise(resolve => { this.resolveExit = resolve; });
    this.child.once('exit', (code, signal) => this.finish(code, signal));
    this.child.once('close', (code, signal) => this.finish(code, signal));
    this.child.on('error', error => this.fail(error));
    for (const stream of [this.child.stdin, this.child.stdout, this.child.stderr]) {
      stream.on('error', error => this.fail(error));
    }
    // JSON-RPC over stdio is LF framed. `node:readline` also treats U+2028 and
    // U+2029 as line separators, which splits valid JSON string content and
    // leaves the caller waiting forever. Decode bytes and split on LF only.
    this.decoder = new StringDecoder('utf8');
    this.stdoutParts = [];
    this.child.stdout.on('data', chunk => this.receiveData(chunk));
    this.child.stdout.on('end', () => this.receiveData(Buffer.alloc(0), true));
    this.child.stderr.resume();
    this.ready = this.call('initialize', {
      clientInfo: { name: 'codex-phone-worker', version: '1' },
      capabilities: { experimentalApi: true },
    }).then(() => this.write({ method: 'initialized' }));
    this.ready.catch(() => {});
  }

  async request(method, params = {}) {
    this.queued++;
    try { await this.ready; } finally { this.queued--; }
    return this.call(method, params);
  }

  call(method, params) {
    if (this.exited) return Promise.reject(this.exitError);
    if (this.transportError) return Promise.reject(this.transportError);
    if (this.closing) return Promise.reject(failure('App-server is closing', 'ERR_WORKER_CLOSING'));
    const id = ++this.sequence;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        // A timeout does not cancel the server operation or prove it is idle.
        reject(failure('App-server request timed out', 'ERR_WORKER_TIMEOUT'));
      }, 120000);
      timer.unref();
      this.pending.set(id, { resolve, reject, timer });
      try {
        this.write({ id, method, params });
      } catch (error) {
        this.pending.delete(id);
        clearTimeout(timer);
        this.fail(error);
        reject(error);
      }
    });
  }

  write(message, done = () => {}) {
    if (this.exited) throw this.exitError;
    if (this.transportError) throw this.transportError;
    this.child.stdin.write(JSON.stringify(message) + '\n', error => {
      if (error) this.fail(error);
      done(error);
    });
  }

  get pendingCount() {
    return this.queued + this.pending.size + this.serverRequests.size;
  }

  fail(error) {
    if (this.transportError || this.exited) return;
    this.transportError = failure('App-server transport failed', error.code || 'ERR_WORKER_TRANSPORT');
    for (const waiting of this.pending.values()) {
      clearTimeout(waiting.timer);
      waiting.reject(this.transportError);
    }
    this.log('worker-transport-error', { code: this.transportError.code });
    // Broken transport cannot prove the server idle. Keep ownership and pending
    // state until the process actually exits, but do not leave it holding locks.
    this.forceClose();
  }

  async closeIdle() {
    if (this.exited) return this.exit;
    if (this.closing) return this.closePromise;
    if (this.pendingCount) throw failure('App-server is busy', 'ERR_WORKER_BUSY');
    this.closing = true;
    this.closePromise = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(failure('App-server did not exit after EOF', 'ERR_WORKER_CLOSE_TIMEOUT'));
      }, 10000);
      timer.unref();
      this.exit.then(result => { clearTimeout(timer); resolve(result); });
      this.child.stdin.end();
    });
    return this.closePromise;
  }

  forceClose() {
    if (this.exited) return this.exit;
    this.closing = true;
    this.closePromise = this.exit;
    try { this.child.kill?.('SIGKILL'); } catch (error) { this.log('worker-force-close-failed', { code: error.code }); }
    return this.exit;
  }

  finish(code, signal) {
    if (this.exited) return;
    this.exited = true;
    this.exitError = failure('App-server exited', 'ERR_WORKER_EXITED');
    for (const waiting of this.pending.values()) {
      clearTimeout(waiting.timer);
      waiting.reject(this.exitError);
    }
    this.pending.clear();
    this.serverRequests.clear();
    this.decoder.end();
    this.stdoutParts = [];
    const result = { code, signal };
    this.resolveExit(result);
    this.onExit(result);
  }

  receiveData(chunk, ended = false) {
    let text = this.decoder.write(chunk) + (ended ? this.decoder.end() : '');
    let cut;
    while ((cut = text.indexOf('\n')) >= 0) {
      this.stdoutParts.push(text.slice(0, cut));
      const line = this.stdoutParts.join('');
      this.receive(line.endsWith('\r') ? line.slice(0, -1) : line);
      this.stdoutParts = [];
      text = text.slice(cut + 1);
    }
    if (text) this.stdoutParts.push(text);
    if (ended && this.stdoutParts.length) {
      this.receive(this.stdoutParts.join(''));
      this.stdoutParts = [];
    }
  }

  async reply(id, result, error) {
    if (!this.serverRequests.has(id)) throw new Error('Unknown server request');
    try {
      await new Promise((resolve, reject) => {
        this.write(error ? { id, error } : { id, result }, failure => failure ? reject(failure) : resolve());
      });
      this.serverRequests.delete(id);
    } catch (failure) {
      this.fail(failure);
      throw failure;
    }
  }

  receive(line) {
    let message;
    try { message = JSON.parse(line); }
    catch { this.log('worker-protocol-error', { kind: 'invalid-json' }); return; }
    if (!message || typeof message !== 'object' || Array.isArray(message)) return;
    if (typeof message.method === 'string') {
      if (message.method === 'serverRequest/resolved') {
        this.serverRequests.delete(message.params?.requestId);
      }
      if (message.id !== undefined) {
        this.serverRequests.add(message.id);
        this.onRequest(message.id, message.method, message.params);
      } else this.onNotification(message.method, message.params);
      return;
    }
    const waiting = this.pending.get(message.id);
    if (!waiting) return;
    this.pending.delete(message.id);
    clearTimeout(waiting.timer);
    if (message.error) {
      const error = new Error(message.error.message || 'App-server request failed');
      error.code = message.error.code;
      waiting.reject(error);
    } else waiting.resolve(message.result);
  }
}
