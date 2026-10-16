import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import http from 'node:http';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {createRequire} from 'node:module';
import {DatabaseSync} from 'node:sqlite';
const require=createRequire(import.meta.url);
let wsPath;
try {wsPath=require.resolve('ws');}
catch {wsPath=require.resolve(path.join(os.homedir(),'.codex/phone/node_modules/ws'));}
const {WebSocket,WebSocketServer}=require(wsPath);
const pause=ms=>new Promise(r=>setTimeout(r,ms));
async function until(fn){
 for(let n=0;n<500;n++){if(fn())return;await pause(20);}
 assert.fail('timed out waiting for bridge fixture');
}
async function fixture(t,{holdInitialize=false,nodeArgs=[],notify=false,extraEnv={},globalState}={}){
 const tmp=await fs.mkdtemp(path.join(os.tmpdir(),'pocket-bridge-'));
 const globalStateFile=path.join(tmp,'.codex/.codex-global-state.json');
 if(globalState!==undefined){
  await fs.mkdir(path.dirname(globalStateFile),{recursive:true});
  await fs.writeFile(globalStateFile,JSON.stringify(globalState));
 }
 const upstream=new WebSocketServer({port:0,host:'127.0.0.1'});
 await once(upstream,'listening');
 const listener=net.createServer();listener.listen(0,'127.0.0.1');await once(listener,'listening');
 const port=listener.address().port;await new Promise(r=>listener.close(r));
 const received=[],responses=[],handshakes=[];let peer;let log='';
 upstream.on('connection',socket=>{peer=socket;socket.on('message',raw=>{
  const m=JSON.parse(raw);if(m.method==='initialize'){
   handshakes.push(m);if(holdInitialize)return;
  }
  if(m.method==='initialized')return;
  if(m.method==='initialize'||String(m.id).startsWith('up-hb-')){
   socket.send(JSON.stringify({id:m.id,result:{}}));return;
  }
  if(String(m.id).startsWith('list-bg-')){
   socket.send(JSON.stringify({id:m.id,result:{data:[],nextCursor:null}}));return;
  }
  if(m.method)received.push(m);else if(m.id!==undefined)responses.push(m);
 });});
 for(const name of await fs.readdir(new URL('./',import.meta.url)))if(name.endsWith('.mjs')){
  await fs.copyFile(new URL(name,import.meta.url),path.join(tmp,name));
 }
 await fs.mkdir(path.join(tmp,'node_modules'));
 await fs.symlink(path.dirname(wsPath),path.join(tmp,'node_modules/ws'));
 await fs.writeFile(path.join(tmp,'token'),'fixture-token');
 const notifications=[];
 const webhook=http.createServer((req,res)=>{
  const chunks=[];req.on('data',chunk=>chunks.push(chunk));
  req.on('end',()=>{notifications.push(JSON.parse(Buffer.concat(chunks)));res.writeHead(200).end('ok');});
 });
 webhook.listen(0,'127.0.0.1');await once(webhook,'listening');
 const notifyConfig=path.join(tmp,'notify.json');
 await fs.writeFile(notifyConfig,JSON.stringify(notify?{webhook:'http://127.0.0.1:'+webhook.address().port}:{}));
 await fs.writeFile(path.join(tmp,'worker'),'#!/usr/bin/env node\n'+
  'require("node:readline").createInterface({input:process.stdin}).on("line",raw=>{'+
  'const m=JSON.parse(raw);if(m.id===undefined)return;'+
  'if(process.env.HOLD_WORKER==="1"&&m.method==="thread/resume")return;'+
  'if(process.env.ACTIVE_WORKER==="1"&&m.method==="thread/resume"){'+
  'console.log(JSON.stringify({id:m.id,result:{thread:{id:m.params.threadId,status:{type:"active"}}}}));'+
  'console.log(JSON.stringify({method:"turn/started",params:{threadId:m.params.threadId,turn:{id:"active-turn"}}}));return;}'+
  'if(process.env.ACTIVE_WORKER==="1"&&["thread/loaded/list","thread/read","thread/turns/list"].includes(m.method)){'+
  'const result=m.method==="thread/read"?{thread:{id:"t",status:{type:"active"}}}:m.method==="thread/turns/list"?{data:[{id:"active-turn",status:"inProgress"}]}:{data:["t"]};'+
  'console.log(JSON.stringify({id:m.id,result}));return;}'+
  'const result=m.method==="thread/start"?{thread:{id:"fake-created"}}:{data:[]};'+
  'console.log(JSON.stringify({id:m.id,result}));});\n',{mode:0o755});
 const child=spawn(process.execPath,[...nodeArgs,path.join(tmp,'bridge.mjs'),path.join(tmp,'token')],{
  env:{...process.env,HOME:tmp,CODEX_HOME:path.join(tmp,'.codex'),CODEX_PHONE_DIR:tmp,SUBMISSION_DIR:path.join(tmp,'submissions'),CC_SWITCH_DB:path.join(tmp,'no-cc-switch.db'),NOTIFY_CONFIG:notifyConfig,CODEX_BIN:path.join(tmp,'worker'),PORT:String(port),BIND:'127.0.0.1',
   UPSTREAM:'ws://127.0.0.1:'+upstream.address().port,IDLE_RESTART_MS:'0',...extraEnv},stdio:['ignore','pipe','pipe']});
 child.stdout.on('data',d=>log+=d);child.stderr.on('data',d=>log+=d);
 const clients=[];
 t.after(async()=>{
  for(const c of clients)c.socket.terminate();
  child.kill('SIGTERM');await once(child,'exit').catch(()=>{});
  for(const c of upstream.clients)c.terminate();
  await new Promise(r=>upstream.close(r));
  await new Promise(r=>webhook.close(r));
 });
 await until(()=>log.includes('bridge http://')&&peer);
 async function client(){
  const socket=new WebSocket('ws://127.0.0.1:'+port+'/ws?t=fixture-token');
  const messages=[];socket.on('message',d=>messages.push(JSON.parse(d)));
  await once(socket,'open');
  const c={socket,messages,send:m=>socket.send(JSON.stringify(m))};clients.push(c);return c;
 }
 return {client,received,responses,handshakes,notifications,globalStateFile,base:'http://127.0.0.1:'+port,
  disconnectUpstream:()=>peer.terminate(),reply:m=>peer.send(JSON.stringify(m)),
  notify:m=>peer.send(JSON.stringify(m))};
}

