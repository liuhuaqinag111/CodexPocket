import test from 'node:test';
import assert from 'node:assert/strict';
import { withAllProviders } from './list-params.mjs';

test('thread/list 默认补上 modelProviders: []，别的 provider 的会话才回得来', () => {
  const out = withAllProviders({ id: 7, method: 'thread/list',
    params: { limit: 100, sortDirection: 'desc' } });
  assert.deepEqual(out.params, { limit: 100, sortDirection: 'desc', modelProviders: [] });
  assert.equal(out.id, 7);
});

test('App 自己指定了 modelProviders 就照它说的走', () => {
  const params = { limit: 100, modelProviders: ['custom'] };
  assert.equal(withAllProviders({ id: 1, method: 'thread/list', params }).params, params);
});

test('别的 method 一个字节都不动', () => {
  const msg = { id: 2, method: 'thread/resume', params: { threadId: 't' } };
  assert.equal(withAllProviders(msg), msg);
});

test('没有 params 的 thread/list 也必须读取所有供应商', () => {
  assert.deepEqual(withAllProviders({ id: 3, method: 'thread/list' }),
                   { id: 3, method: 'thread/list', params: {modelProviders: []} });
});

test('null / 缺 method 的原样返回', () => {
  assert.equal(withAllProviders(null), null);
  assert.deepEqual(withAllProviders({ id: 4 }), { id: 4 });
});
