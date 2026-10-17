import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import {randomUUID} from 'node:crypto';

export function desktopEndpoint({platform=process.platform,env=process.env,home=os.homedir()}={}){
 return env.CODEX_DESKTOP_IPC || (platform==='win32'?'\\\\.\\pipe\\codex-ipc':
  path.posix.join(env.CODEX_HOME||path.posix.join(home,'.codex'),'ipc','ipc.sock'));
}
export async function desktopRequest(method,params,{targetClientId,timeoutMs=5000,
 endpoint=desktopEndpoint()}={}){
 const socket=net.createConnection(endpoint),pending=new Map();let buffer=Buffer.alloc(0);
 let clientId='initializing-client';
 function send(message){
  const data=Buffer.from(JSON.stringify(message)),header=Buffer.alloc(4);
  header.writeUInt32LE(data.length);socket.write(Buffer.concat([header,data]));
 }
 function fail(error){for(const p of pending.values())p.reject(error);pending.clear();}
 socket.on('error',fail);socket.on('close',()=>fail(Error('电脑连接已断开')));
 socket.on('data',chunk=>{
  buffer=Buffer.concat([buffer,chunk]);
  try{while(buffer.length>=4){
   const length=buffer.readUInt32LE(0);
   if(!length||length>268435456)throw Error('无效电脑消息');
   if(buffer.length<4+length)break;
   const message=JSON.parse(buffer.subarray(4,4+length));buffer=buffer.subarray(4+length);
   if(message.type==='client-discovery-request')send({type:'client-discovery-response',
    requestId:message.requestId,response:{canHandle:false}});
   if(message.type==='response'){
    const waiter=pending.get(message.requestId);if(!waiter)continue;
    pending.delete(message.requestId);
    if(message.resultType==='error')waiter.reject(Error(message.error));else waiter.resolve(message);
   }
  }}catch(error){fail(error);socket.destroy();}
 });
 function call(method,params,options={}){
  return new Promise((resolve,reject)=>{
   const requestId=randomUUID();pending.set(requestId,{resolve,reject});
   send({type:'request',requestId,sourceClientId:clientId,method,params,
    version:method==='initialize'?0:method==='thread-follower-start-turn'?2:1,
    timeoutMs,...options});
  });
 }
 const timer=setTimeout(()=>{fail(Error('电脑请求结果未确认'));socket.destroy();},timeoutMs);
 try{
  await new Promise((resolve,reject)=>{
   socket.once('connect',resolve);socket.once('error',reject);socket.once('close',()=>reject(Error('电脑连接失败')));
  });
  const init=await call('initialize',{clientType:'codexpocket'});
  clientId=init.result?.clientId;
  if(!clientId)throw Error('电脑未确认连接');
  return await call(method,params,{targetClientId});
 }finally{clearTimeout(timer);socket.destroy();}
}