test('provider catalog RPC falls back cleanly without CC Switch',async t=>{
 const f=await fixture(t,{extraEnv:{CC_SWITCH_DB:'/tmp/pocket-no-database'}}),a=await f.client();
 a.send({id:98,method:'bridge/provider/models',params:{}});
 await until(()=>a.messages.some(m=>m.id===98)||f.received.some(m=>m.method==='bridge/provider/models'));
 assert.equal(f.received.some(m=>m.method==='bridge/provider/models'),false);
 assert.equal(a.messages.find(m=>m.id===98).result.available,false);
});

test('provider catalog RPC returns all models from selected provider only',async t=>{
 const tmp=await fs.mkdtemp(path.join(os.tmpdir(),'pocket-provider-rpc-'));
 const api=http.createServer((req,res)=>res.writeHead(200,{'content-type':'application/json'})
  .end(JSON.stringify({data:[{id:'model-a'},{id:'model-b'},{id:'model-c'}]})));
 api.listen(0,'127.0.0.1');await once(api,'listening');
 const dbPath=path.join(tmp,'cc.db'),db=new DatabaseSync(dbPath);
 db.exec('CREATE TABLE providers(id TEXT,name TEXT,app_type TEXT,is_current INTEGER,settings_config TEXT)');
 const config='model="model-b"\nmodel_provider="custom"\n[model_providers.custom]\nbase_url="http://127.0.0.1:'+api.address().port+'/v1"';
 db.prepare('INSERT INTO providers VALUES(?,?,?,?,?)').run('current','Provider','codex',1,JSON.stringify({config}));
 db.close();t.after(async()=>{api.close();await fs.rm(tmp,{recursive:true,force:true});});
 const f=await fixture(t,{extraEnv:{CC_SWITCH_DB:dbPath}}),a=await f.client();
 a.send({id:99,method:'bridge/provider/models',params:{}});
 await until(()=>a.messages.some(m=>m.id===99));
 assert.deepEqual(a.messages.find(m=>m.id===99).result.models.map(m=>m.id),['model-a','model-b','model-c']);
});

