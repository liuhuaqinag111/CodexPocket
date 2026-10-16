import {randomUUID} from 'node:crypto';

export function requestSocket(sock,method,params,{timeout=20000}={}) {
 if(!sock||sock.readyState!==1)return Promise.resolve(null);
 return new Promise(resolve=>{
  const id='internal-'+randomUUID();let timer;
  const finish=result=>{
   clearTimeout(timer);sock.off('message',receive);sock.off('close',closed);resolve(result);
  };
  const closed=()=>finish(null);
  const receive=raw=>{
   let message;try{message=JSON.parse(String(raw));}catch{return;}
   if(message?.id===id&&!message.method)finish(message.error?null:message.result);
  };
  sock.on('message',receive);sock.once('close',closed);
  timer=setTimeout(closed,timeout);timer.unref?.();
  try{sock.send(JSON.stringify({id,method,params}),error=>{if(error)closed();});}
  catch{closed();}
 });
}
