const byId = id => document.getElementById(id);
const fragment = location.hash.slice(1);
if (fragment) sessionStorage.setItem('codexpocket.admin', fragment);
const admin = fragment || sessionStorage.getItem('codexpocket.admin') || '';
history.replaceState(null, '', location.pathname);
let state = {}, pairURI = '', busy = false, initialized = false;
function notice(message = '') {
  byId('notice').textContent = message;
  byId('notice').hidden = !message;
}
async function api(path, body) {
  const response = await fetch('/api/' + path, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { Authorization: 'Bearer ' + admin, 'Content-Type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || '连接暂时不可用，请重试。');
  return result;
}

function mode(value) {
  byId('tailpane').hidden = value !== 'tailscale';
  byId('vpspane').hidden = value !== 'vps';
  byId('tailtab').setAttribute('aria-pressed', value === 'tailscale');
  byId('vpstab').setAttribute('aria-pressed', value === 'vps');
}
async function refresh() {
  if (busy) return;
  busy = true;
  try {
    state = await api('status');
    byId('status').textContent = state.running ? '电脑已就绪' : '电脑尚未连接';
    byId('status').classList.toggle('ready', state.running);
    byId('toggle').textContent = state.running ? '停止连接' : '启动连接';
    byId('toggle').disabled = false;
    byId('codex').textContent = state.codex?.version ? 'Codex ' + state.codex.version : '启动后自动识别这台电脑上的 Codex。';
    if (!initialized) {
      byId('name').value = state.name || '';
      byId('endpoint').value = state.externalURL || '';
      mode(state.externalURL && !state.externalURL.includes('.ts.net') ? 'vps' : 'tailscale');
      initialized = true;
    }
    byId('details').textContent = [state.phase, state.codex?.path || state.codexPath || '', state.error || ''].filter(Boolean).join('\n');
    if (state.error) notice(state.error);
    if (state.running && state.endpoint) {
      const pair = await api('pair');
      if (pair.uri !== pairURI) {
        pairURI = pair.uri;
        const code = qrcode(0, 'M'); code.addData(pairURI); code.make();
        byId('qr').innerHTML = code.createSvgTag({ cellSize: 4, margin: 3, scalable: true });
        byId('qr').setAttribute('aria-label', '手机配对二维码');
      }
      byId('pairedEndpoint').textContent = pair.endpoint;
      byId('copy').disabled = false;
    } else {
      pairURI = '';
      byId('qr').textContent = state.running ? '选择连接方式后，这里会显示配对二维码。' : '启动连接端后设置连接方式。';
      byId('pairedEndpoint').textContent = '';
      byId('copy').disabled = true;
    }
  } catch (error) { notice(error.message); }
  finally { busy = false; }
}

async function action(button, path, body = {}) {
  button.disabled = true; notice();
  try { await api(path, body); await refresh(); }
  catch (error) { notice(error.message); }
  finally { button.disabled = false; }
}
byId('tailtab').onclick = () => mode('tailscale');
byId('vpstab').onclick = () => mode('vps');
byId('toggle').onclick = event => action(event.currentTarget, state.running ? 'stop' : 'start');
byId('tailscale').onclick = event => action(event.currentTarget, 'tailscale');
byId('save').onclick = event => action(event.currentTarget, 'config', {
  name: byId('name').value.trim(), externalURL: byId('endpoint').value.trim()
});
byId('name').onchange = () => action(byId('toggle'), 'config', { name: byId('name').value.trim() });
byId('copy').onclick = async () => {
  try { await navigator.clipboard.writeText(pairURI); notice('配对链接已复制，在手机上打开 CodexPocket 后粘贴。'); }
  catch { notice('复制失败，请重新点击，或直接用手机扫描二维码。'); }
};
if (!admin) notice('请从电脑连接端打开这个页面。');
else refresh();
setInterval(() => { if (!document.hidden && admin) refresh(); }, 2000);
document.addEventListener('visibilitychange', () => { if (!document.hidden && admin) refresh(); });
