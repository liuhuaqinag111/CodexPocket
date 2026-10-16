#!/usr/bin/env node
import fs from 'node:fs/promises';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {loadConfig,saveConfig} from './config.mjs';
import {discoverCodex,probeCodex} from './discovery.mjs';
import {ConnectorManager} from './processes.mjs';
import {startControlServer} from './control.mjs';
const args=process.argv.slice(2),command=args.shift()||'start';
const values={},flags=new Set();
const keys={'--data-dir':'dataDir','--external-url':'externalURL','--codex':'codexPath',
 '--bridge-port':'bridgePort','--upstream-port':'upstreamPort','--name':'name'};
function print(value){console.log(JSON.stringify(value,null,2));}
function openDashboard(url) {
 let child;
 if(process.platform==='win32')child=spawn('rundll32.exe',['url.dll,FileProtocolHandler',url],{detached:true,stdio:'ignore',windowsHide:true});
 else child=spawn(process.platform==='darwin'?'open':'xdg-open',[url],{detached:true,stdio:'ignore'});
 child.on('error',()=>console.error('浏览器未能自动打开，请运行 npm run dashboard'));
 child.unref();
}
async function activeControl(config) {
 try {
  const runtime=JSON.parse(await fs.readFile(path.join(config.dataDir,'control.json'),'utf8'));
  if(!Number.isInteger(runtime.port)||runtime.port<1||runtime.port>65535)return null;
  const base='http://127.0.0.1:'+runtime.port;
  const response=await fetch(base+'/api/status',{headers:{authorization:'Bearer '+config.adminToken},signal:AbortSignal.timeout(2000)});
  if(!response.ok)return null;
  return {base,status:await response.json()};
 }catch{return null;}
}
async function call(control,config,route,body={}) {
 const response=await fetch(control.base+route,{method:route==='/api/pair'?'GET':'POST',
  headers:{authorization:'Bearer '+config.adminToken,'content-type':'application/json'},
  body:route==='/api/pair'?undefined:JSON.stringify(body),signal:AbortSignal.timeout(40000)});
 const result=await response.json();if(!response.ok)throw new Error(result.error);return result;
}
async function acquireLock(config) {
 const file=path.join(config.dataDir,'connector.lock');
 try {await fs.writeFile(file,JSON.stringify({pid:process.pid}),{flag:'wx',mode:0o600});}
 catch(error) {
  if(error.code!=='EEXIST')throw error;
  const previous=JSON.parse(await fs.readFile(file,'utf8'));
  try{process.kill(previous.pid,0);}catch(failure){
   if(failure.code==='ESRCH'){await fs.unlink(file);return acquireLock(config);}throw failure;
  }
  throw new Error('另一个电脑连接端正在启动或运行，请勿重复启动');
 }
 return ()=>fs.unlink(file).catch(()=>{});
}
async function main() {
 if(!['init','doctor','start','status','stop','pair','tailscale','dashboard','help'].includes(command))throw new Error('未知命令：'+command);
 for(let n=0;n<args.length;n++) {
  const arg=args[n];
  if(arg==='--open'){flags.add(arg);continue;}
  if(!keys[arg]||args[n+1]===undefined)throw new Error('未知或缺少参数：'+arg);
  values[keys[arg]]=arg.endsWith('-port')?Number(args[++n]):args[++n];
 }
 if(command==='help')return console.log('CodexPocket Connector: init | doctor | start [--open] | status | stop | pair | tailscale | dashboard\n配置：--data-dir PATH --external-url https://自己的域名 --codex PATH --name NAME --bridge-port PORT --upstream-port PORT');
 const config=await loadConfig({dataDir:values.dataDir});
 const patch={...values};delete patch.dataDir;
 const control=await activeControl(config);
 if(Object.keys(patch).length) {
  if(control){control.status=await call(control,config,'/api/config',patch);Object.assign(config,await loadConfig({dataDir:config.dataDir}));}
  else await saveConfig(config,patch);
 }
 const manager=new ConnectorManager(config);
 if(command==='init')return print(manager.status());
 if(command==='doctor') {
  const binary=await discoverCodex({codexPath:config.codexPath});
  return print({...manager.status(),node:process.version,codex:{path:binary,...await probeCodex(binary)}});
 }
 if(command==='status')return print(control?.status||manager.status());
 if(command==='pair')return print(control?await call(control,config,'/api/pair'):manager.pair());
 if(command==='stop')return print(control?await call(control,config,'/api/shutdown'):manager.status());
 if(command==='tailscale') {
  if(!control)throw new Error('请先运行 start 启动电脑连接端');
  return print(await call(control,config,'/api/tailscale'));
 }
 if(command==='dashboard'||control) {
  if(!control)throw new Error('请先运行 start 启动电脑连接端');
  if(command==='dashboard'||flags.has('--open'))openDashboard(control.base+'/#'+config.adminToken);
  return print(control.status);
 }
 const release=await acquireLock(config);
 let server,closing=false;
 const cleanup=async()=>{
  if(closing)return;closing=true;
  await manager.stop();if(server)await new Promise(resolve=>server.close(resolve));
  await fs.unlink(path.join(config.dataDir,'control.json')).catch(()=>{});await release();
 };
 process.once('SIGINT',()=>void cleanup());process.once('SIGTERM',()=>void cleanup());
 try {
  server=await startControlServer({manager,adminToken:config.adminToken});
  const port=server.address().port;
  await fs.writeFile(path.join(config.dataDir,'control.json'),JSON.stringify({pid:process.pid,port}),{mode:0o600});
  server.once('close',()=>{void cleanup();});
  if(flags.has('--open'))openDashboard('http://127.0.0.1:'+port+'/#'+config.adminToken);
  console.log('电脑连接端控制面板：http://127.0.0.1:'+port+' （运行 dashboard 打开）');
  try {print(await manager.start());}catch(error){console.error(manager.redact(error.message));}
 }catch(error){await cleanup();throw error;}
}
main().catch(error=>{console.error(error.message);process.exitCode=1;});
