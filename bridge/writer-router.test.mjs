import test from 'node:test';
import assert from 'node:assert/strict';
import { WriterRouter } from './writer-router.mjs';
import { ApprovalRoutes } from './approval-routes.mjs';
import { spawn } from 'node:child_process';
import { StdioWorker } from './stdio-worker.mjs';

const transportFixture = `
 import { createInterface } from 'node:readline';
 createInterface({input:process.stdin}).on('line',line=>{
  const message=JSON.parse(line);
  if(message.method==='thread/read'){
   process.stdout.write(JSON.stringify({id:77,method:'approval',params:{}})+'\\n');
  }else if(message.id!==undefined){
   process.stdout.write(JSON.stringify({id:message.id,
    result:message.method==='thread/resume'?{thread:{id:'t',status:{type:'active'}}}:{}})+'\\n');
  }
 });`;

test('failed writer approval stays routable with its original id until retry succeeds',async t=>{
 const {router,workers}=fixture(),sent=[],calls=[];
 t.after(()=>router.cancelTimers());
 const routes=new ApprovalRoutes({broadcast:m=>sent.push(m)});
 router.onRequest=(id,method,params)=>routes.register('writer',{id,method,params},r=>router.route(r,()=>{}));
 router.create('a');let fail=true;
 workers[0].reply=async(id,result)=>{calls.push([id,result]);if(fail)throw new Error('not written');};
 workers[0].options.onRequest(7,'approval',{});
 const id=sent[0].id;
 await routes.reply({id,result:{decision:'accept'}});
 assert.equal(router.approvals.size,1);
 assert.equal(routes.pending.has(id),true);
 assert.equal(sent.filter(m=>m.method==='bridge/approvalResolved').length,0);
 fail=false;await routes.reply({id,result:{decision:'accept'}});
 assert.equal(router.approvals.size,0);assert.equal(routes.pending.size,0);
 assert.deepEqual(calls,[[7,{decision:'accept'}],[7,{decision:'accept'}]]);
 assert.equal(sent.filter(m=>m.method==='bridge/approvalResolved').length,1);
});

test('a close timeout retires the stuck worker so the next write gets a new lock holder',async()=>{
 const workers=[];
 const router=new WriterRouter({delay:60000,createWorker:options=>{
  const w={options,ready:Promise.resolve(),pendingCount:0,thread:'t',status:'idle',queued:[],terminals:[],calls:[],
   async request(method){this.calls.push(method);if(method==='thread/loaded/list')return{data:['t'],nextCursor:null};
    if(method==='thread/read')return{thread:{id:'t',status:{type:'idle'}}};return{data:[],nextCursor:null};},
   async closeIdle(){throw Object.assign(new Error('close timeout'),{code:'ERR_WORKER_CLOSE_TIMEOUT'});},
   forceClose(){options.onExit();}};workers.push(w);return w;}});
 await router.route({id:1,method:'thread/resume',params:{threadId:'t'}},()=>{});
 await router.releaseIdle();
 assert.equal(router.entries.has('t'),false);
 let response;await router.route({id:2,method:'thread/start',params:{threadId:'t'}},r=>response=r);
 assert.equal(response.error,undefined);assert.equal(workers.length,2);
 router.cancelTimers();
});

test('releaseIdle reports active turns and does not claim release',async()=>{
 const {router,workers}=fixture();
 await router.route({id:1,method:'thread/resume',params:{threadId:'t'}},()=>{});
 workers[0].options.onNotification('thread/status/changed',
  {threadId:'t',status:{type:'active'}});
 workers[0].status='active';
 workers[0].turnStatus='inProgress';
 const result=await router.releaseIdle();
 assert.deepEqual(result,{released:false,writerWorkers:1,reason:'active-turn'});
 router.cancelTimers();
});

