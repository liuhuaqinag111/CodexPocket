import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const CONFIG = process.env.NOTIFY_CONFIG
  || path.join(os.homedir(), '.codex', 'phone', 'notify.json');

/// 推送配置。支持 bark / ntfy / 自定义 webhook，可同时配多个。
export function loadNotifyConfig() {
  try {
    return JSON.parse(fs.readFileSync(CONFIG, 'utf8'));
  } catch {
    return {};
  }
}

export function notifyConfigured() {
  const c = loadNotifyConfig();
  return Boolean(c.bark || c.ntfy || c.webhook);
}

/// 把标题/正文按各渠道格式发出去。任一渠道失败不影响其他渠道。
export async function push({ title, body, url }) {
  const c = loadNotifyConfig();
  const jobs = [];

  if (c.bark) {
    const base = String(c.bark).replace(/\/+$/, '');
    const q = new URLSearchParams({
      title: title || '',
      body: body || '',
      group: c.barkGroup || 'Codex',
      ...(url ? { url } : {}),
    });
    jobs.push(fetch(`${base}/${encodeURIComponent(title || '')}/${encodeURIComponent(body || '')}?${q}`));
  }

  if (c.ntfy) {
    jobs.push(fetch(String(c.ntfy).replace(/\/+$/, ''), {
      method: 'POST',
      headers: {
        Title: encodeHeader(title || ''),
        ...(url ? { Click: url } : {}),
        ...(c.ntfyToken ? { Authorization: `Bearer ${c.ntfyToken}` } : {}),
      },
      body: body || '',
    }));
  }

  if (c.webhook) {
    jobs.push(fetch(c.webhook, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title, body, url }),
    }));
  }

  const results = await Promise.allSettled(jobs);
  return results.map((r) => (r.status === 'fulfilled' ? r.value.status : String(r.reason)));
}

/// HTTP 头不能带非 ASCII，中文标题需要编码。
function encodeHeader(s) {
  return /^[\x20-\x7E]*$/.test(s) ? s : encodeURIComponent(s);
}
