import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {StdioWorker} from './stdio-worker.mjs';
import {WriterRouter} from './writer-router.mjs';

test('manual release distinguishes external ownership from a real idle release',
 {skip:!process.env.CODEX_BIN,timeout:30000},async t=>{
 const home=await fs.mkdtemp(path.join(os.tmpdir(),'pocket-release-'));
 const workers=[];
 const createWorker=callbacks=>{
  const w=new StdioWorker({binary:process.env.CODEX_BIN,cwd:home,
   env:{...process.env,CODEX_HOME:home},...callbacks});workers.push(w);return w;
 };
 const router=new WriterRouter({createWorker,delay:60000});
 t.after(async()=>{router.cancelTimers();await Promise.all(workers.map(w=>w.forceClose()));
  await fs.rm(home,{recursive:true,force:true});});
 const desktop=createWorker();
 const started=await desktop.request('thread/start',{cwd:home});
 const id=started.thread.id;
 await desktop.request('thread/name/set',{threadId:id,name:'Lock release regression'});
 const held=await router.releaseIdle({threadId:id,force:true});
 assert.equal(held.released,false);assert.equal(held.reason,'external-writer');
 const unsubscribed=await desktop.request('thread/unsubscribe',{threadId:id});
 assert.equal(unsubscribed.status,'unsubscribed');
 const stillHeld=await router.releaseIdle({threadId:id,force:true});
 assert.equal(stillHeld.reason,'external-writer');
 await desktop.closeIdle();
 let released;
 for(let n=0;n<10;n++){
  released=await router.releaseIdle({threadId:id,force:true});
  if(released.released)break;
  await new Promise(resolve=>setTimeout(resolve,50));
 }
 assert.equal(released.released,true);assert.equal(released.writerWorkers,0);
 const next=createWorker();
 const resumed=await next.request('thread/resume',{threadId:id,excludeTurns:true});
 assert.equal(resumed.thread.id,id);
 await next.request('thread/delete',{threadId:id});await next.closeIdle();
});