test('manual release rechecks stale live status before closing its worker',async t=>{
 const {router,workers}=fixture();t.after(()=>router.cancelTimers());
 await router.route({id:1,method:'thread/resume',params:{threadId:'t'}},()=>{});
 workers[0].options.onNotification('turn/started',{threadId:'t',turn:{id:'old'}});
 workers[0].status='idle';
 assert.deepEqual(await router.releaseIdle({threadId:'t',force:true}),
  {released:true,writerWorkers:0,reason:''});
 assert.equal(workers[0].closed,true);
});

test('manual verification retains ownership on read failure or a concurrent new turn',async t=>{
 const {router,workers}=fixture();t.after(()=>router.cancelTimers());
 await router.route({id:1,method:'thread/resume',params:{threadId:'t'}},()=>{});
 const w=workers[0],request=w.request.bind(w);
 w.options.onNotification('turn/started',{threadId:'t',turn:{id:'old'}});
 w.request=async method=>{if(method==='thread/read')throw Error('offline');return request(method);};
 assert.equal((await router.releaseIdle({threadId:'t',force:true})).released,false);
 assert.equal(w.closed,false);
 w.request=async method=>{
  if(method==='thread/read')w.options.onNotification('turn/started',{threadId:'t',turn:{id:'new'}});
  return request(method);
 };
 assert.equal((await router.releaseIdle({threadId:'t',force:true})).released,false);
 assert.equal(w.closed,false);assert.equal(router.entries.get('t').activeTurns.get('t'),'new');
});

test('active status never releases from a stale persisted completed turn',async()=>{
 const {router,workers}=fixture();
 await router.route({id:1,method:'thread/resume',params:{threadId:'t'}},()=>{});
 workers[0].status='active';
 workers[0].turnStatus='completed';
 const result=await router.releaseIdle();
 assert.deepEqual(result,{released:false,writerWorkers:1,reason:'busy-or-unverified'});
 assert.equal(workers[0].closed,false);
 assert.equal(workers[0].calls.includes('thread/turns/list'),false);
 router.cancelTimers();
});

test('persisted active turn alone retains worker without claiming live generation',async()=>{
 const {router,workers}=fixture();
 await router.route({id:1,method:'thread/resume',params:{threadId:'t'}},()=>{});
 workers[0].status='active';
 workers[0].turnStatus='inProgress';
 const result=await router.releaseIdle();
 assert.deepEqual(result,{released:false,writerWorkers:1,reason:'busy-or-unverified'});
 assert.equal(workers[0].closed,false);
 router.cancelTimers();
});

test('releaseIdle reports unknown turn state instead of claiming generation',async()=>{
 const {router,workers}=fixture();
 await router.route({id:1,method:'thread/resume',params:{threadId:'t'}},()=>{});
 workers[0].status='active';
 workers[0].turnStatus='';
 const result=await router.releaseIdle();
 assert.deepEqual(result,{released:false,writerWorkers:1,reason:'busy-or-unverified'});
 assert.equal(workers[0].closed,false);
 router.cancelTimers();
});

test('live turn survives repeated releases during persistence gap then releases after idle',async t=>{
 const {router,workers}=fixture();t.after(()=>router.cancelTimers());
 await router.route({id:1,method:'thread/resume',params:{threadId:'t'}},()=>{});
 const w=workers[0];w.status='active';w.turnStatus='completed';
 w.options.onNotification('turn/started',{threadId:'t',turn:{id:'new'}});
 for(let i=0;i<2;i++)assert.deepEqual(await router.releaseIdle({threadId:'t'}),
  {released:false,writerWorkers:1,reason:'active-turn'});
 w.options.onNotification('turn/completed',{threadId:'t',turn:{id:'old'}});
 assert.equal((await router.releaseIdle()).reason,'active-turn');
 w.options.onNotification('turn/completed',{threadId:'t',turn:{id:'new'}});
 assert.equal((await router.releaseIdle()).reason,'busy-or-unverified');
 assert.equal(w.closed,false);
 w.status='idle';w.options.onNotification('thread/status/changed',{threadId:'t',status:{type:'idle'}});
 assert.deepEqual(await router.releaseIdle(),{released:true,writerWorkers:0,reason:''});
});