test('shared upstream isolates equal request IDs from two clients',async t=>{
 const f=await fixture(t),a=await f.client(),b=await f.client();
 a.send({id:7,method:'config/read',params:{tag:'a'}});
 b.send({id:7,method:'config/read',params:{tag:'b'}});
 await until(()=>f.received.length===2);
 assert.notEqual(f.received[0].id,f.received[1].id);
 for(const req of f.received.toReversed())f.reply({id:req.id,result:{tag:req.params.tag}});
 await until(()=>a.messages.some(m=>m.id===7)&&b.messages.some(m=>m.id===7));
 assert.deepEqual(a.messages.filter(m=>m.id===7),[{id:7,result:{tag:'a'}}]);
 assert.deepEqual(b.messages.filter(m=>m.id===7),[{id:7,result:{tag:'b'}}]);
});

test('release-writers reports busy instead of claiming locks were released',async t=>{
 const f=await fixture(t,{extraEnv:{HOLD_WORKER:'1',WRITER_RELEASE_MS:'60000',IDLE_RESTART_MS:'0'}}),a=await f.client();
 a.send({id:42,method:'thread/resume',params:{threadId:'busy'}});
 for(let n=0;n<100;n++){
  if((await (await fetch(f.base+'/status')).json()).writerWorkers===1)break;
  await pause(20);
 }
 const response=await fetch(f.base+'/release-writers',{headers:{Authorization:'Bearer fixture-token'}});
 assert.equal(response.status,200);
 assert.deepEqual(await response.json(),{released:false,writerWorkers:1,reason:'busy-or-unverified'});
});

test('release-writers preserves active workers without restarting the upstream',async t=>{
 const f=await fixture(t,{extraEnv:{ACTIVE_WORKER:'1',WRITER_RELEASE_MS:'60000'}}),a=await f.client();
 a.send({id:43,method:'thread/resume',params:{threadId:'t'}});
 await until(()=>a.messages.some(m=>m.id===43));
 const response=await fetch(f.base+'/release-writers',{headers:{Authorization:'Bearer fixture-token'}});
 assert.deepEqual(await response.json(),{released:false,writerWorkers:1,reason:'active-turn'});
 assert.equal((await (await fetch(f.base+'/status')).json()).upstreamReady,true);
 assert.equal(f.handshakes.length,1);
});

test('release-writers confirms success only after the last idle worker exits',async t=>{
 const f=await fixture(t,{extraEnv:{WRITER_RELEASE_MS:'60000'}}),a=await f.client();
 a.send({id:44,method:'thread/resume',params:{threadId:'t'}});
 await until(()=>a.messages.some(m=>m.id===44));
 const response=await fetch(f.base+'/release-writers',{headers:{Authorization:'Bearer fixture-token'}});
 assert.deepEqual(await response.json(),{released:true,writerWorkers:0,reason:''});
 assert.equal((await (await fetch(f.base+'/status')).json()).upstreamReady,true);
 assert.equal(f.handshakes.length,1);
});

test('online quiet clients release idle writer workers without restarting upstream',async t=>{
 const f=await fixture(t,{extraEnv:{WRITER_RELEASE_MS:'60',IDLE_RESTART_MS:'0'}}),a=await f.client();
 a.send({id:40,method:'thread/resume',params:{threadId:'t'}});
 await until(()=>a.messages.some(m=>m.id===40));
 let status;
 for(let i=0;i<12;i++){
  status=await (await fetch(f.base+'/status')).json();
  if(status.writerWorkers===0)break;
  await pause(30);
 }
 assert.equal(status.writerWorkers,0);
 assert.equal(status.upstreamReady,true);
});

test('online active turns keep writer workers and upstream alive',async t=>{
 const f=await fixture(t,{extraEnv:{WRITER_RELEASE_MS:'500',IDLE_RESTART_MS:'0'}}),a=await f.client();
 a.send({id:41,method:'thread/resume',params:{threadId:'t'}});
 await until(()=>a.messages.some(m=>m.id===41));
 f.notify({method:'turn/started',params:{threadId:'t',turn:{id:'turn-active'}}});
 await pause(220);
 const status=await (await fetch(f.base+'/status')).json();
 assert.equal(status.writerWorkers,1);
 assert.equal(status.upstreamReady,true);
});

