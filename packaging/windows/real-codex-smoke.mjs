// Run with the ZIP's runtime/node.exe; argv: extracted package, evidence JSON.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import {spawn,execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';

const run=promisify(execFile),root=path.resolve(process.argv[2]||'.');
const evidence=process.argv[3]&&path.resolve(process.argv[3]);
const report={versions:{node:process.version,codex:''},ready:false,listCount:null,processes:[]};
let temporary,child,socket,env,pids=[];
const alive=pid=>{try{process.kill(pid,0);return true;}catch{return false;}};
async function port(){
 const server=net.createServer();
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
 const value=server.address().port;await new Promise(resolve=>server.close(resolve));return value;
}
async function processTree(pid){
 const command='Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId | ConvertTo-Json -Compress';
 const {stdout}=await run('powershell.exe',['-NoProfile','-NonInteractive','-Command',command],
  {encoding:'utf8',windowsHide:true,timeout:15000});
 const rows=JSON.parse(stdout),found=new Set([pid]);
 let changed=true;
 while(changed){changed=false;for(const row of rows){
  if(found.has(row.ParentProcessId)&&!found.has(row.ProcessId)){found.add(row.ProcessId);changed=true;}
 }}
 return [...found];
}
async function until(read,timeout=40000){
 const deadline=Date.now()+timeout;
 while(Date.now()<deadline){const result=await read();if(result)return result;await delay(150);}
 throw new Error('Timed out');
}
async function closeSocket(){
 if(!socket)return;
 socket.close();
 try{await until(()=>socket.readyState===3,2000);}catch{socket.terminate();}
 socket=null;
}
let sequence=0;
function call(method,params){
 const id=++sequence;
 return new Promise((resolve,reject)=>{
  const timer=setTimeout(()=>finish(new Error('RPC timeout')),20000);
  function finish(error,result){clearTimeout(timer);socket.off('message',message);socket.off('error',failed);
   error?reject(error):resolve(result);}
  function failed(){finish(new Error('WebSocket failed'));}
  function message(raw){let value;try{value=JSON.parse(String(raw));}catch{return;}
   if(value.id===id)finish(value.error?new Error('RPC failed'):null,value.result);}
  socket.on('message',message);socket.once('error',failed);
  socket.send(JSON.stringify({id,method,params}));
 });
}
async function stop(){
 await closeSocket();
 if(!child)return;
 await run(path.join(root,'runtime','node.exe'),[path.join(root,'app','connector','cli.mjs'),
  'stop','--data-dir',path.join(temporary,'Data')],{env,windowsHide:true,timeout:45000});
 await until(()=>pids.every(pid=>!alive(pid)),10000);
}
async function main(){
 assert.equal(process.platform,'win32');
 assert.equal(path.resolve(process.execPath).toLowerCase(),path.join(root,'runtime','node.exe').toLowerCase());
 temporary=await fs.mkdtemp(path.join(os.tmpdir(),'CodexPocket Real Smoke '));
 const home=path.join(temporary,'Codex Home'),data=path.join(temporary,'Data');
 await fs.mkdir(home);assert.deepEqual(await fs.readdir(home),[]);
 env={...process.env,CODEX_HOME:home,CODEX_POCKET_DATA_DIR:data};
 const discovery=await import(pathToFileURL(path.join(root,'app','connector','discovery.mjs')));
 const binary=await discovery.discoverCodex({env});
 const capabilities=await discovery.probeCodex(binary,{run:(file,args,options)=>
  discovery.runCommand(file,args,{...options,env})});
 report.versions.codex=capabilities.version;
 const bridgePort=await port();let upstreamPort=await port();
 while(upstreamPort===bridgePort)upstreamPort=await port();
 child=spawn(process.execPath,[path.join(root,'app','connector','cli.mjs'),'start',
  '--data-dir',data,'--codex',binary,'--bridge-port',String(bridgePort),
  '--upstream-port',String(upstreamPort)],{env,windowsHide:true,stdio:'ignore'});
 pids=[child.pid];child.on('error',()=>{});
 await until(async()=>{
  assert.equal(child.exitCode,null);
  try{
   const control=JSON.parse(await fs.readFile(path.join(data,'control.json'),'utf8'));
   const admin=(await fs.readFile(path.join(data,'connector-admin-token'),'utf8')).trim();
   const response=await fetch('http://127.0.0.1:'+control.port+'/api/status',{
    headers:{authorization:'Bearer '+admin},signal:AbortSignal.timeout(1500)});
   if(!response.ok)return false;
   const status=await response.json();return status.running;
  }catch{return false;}
 });
 const response=await fetch('http://127.0.0.1:'+bridgePort+'/status',
  {signal:AbortSignal.timeout(3000)});
 const status=await response.json();
 assert.equal(status.upstreamReady,true);assert.equal(status.writerWorkers,0);
 report.ready=true;pids=await processTree(child.pid);assert.ok(pids.length>=3);
 const require=createRequire(path.join(root,'app','package.json')),WebSocket=require('ws');
 const token=(await fs.readFile(path.join(data,'connector-token'),'utf8')).trim();
 socket=new WebSocket('ws://127.0.0.1:'+bridgePort+'/ws',{headers:{Authorization:'Bearer '+token}});
 socket.on('error',()=>{});
 await until(()=>{if(socket.readyState===3)throw new Error('WebSocket closed');return socket.readyState===1;},10000);
 await call('initialize',{clientInfo:{name:'codexpocket-real-smoke',version:'1.0.0'}});
 const listed=await call('thread/list',{limit:100,sortDirection:'desc',modelProviders:[]});
 assert.ok(Array.isArray(listed.data));report.listCount=listed.data.length;
 assert.equal(report.listCount,0);assert.equal(listed.nextCursor??null,null);
 await stop();
}
try{await main();}catch{process.exitCode=1;}
finally{
 await closeSocket();
 if(child){
  if(alive(child.pid)){
   try{pids=[...new Set([...pids,...await processTree(child.pid)])];}catch{}
   try{await stop();}catch{}
  }
  for(const pid of pids.filter(alive).reverse())
   await run('taskkill.exe',['/PID',String(pid),'/T','/F'],
    {windowsHide:true,timeout:15000}).catch(()=>{});
  try{await until(()=>pids.every(pid=>!alive(pid)),5000);}catch{process.exitCode=1;}
 }
 report.processes=pids.map(pid=>({pid,alive:alive(pid)}));
 if(report.processes.some(row=>row.alive))process.exitCode=1;
 if(temporary)await fs.rm(temporary,{recursive:true,force:true,maxRetries:3,retryDelay:200});
 const output=JSON.stringify(report,null,2)+'\n';
 if(evidence){await fs.mkdir(path.dirname(evidence),{recursive:true});await fs.writeFile(evidence,output);}
 process.stdout.write(output);
}
