import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
import {discoverCodex,probeCodex,runtimeEnvironment} from './discovery.mjs';
import {saveConfig} from './config.mjs';
import {pairingURL} from './pairing.mjs';
import {enableTailscale} from './tailscale.mjs';

export async function checkPorts(ports) {
 for(const port of ports)await new Promise((resolve,reject)=>{
  const server=net.createServer();
  server.once('error',error=>reject(new Error('本机端口 '+port+' 已被使用，请更换连接端端口：'+error.code)));
  server.listen(port,'127.0.0.1',()=>server.close(resolve));
 });
}
async function waitReady(url,{children,timeout=30000}) {
 const deadline=Date.now()+timeout;
 while(Date.now()<deadline) {
  if(children.some(child=>child.exitCode!==null||child.__failed))throw new Error('Codex 连接端子进程提前退出，请查看日志');
  try {
   const response=await fetch(url,{signal:AbortSignal.timeout(1500)});
   if(response.ok&&(!url.endsWith('/status')||(await response.json()).upstreamReady))return;
  }catch{}
  await delay(150);
 }
 throw new Error('Codex 连接未就绪，请检查当前服务商或 CC Switch 配置及日志');
}
export class ConnectorManager {
 constructor(config,{discover=discoverCodex,probe=probeCodex,spawnProcess=spawn,
  checkPorts:check=checkPorts,wait=waitReady}={}) {
  this.config=config;this.discover=discover;this.probe=probe;this.spawn=spawnProcess;
  this.checkPorts=check;this.wait=wait;this.children=[];this.phase='stopped';this.logs=[];this.error='';
 }
 redact(text){return String(text).replaceAll(this.config.token,'[redacted]').replaceAll(this.config.adminToken,'[redacted]');}
 log(text){this.logs.push(this.redact(text).slice(-2048));if(this.logs.length>80)this.logs.shift();}
 status(){const c=this.config;return {running:this.phase==='running',phase:this.phase,error:this.error,
  endpoint:c.externalURL||null,codex:{path:this.binary||c.codexPath||'',version:this.version||''},
  name:c.name,platform:process.platform,dataDir:c.dataDir,externalURL:c.externalURL,
  bridgePort:c.bridgePort,upstreamPort:c.upstreamPort,codexPath:this.binary||c.codexPath||'',
  codexVersion:this.version||'',logs:this.logs.slice(-10)};}
 start() {
  if(this.starting)return this.starting;
  if(this.phase==='running')return Promise.resolve(this.status());
  this.starting=this.startOwned().finally(()=>{this.starting=null;});
  return this.starting;
 }
 async startOwned() {
  this.phase='starting';this.error='';
  try {
   const c=this.config;
   await this.checkPorts([c.bridgePort,c.upstreamPort]);
   this.binary=await this.discover({codexPath:c.codexPath});
   const capabilities=await this.probe(this.binary);this.version=capabilities.version;
   const args=['app-server','--listen','ws://127.0.0.1:'+c.upstreamPort];
   if(capabilities.wsAuth)args.push('--ws-auth','capability-token','--ws-token-file',c.tokenFile);
   const env={...runtimeEnvironment(),CODEX_PHONE_DIR:c.dataDir,CODEX_BIN:this.binary,
    CODEX_APP_SERVER_STDIO:capabilities.explicitStdio?'explicit':'default',
    BIND:'127.0.0.1',PORT:String(c.bridgePort),UPSTREAM:'ws://127.0.0.1:'+c.upstreamPort,
    IDLE_RESTART_MS:'0',DEPLOYMENT_ID:'portable-connector',
    NOTIFY_CONFIG:path.join(c.dataDir,'notify.json'),CONNECTOR_MANAGED:'1',
    SUBMISSION_DIR:path.join(c.dataDir,'submissions'),UPLOAD_DIR:path.join(c.dataDir,'uploads'),
    IPA_PATH:path.join(c.dataDir,'CodexPocket.ipa'),TOKEN_FILE:c.tokenFile,APP_SCHEME:'codexpocket'};
   delete env.UPSTREAM_PID_FILE;delete env.SUPERVISOR_PID;
   this.launch(this.binary,args,env,'Codex');
   this.launch(process.execPath,[fileURLToPath(new URL('../bridge/bridge.mjs',import.meta.url)),c.tokenFile],env,'Bridge');
   await this.wait('http://127.0.0.1:'+c.bridgePort+'/status',{children:this.children});
   this.phase='running';return this.status();
  }catch(error){this.error=this.redact(error.message);await this.stopOwned();this.phase='failed';throw error;}
 }
 launch(file,args,env,label) {
  const child=this.spawn(file,args,{cwd:os.homedir(),env,windowsHide:true,
   stdio:label==='Bridge'?['ignore','pipe','pipe','ipc']:['ignore','pipe','pipe']});
  this.children.push(child);
  for(const stream of [child.stdout,child.stderr])if(stream) {
   let buffered='';
   stream.setEncoding?.('utf8');
   stream.on('data',data=>{
    buffered+=data;
    let newline;
    while((newline=buffered.indexOf('\n'))!==-1){this.log(label+': '+buffered.slice(0,newline));buffered=buffered.slice(newline+1);}
    if(buffered.length>8192)buffered=buffered.slice(-8192);
   });
   stream.on('end',()=>{if(buffered)this.log(label+': '+buffered);});
  }
  child.once('error',error=>{child.__failed=true;this.error=this.redact(error.message);this.log(this.error);
   if(this.phase==='running')void this.failed(label);});
  child.once('exit',(code,signal)=>{if(this.phase==='running')void this.failed(label+' '+(code??signal));});
  return child;
 }
 async failed(label) {this.error=this.redact(label+' 已退出');this.phase='failed';await this.stopOwned();}
 async stop() {
  if(this.starting)await this.starting.catch(()=>{});
  this.phase='stopping';await this.stopOwned();this.phase='stopped';return this.status();
 }
 async stopOwned() {
  for(const child of this.children.splice(0).reverse()) {
   if(child.exitCode!==null)continue;
   await new Promise(resolve=>{
    const finish=()=>{clearTimeout(timer);resolve();};
    const timer=setTimeout(()=>{try{child.kill('SIGKILL');}catch{}resolve();},5000);
    child.once('exit',finish);child.once('close',finish);
    try {if(child.connected)child.send({command:'shutdown'});else child.kill('SIGTERM');}
    catch{finish();}
   });
  }
 }
 async configure(patch) {
  if(this.phase!=='stopped'&&this.phase!=='failed'&&['codexPath','bridgePort','upstreamPort'].some(key=>key in patch))
   throw new Error('修改程序路径或本机端口前，请先停止连接');
  await saveConfig(this.config,patch);return this.status();
 }
 pair(){const c=this.config;return {uri:pairingURL(c),name:c.name,endpoint:c.externalURL};}
 async enableTailscale() {
  if(this.phase!=='running')throw new Error('请先启动电脑连接');
  const externalURL=await enableTailscale({port:this.config.bridgePort});
  return this.configure({externalURL});
 }
}