test('list cache hits reply only to the requesting connection',async t=>{
 const f=await fixture(t),a=await f.client(),b=await f.client();
 const params={limit:7};
 a.send({id:1,method:'thread/list',params});
 await until(()=>f.received.length===1);
 f.reply({id:f.received[0].id,result:{data:[{id:'visible'}],nextCursor:null}});
 await until(()=>a.messages.some(m=>m.id===1));
 b.send({id:2,method:'thread/list',params});
 await until(()=>b.messages.some(m=>m.id===2));
 assert.equal(a.messages.filter(m=>m.id===2).length,0);
 assert.equal(b.messages.filter(m=>m.id===1).length,0);
 assert.equal(f.received.length,1);
 f.reply({method:'thread/name/updated',params:{threadId:'visible',name:'renamed'}});
 await until(()=>a.messages.some(m=>m.method==='thread/name/updated')&&b.messages.some(m=>m.method==='thread/name/updated'));
});

test('late response after reconnect cannot satisfy a reused client id',async t=>{
 const f=await fixture(t),a=await f.client();
 a.send({id:9,method:'config/read'});await until(()=>f.received.length===1);
 a.socket.close();await once(a.socket,'close');
 const b=await f.client();b.send({id:9,method:'config/read'});
 await until(()=>f.received.length===2);
 f.reply({id:f.received[0].id,result:{old:true}});
 f.reply({id:f.received[1].id,result:{fresh:true}});
 await until(()=>b.messages.some(m=>m.id===9));
 assert.deepEqual(b.messages.filter(m=>m.id===9),[{id:9,result:{fresh:true}}]);
});

test('desktop projectless marks null rows without changing legacy directory projects',async t=>{
 const f=await fixture(t,{globalState:{'projectless-thread-ids':['unfiled']}}),a=await f.client();
 a.send({id:1,method:'thread/list',params:{limit:7,archived:true}});
 await until(()=>f.received.length===1);
 const rows=[{id:'unfiled',cwd:'/repo',projectId:null,archived:true},
  {id:'legacy',cwd:'/repo',projectId:null,archived:true}];
 f.reply({id:f.received[0].id,result:{data:rows,nextCursor:null}});
 await until(()=>a.messages.some(m=>m.id===1));
 const result=a.messages.find(m=>m.id===1).result;
 assert.equal(result.data[0].desktopProjectless,true);
 assert.equal(result.data[1].desktopProjectless,false);
 assert.deepEqual(result.data.map(({desktopProjectless,...row})=>row),rows);
 assert.equal(result.nextCursor,null);
});

test('cached lists re-read desktop projectless state without overwriting desktop changes',async t=>{
 const f=await fixture(t,{globalState:{'projectless-thread-ids':[],unrelated:1}}),a=await f.client();
 a.send({id:1,method:'thread/list',params:{limit:7}});
 await until(()=>f.received.length===1);
 f.reply({id:f.received[0].id,result:{data:[{id:'row',projectId:null}]}});
 await until(()=>a.messages.some(m=>m.id===1));
 const changed={'projectless-thread-ids':['row'],unrelated:2};
 await fs.writeFile(f.globalStateFile,JSON.stringify(changed));
 a.send({id:2,method:'thread/list',params:{limit:7}});
 await until(()=>a.messages.some(m=>m.id===2));
 assert.equal(a.messages.find(m=>m.id===2).result.data[0].desktopProjectless,true);
 assert.equal(f.received.length,1);
 assert.deepEqual(JSON.parse(await fs.readFile(f.globalStateFile,'utf8')),changed);
 await fs.writeFile(f.globalStateFile,JSON.stringify({'projectless-thread-ids':[]}));
 a.send({id:3,method:'thread/list',params:{limit:7}});
 await until(()=>a.messages.some(m=>m.id===3));
 assert.equal(a.messages.find(m=>m.id===3).result.data[0].desktopProjectless,false);
 assert.equal(f.received.length,1);
});