test('turn start response confirms live work even before notifications',async t=>{
 const {router,workers}=fixture();t.after(()=>router.cancelTimers());
 await router.route({id:1,method:'thread/resume',params:{threadId:'t'}},()=>{});
 const w=workers[0],request=w.request.bind(w);
 w.request=async(method,params)=>method==='turn/start'
  ?{turn:{id:'new',status:'inProgress'}}:request(method,params);
 await router.route({id:2,method:'turn/start',params:{threadId:'t'}},()=>{});
 assert.equal((await router.releaseIdle()).reason,'active-turn');
 assert.equal(w.closed,false);
 w.options.onNotification('turn/completed',{threadId:'t',turn:{id:'new'}});
 assert.equal((await router.releaseIdle()).released,true);
});

test('late turn start response does not resurrect an already completed turn',async t=>{
 const {router,workers}=fixture();t.after(()=>router.cancelTimers());
 await router.route({id:1,method:'thread/resume',params:{threadId:'t'}},()=>{});
 const w=workers[0],request=w.request.bind(w);
 w.request=async(method,params)=>{
  if(method!=='turn/start')return request(method,params);
  w.options.onNotification('turn/started',{threadId:'t',turn:{id:'quick'}});
  w.options.onNotification('turn/completed',{threadId:'t',turn:{id:'quick'}});
  return {turn:{id:'quick',status:'inProgress'}};
 };
 await router.route({id:2,method:'turn/start',params:{threadId:'t'}},()=>{});
 assert.equal((await router.releaseIdle()).released,true);
});

test('releasing the current chat ignores another chats active turn',async t=>{
 const {router,workers}=fixture();t.after(()=>router.cancelTimers());
 await router.route({id:1,method:'thread/resume',params:{threadId:'idle'}},()=>{});
 await router.route({id:2,method:'thread/resume',params:{threadId:'running'}},()=>{});
 workers[1].status='active';workers[1].turnStatus='inProgress';
 assert.deepEqual(await router.releaseIdle({threadId:'idle'}),
  {released:true,writerWorkers:0,reason:''});
 assert.equal(workers[0].closed,true);assert.equal(workers[1].closed,false);
 assert.equal(router.entries.size,1);
});

test('another chats broadcast active status does not keep an idle writer locked',async t=>{
 const {router,workers}=fixture();t.after(()=>router.cancelTimers());
 await router.route({id:1,method:'thread/resume',params:{threadId:'idle'}},()=>{});
 workers[0].options.onNotification('thread/status/changed',
  {threadId:'other',status:{type:'active'}});
 workers[0].options.onNotification('turn/started',{threadId:'other',turn:{id:'elsewhere'}});
 assert.deepEqual(await router.releaseIdle({threadId:'idle'}),
  {released:true,writerWorkers:0,reason:''});
});

test('releasing an unowned chat does not release other chats',async t=>{
 const {router,workers}=fixture();t.after(()=>router.cancelTimers());
 await router.route({id:1,method:'thread/resume',params:{threadId:'other'}},()=>{});
 assert.deepEqual(await router.releaseIdle({threadId:'unowned'}),
  {released:false,writerWorkers:0,reason:'not-owned'});
 assert.equal(workers[0].closed,false);
});

test('manual release verifies an external writer and never reports success',async t=>{
 const {router,workers}=fixture();t.after(()=>router.cancelTimers());
 const create=router.createWorker;
 router.createWorker=options=>{
  const worker=create(options),request=worker.request.bind(worker);
  worker.request=async(method,params)=>{
   if(method==='thread/resume')throw Error('thread t already has an active writer');
   return request(method,params);
  };return worker;
 };
 const result=await router.releaseIdle({threadId:'t',force:true});
 assert.equal(result.released,false);assert.equal(result.reason,'external-writer');
 assert.equal(workers.length,1);assert.equal(workers[0].closed,true);
});

test('normal worker exit only retires its mapping without forcing any process',()=>{
 const {router,workers}=fixture();let forced=0;
 router.create('a');router.create('b');
 for(const w of workers)w.forceClose=()=>{forced++;};
 workers[0].options.onExit();
 assert.equal(forced,0);
 assert.equal(router.entries.has('a'),false);
 assert.equal(router.entries.has('b'),true);
 router.cancelTimers();
});

