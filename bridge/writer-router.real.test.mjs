import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import {existsSync} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {StdioWorker} from './stdio-worker.mjs';

// CODEX_BIN selects the real CLI; WRITER_ROUTER_MODULE can select a pre-fix file.
const binary=process.env.CODEX_BIN || [
 '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex',
 '/Applications/Codex.app/Contents/Resources/codex'
].find(existsSync);
const routerURL=process.env.WRITER_ROUTER_MODULE
 ? pathToFileURL(path.resolve(process.env.WRITER_ROUTER_MODULE))
 : new URL('./writer-router.mjs',import.meta.url);
const {WriterRouter}=await import(routerURL);
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));

test('persisted unloaded thread changes model and changes back across real worker exits',
 {skip:!binary,timeout:60000},async t=>{
 const home=await fs.mkdtemp(path.join(os.tmpdir(),'pocket-model-roundtrip-'));
 const workers=[];
 let router;
 t.after(async()=>{
  router?.cancelTimers();
  await Promise.all(workers.map(async worker=>{
   if(worker.exited)return;
   worker.child.kill('SIGTERM');
   const timer=setTimeout(()=>worker.child.kill('SIGKILL'),1000);
   try{await worker.exit;}finally{clearTimeout(timer);}
  }));
  await fs.rm(home,{recursive:true,force:true});
 });
 await fs.writeFile(path.join(home,'config.toml'),
  'model = "gpt-6.1-sol"\nmodel_reasoning_effort = "max"\n');
 function createWorker(options={}){
  const worker=new StdioWorker({binary,cwd:home,
   env:{...process.env,CODEX_HOME:home},...options});
  workers.push(worker);return worker;
 }
 const creator=createWorker();
 const started=await creator.request('thread/start',{cwd:home,model:'gpt-6.1-sol'});
 const id=started.thread.id;
 await creator.request('thread/name/set',{threadId:id,name:'Model persistence regression'});
 await creator.request('thread/settings/update',{threadId:id,model:'gpt-6.1-sol',effort:'max'});
 assert.deepEqual(await creator.closeIdle(),{code:0,signal:null});
 const rollout=await fs.readFile(started.thread.path,'utf8');
 assert.ok(rollout.trim().length>0,'fixture must have an on-disk rollout after creator exits');
 assert.ok(rollout.split('\n').filter(Boolean).map(JSON.parse)
  .some(row=>row.type==='session_meta'&&row.payload.id===id));
 const read=(worker,label)=>worker.request('thread/read',{threadId:id,includeTurns:false})
  .then(result=>{assert.equal(result.thread.id,id,label);return result.thread;});
 const reader=createWorker();
 const before=await read(reader,'old thread read');
 assert.equal(before.model,'gpt-6.1-sol');
 assert.equal(before.status.type,'notLoaded');
 assert.deepEqual(await reader.closeIdle(),{code:0,signal:null});
 router=new WriterRouter({delay:60000,createWorker});
 async function update(model,effort){
  let response;
  const handled=await router.route({id:Math.random(),method:'thread/settings/update',
   params:{threadId:id,model,effort}},result=>{response=result;});
  assert.equal(handled,true);
  assert.equal(response.error,undefined);
  assert.deepEqual(response.result,{});
 }
 await update('gpt-6-astra','high');
 await router.releaseIdle();
 const checkA=createWorker();
 assert.equal((await read(checkA,'changed model read')).model,'gpt-6-astra');
 await checkA.closeIdle();
 await update('gpt-6.1-sol','max');
 await router.releaseIdle();
 const checkB=createWorker();
 const final=await read(checkB,'restored model read');
 assert.equal(final.model,'gpt-6.1-sol');
 assert.equal(final.reasoningEffort,'max');
 await checkB.request('thread/delete',{threadId:id});
 await checkB.closeIdle();
 await pause(20);
});