test('desktop projectless is included in shared reads and writer-created thread responses',async t=>{
 const f=await fixture(t,{globalState:{'projectless-thread-ids':['row','fake-created']}}),a=await f.client();
 a.send({id:1,method:'thread/read',params:{threadId:'row'}});
 await until(()=>f.received.length===1);
 f.reply({id:f.received[0].id,result:{thread:{id:'row',projectId:null}}});
 a.send({id:2,method:'thread/start',params:{}});
 await until(()=>a.messages.some(m=>m.id===1)&&a.messages.some(m=>m.id===2));
 assert.equal(a.messages.find(m=>m.id===1).result.thread.desktopProjectless,true);
 assert.equal(a.messages.find(m=>m.id===2).result.thread.desktopProjectless,true);
});

test('empty list retries stay associated with the requesting client',async t=>{
 const f=await fixture(t),a=await f.client(),b=await f.client();
 a.send({id:3,method:'thread/list',params:{limit:8}});
 b.send({id:3,method:'config/read'});await until(()=>f.received.length===2);
 const list=f.received.find(m=>m.method==='thread/list'),config=f.received.find(m=>m.method==='config/read');
 f.reply({id:list.id,result:{data:[]}});f.reply({id:config.id,result:{model:'b'}});
 await until(()=>f.received.length===3);
 assert.equal(f.received[2].id,list.id);
 f.reply({id:list.id,result:{data:[{id:'a'}]}});
 await until(()=>a.messages.some(m=>m.id===3));
 assert.deepEqual(b.messages.filter(m=>m.id===3),[{id:3,result:{model:'b'}}]);
 assert.equal(a.messages.find(m=>m.id===3).result.data[0].id,'a');
});

test('upstream mutation completion invalidates lists filled during the mutation',async t=>{
 const f=await fixture(t),a=await f.client();
 a.send({id:1,method:'thread/archive',params:{threadId:'old'}});
 a.send({id:2,method:'thread/list',params:{limit:6}});
 await until(()=>f.received.length===2);
 const mutation=f.received.find(m=>m.method==='thread/archive');
 const list=f.received.find(m=>m.method==='thread/list');
 f.reply({id:list.id,result:{data:[{id:'old'}]}});
 await until(()=>a.messages.some(m=>m.id===2));
 f.reply({id:mutation.id,result:{}});await until(()=>a.messages.some(m=>m.id===1));
 a.send({id:3,method:'thread/list',params:{limit:6}});
 await until(()=>f.received.length===3);
 f.reply({id:f.received[2].id,result:{data:[{id:'new'}]}});
 await until(()=>a.messages.some(m=>m.id===3));
 assert.equal(a.messages.find(m=>m.id===3).result.data[0].id,'new');
});

test('writer mutations invalidate the list cache too',async t=>{
 const f=await fixture(t),a=await f.client();
 a.send({id:1,method:'thread/list',params:{limit:6}});
 await until(()=>f.received.length===1);
 f.reply({id:f.received[0].id,result:{data:[{id:'old'}]}});
 await until(()=>a.messages.some(m=>m.id===1));
 a.send({id:2,method:'thread/start',params:{}});
 await until(()=>a.messages.some(m=>m.id===2));
 a.send({id:3,method:'thread/list',params:{limit:6}});
 await until(()=>f.received.length===2);
});

test('client request waits until upstream initialize is acknowledged',async t=>{
 const f=await fixture(t,{holdInitialize:true}),a=await f.client();
 a.send({id:4,method:'config/read',params:{}});
 await pause(80);
 assert.equal(f.received.length,0);
 assert.equal(a.messages.some(m=>m.id===4),false);
 f.reply({id:'up-init',result:{}});
 await until(()=>f.received.some(m=>m.method==='config/read'));
});

test('oversized upload returns 413 without destroying the HTTP connection',async t=>{
 const f=await fixture(t),payload=Buffer.alloc(24*1024*1024+1,1);
 const response=await fetch(f.base+'/upload?name=large.jpg',
   {method:'POST',headers:{Authorization:'Bearer fixture-token'},body:payload});
 assert.equal(response.status,413);
 assert.match(await response.text(),/too large/i);
});

