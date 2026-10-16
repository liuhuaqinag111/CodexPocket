import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {SubmissionDedup} from './submission-dedup.mjs';
async function fixture(t){
 const directory=await fs.mkdtemp(path.join(os.tmpdir(),'submission-dedup-'));
 t.after(()=>fs.rm(directory,{recursive:true,force:true}));
 return new SubmissionDedup({directory});
}
test('status replays a persisted ACK across restart and is scoped to thread and client ID',async t=>{
 const first=await fixture(t),params={threadId:'a',clientUserMessageId:'status-ack'};
 const m={id:1,method:'thread/queue/add',params};
 await first.begin(m,()=>{});await first.settle(m,{id:1,result:{queued:true}});
 const next=new SubmissionDedup({directory:first.directory});
 assert.deepEqual(await next.status(params),{state:'accepted',result:{result:{queued:true}}});
 assert.deepEqual(await next.status({...params,threadId:'b'}),{state:'missing'});
 assert.deepEqual(await next.status({...params,clientUserMessageId:'other'}),{state:'missing'});
});

test('status reports in-flight rows as pending and durable intent after restart as unknown',async t=>{
 const first=await fixture(t),params={threadId:'a',clientUserMessageId:'inflight'};
 await first.begin({id:1,method:'turn/steer',params},()=>{});
 assert.deepEqual(await first.status(params),{state:'pending'});
 const next=new SubmissionDedup({directory:first.directory});
 assert.deepEqual(await next.status(params),{state:'unknown'});
});

test('status treats malformed records and ACKs without a result as unknown',async t=>{
 const dedup=await fixture(t),params={threadId:'a',clientUserMessageId:'bad'};
 const key=dedup.key({method:'turn/start',params}),file=dedup.filename(key);
 for(const record of ['{', '{}', '{"state":"ack"}', '{"state":"ack","result":{}}',
  '{"state":"unknown"}', '{"state":"ack","result":{"error":{"code":-1}}}']){
  await fs.writeFile(file,record);
  assert.deepEqual(await dedup.status(params),{state:'unknown'});
 }
});

test('missing status is read-only and invalid identities are rejected',async t=>{
 const dedup=await fixture(t),params={threadId:'a',clientUserMessageId:'absent'};
 assert.deepEqual(await dedup.status(params),{state:'missing'});
 assert.deepEqual(await fs.readdir(dedup.directory),[]);
 await assert.rejects(dedup.status({threadId:'a'}),TypeError);
 await assert.rejects(dedup.status({threadId:[],clientUserMessageId:'x'}),TypeError);
});

test('retrying an incomplete persisted ACK reports unknown instead of an empty RPC',async t=>{
 const dedup=await fixture(t),m={id:7,method:'turn/start',params:{threadId:'a',clientUserMessageId:'bad-ack'}};
 const file=dedup.filename(dedup.key(m));
 for(const record of [null,false,0,'',{state:'ack'},{state:'ack',result:{}},{state:'ack',result:{error:{code:-1}}}]){
  await fs.writeFile(file,JSON.stringify(record));
  const replies=[];
  assert.equal((await dedup.begin(m,r=>replies.push(r))).duplicate,true);
  assert.equal(replies[0]?.error?.code,-32091);
  assert.equal(dedup.rows.size,0);
 }
});

test('a submission that begins and finishes during a missing read is never declared missing',async t=>{
 const dedup=await fixture(t),params={threadId:'a',clientUserMessageId:'fast-race'};
 const read=fs.readFile.bind(fs);let release,entered,calls=0;
 const started=new Promise(r=>{entered=r;}),barrier=new Promise(r=>{release=r;});
 t.mock.method(fs,'readFile',async(...args)=>{
  if(calls++)return read(...args);
  let error;try{await read(...args);}catch(e){error=e;}
  entered();await barrier;throw error;
 });
 const checking=dedup.status(params);await started;
 const m={id:1,method:'turn/start',params};
 await dedup.begin(m,()=>{});await dedup.settle(m,{result:{turn:{id:'accepted'}}});
 release();assert.notEqual((await checking).state,'missing');
});

