import test from 'node:test';
import assert from 'node:assert/strict';
import { ListFast } from './list-fast.mjs';

function fixture(opts = {}) {
  const up = [], down = [];
  const f = new ListFast({ sendUpstream: m => up.push(m),
                           sendClient: m => down.push(m),
                           retryDelay: 1, ...opts });
  return { f, up, down };
}
const page = n => ({ data: Array.from({ length: n }, (_, i) => ({ id: 't' + i })), nextCursor: null });

test('confirmed empty background refresh replaces the old active page',async()=>{
 const {f,up,down}=fixture({ttl:0,retries:1});
 f.handle({id:1,method:'thread/list',params:{}});
 f.onUpstream({id:1,result:page(1)});
 f.handle({id:2,method:'thread/list',params:{}});
 const id=up.at(-1).id;
 f.onUpstream({id,result:page(0)});
 await new Promise(r=>setTimeout(r,10));
 assert.equal(up.length,2,'empty background response must be retried');
 f.onUpstream({id,result:page(0)});
 f.handle({id:3,method:'thread/list',params:{}});
 assert.deepEqual(down.at(-1).result.data,[]);f.cancelTimers();
});

test('warm uses the same all-provider parameters as phone requests',()=>{
 const {f,up}=fixture();f.warm();
 assert.deepEqual(up[0].params.modelProviders,[]);f.cancelTimers();
});

test('第一次请求照常转发，不拦', () => {
  const { f, up, down } = fixture();
  assert.equal(f.handle({ id: 1, method: 'thread/list', params: { limit: 100 } }), false);
  assert.equal(up.length, 0); assert.equal(down.length, 0);
});

test('拿到内容后，同一组参数再来就直接秒回缓存', () => {
  const { f, down } = fixture();
  f.handle({ id: 1, method: 'thread/list', params: { limit: 100 } });
  assert.equal(f.onUpstream({ id: 1, result: page(3) }), 'pass');
  assert.equal(f.handle({ id: 2, method: 'thread/list', params: { limit: 100 } }), true);
  assert.equal(down.length, 1);
  assert.equal(down[0].id, 2);
  assert.equal(down[0].result.data.length, 3);
});

test('参数字段顺序不同也算同一条缓存', () => {
  const { f, down } = fixture();
  f.handle({ id: 1, method: 'thread/list', params: { limit: 100, archived: true } });
  f.onUpstream({ id: 1, result: page(2) });
  assert.equal(f.handle({ id: 2, method: 'thread/list', params: { archived: true, limit: 100 } }), true);
  assert.equal(down[0].id, 2);
});

test('重试耗尽后确认的空结果可以替换旧缓存', () => {
  const { f, down } = fixture({ retries: 0 });
  f.handle({ id: 1, method: 'thread/list', params: {} });
  assert.equal(f.onUpstream({ id: 1, result: { data: [], nextCursor: null } }), 'pass');
  assert.equal(f.handle({ id: 2, method: 'thread/list', params: {} }), true);
  assert.deepEqual(down[0].result.data, []);
});

test('mutation invalidation retries stale inflight pages before returning them',()=>{
 const {f,up}=fixture();
 f.handle({id:1,method:'thread/list',params:{}});
 f.invalidate();
 assert.equal(f.onUpstream({id:1,result:page(1)}),'hold');
 assert.equal(f.cache.size,0);assert.equal(up.length,1);
 assert.equal(f.onUpstream({id:1,result:page(2)}),'pass');
 assert.equal(f.cache.values().next().value.result.data.length,2);f.cancelTimers();
});

test('第一页空结果会重试，重试后仍空才放行', async () => {
  const { f, up } = fixture({ retries: 1 });
  f.handle({ id: 1, method: 'thread/list', params: {} });
  assert.equal(f.onUpstream({ id: 1, result: { data: [], nextCursor: null } }), 'hold');
  await new Promise(r => setTimeout(r, 20));
  assert.equal(up.length, 1);
  assert.deepEqual(up[0], { id: 1, method: 'thread/list', params: {} });
  assert.equal(f.onUpstream({ id: 1, result: { data: [], nextCursor: null } }), 'pass');
});