test('upload names remain unique for same-millisecond requests',async t=>{
 const clock='data:text/javascript,'+encodeURIComponent('Date.now=()=>1760000000000;');
 const f=await fixture(t,{nodeArgs:['--import',clock]}),body=Buffer.from('x');
 const responses=await Promise.all([1,2,3].map(()=>fetch(f.base+'/upload?name=same.jpg',
   {method:'POST',headers:{Authorization:'Bearer fixture-token'},body})));
 assert.deepEqual(responses.map(r=>r.status),[200,200,200]);
 const paths=await Promise.all(responses.map(r=>r.json().then(v=>v.path)));
 assert.equal(new Set(paths).size,3);
 await Promise.all(paths.map(p=>fs.rm(p)));
});

test('oversized frame log returns 413 instead of blocking the bridge',async t=>{
 const f=await fixture(t),payload=Buffer.alloc(8*1024*1024+1,1);
 const response=await fetch(f.base+'/framelog',
   {method:'POST',headers:{Authorization:'Bearer fixture-token'},body:payload});
 assert.equal(response.status,413);
 assert.match(await response.text(),/frame log too large/i);
});

test('upstream disconnect rejects in-flight RPC instead of replaying a mutation',async t=>{
 const f=await fixture(t),a=await f.client();
 a.send({id:11,method:'thread/archive',params:{threadId:'a'}});
 await until(()=>f.received.length===1);
 f.disconnectUpstream();
 await pause(100);
 const reply=a.messages.find(m=>m.id===11);
 assert.ok(reply?.error,'disconnect must explicitly settle the client request');
 await pause(1200);
 assert.equal(f.received.filter(m=>m.method==='thread/archive').length,1);
});

test('same thread submission id is dispatched once and both callers receive one ACK',async t=>{
 const f=await fixture(t),a=await f.client(),b=await f.client();
 const params={threadId:'t',clientUserMessageId:'local-same',input:[{type:'text',text:'x'}]};
 a.send({id:21,method:'thread/queue/add',params});
 b.send({id:22,method:'thread/queue/add',params});
 await until(()=>f.received.filter(m=>m.method==='thread/queue/add').length===1);
 const queued=f.received.find(m=>m.method==='thread/queue/add');
 f.reply({id:queued.id,result:{queued:{id:'q'}}});
 await until(()=>a.messages.some(m=>m.id===21)&&b.messages.some(m=>m.id===22));
 assert.equal(a.messages.filter(m=>m.id===21).length,1);
 assert.equal(b.messages.filter(m=>m.id===22).length,1);
});

test('notLoaded status does not begin completion notification lookups',async t=>{
 const f=await fixture(t,{notify:true});
 f.notify({method:'thread/status/changed',params:{threadId:'t',status:{type:'active'}}});
 f.notify({method:'thread/status/changed',params:{threadId:'t',status:{type:'notLoaded'}}});
 await pause(80);
 assert.equal(f.received.filter(m=>m.method==='thread/turns/list').length,0);
});

test('concurrent completed turns in one thread use different reply lookup ids',async t=>{
 const f=await fixture(t,{notify:true});
 for(const id of ['turn-a','turn-b'])f.notify({method:'turn/completed',params:{threadId:'t',turn:{id}}});
 await until(()=>f.received.filter(m=>m.method==='thread/turns/list').length===2);
 const reads=f.received.filter(m=>m.method==='thread/turns/list');
 assert.notEqual(reads[0].id,reads[1].id);
});

test('a malformed RPC is rejected without killing the async websocket handler',async t=>{
 const f=await fixture(t),a=await f.client();
 a.send({id:30,method:'config/read',params:null});
 await until(()=>a.messages.some(m=>m.id===30));
 assert.ok(a.messages.find(m=>m.id===30).error);
 a.send({id:31,method:'config/read',params:{}});
 await until(()=>f.received.some(m=>m.method==='config/read'));
 const request=f.received.find(m=>m.method==='config/read');
 f.reply({id:request.id,result:{okay:true}});
 await until(()=>a.messages.some(m=>m.id===31));
 assert.deepEqual(a.messages.find(m=>m.id===31).result,{okay:true});
});

