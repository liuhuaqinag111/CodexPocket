import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {DatabaseSync} from 'node:sqlite';

const DEFAULT_TTL_MS = 30_000;
const cache = new Map();

function tomlString(value) {
  const text = String(value ?? '').trim();
  if (!text) return '';
  if (text.startsWith('"') && text.endsWith('"')) {
    try { return JSON.parse(text); } catch { return text.slice(1, -1); }
  }
  if (text.startsWith("'") && text.endsWith("'")) return text.slice(1, -1);
  return text.split('#', 1)[0].trim();
}

// CC Switch stores the provider's TOML as text. We only read the scalar keys
// needed to identify the endpoint and model; no TOML is written or re-emitted.
function parseProviderConfig(text) {
  let section = '';
  const values = new Map();
  for (const line of String(text || '').split(/\r?\n/)) {
    const clean = line.replace(/\s+#.*$/, '').trim();
    if (!clean || clean.startsWith('#')) continue;
    const header = clean.match(/^\[([^\]]+)\]$/);
    if (header) { section = header[1].trim(); continue; }
    const pair = clean.match(/^([A-Za-z0-9_-]+)\s*=\s*(.+)$/);
    if (!pair) continue;
    values.set(section ? `${section}.${pair[1]}` : pair[1], tomlString(pair[2]));
  }
  const provider = values.get(`model_providers.${values.get('model_provider')}.base_url`)
    ? values.get('model_provider') : '';
  return {
    model: values.get('model') || '',
    modelProvider: values.get('model_provider') || '',
    baseURL: provider ? values.get(`model_providers.${provider}.base_url`) : '',
    wireAPI: provider ? values.get(`model_providers.${provider}.wire_api`) : '',
  };
}

function readActiveProvider(dbPath) {
  if (!dbPath || !fs.existsSync(dbPath)) return null;
  let db;
  try {
    db = new DatabaseSync(dbPath, { readOnly: true });
    const row = db.prepare(
      'SELECT id, name, settings_config FROM providers WHERE app_type = ? AND is_current = 1 LIMIT 1',
    ).get('codex');
    if (!row) return null;
    const settings = JSON.parse(row.settings_config || '{}');
    const config = parseProviderConfig(settings.config);
    const selected = config.modelProvider;
    const auth = settings.auth && typeof settings.auth === 'object' ? settings.auth : {};
    const token = typeof auth.OPENAI_API_KEY === 'string' ? auth.OPENAI_API_KEY : '';
    const fingerprint = crypto.createHash('sha256').update(JSON.stringify({
      id: row.id, name: row.name, model: config.model, modelProvider: selected,
      baseURL: config.baseURL, wireAPI: config.wireAPI, token,
    })).digest('hex');
    return {
      id: String(row.id), name: String(row.name || row.id), fingerprint,
      model: config.model, modelProvider: selected, baseURL: config.baseURL,
      wireAPI: config.wireAPI, token,
    };
  } finally { try { db?.close(); } catch {} }
}

function normalizeModels(body) {
  const rows = Array.isArray(body) ? body : body?.data;
  if (!Array.isArray(rows)) return [];
  return rows.filter(row => row && typeof row.id === 'string' && row.id.trim()).map(row => ({
    id: row.id,
    name: typeof row.display_name === 'string' && row.display_name ? row.display_name
      : typeof row.name === 'string' && row.name ? row.name : row.id,
    detail: typeof row.description === 'string' ? row.description : '',
  }));
}

export function clearProviderCatalogCache() { cache.clear(); }

export async function loadProviderCatalog({
  dbPath = process.env.CC_SWITCH_DB || path.join(os.homedir(), '.cc-switch', 'cc-switch.db'),
  fetchImpl = globalThis.fetch,
  ttlMs = DEFAULT_TTL_MS,
  now = () => Date.now(),
} = {}) {
  let provider;
  try { provider = readActiveProvider(dbPath); }
  catch { return {available:true,models:[],error:'暂时无法读取 CC Switch 当前分组，请重试'}; }
  if (!provider || !provider.baseURL) return { available: false, models: [], reason: 'cc-switch-unavailable' };
  const cached = cache.get(provider.fingerprint);
  if (cached && now() - cached.at < ttlMs) return cached.value;
  const endpoint = provider.baseURL.replace(/\/+$/, '') + '/models';
  try {
    const response = await fetchImpl(endpoint, {
      headers: provider.token ? { Authorization: `Bearer ${provider.token}` } : {},
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) throw new Error(`provider returned HTTP ${response.status}`);
    const models = normalizeModels(await response.json());
    const value = {
      available: true,
      provider: { id: provider.id, name: provider.name, fingerprint: provider.fingerprint,
        model: provider.model, modelProvider: provider.modelProvider, baseURL: provider.baseURL,
        wireAPI: provider.wireAPI },
      models,
    };
    cache.set(provider.fingerprint, { at: now(), value });
    while(cache.size>4)cache.delete(cache.keys().next().value);
    return value;
  } catch (error) {
    const message = error instanceof Error ? error.message : 'provider request failed';
    const safeError = provider.token && message.includes(provider.token)
      ? message.replaceAll(provider.token, '[redacted]') : message;
    return { available: true, provider: { id: provider.id, name: provider.name,
      fingerprint: provider.fingerprint, model: provider.model,
      modelProvider: provider.modelProvider, baseURL: provider.baseURL, wireAPI: provider.wireAPI },
      models: [], error: safeError };
  }
}

export {normalizeModels, parseProviderConfig, readActiveProvider};