test('a busy close rejection retains the worker without forcing exit',async()=>{
 const {router,workers}=fixture();let forced=0;
 await router.route({id:1,method:'thread/resume',params:{threadId:'t'}},()=>{});
 workers[0].closeIdle=async()=>{throw Object.assign(new Error('busy'),{code:'ERR_WORKER_BUSY'});};
 workers[0].forceClose=()=>{forced++;};
 assert.deepEqual(await router.releaseIdle(),
  {released:false,writerWorkers:1,reason:'busy-or-unverified'});
 assert.equal(forced,0);router.cancelTimers();
});

test('timed-out close keeps ownership until forced process exit is confirmed',async()=>{
 const {router,workers}=fixture();
 await router.route({id:1,method:'thread/resume',params:{threadId:'t'}},()=>{});
 const w=workers[0];let finish;
 w.closeIdle=async()=>{throw Object.assign(new Error('timeout'),{code:'ERR_WORKER_CLOSE_TIMEOUT'});};
 w.forceClose=()=>new Promise(resolve=>{finish=()=>{w.options.onExit();resolve();};});
 const closing=router.releaseIdle();
 for(let n=0;n<20&&!finish;n++)await Promise.resolve();
 assert.equal(router.entries.has('t'),true);
 assert.equal(router.owners.has('t'),true);
 finish();assert.equal((await closing).released,true);
 router.cancelTimers();
});

test('native resolution closes only matching worker request and stops replay',()=>{
 const {router,workers}=fixture(),closed=[];
 router.onRequestClosed=id=>closed.push(id);
 router.create('a');router.create('b');
 for(const w of workers)w.options.onRequest(7,'approval',{});
 const ids=[...router.approvals.keys()];
 workers[0].options.onNotification('serverRequest/resolved',{requestId:7});
 assert.deepEqual(closed,[ids[0]]);
 assert.deepEqual([...router.approvals.keys()],[ids[1]]);
 router.cancelTimers();
});

test('worker exit removes only approvals belonging to that worker',()=>{
 const {router,workers}=fixture(),sent=[],routes=new ApprovalRoutes({broadcast:m=>sent.push(m)});
 router.onRequest=(id,method,params)=>routes.register('writer',{id,method,params},()=>{});
 router.onRequestClosed=id=>routes.drop('writer',id);
 router.create('a');router.create('b');
 for(const w of workers)w.options.onRequest(7,'approval',{});
 const first=sent[0].id,second=sent[1].id;
 workers[0].options.onExit();
 const replay=[];routes.replay(m=>replay.push(m.id));
 assert.deepEqual(replay,[second]);
 assert.ok(sent.some(m=>m.params?.requestId===first));
 router.cancelTimers();
});

test('transport failure kills the process and retains writer ownership until real exit',{timeout:5000},async t=>{
 const workers=[];
 const router=new WriterRouter({delay:60000,createWorker:options=>{
  const worker=new StdioWorker({binary:process.execPath,
   spawnProcess:(_binary,_args,stdio)=>spawn(process.execPath,
    ['--input-type=module','-e',transportFixture],stdio),...options});
  workers.push(worker);return worker;
 }});
 t.after(async()=>{
  router.cancelTimers();
  await Promise.all(workers.map(worker=>worker.exited?null:worker.forceClose()));
 });
 let approved;
 const approval=new Promise(resolve=>{approved=resolve;});
 router.onRequest=()=>approved();
 let response;
 await router.route({id:1,method:'thread/resume',params:{threadId:'t'}},r=>response=r);
 assert.equal(response.error,undefined);
 const worker=workers[0],entry=router.entries.get('t');
 const read=router.route({id:2,method:'thread/read',params:{threadId:'t'}},r=>response=r);
 await approval;
 const failed=new Promise(resolve=>worker.child.stdout.once('error',resolve));
 const exited=new Promise(resolve=>worker.child.once('exit',resolve));
 worker.child.stdout.destroy(Object.assign(new Error('broken stdout'),{code:'EPIPE'}));
 await failed;
 assert.equal(worker.child.killed,true);
 assert.equal(worker.exited,undefined);
 assert.equal(router.owners.get('t'),entry);
 assert.equal(router.approvals.size,1);
 await read;assert.equal(response.error.code,'EPIPE');
 await exited;
 assert.equal(worker.exited,true);
 assert.equal(worker.exitError.code,'ERR_WORKER_EXITED');
 assert.equal(worker.child.signalCode,'SIGKILL');
 assert.equal(router.entries.has('t'),false);
 assert.equal(router.owners.has('t'),false);
 assert.equal(router.approvals.size,0);
 assert.equal(worker.pendingCount,0);
 await router.route({id:3,method:'turn/start',params:{threadId:'t'}},()=>{});
 assert.equal(workers.length,2);
 assert.notEqual(router.entries.get('t'),entry);
});