test('two clients can answer an approval only once on its original socket',async t=>{
 const f=await fixture(t),a=await f.client(),b=await f.client();
 f.notify({id:77,method:'item/commandExecution/requestApproval',params:{threadId:'t',command:'echo hi'}});
 await until(()=>a.messages.some(m=>m.method==='item/commandExecution/requestApproval'));
 const request=a.messages.find(m=>m.method==='item/commandExecution/requestApproval');
 a.send({id:request.id,result:{decision:'accept'}});
 await until(()=>f.responses.some(m=>m.id===77));
 assert.equal(f.responses.filter(m=>m.id===77).length,1);
 b.send({id:request.id,result:{decision:'decline'}});
 await pause(80);
 assert.equal(f.responses.filter(m=>m.id===77).length,1);
});

test('reconnected client receives approval raised while it was offline',async t=>{
 const f=await fixture(t),a=await f.client();
 a.socket.close();await once(a.socket,'close');
 f.notify({id:88,method:'item/commandExecution/requestApproval',params:{threadId:'t'}});
 const b=await f.client();
 await pause(100);
 const request=b.messages.find(m=>m.method==='item/commandExecution/requestApproval');
 assert.ok(request,'pending approval must survive a phone disconnect');
 b.send({id:request.id,result:{decision:'decline'}});
 await until(()=>f.responses.some(m=>m.id===88));
 const c=await f.client();await pause(50);
 assert.equal(c.messages.some(m=>m.method==='item/commandExecution/requestApproval'),false);
});

test('fs/readFile rejects text over 2 MiB before upstream dispatch',async t=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'pocket-file-limit-'));
 t.after(()=>fs.rm(dir,{recursive:true,force:true}));
 const large=path.join(dir,'large.txt'),small=path.join(dir,'small.txt');
 await fs.writeFile(large,Buffer.alloc(2*1024*1024+1));await fs.writeFile(small,'ok');
 const f=await fixture(t),a=await f.client();
 a.send({id:91,method:'fs/readFile',params:{path:large}});
 await pause(100);
 assert.equal(a.messages.find(m=>m.id===91)?.error?.code,-32094);
 assert.equal(f.received.some(m=>m.method==='fs/readFile'),false);
 a.send({id:92,method:'fs/readFile',params:{path:small}});
 await until(()=>f.received.some(m=>m.method==='fs/readFile'));
 assert.equal(f.received.find(m=>m.method==='fs/readFile').params.path,small);
});

test('release refuses an upstream RPC still in flight',async t=>{
 const guard='data:text/javascript,'+encodeURIComponent(
  'import c from "node:child_process";import{syncBuiltinESMExports}from"node:module";'+
  'c.execFile=(file,args,done)=>done?.(null,"");syncBuiltinESMExports();');
 const f=await fixture(t,{nodeArgs:['--import',guard]}),a=await f.client();
 a.send({id:93,method:'thread/archive',params:{threadId:'t'}});
 await until(()=>f.received.length===1);
 const response=await fetch(f.base+'/release',{headers:{Authorization:'Bearer fixture-token'}});
 assert.equal((await response.json()).released,false);
});

test('late completion of previous turn does not mark the newer turn idle',async t=>{
 const f=await fixture(t),a=await f.client();
 f.notify({method:'turn/started',params:{threadId:'t',turn:{id:'new'}}});
 f.notify({method:'turn/completed',params:{threadId:'t',turn:{id:'old'}}});
 await until(()=>a.messages.some(m=>m.method==='turn/completed'));
 const request=fetch(f.base+'/release',{headers:{Authorization:'Bearer fixture-token'}});
 await pause(50);
 for(const m of f.received)if(m.method==='thread/loaded/list')f.reply({id:m.id,result:{data:[]}});
 const response=await request;
 assert.equal((await response.json()).activeTurns,1);
});

test('maintenance refuses a PID owned by another supervisor',async t=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'pocket-owner-'));
 t.after(()=>fs.rm(dir,{recursive:true,force:true}));
 const pidFile=path.join(dir,'pid');await fs.writeFile(pidFile,String(process.pid));
 const f=await fixture(t,{extraEnv:{UPSTREAM_PID_FILE:pidFile,SUPERVISOR_PID:'1'}});
 const request=fetch(f.base+'/maintenance',{headers:{Authorization:'Bearer fixture-token'}});
 await until(()=>f.received.some(m=>m.method==='thread/loaded/list'));
 const m=f.received.find(m=>m.method==='thread/loaded/list');
 f.reply({id:m.id,result:{data:[]}});
 assert.equal((await (await request).json()).released,false);
});
