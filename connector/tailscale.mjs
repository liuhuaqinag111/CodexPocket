import fs from 'node:fs';
import path from 'node:path';
import {runCommand} from './discovery.mjs';
function tailscaleBinary() {
 if(process.env.TAILSCALE_BIN)return process.env.TAILSCALE_BIN;
 if(process.platform==='win32') {
  const file=path.win32.join(process.env.ProgramFiles||'C:\\Program Files','Tailscale','tailscale.exe');
  if(fs.existsSync(file))return file;
 }
 for(const file of ['/Applications/Tailscale.app/Contents/MacOS/Tailscale','/usr/local/bin/tailscale'])
  if(fs.existsSync(file))return file;
 return 'tailscale';
}
function serveState(config,domain,httpsPort,target) {
 const suffix=':'+httpsPort,tcp=config.TCP?.[httpsPort];
 const web=Object.entries(config.Web||{}).filter(([key])=>key.endsWith(suffix));
 const funnel=Object.entries(config.AllowFunnel||{}).some(([key,value])=>key.endsWith(suffix)&&value);
 if(!tcp&&!web.length&&!funnel)return 'free';
 if(funnel||tcp?.HTTPS!==true||tcp.TCPForward||web.length!==1||web[0][0]!==domain+suffix)return 'conflict';
 const handlers=web[0][1].Handlers||{};
 return Object.keys(handlers).length===1&&handlers['/']?.Proxy===target?'own':'conflict';
}
export async function enableTailscale({port,run=runCommand,binary=tailscaleBinary()}={}) {
 const status=JSON.parse((await run(binary,['status','--json'])).stdout);
 if(status.BackendState!=='Running'||!status.Self?.DNSName)throw new Error('请先安装 Tailscale，并让电脑和手机登录同一个网络');
 const domain=status.Self.DNSName.replace(/\.$/,'');
 const target='http://127.0.0.1:'+port;
 const current=JSON.parse((await run(binary,['serve','status','--json'])).stdout||'{}');
 const httpsPort=[443,8443].find(candidate=>serveState(current,domain,candidate,target)!=='conflict');
 if(!httpsPort)throw new Error('Tailscale 的 443 和 8443 端口均已有其他服务，未覆盖任何配置');
 if(serveState(current,domain,httpsPort,target)==='free')
  await run(binary,['serve','--bg','--https='+httpsPort,target],{timeout:30000});
 const verified=JSON.parse((await run(binary,['serve','status','--json'])).stdout||'{}');
 if(serveState(verified,domain,httpsPort,target)!=='own')throw new Error('Tailscale HTTPS 尚未就绪；请按 Tailscale 提示开启 HTTPS 后重试');
 return 'wss://'+domain+(httpsPort===443?'':':'+httpsPort)+'/ws';
}