function fixture() {
 const workers=[];
 const router=new WriterRouter({delay:60000,createWorker:options=>{
  const worker={options,ready:Promise.resolve(),pendingCount:0,closed:false,
   thread:'t',status:'idle',turnStatus:'completed',queued:[],terminals:[],calls:[],
   name:null,preview:'',names:[],
   async request(method,params) {
    this.calls.push(method);
    if(method==='thread/loaded/list')return {data:[this.thread],nextCursor:null};
    if(method==='thread/resume')this.thread=params.threadId;
    if(method==='thread/read')return {thread:{id:this.thread,status:{type:this.status},
     name:this.name,preview:this.preview}};
    if(method==='thread/turns/list')return {data:this.turnStatus?[{id:'latest',status:this.turnStatus}]:[]};
    if(method==='thread/name/set')this.names.push(params.name);
    if(method==='thread/queue/list')return {data:this.queued,nextCursor:null};
    if(method==='thread/backgroundTerminals/list')return {data:this.terminals,nextCursor:null};
    return {thread:{id:this.thread},model:'selected-model',reasoningEffort:'high',cwd:'/repo'};
   },async closeIdle(){this.closed=true;options.onExit();},reply() {}};
  workers.push(worker);return worker;
 }});
 return {router,workers};
}
async function freshFixture() {
 const f=fixture();
 await f.router.route({id:1,method:'thread/start',params:{}},()=>{});
 const w=f.workers[0],request=w.request.bind(w);
 w.request=async(method,params)=>{
  if(method==='thread/resume')throw Object.assign(new Error('no rollout found for thread id t'),{code:-32600});
  return request(method,params);
 };
 return f;
}
test('fresh thread resume succeeds from its live worker before rollout exists',async t=>{
 const {router,workers}=await freshFixture();t.after(()=>router.cancelTimers());
 let response;
 await router.route({id:2,method:'thread/resume',params:{threadId:'t'}},r=>response=r);
 assert.equal(response.error,undefined);
 assert.equal(response.result.thread.id,'t');
 assert.equal(response.result.model,'selected-model');
 assert.equal(response.result.reasoningEffort,'high');
 await router.route({id:3,method:'turn/start',params:{threadId:'t',input:[]}},()=>{});
 assert.equal(workers.length,1);
 assert.equal(workers[0].calls.filter(m=>m==='turn/start').length,1);
});
test('fresh resume does not silently ignore configuration overrides',async t=>{
 const {router}=await freshFixture();t.after(()=>router.cancelTimers());
 for(const overrides of [{model:'other'},{cwd:'/other'},{config:{}},{history:[]}]){
  let response;
  await router.route({id:2,method:'thread/resume',params:{threadId:'t',...overrides}},r=>response=r);
  assert.match(response.error?.message||'',/no rollout/);
 }
});
test('unowned missing thread is never reported as resumed',async t=>{
 const {router}=fixture();t.after(()=>router.cancelTimers());
 const entry=router.create('t');
 entry.worker.request=async method=>{
  if(method==='thread/resume')throw new Error('no rollout found for thread id t');
  return {thread:{id:'t'}};
 };
 let response;
 await router.route({id:2,method:'thread/resume',params:{threadId:'t'}},r=>response=r);
 assert.match(response.error?.message||'',/no rollout/);
});
test('idle phone writer exits without touching another active worker',async()=>{
 const {router,workers}=fixture();
 await router.route({id:1,method:'thread/resume',params:{threadId:'a'}},()=>{});
 await router.route({id:2,method:'thread/resume',params:{threadId:'b'}},()=>{});
 workers[1].status='active';workers[1].turnStatus='inProgress';await router.releaseIdle();
 assert.equal(workers[0].closed,true);assert.equal(workers[1].closed,false);
 router.cancelTimers();
});
test('fresh resume preserves the error when its in-memory read fails or differs',async t=>{
 for(const mode of ['failed','wrong-id']){
  const {router,workers}=await freshFixture();t.after(()=>router.cancelTimers());
  const request=workers[0].request.bind(workers[0]);
  workers[0].request=async(method,params)=>{
   if(method!=='thread/read')return request(method,params);
   if(mode==='failed')throw new Error('worker exited');
   return {thread:{id:'another-thread'}};
  };
  let response;
  await router.route({id:2,method:'thread/resume',params:{threadId:'t'}},r=>response=r);
  assert.match(response.error?.message||'',/no rollout/);
 }
});
test('fresh resume still reports real writer conflicts',async t=>{
 const {router,workers}=await freshFixture();t.after(()=>router.cancelTimers());
 workers[0].request=async()=>{throw new Error('already has an active writer');};
 let response;
 await router.route({id:2,method:'thread/resume',params:{threadId:'t'}},r=>response=r);
 assert.match(response.error.message,/active writer/);
});
test('queued submissions and background commands retain their worker',async()=>{
 for(const field of ['queued','terminals']) {
  const {router,workers}=fixture();
  await router.route({id:1,method:'thread/resume',params:{threadId:'t'}},()=>{});
  workers[0][field]=[{id:'pending'}];await router.releaseIdle();
  assert.equal(workers[0].closed,false);router.cancelTimers();
 }
});
test('viewing an unowned thread stays on the read connection',async()=>{
 const {router,workers}=fixture();
 const handled=await router.route({id:1,method:'thread/turns/list',params:{threadId:'t'}},()=>{});
 assert.equal(handled,false);assert.equal(workers.length,0);router.cancelTimers();
});
test('failed completed session releases after queue and terminal checks',async()=>{
 const {router,workers}=fixture();
 await router.route({id:1,method:'thread/resume',params:{threadId:'t'}},()=>{});
 workers[0].status='systemError';await router.releaseIdle();
 assert.equal(workers[0].closed,true);router.cancelTimers();
});
test('write arriving during an idle check prevents process exit',async()=>{
 const {router,workers}=fixture();
 await router.route({id:1,method:'thread/resume',params:{threadId:'t'}},()=>{});
 const worker=workers[0];const original=worker.request.bind(worker);let resolveRead;
 worker.request=(method,params)=>method==='thread/read'
  ?new Promise(resolve=>{resolveRead=resolve;}):original(method,params);
 const release=router.releaseIdle();
 while(!resolveRead)await Promise.resolve();
 await router.route({id:2,method:'turn/start',params:{threadId:'t'}},()=>{});
 resolveRead({thread:{id:'t',status:{type:'idle'}}});await release;
 assert.equal(worker.closed,false);router.cancelTimers();
});
test('phone can write again after an earlier worker exited',async()=>{
 const {router,workers}=fixture();
 await router.route({id:1,method:'thread/resume',params:{threadId:'t'}},()=>{});
 await router.releaseIdle();
 await router.route({id:2,method:'turn/start',params:{threadId:'t'}},()=>{});
 assert.equal(workers.length,2);
 assert.deepEqual(workers[1].calls.slice(0,2),['thread/resume','turn/start']);
 router.cancelTimers();
});
test('two writes waiting for closing worker reuse one replacement',async t=>{
 const {router,workers}=fixture();t.after(()=>router.cancelTimers());
 await router.route({id:1,method:'thread/resume',params:{threadId:'t'}},()=>{});
 const entry=router.entries.get('t');let finish;
 entry.closing=new Promise(resolve=>{finish=resolve;});
 const first=router.route({id:2,method:'turn/start',params:{threadId:'t'}},()=>{});
 const second=router.route({id:3,method:'thread/resume',params:{threadId:'t'}},()=>{});
 workers[0].options.onExit();finish();await Promise.all([first,second]);
 assert.equal(workers.length,2,'one original and one replacement');
 assert.equal(router.owners.get('t'),router.entries.get('t'));
});
test('empty new chat is persisted before releasing its writer',async()=>{
 const {router,workers}=fixture();let response;
 await router.route({id:1,method:'thread/start',params:{}},r=>response=r);
 assert.equal(response.result.thread.id,'t');
 assert.deepEqual(workers[0].calls,['thread/start']);
 await router.releaseIdle();
 assert.ok(workers[0].calls.includes('thread/name/set'));
 assert.equal(workers[0].closed,true);router.cancelTimers();
});
test('read arriving while idle writer exits does not reacquire its lock',async()=>{
 const {router,workers}=fixture();
 await router.route({id:1,method:'thread/resume',params:{threadId:'t'}},()=>{});
 const entry=router.entries.get('t');entry.closing=Promise.resolve();
 const handled=await router.route({id:2,method:'thread/read',params:{threadId:'t'}},()=>{});
 assert.equal(handled,false);assert.equal(workers.length,1);router.cancelTimers();
});
test('list polling preserves the owned worker live status',async()=>{
 const {router,workers}=fixture();
 await router.route({id:1,method:'thread/resume',params:{threadId:'t'}},()=>{});
 workers[0].options.onNotification('thread/status/changed',{threadId:'t',status:{type:'active'}});
 const response=router.decorate({result:{data:[{id:'t',status:{type:'notLoaded'}}]}});
 assert.equal(response.result.data[0].status.type,'active');router.cancelTimers();
});
test('realtime voice keeps its process until call ends',async()=>{
 const {router,workers}=fixture();
 await router.route({id:1,method:'thread/realtime/start',params:{threadId:'t'}},()=>{});
 await router.releaseIdle();assert.equal(workers[0].closed,false);
 await router.route({id:2,method:'thread/realtime/stop',params:{threadId:'t'}},()=>{});
 await router.releaseIdle();assert.equal(workers[0].closed,true);router.cancelTimers();
});

