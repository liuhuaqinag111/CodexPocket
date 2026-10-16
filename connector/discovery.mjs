import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
export function runtimeEnvironment(env=process.env) {
 const next={...env},key=Object.keys(next).find(key=>key.toUpperCase()==='PATH');
 const inherited=key?next[key]:'';
 for(const name of Object.keys(next))if(name.toUpperCase()==='PATH')delete next[name];
 next.PATH=[path.dirname(process.execPath),inherited].filter(Boolean).join(path.delimiter);
 return next;
}
export const runCommand=(file,args,options={})=>promisify(execFile)(file,args,
 {encoding:'utf8',windowsHide:true,timeout:15000,maxBuffer:1024*1024,...options,env:runtimeEnvironment(options.env)});
export async function discoverCodex({codexPath,platform=process.platform,env=process.env,
 home=os.homedir(),exists=fs.existsSync,run=runCommand}={}) {
 const explicit=codexPath||env.CODEX_BIN;
 if(explicit){if(exists(explicit))return explicit;throw new Error('找不到指定的 Codex CLI：'+explicit);}
 let candidates=[];
 if(platform==='win32') {
  try{candidates.push(...(await run('where.exe',['codex.exe'])).stdout.trim().split(/\r?\n/));}catch{}
  const base=env.APPDATA||path.win32.join(home,'AppData','Roaming');
  const vendor='vendor/x86_64-pc-windows-msvc/codex/codex.exe';
  for(const module of ['@openai/codex','@openai/codex/node_modules/@openai/codex-win32-x64'])
   candidates.push(path.win32.join(base,'npm/node_modules',module,vendor));
 } else {
  for(const dir of (env.PATH||'').split(path.posix.delimiter))if(dir)candidates.push(path.posix.join(dir,'codex'));
 }
 if(platform==='darwin')candidates.push('/usr/local/bin/codex','/opt/homebrew/bin/codex',path.posix.join(home,'.local','bin','codex'),
  '/Applications/Codex.app/Contents/Resources/codex',
  '/Applications/ChatGPT.app/Contents/Resources/codex',
  '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex',
  '/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex');
 const found=candidates.find(candidate=>candidate&&exists(candidate));
 if(found)return found;
 if(platform==='win32') {
  try {
   const script="Get-AppxPackage -Name '*Codex*' | ForEach-Object { Join-Path $_.InstallLocation 'app\\resources\\codex.exe' }";
   const result=await run('powershell.exe',['-NoProfile','-NonInteractive','-Command',script]);
   const store=result.stdout.trim().split(/\r?\n/).find(candidate=>candidate&&exists(candidate));
   if(store)return store;
  }catch{}
 }
 throw new Error('未找到 Codex CLI；请安装 Codex 桌面版或 CLI，支持现有 CC Switch 配置，也可指定程序路径');
}
export async function probeCodex(binary,{run=runCommand}={}) {
 const version=(await run(binary,['--version'])).stdout.trim();
 const help=(await run(binary,['app-server','--help'])).stdout;
 if(!help.includes('--listen'))throw new Error('Codex CLI 版本过旧，请升级到支持 app-server --listen 的版本');
 return {version,appServerArgs:['app-server','--listen'],
  explicitStdio:help.includes('--stdio'),wsAuth:help.includes('--ws-auth')&&help.includes('--ws-token-file')};
}
