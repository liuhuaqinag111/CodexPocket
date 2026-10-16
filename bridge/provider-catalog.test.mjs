import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {clearProviderCatalogCache, loadProviderCatalog} from './provider-catalog.mjs';

const config = (model, provider, base) => `model = ${JSON.stringify(model)}
model_provider = ${JSON.stringify(provider)}
[model_providers.${provider}]
name = ${JSON.stringify(provider)}
base_url = ${JSON.stringify(base)}
wire_api = "responses"
`;
async function fixture(name, settings) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'provider-catalog-'));
  const dbPath = path.join(dir, 'cc-switch.db');
  const db = new DatabaseSync(dbPath);
  db.exec('CREATE TABLE providers (id TEXT, app_type TEXT, name TEXT, settings_config TEXT, is_current INTEGER)');
  db.prepare('INSERT INTO providers VALUES (?, ?, ?, ?, ?)').run('p-' + name, 'codex', name, JSON.stringify(settings), 1);
  db.close();
  return {dbPath, dir};
}

test('without CC Switch returns no models', async () => {
  clearProviderCatalogCache();
  const got = await loadProviderCatalog({dbPath: '/tmp/does-not-exist-codexpocket.db'});
  assert.deepEqual(got, {available: false, models: [], reason: 'cc-switch-unavailable'});
});

test('returns every provider model and never exposes auth', async () => {
  clearProviderCatalogCache();
  const f = await fixture('alpha', {config: config('gpt-alpha', 'custom', 'https://alpha.test/v1'), auth: {OPENAI_API_KEY: 'secret'}});
  const got = await loadProviderCatalog({dbPath: f.dbPath, fetchImpl: async (url, opts) => {
    assert.equal(url, 'https://alpha.test/v1/models');
    assert.equal(opts.headers.Authorization, 'Bearer secret');
    return {ok: true, json: async () => ({data: [{id: 'one'}, {id: 'two', owned_by: 'x'}]})};
  }});
  assert.deepEqual(got.models.map(m => m.id), ['one', 'two']);
  assert.equal(got.provider.name, 'alpha');
  assert.equal(JSON.stringify(got).includes('secret'), false);
  await fs.rm(f.dir, {recursive: true, force: true});
});

test('switching provider uses a new fingerprint and does not reuse old models', async () => {
  clearProviderCatalogCache();
  const f = await fixture('first', {config: config('one', 'custom', 'https://one.test/v1')});
  let calls = 0;
  const fetchImpl = async () => ({ok: true, json: async () => ({data: [{id: ++calls === 1 ? 'one' : 'two'}]})});
  const first = await loadProviderCatalog({dbPath: f.dbPath, fetchImpl});
  const db = new DatabaseSync(f.dbPath);
  db.prepare('UPDATE providers SET id=?, name=?, settings_config=?').run('p-second', 'second', JSON.stringify({config: config('two', 'custom', 'https://two.test/v1')}));
  db.close();
  const second = await loadProviderCatalog({dbPath: f.dbPath, fetchImpl});
  assert.deepEqual(first.models.map(m => m.id), ['one']);
  assert.deepEqual(second.models.map(m => m.id), ['two']);
  await fs.rm(f.dir, {recursive: true, force: true});
});

test('provider error returns no stale models and redacts auth', async () => {
  clearProviderCatalogCache();
  const f = await fixture('bad', {config: config('bad', 'custom', 'https://bad.test/v1'), auth: {OPENAI_API_KEY: 'secret'}});
  const got = await loadProviderCatalog({dbPath: f.dbPath, fetchImpl: async () => { throw new Error('401 secret'); }});
  assert.deepEqual(got.models, []);
  assert.equal(JSON.stringify(got).includes('secret'), false);
  await fs.rm(f.dir, {recursive: true, force: true});
});