test('queue/add does not pre-resume, so a locked thread can still be queued',async()=>{
 // 现场（2026-10-09 21:2x）：电脑端 Codex 占着会话的写者锁，手机端
 // `turn/start` 报 active writer，退回 `thread/queue/add` —— 结果**也**报
 // active writer，用户看到「电脑端占用 排队也失败」，消息一条都发不出去。
 // 根因是这个路由在 queue/add 之前替它 resume 了一次，自己撞上了那把锁。
 const {router,workers}=fixture();
 const replies=[];
 // 真实现场：`turn/start` 先建了 worker，它的 resume 撞上写者锁**失败了**
 // —— 所以 `e.threadID` 一直是 null，而 worker 还活着（1.5 秒后才释放）。
 // 紧接着的 `queue/add` 就落到这个 worker 上。
 router.create('locked');
 workers[0].calls.length=0;
 const handled=await router.route(
  {id:1,method:'thread/queue/add',params:{threadId:'locked',input:[{type:'text',text:'x'}]}},
  r=>replies.push(r));
 assert.equal(handled,false,'queue/add 应该交给共享上游');
 assert.equal(workers[0].calls.includes('thread/resume'),false,
  'queue/add 之前不该 resume —— 那等于自己先去撞写者锁');
 assert.equal(replies.length,0,'交给共享上游的请求不应由 worker 应答');
 router.cancelTimers();
});
test('failed writer acquisition falls back for read and queue metadata',async()=>{
 const {router,workers}=fixture();
 router.create('locked');
 const request=workers[0].request.bind(workers[0]);
 workers[0].request=async(method,params)=>{
  if(method==='thread/resume')throw new Error('already has an active writer');
  return request(method,params);
 };
 let error;
 await router.route({id:1,method:'thread/resume',params:{threadId:'locked'}},r=>error=r.error);
 assert.match(error.message,/active writer/);
 const methods=['thread/read','thread/turns/list','thread/queue/list','thread/queue/delete'];
 for(const method of methods){
  workers[0].calls.length=0;
  const handled=await router.route({id:1,method,params:{threadId:'locked'}},()=>{});
  assert.equal(handled,false,method+' should use the shared upstream');
  assert.deepEqual(workers[0].calls,[],method+' must not retry resume on the failed worker');
 }
 router.cancelTimers();
});
test('unloaded old thread settings are written after acquiring its writer',async t=>{
 const {router,workers}=fixture();t.after(()=>router.cancelTimers());
 let response;
 const params={threadId:'old',model:'selected-model',effort:'high'};
 const handled=await router.route({id:7,method:'thread/settings/update',params},r=>response=r);
 assert.equal(handled,true,'unloaded settings must not fall through to the shared reader');
 assert.deepEqual(workers[0].calls,['thread/resume','thread/settings/update']);
 assert.equal(response.id,7);assert.equal(response.error,undefined);
 assert.equal(router.owners.get('old'),router.entries.get('old'));
});
test('settings update preserves writer conflicts without pretending success',async t=>{
 const {router,workers}=fixture();t.after(()=>router.cancelTimers());
 router.create('locked');
 workers[0].request=async method=>{
  workers[0].calls.push(method);
  if(method==='thread/resume')throw Object.assign(new Error('already has an active writer'),{code:-32600});
  throw new Error('settings must not run after failed resume');
 };
 let response;
 const handled=await router.route({id:8,method:'thread/settings/update',
  params:{threadId:'locked',model:'new'}},r=>response=r);
 assert.equal(handled,true);assert.equal(response.error.code,-32600);
 assert.match(response.error.message,/active writer/);assert.equal(response.result,undefined);
 assert.deepEqual(workers[0].calls,['thread/resume']);assert.equal(router.owners.has('locked'),false);
});
test('phone-created thread is renamed from its first message',async()=>{
 const {router,workers}=fixture();
 await router.route({id:1,method:'thread/start',params:{}},()=>{});
 const w=workers[0];
 w.preview='我问你 归档的会话全删了 会影响记忆吗';
 await router.releaseIdle();
 assert.deepEqual(w.names,['我问你 归档的会话全删了 会影响记忆…']);
 router.cancelTimers();
});
test('owned thread metadata stays on its writer without another resume',async()=>{
 const {router,workers}=fixture();
 await router.route({id:1,method:'thread/resume',params:{threadId:'t'}},()=>{});
 for(const method of ['thread/read','thread/turns/list','thread/queue/list','thread/queue/delete','thread/settings/update']){
  workers[0].calls.length=0;
  const handled=await router.route({id:2,method,params:{threadId:'t'}},()=>{});
  assert.equal(handled,true);
  assert.deepEqual(workers[0].calls,[method]);
 }
 router.cancelTimers();
});
test('empty phone thread keeps the placeholder so it stays listable',async()=>{
 const {router,workers}=fixture();
 await router.route({id:1,method:'thread/start',params:{}},()=>{});
 await router.releaseIdle();
 assert.deepEqual(workers[0].names,['新会话']);
 router.cancelTimers();
});
test('a thread the user already named is never renamed',async()=>{
 const {router,workers}=fixture();
 await router.route({id:1,method:'thread/resume',params:{threadId:'t'}},()=>{});
 const w=workers[0];w.name='我的会话';w.preview='随便什么';
 await router.releaseIdle();
 assert.deepEqual(w.names,[]);
 router.cancelTimers();
});
