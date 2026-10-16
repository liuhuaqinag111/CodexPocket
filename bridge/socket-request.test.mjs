import test from 'node:test';
import assert from 'node:assert/strict';
import {EventEmitter} from 'node:events';
import {requestSocket} from './socket-request.mjs';
test('concurrent socket requests retain request identity and release all listeners',async()=>{
 const socket=new EventEmitter(),sent=[];
 socket.readyState=1;socket.send=raw=>sent.push(JSON.parse(raw));
 const a=requestSocket(socket,'thread/read',{threadId:'same'});
 const b=requestSocket(socket,'thread/read',{threadId:'same'});
 assert.notEqual(sent[0].id,sent[1].id);
 socket.emit('message',JSON.stringify({id:sent[1].id,result:{name:'second'}}));
 socket.emit('message',JSON.stringify({id:sent[0].id,result:{name:'first'}}));
 assert.deepEqual(await a,{name:'first'});assert.deepEqual(await b,{name:'second'});
 assert.equal(socket.listenerCount('message'),0);assert.equal(socket.listenerCount('close'),0);
});
test('a closed socket settles its own pending request',async()=>{
 const socket=new EventEmitter();socket.readyState=1;socket.send=()=>{};
 const response=requestSocket(socket,'thread/read',{});socket.emit('close');
 assert.equal(await response,null);assert.equal(socket.listenerCount('message'),0);
});
