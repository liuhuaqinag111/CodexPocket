export class ApprovalRoutes {
 constructor({broadcast,log=()=>{}}) {
  this.broadcast=broadcast;this.log=log;this.pending=new Map();this.sequence=-2000000;
 }
 register(source,request,reply) {
  const old=[...this.pending.values()].find(row=>row.source===source&&row.original===request.id);
  if(old)return;
  const id=--this.sequence;
  const message={...request,id};
  this.pending.set(id,{source,original:request.id,reply,message});
  this.broadcast(message);
 }
 replay(send) {for(const row of this.pending.values())send(row.message);}
 async reply(message) {
  const row=this.pending.get(message.id);
  if(!row)return false;
  if(row.replying)return true;
  row.replying=true;
  try {
   const ok=await row.reply({...message,id:row.original});
   if(ok===false){row.replying=false;return true;}
  }
  catch(error){row.replying=false;this.log('[approval] reply failed',error.message);return true;}
  this.pending.delete(message.id);
  this.broadcast({method:'bridge/approvalResolved',params:{requestId:message.id}});
  return true;
 }
 drop(source,original) {
  for(const [id,row] of this.pending)if(row.source===source&&(original===undefined||row.original===original)){
   this.pending.delete(id);
   this.broadcast({method:'bridge/approvalResolved',params:{requestId:id}});
  }
 }
}
