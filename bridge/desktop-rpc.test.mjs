import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {desktopEndpoint,desktopRequest} from './desktop-rpc.mjs';

test('desktop endpoints match native Mac sockets and Windows named pipes',()=>{
 assert.equal(desktopEndpoint({platform:'win32',env:{},home:'x'}),'\\\\.\\pipe\\codex-ipc');
 assert.equal(desktopEndpoint({platform:'darwin',env:{CODEX_HOME:'/fixture'}}),'/fixture/ipc/ipc.sock');
});

test('desktop RPC handles split frames and discovery without replaying requests',async t=>{
 const id=randomUUID(),endpoint=process.platform==='win32'?'\\\\.\\pipe\\pocket-'+id:
  path.join(os.tmpdir(),'pocket-'+id+'.sock');
 const received=[],peers=new Set();
 const server=net.createServer(socket=>{
  peers.add(socket);socket.on('close',()=>peers.delete(socket));let bytes=Buffer.alloc(0);
  const send=value=>{
   const data=Buffer.from(JSON.stringify(value)),header=Buffer.alloc(4);header.writeUInt32LE(data.length);
   const frame=Buffer.concat([header,data]);socket.write(frame.subarray(0,3));socket.write(frame.subarray(3));
  };
  socket.on('data',chunk=>{
   bytes=Buffer.concat([bytes,chunk]);
   while(bytes.length>=4&&bytes.length>=4+bytes.readUInt32LE(0)){
    const size=bytes.readUInt32LE(0),m=JSON.parse(bytes.subarray(4,4+size));bytes=bytes.subarray(4+size);
    received.push(m);if(m.type!=='request')continue;
    if(m.method==='initialize')send({type:'client-discovery-request',requestId:'discovery'});
    send({type:'response',requestId:m.requestId,resultType:'success',handledByClientId:'desktop',
     result:m.method==='initialize'?{clientId:'phone'}:{result:{turn:{id:'turn'}}}});
   }
  });
 });
 await new Promise(resolve=>server.listen(endpoint,resolve));
 t.after(async()=>{for(const p of peers)p.destroy();await new Promise(resolve=>server.close(resolve));});
 const response=await desktopRequest('thread-follower-start-turn',{conversationId:'t'},
  {endpoint,targetClientId:'desktop'});
 assert.equal(response.result.result.turn.id,'turn');
 const requests=received.filter(m=>m.type==='request');assert.equal(requests.length,2);
 assert.equal(requests[1].sourceClientId,'phone');assert.equal(requests[1].version,2);
 assert.equal(requests[1].targetClientId,'desktop');assert.equal(requests[1].hostId,undefined);
 assert.ok(received.some(m=>m.type==='client-discovery-response'&&!m.response.canHandle));
});
