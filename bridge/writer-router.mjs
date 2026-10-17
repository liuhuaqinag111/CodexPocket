// settings/update 只能改已加载的会话；旧会话先 resume 到短生命周期写进程。
const acquire=new Set(['thread/resume','thread/settings/update','turn/start','thread/compact/start','thread/revert',
 'thread/realtime/start','thread/queue/start']);
const isNoRollout=error=>/no rollout found for thread id/i.test(String(error?.message||error));
// 会话标题：占位名 "新会话" 只用来让空会话出现在 thread/list 里
// （既没 name 又没 preview 的会话，服务端根本不返回它）。
// 一旦用户发了消息就必须换成首条消息 —— 否则手机端的 autoName
// 会因为 `named` 已是 true 而跳过，会话永远停在"新会话"。
function titleFrom(preview) {
 const lines=String(preview||'').split('\n');
 const at=lines.findIndex(l=>l.trim().startsWith('## My request:'));
 const pool=at>=0?lines.slice(at+1):lines;
 const s=(pool.find(l=>l.trim()&&!l.trim().startsWith('#'))||'').trim();
 if(!s)return '新会话';
 return s.length>18?s.slice(0,18)+'…':s;
}
export class WriterRouter {
 constructor({createWorker,onNotification=()=>{},onRequest=()=>{},onRequestClosed=()=>{},log=()=>{},delay=1500}) {
  Object.assign(this,{createWorker,onNotification,onRequest,onRequestClosed,log,delay});
  this.entries=new Map();this.owners=new Map();this.statuses=new Map();
  this.approvals=new Map();this.seq=0;this.approvalSeq=-1000000;
 }
 cancelTimers(){for(const e of this.entries.values())clearTimeout(e.timer);}
 retire(e) {
  if(e.dead)return;
  e.dead=true;clearTimeout(e.timer);
  if(this.entries.get(e.key)===e)this.entries.delete(e.key);
  for(const [id,owner] of this.owners)if(owner===e){this.owners.delete(id);this.statuses.delete(id);}
  for(const [id,approval] of this.approvals)if(approval.e===e){
   this.approvals.delete(id);this.onRequestClosed(id);
  }
 }
 schedule(e,delay=this.delay) {
  clearTimeout(e.timer);
  if(e.dead)return;
  e.timer=setTimeout(()=>void this.release(e),delay);e.timer.unref?.();
 }
 create(key) {
  const e={key,threadID:null,busy:0,generation:0,dead:false,activeTurns:new Map()};
  e.worker=this.createWorker({
   onNotification:(method,params)=>{
    if(method==='serverRequest/resolved') {
     for(const [id,row] of this.approvals)if(row.e===e&&row.id===params?.requestId){
      this.approvals.delete(id);this.onRequestClosed(id);
     }
    }
    if(method==='thread/started' && params.thread?.id)this.owners.set(params.thread.id,e);
    const owned=this.owners.get(params.threadId)===e||e.threadID===params.threadId||e.key===params.threadId;
    if(method==='thread/status/changed'){
     this.statuses.set(params.threadId,params.status);
     if(owned&&params.status?.type==='active'&&!e.activeTurns.has(params.threadId))
      e.activeTurns.set(params.threadId,null);
     else if(['idle','completed','interrupted','failed','systemError'].includes(params.status?.type))
      e.activeTurns.delete(params.threadId);
    }
    if(owned&&method==='turn/started')e.activeTurns.set(params.threadId,params.turn?.id||params.turnId||null);
    if(method==='turn/completed'){
     const current=e.activeTurns.get(params.threadId),finished=params.turn?.id||params.turnId;
     if(current===null||current===finished)e.activeTurns.delete(params.threadId);
    }
    if(['thread/realtime/closed','thread/realtime/error'].includes(method))e.realtime=false;
    if(method!=='thread/name/updated')e.generation++;
    this.onNotification(method,params);this.schedule(e);
   },
   onRequest:(id,method,params)=>{
    const outward=--this.approvalSeq;this.approvals.set(outward,{e,id});
    this.onRequest(outward,method,params);
  },onExit:()=>this.retire(e)
  });
  this.entries.set(key,e);return e;
 }
 async route(message,respond) {
  if(!message.method && this.approvals.has(message.id)) {
   const {e,id}=this.approvals.get(message.id);
   await e.worker.reply(id,message.result??{},message.error);
   this.approvals.delete(message.id);this.schedule(e);return true;
  }
  const {method,params={}}=message;
  const fresh=method==='thread/start'||method==='thread/fork';
  let e=this.owners.get(params.threadId)||this.entries.get(params.threadId);
  // resume 失败也会留下 entry。没拿到写者锁的读取和队列请求
  // 继续交给共享上游，别为了查状态、撤销排队又去撞一次锁。
  if(!fresh && !e?.threadID && !acquire.has(method))return false;
  while(e?.closing){
   const closing=e;
   try {await e.closing;} catch(error) {
    respond({id:message.id,error:{code:-32603,message:error.message}});return true;
   }
   if(!fresh&&!acquire.has(method))return false;
   e=this.owners.get(params.threadId)||this.entries.get(params.threadId);
   if(e===closing)e=null;
  }
  try {
   if(!e || e.dead)e=this.create(fresh?'new-'+(++this.seq):params.threadId);
  } catch(error) {
   respond({id:message.id,error:{code:-32603,message:error.message}});return true;
  }
  e.busy++;e.generation++;clearTimeout(e.timer);
  try {
   await e.worker.ready;
   // **`thread/queue/add` 不要先 resume。**
   //
   // 队列的意义就是"写者锁被别人占着时，把消息交出去让持锁那边执行"
   // （见 ConversationQueue 的注释：实测不持锁的连接也能 add 成功）。
   // 这里替它 resume 一次，等于自己先去撞那把锁 —— 撞不上就回
   // "already has an active writer"，**队列这条路整个作废**。
   // 手机端的表现就是用户报的「电脑端占用 排队也失败」。
   // 实测对照：走桥接的 worker → active writer；直连主 upstream → 通过。
   // 队列自己的入队/取消不需要会话被加载，交给持有锁的那边执行即可。
   if(!e.threadID && !fresh && method!=='thread/resume' && method!=='thread/queue/add') {
    await e.worker.request('thread/resume',{threadId:params.threadId,excludeTurns:true});
    e.threadID=params.threadId;this.owners.set(e.threadID,e);
   }
   const requestGeneration=e.generation;
   const result=await e.worker.request(method,params);
   if(method==='turn/start'&&e.generation===requestGeneration&&result?.turn?.id
      &&['inProgress','in_progress','active'].includes(result.turn.status?.type||result.turn.status))
    e.activeTurns.set(params.threadId,result.turn.id);
   if(method==='thread/start')e.freshResult=result;
   else if(method==='turn/start'||method==='thread/resume')delete e.freshResult;
   if(method==='thread/realtime/start')e.realtime=true;
   if(method==='thread/realtime/stop')e.realtime=false;
   const id=result?.thread?.id || (method==='thread/resume'?params.threadId:null);
   if(id){e.threadID=e.threadID||id;this.owners.set(id,e);if(result.thread?.status)this.statuses.set(id,result.thread.status);}
   respond({id:message.id,result});
  } catch(error) {
   // 空会话尚未落盘，但创建它的 worker 已持有它。只兼容不改配置的
   // resume；保留创建时的真实配置，不能把未知会话或配置失败伪装成成功。
   if(method==='thread/resume'&&isNoRollout(error)&&e.freshResult?.thread?.id===params.threadId
      &&e.threadID===params.threadId&&this.owners.get(params.threadId)===e
      &&Object.keys(params).every(key=>['threadId','excludeTurns'].includes(key))){
    try {
     const current=await e.worker.request('thread/read',{threadId:params.threadId,includeTurns:false});
     if(current?.thread?.id===params.threadId){
      e.threadID=params.threadId;this.owners.set(e.threadID,e);
      respond({id:message.id,result:{...e.freshResult,thread:current.thread}});return true;
     }
    } catch {}
   }
   respond({id:message.id,error:{code:error.code||-32603,message:error.message}});
  } finally {e.busy--;this.schedule(e);}
  return true;
 }
 async releaseIdle({threadId,force=false}={}){
  if(force&&threadId&&!this.owners.has(threadId)){
   let reply;
   await this.route({id:'release-probe',method:'thread/resume',
    params:{threadId,excludeTurns:true}},value=>{reply=value;});
   if(reply?.error){
    const entry=this.entries.get(threadId);
    if(entry)await this.release(entry);
    return {released:false,writerWorkers:entry&&!entry.dead?1:0,
     reason:/(active writer|live local writer)/i.test(reply.error.message)?'external-writer':'busy-or-unverified'};
   }
  }
  const selected=threadId?[this.owners.get(threadId)||this.entries.get(threadId)].filter(Boolean)
   :[...this.entries.values()];
  if(threadId&&!selected.length)return {released:false,writerWorkers:0,reason:'not-owned'};
  await Promise.all(selected.map(e=>this.release(e,{verify:force})));
  const remaining=selected.filter(e=>!e.dead);
  const active=remaining.some(e=>e.realtime||e.activeTurns.size);
  return {released:remaining.length===0,writerWorkers:remaining.length,
   reason:active?'active-turn':remaining.length?'busy-or-unverified':''};
 }
 decorate(message) {
  const patch=thread=>{
   if(thread&&this.owners.has(thread.id)&&this.statuses.has(thread.id))thread.status=this.statuses.get(thread.id);
  };
  if(Array.isArray(message.result?.data))message.result.data.forEach(patch);
  patch(message.result?.thread);return message;
 }
 async release(e,{verify=false}={}) {
  if(e.dead||e.busy||e.realtime||(!verify&&e.activeTurns.size)||e.checking||e.closing||e.worker.pendingCount)return;
  const generation=e.generation;
  const valid=()=>!e.dead&&!e.busy&&e.generation===generation&&!e.worker.pendingCount;
  e.checking=true;
  try {
   await e.worker.ready;
   const loaded=await e.worker.request('thread/loaded/list',{});
   if(!valid()||!Array.isArray(loaded.data)||loaded.nextCursor)return;
   if([...e.activeTurns.keys()].some(id=>!loaded.data.includes(id)))return;
   for(const id of loaded.data) {
    const result=await e.worker.request('thread/read',{threadId:id,includeTurns:false});
    if(!valid()||result.thread?.id!==id)return;
    const status=result.thread.status?.type;
    this.statuses.set(id,result.thread.status);
    // turns/list may lag a live turn; a persisted completed tail cannot prove idle.
    if(!['idle','systemError'].includes(status))return;
    if(verify)e.activeTurns.delete(id);
    // 会话标题。空会话既没 name 也没 preview，`thread/list` 根本不返回它，
    // 所以先落个占位名"新会话"；发过消息（有 preview）就换成首条消息。
    // 占位名不换掉，手机端 autoName 会因为 `named` 已是 true 而跳过，
    // 会话就永远停在"新会话"。
    const cur=result.thread.name;
    if(!cur||cur==='新会话'||/^新会话 \(\d+\)$/.test(cur)) {
     const want=result.thread.preview?titleFrom(result.thread.preview):'新会话';
     if(want!==cur) {
      await e.worker.request('thread/name/set',{threadId:id,name:want});
      if(!valid())return;
     }
    }
    for(const method of ['thread/queue/list','thread/backgroundTerminals/list']) {
     const result=await e.worker.request(method,{threadId:id});
     if(!valid()||!Array.isArray(result.data)||result.data.length||result.nextCursor)return;
    }
   }
   if(!valid())return;
   e.closing=e.worker.closeIdle();await e.closing;
   this.log('[writer] released',e.threadID||e.key);
  } catch(error) {
   this.log('[writer] retaining worker',error.message);
   if(e.closing&&error.code==='ERR_WORKER_CLOSE_TIMEOUT'){
    e.closing=Promise.resolve().then(()=>e.worker.forceClose());
    try {await e.closing;this.retire(e);}
    catch(failure){this.log('[writer] force close failed',failure.message);}
   }
  }
  finally {e.checking=false;if(!e.dead&&!e.closing)this.schedule(e,10000);}
 }
}
