export async function restartIdleUpstream({snapshot,request,restart}) {
 const initial=snapshot();if(initial.busy)return false;
 const valid=()=>{const now=snapshot();return !now.busy&&now.epoch===initial.epoch;};
 try {
  const loaded=await request('thread/loaded/list',{});
  if(!valid()||!Array.isArray(loaded?.data)||loaded.nextCursor)return false;
  for(const id of loaded.data){
   const result=await request('thread/read',{threadId:id,includeTurns:false});
   if(!valid()||result?.thread?.id!==id||!['idle','systemError'].includes(result.thread.status?.type))return false;
   for(const method of ['thread/queue/list','thread/backgroundTerminals/list']){
    const result=await request(method,{threadId:id});
    if(!valid()||!Array.isArray(result?.data)||result.data.length||result.nextCursor)return false;
   }
  }
  if(!valid())return false;
  return restart()!==false;
 }catch{return false;}
}
