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

// 从代理 /status 拿当前活跃 provider id，超时或失败返回 null。
async function fetchLiveProviderId(address, port, fetchImpl) {
  try {
    const resp = await fetchImpl(`http://${address}:${port}/status`, {
      signal: AbortSignal.timeout(2_000),
    });
    if (!resp.ok) return null;
    const data = await resp.json();
    return typeof data.current_provider_id === 'string' && data.current_provider_id
      ? data.current_provider_id : null;
  } catch { return null; }
}

// 读代理配置拿地址和端口。
function readProxyConfig(dbPath) {
  if (!dbPath || !fs.existsSync(dbPath)) return null;
  let db;
  try {
    db = new DatabaseSync(dbPath, { readOnly: true });
    const row = db.prepare(
      'SELECT listen_address, listen_port FROM proxy_config WHERE app_type = ? AND enabled = 1 LIMIT 1',
    ).get('codex');
    if (!row) return null;
    return { address: String(row.listen_address || '127.0.0.1'), port: Number(row.listen_port || 15721) };
  } catch { return null; }
  finally { try { db?.close(); } catch {} }
}

export function readExecutionProvider(dbPath) {
  // Proxy mode must inherit the desktop config; is_current can lag hot switches.
  if (readProxyConfig(dbPath)) return null;
  return readActiveProvider(dbPath);
}

function readActiveProvider(dbPath, liveProviderId) {
  if (!dbPath || !fs.existsSync(dbPath)) return null;
  let db;
  try {
    db = new DatabaseSync(dbPath, { readOnly: true });
    // 优先用代理实时 id，兜底才用 is_current。
    const row = liveProviderId
      ? db.prepare(
          'SELECT id, name, settings_config FROM providers WHERE app_type = ? AND id = ? LIMIT 1',
        ).get('codex', liveProviderId)
      : db.prepare(
          'SELECT id, name, settings_config FROM providers WHERE app_type = ? AND is_current = 1 LIMIT 1',
        ).get('codex');
    if (!row) return null;
    const settings = JSON.parse(row.settings_config || '{}');
    const config = parseProviderConfig(settings.config);
    // modelCatalog 字段包含该分组的完整模型列表，优先使用。
    const catalogModels = settings.modelCatalog?.models;
    const selected = config.modelProvider;
    const auth = settings.auth && typeof settings.auth === 'object' ? settings.auth : {};
    const token = typeof auth.OPENAI_API_KEY === 'string' ? auth.OPENAI_API_KEY : '';
    const fingerprint = crypto.createHash('sha256').update(JSON.stringify({
      id: row.id, name: row.name, model: config.model, modelProvider: selected,
      baseURL: config.baseURL, wireAPI: config.wireAPI, token, catalogModels,
    })).digest('hex');
    return {
      id: String(row.id), name: String(row.name || row.id), fingerprint,
      model: config.model, modelProvider: selected, baseURL: config.baseURL,
      wireAPI: config.wireAPI, token, catalogModels: Array.isArray(catalogModels) ? catalogModels : null,
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

// 从 modelCatalog 字段直接构建模型列表，不发网络请求。
function normalizeCatalogModels(rows) {
  if (!Array.isArray(rows)) return [];
  return rows.filter(r => r && (r.model || r.id)).map(r => ({
    id: r.model || r.id,
    name: r.displayName || r.display_name || r.model || r.id,
    detail: '',
  }));
}

export function clearProviderCatalogCache() { cache.clear(); }

export async function loadProviderCatalog({
  dbPath = process.env.CC_SWITCH_DB || path.join(os.homedir(), '.cc-switch', 'cc-switch.db'),
  fetchImpl = globalThis.fetch,
  ttlMs = DEFAULT_TTL_MS,
  now = () => Date.now(),
} = {}) {
  // 1. 拿代理实时 provider id
  const proxyConf = readProxyConfig(dbPath);
  const liveId = proxyConf ? await fetchLiveProviderId(proxyConf.address, proxyConf.port, fetchImpl) : null;
  if (proxyConf && !liveId) return {available:true,models:[],error:'暂时无法确认电脑当前分组，请重试'};

  // 2. 读 provider 行
  let provider;
  try { provider = readActiveProvider(dbPath, liveId); }
  catch { return {available:true,models:[],error:'暂时无法读取 CC Switch 当前分组，请重试'}; }
  if (liveId && !provider) return {available:true,models:[],error:'电脑当前分组未找到，请重试'};
  if (!provider || !provider.baseURL) return { available: false, models: [], reason: 'cc-switch-unavailable' };

  const cached = cache.get(provider.fingerprint);
  if (cached && now() - cached.at < ttlMs) return cached.value;

  // 3. 优先从 modelCatalog 字段拿模型列表，无需额外网络请求。
  if (provider.catalogModels && provider.catalogModels.length > 0) {
    const models = normalizeCatalogModels(provider.catalogModels);
    if (models.length > 0) {
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
    }
  }

  // 4. 兜底：请求 /models 接口。
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
