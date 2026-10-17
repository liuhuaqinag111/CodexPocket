import {desktopRequest} from './desktop-rpc.mjs';

export class DesktopOwner {
 constructor({rpc=desktopRequest,readThread}={}){this.rpc=rpc;this.readThread=readThread;}
 async owner(threadId){
  try{
   const response=await this.rpc('thread-owner-discovery',{hostId:'local',conversationId:threadId});
   return response.handledByClientId;
  }catch(error){if(error.message==='no-client-found')return null;throw error;}
 }
 async forward({method,params}){
  if(!['thread/resume','turn/start'].includes(method))return null;
  const targetClientId=await this.owner(params.threadId);
  if(!targetClientId)return null;
  if(method==='thread/resume'){
   if(Object.keys(params).some(k=>!['threadId','excludeTurns'].includes(k)))return null;
   return this.readThread(params.threadId);
  }
  const response=await this.rpc('thread-follower-start-turn',{
   conversationId:params.threadId,
   turnStart:{request:params,context:{inheritThreadSettings:true}}
  },{targetClientId,timeoutMs:120000});
  if(!response.result?.result?.turn?.id)throw Error('桌面未确认发送结果，请先核对会话历史');
  return response.result.result;
 }
}
