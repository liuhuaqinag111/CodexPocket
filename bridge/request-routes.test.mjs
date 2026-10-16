import test from 'node:test';
import assert from 'node:assert/strict';
import {RequestRoutes} from './request-routes.mjs';
test('timeout and disconnect never deliver an old reply to a new connection',async()=>{
 const sent=[],settled=[];
 const routes=new RequestRoutes({send:(c,m)=>sent.push([c,m]),timeout:10,onSettled:m=>settled.push(m)});
 const old=routes.register('a',{id:1,method:'thread/archive'});
 routes.drop('a');assert.equal(routes.isPending(old),false);
 const fresh=routes.register('b',{id:1,method:'config/read'});
 routes.deliver({id:old.id,result:{}});assert.equal(sent.length,0);
 assert.deepEqual(settled,['thread/archive']);
 await new Promise(r=>setTimeout(r,20));
 assert.equal(sent.length,1);assert.equal(sent[0][0],'b');assert.equal(sent[0][1].id,1);
 assert.ok(sent[0][1].error);
 assert.equal(routes.deliver({id:fresh.id,result:{late:true}}),false);
});
