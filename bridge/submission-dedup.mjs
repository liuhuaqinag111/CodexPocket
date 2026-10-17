import fs from 'node:fs/promises';
import path from 'node:path';
import {createHash,randomUUID} from 'node:crypto';

const UNKNOWN={code:-32091,message:'提交结果未知，请先查询会话历史或队列'};
const rejected=e=>e&&([-32600,-32601,-32602].includes(e.code)||
 /active writer|not initialized|thread not found|expected active turn/i.test(e.message||''));
const acknowledged=record=>record?.state==='ack'&&record.result&&
 typeof record.result==='object'&&!record.result.error&&Object.hasOwn(record.result,'result');

export class SubmissionDedup {
 constructor({directory}={}) {
  this.directory=directory||path.join(process.env.CODEX_PHONE_DIR||process.env.HOME+'/.codex/phone','submissions');
  this.rows=new Map();
  this.revision=0;
 }
 key(m) {
  if(!['turn/start','turn/steer','thread/queue/add'].includes(m?.method))return null;
  const p=m.params||{};
  return p.threadId&&p.clientUserMessageId?JSON.stringify([p.threadId,p.clientUserMessageId]):null;
 }
 filename(key) { return path.join(this.directory,createHash('sha256').update(key).digest('hex')+'.json'); }
 async persist(key,value) {
  await fs.mkdir(this.directory,{recursive:true});
  const name=this.filename(key),tmp=name+'.'+randomUUID()+'.tmp';
  const file=await fs.open(tmp,'wx',0o600);
  try {await file.writeFile(JSON.stringify(value));await file.sync();}finally{await file.close();}
  await fs.rename(tmp,name);
  const dir=await fs.open(this.directory,'r');try{await dir.sync();}finally{await dir.close();}
 }
 async prepare(key) {
  try {
   const old=JSON.parse(await fs.readFile(this.filename(key),'utf8'));
   return {result:acknowledged(old)?old.result:{error:UNKNOWN},stored:true};
  }
  catch(error){if(error.code!=='ENOENT')throw error;}
  await this.persist(key,{state:'intent'});
  return {result:null,stored:false};
 }
 async status(params) {
  if(typeof params?.threadId!=='string'||!params.threadId||
     typeof params?.clientUserMessageId!=='string'||!params.clientUserMessageId)
   throw new TypeError('threadId and clientUserMessageId are required');
  const key=JSON.stringify([params.threadId,params.clientUserMessageId]);
  const revision=this.revision;
  if(this.rows.has(key))return {state:'pending'};
  let record;
  try { record=JSON.parse(await fs.readFile(this.filename(key),'utf8')); }
  catch(error) {
   if(error.code!=='ENOENT')return this.rows.has(key)?{state:'pending'}:{state:'unknown'};
   if(this.rows.has(key))return {state:'pending'};
   return {state:this.revision===revision?'missing':'unknown'};
  }
  if(this.rows.has(key))return {state:'pending'};
  if(acknowledged(record))return {state:'accepted',result:record.result};
  return {state:'unknown'};
 }
 async begin(message,reply) {
  const key=this.key(message);if(!key)return {duplicate:false};
  const old=this.rows.get(key);
  if(old){old.replies.push({id:message.id,reply});return {duplicate:true};}
  if(this.rows.size>=500){
   reply({id:message.id,error:{code:-32093,message:'待发队列已满，消息未发出'}});
   return {duplicate:true};
  }
  const row={replies:[{id:message.id,reply}]};this.revision++;this.rows.set(key,row);
  try {
   const saved=await this.prepare(key);
   if(saved.stored){this.deliver(key,saved.result);return {duplicate:true};}
   return {duplicate:false};
  }catch(error){
   this.deliver(key,{error:error instanceof SyntaxError?UNKNOWN:
    {code:-32092,message:'提交记录保存失败，消息未发出'}});
   return {duplicate:true};
  }
 }
 deliver(key,result){
  const row=this.rows.get(key);if(!row)return;
  for(const waiter of row.replies)waiter.reply({...result,id:waiter.id});
  this.rows.delete(key);
 }
 async settle(message,result) {
  const key=this.key(message),row=key&&this.rows.get(key);if(!row)return false;
  if(result.error&&rejected(result.error)){
   try{await fs.unlink(this.filename(key));}catch(error){if(error.code!=='ENOENT')return this.deliver(key,{error:UNKNOWN});}
   this.deliver(key,result);return true;
  }
  const saved=result.error?{state:'unknown',result:{error:UNKNOWN}}:{state:'ack',result:{...result,id:undefined}};
  try{await this.persist(key,saved);}catch{saved.result={error:UNKNOWN};}
  this.deliver(key,saved.result);return true;
 }
}
