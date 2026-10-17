import test from 'node:test';
import assert from 'node:assert/strict';
import {DesktopOwner} from './desktop-owner.mjs';

test('desktop-owned idle turn is forwarded once with its submission id',async()=>{
 const sent=[];
 const owner=new DesktopOwner({rpc:async(method,params,options)=>{
  sent.push({method,params,options});
  if(method==='thread-owner-discovery')return{handledByClientId:'desktop'};
  return{result:{result:{turn:{id:'accepted'}}}};
 }});
 const message={method:'turn/start',params:{threadId:'t',input:[{type:'text',text:'hello'}],
  clientUserMessageId:'submission'}};
 assert.deepEqual(await owner.forward(message),{turn:{id:'accepted'}});
 assert.equal(sent[1].method,'thread-follower-start-turn');
 assert.equal(sent[1].params.turnStart.request.clientUserMessageId,'submission');
 assert.equal(sent[1].options.targetClientId,'desktop');
});

test('desktop resume reads metadata without acquiring a second writer',async()=>{
 const owner=new DesktopOwner({rpc:async()=>({handledByClientId:'desktop'}),
  readThread:async id=>({thread:{id,model:'current'}})});
 assert.equal((await owner.forward({method:'thread/resume',params:{threadId:'t'}})).thread.id,'t');
});