test('status rechecks in-flight rows after both a missing and an existing disk read',async t=>{
 for(const existing of [false,true]){
  const dedup=await fixture(t),params={threadId:'a',clientUserMessageId:'race'};
  const key=dedup.key({method:'turn/start',params});
  if(existing)await dedup.persist(key,{state:'ack',result:{result:{turn:{id:'old'}}}});
  const read=fs.readFile.bind(fs);
  let resume,started;
  const reading=new Promise(resolve=>{started=resolve;});
  const barrier=new Promise(resolve=>{resume=resolve;});
  t.mock.method(fs,'readFile',async(...args)=>{
   let value,error;try{value=await read(...args);}catch(e){error=e;}
   started();await barrier;if(error)throw error;return value;
  });
  const status=dedup.status(params);await reading;
  dedup.rows.set(key,{replies:[]});resume();
  assert.deepEqual(await status,{state:'pending'});
  t.mock.restoreAll();
 }
});
test('same client submission across steer and start shares one dispatch and ACK',async t=>{
 const dedup=await fixture(t),sent=[];
 const start={id:1,method:'turn/steer',params:{threadId:'t',clientUserMessageId:'L'}};
 const repeat={...start,id:2,method:'turn/start'};
 assert.equal((await dedup.begin(start,r=>sent.push(r))).duplicate,false);
 assert.equal((await dedup.begin(repeat,r=>sent.push(r))).duplicate,true);
 await dedup.settle(start,{id:1,result:{turn:{id:'turn'}}});
 assert.deepEqual(sent,[{id:1,result:{turn:{id:'turn'}}},{id:2,result:{turn:{id:'turn'}}}]);
 assert.equal((await dedup.begin({...repeat,id:3},r=>sent.push(r))).duplicate,true);
 assert.equal(sent[2].id,3);
});
test('different threads and explicit rejection are independently retryable',async t=>{
 const dedup=await fixture(t),m={id:1,method:'turn/start',params:{threadId:'a',clientUserMessageId:'L'}};
 await dedup.begin(m,()=>{});await dedup.settle(m,{id:1,error:{code:-32600,message:'already has an active writer'}});
 assert.equal((await dedup.begin({...m,method:'thread/queue/add'},()=>{})).duplicate,false);
 assert.equal((await dedup.begin({...m,params:{...m.params,threadId:'b'}},()=>{})).duplicate,false);
});

test('restart converts durable intent to unknown and never re-dispatches it', async t => {
 const first=await fixture(t), message={id:1,method:'turn/start',params:{threadId:'a',clientUserMessageId:'persisted'}};
 await first.begin(message,()=>{});
 const second=new SubmissionDedup({directory:first.directory});
 const replies=[]; const state=await second.begin({...message,id:2},r=>replies.push(r));
 assert.equal(state.duplicate,true);
 assert.equal(replies[0].error.code,-32091);
});

test('durable ACK survives a new dedup instance and in-memory rows stay bounded',async t=>{
 const first=await fixture(t),m={id:1,method:'turn/start',params:{threadId:'a',clientUserMessageId:'ack'}};
 await first.begin(m,()=>{});await first.settle(m,{id:1,result:{turn:{id:'done'}}});
 assert.equal(first.rows.size,0);
 const second=new SubmissionDedup({directory:first.directory}),sent=[];
 assert.equal((await second.begin({...m,id:9},r=>sent.push(r))).duplicate,true);
 assert.deepEqual(sent,[{id:9,result:{turn:{id:'done'}}}]);
 assert.equal(second.rows.size,0);
});

test('failed durable intent returns not-sent and never authorizes dispatch',async t=>{
 const dedup=await fixture(t),sent=[];
 await fs.writeFile(path.join(dedup.directory,'blocked'),'file');
 dedup.directory=path.join(dedup.directory,'blocked');
 const m={id:1,method:'turn/start',params:{threadId:'t',clientUserMessageId:'x'}};
 assert.equal((await dedup.begin(m,r=>sent.push(r))).duplicate,true);
 assert.equal(sent[0].error.code,-32092);
 assert.equal(dedup.rows.size,0);
});

test('ambiguous failure remains unknown across restart and preserves identity',async t=>{
 const dedup=await fixture(t),m={id:1,method:'turn/start',params:{threadId:'t',clientUserMessageId:'x'}};
 await dedup.begin(m,()=>{});await dedup.settle(m,{error:{code:-32000,message:'timeout'}});
 const next=new SubmissionDedup({directory:dedup.directory}),sent=[];
 assert.equal((await next.begin({...m,id:8},r=>sent.push(r))).duplicate,true);
 assert.equal(sent[0].id,8);assert.equal(sent[0].error.code,-32091);
});
