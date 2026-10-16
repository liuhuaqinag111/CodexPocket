import test from 'node:test';
import assert from 'node:assert/strict';
import {restartIdleUpstream} from './upstream-maintenance.mjs';

function fixture(overrides={}) {
 const calls=[],state={epoch:0,busy:false},restarts=[];
 const request=async(method)=>{
  calls.push(method);
  if(method==='thread/read')return {thread:{id:'t',status:{type:'idle'}}};
  return {data:method==='thread/loaded/list'?['t']:[],nextCursor:null};
 };
 return {calls,state,restarts,options:{snapshot:()=>({...state}),request,
  restart:()=>{restarts.push('restart');},...overrides}};
}
test('idle restart refuses active requests, approvals, and disconnected upstream',async()=>{
 const f=fixture();f.state.busy=true;
 assert.equal(await restartIdleUpstream(f.options),false);
 assert.deepEqual(f.calls,[]);assert.deepEqual(f.restarts,[]);
});
test('idle restart inspects loaded threads, queued work, and terminals',async()=>{
 const f=fixture();assert.equal(await restartIdleUpstream(f.options),true);
 assert.deepEqual(f.calls,['thread/loaded/list','thread/read','thread/queue/list','thread/backgroundTerminals/list']);
 assert.equal(f.restarts.length,1);
});
test('active threads, queued work, terminals, and unknown state prevent restart',async()=>{
 for(const [method,result] of [
  ['thread/loaded/list',null],['thread/loaded/list',{data:['t'],nextCursor:'next'}],
  ['thread/read',{thread:{id:'t',status:{type:'active'}}}],
  ['thread/queue/list',{data:[{id:'q'}]}],
  ['thread/backgroundTerminals/list',{data:[{id:'cmd'}]}],
 ]){
  const f=fixture(),base=f.options.request;
  f.options.request=m=>m===method?result:base(m);
  assert.equal(await restartIdleUpstream(f.options),false,method);
  assert.deepEqual(f.restarts,[]);
 }
});
test('request or notification during inspection cancels maintenance',async()=>{
 const f=fixture(),base=f.options.request;
 f.options.request=async m=>{const value=await base(m);f.state.epoch++;return value;};
 assert.equal(await restartIdleUpstream(f.options),false);
 assert.deepEqual(f.restarts,[]);
});
