export class RequestRoutes {
 constructor({send,timeout=120000,onSettled=()=>{}}) {
  Object.assign(this,{send,timeout,onSettled});this.requests=new Map();this.sequence=0;
 }
 register(client,message,respond) {
  if(!message.method||message.id===undefined)return message;
  const id='client-rpc-'+(++this.sequence);
  const entry={client,original:message.id,method:message.method,respond};
  entry.timer=setTimeout(()=>this.deliver({id,error:{code:-32000,message:'请求超时'}}),this.timeout);
  entry.timer.unref?.();this.requests.set(id,entry);
  return {...message,id};
 }
 deliver(message) {
  const entry=this.requests.get(message.id);
  if(!entry)return false;
  this.requests.delete(message.id);clearTimeout(entry.timer);
  this.onSettled(entry.method,message.id,message);
  const result={...message,id:entry.original};
  if(entry.respond)entry.respond(result);else if(entry.client)this.send(entry.client,result);return true;
 }
 drop(client) {
  const dropped=[];
  for(const [id,entry] of this.requests)if(entry.client===client){
   entry.client=null;dropped.push(id);
  }
  return dropped;
 }
 failAll(error={code:-32001,message:'上游连接已断开'}) {
  for(const [id,entry] of [...this.requests]){
   this.requests.delete(id);clearTimeout(entry.timer);
   this.onSettled(entry.method,id,{id,error});
   if(entry.respond)entry.respond({id:entry.original,error});else if(entry.client)this.send(entry.client,{id:entry.original,error});
  }
 }
 isPending(message) {
  return !String(message.id).startsWith('client-rpc-')||!!this.requests.get(message.id)?.client;
 }
}