test('重试之后拿到内容就正常回给客户端', async () => {
  const { f, up } = fixture({ retries: 2 });
  f.handle({ id: 1, method: 'thread/list', params: {} });
  f.onUpstream({ id: 1, result: { data: [] } });
  await new Promise(r => setTimeout(r, 20));
  assert.equal(f.onUpstream({ id: 1, result: page(5) }), 'pass');
  assert.equal(f.handle({ id: 2, method: 'thread/list', params: {} }), true);
});

test('翻页（带 cursor）空结果不重试 —— 翻到底本来就是空的', () => {
  const { f, up } = fixture();
  f.handle({ id: 1, method: 'thread/list', params: { cursor: 'abc' } });
  assert.equal(f.onUpstream({ id: 1, result: { data: [], nextCursor: null } }), 'pass');
  assert.equal(up.length, 0);
});

test('错误包不缓存、不重试，原样放行', () => {
  const { f } = fixture();
  f.handle({ id: 1, method: 'thread/list', params: {} });
  assert.equal(f.onUpstream({ id: 1, error: { message: 'boom' } }), 'pass');
  assert.equal(f.handle({ id: 2, method: 'thread/list', params: {} }), false);
});

test('别的 method 一个字节都不碰', () => {
  const { f } = fixture();
  assert.equal(f.handle({ id: 1, method: 'thread/resume', params: { threadId: 't' } }), false);
  assert.equal(f.onUpstream({ id: 1, result: {} }), 'pass');
});

test('缓存过期后不秒回，但仍会后台刷新', async () => {
  const { f, up, down } = fixture({ ttl: 0, maxStale: 60000 });
  f.handle({ id: 1, method: 'thread/list', params: { limit: 100 } });
  f.onUpstream({ id: 1, result: page(3) });
  up.length = 0;
  assert.equal(f.handle({ id: 2, method: 'thread/list', params: { limit: 100 } }), true);
  assert.equal(down[0].id, 2);
  assert.equal(up.length, 1);
  assert.match(String(up[0].id), /^list-bg-/);
});

test('后台刷新的回包不广播给客户端', () => {
  const { f, up } = fixture({ ttl: 0 });
  f.handle({ id: 1, method: 'thread/list', params: {} });
  f.onUpstream({ id: 1, result: page(1) });
  f.handle({ id: 2, method: 'thread/list', params: {} });
  const bgId = up[0].id;
  assert.equal(f.onUpstream({ id: bgId, result: page(9) }), 'drop');
});

test('缓存太老就不兜了，老老实实去拉', () => {
  const { f } = fixture({ maxStale: -1 });
  f.handle({ id: 1, method: 'thread/list', params: {} });
  f.onUpstream({ id: 1, result: page(2) });
  assert.equal(f.handle({ id: 2, method: 'thread/list', params: {} }), false);
});

test('缓存条数有上限，不会无限涨', () => {
  const { f } = fixture({ maxEntries: 2 });
  for (let i = 0; i < 5; i++) {
    f.handle({ id: i + 1, method: 'thread/list', params: { limit: i } });
    f.onUpstream({ id: i + 1, result: page(1) });
  }
  assert.equal(f.cache.size, 2);
});

test('warm() 把活跃页和归档页都烘一遍', () => {
  const { f, up } = fixture();
  f.warm();
  assert.equal(up.length, 2);
  const arch = up.find(m => m.params.archived);
  assert.ok(arch, '归档页也要烘');
  assert.equal(arch.params.limit, 100);
});

test('warm() 不会给同一条参数烘两遍', () => {
  const { f, up } = fixture();
  f.warm(); f.warm();
  assert.equal(up.length, 2);
});

test('上游没连上时不发起后台刷新（避免上游一回来就被刷屏）', () => {
  const { f, up } = fixture({ ttl: 0, canUpstream: () => false });
  f.handle({ id: 1, method: 'thread/list', params: {} });
  f.onUpstream({ id: 1, result: page(1) });
  up.length = 0;
  assert.equal(f.handle({ id: 2, method: 'thread/list', params: {} }), true);
  assert.equal(up.length, 0);
});

test('上游连上后照常刷新', () => {
  const { f, up } = fixture({ ttl: 0, canUpstream: () => true });
  f.handle({ id: 1, method: 'thread/list', params: {} });
  f.onUpstream({ id: 1, result: page(1) });
  up.length = 0;
  f.handle({ id: 2, method: 'thread/list', params: {} });
  assert.equal(up.length, 1);
});
