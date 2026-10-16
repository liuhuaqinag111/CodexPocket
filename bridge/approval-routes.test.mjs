import test from 'node:test';
import assert from 'node:assert/strict';
import {ApprovalRoutes} from './approval-routes.mjs';
test('same native id on writer and shared sockets remains isolated and single-use',async()=>{
 const sent=[],replies=[],routes=new ApprovalRoutes({broadcast:m=>sent.push(m)});
 const m={id:7,method:'item/commandExecution/requestApproval',params:{}};
 routes.register('writer',m,r=>replies.push(['writer',r]));
 routes.register('socket',m,r=>replies.push(['socket',r]));
 assert.notEqual(sent[0].id,sent[1].id);
 await routes.reply({id:sent[0].id,result:{decision:'accept'}});
 await routes.reply({id:sent[0].id,result:{decision:'decline'}});
 routes.drop('socket');
 await routes.reply({id:sent[1].id,result:{decision:'accept'}});
 assert.deepEqual(replies,[['writer',{id:7,result:{decision:'accept'}}]]);
 assert.equal(routes.pending.size,0);
});

test('replay keeps unresolved approval and targeted drop preserves others',()=>{
 const sent=[],routes=new ApprovalRoutes({broadcast:m=>sent.push(m)});
 routes.register('writer-a',{id:1,method:'approval'},()=>{});
 routes.register('writer-b',{id:2,method:'approval'},()=>{});
 const ids=sent.map(m=>m.id);
 routes.drop('writer-a',1);
 const replay=[];routes.replay(m=>replay.push(m.id));
 assert.deepEqual(replay,[ids[1]]);
});

test('failed approval reply stays pending and is replayable',async()=>{
 const sent=[],routes=new ApprovalRoutes({broadcast:m=>sent.push(m)});
 let fail=true;
 routes.register('writer',{id:3,method:'approval'},async()=>{if(fail)throw new Error('socket closed');});
 const id=sent[0].id;
 assert.equal(await routes.reply({id,result:{decision:'accept'}}),true);
 assert.equal(routes.pending.has(id),true);
 fail=false;
 assert.equal(await routes.reply({id,result:{decision:'accept'}}),true);
 assert.equal(routes.pending.has(id),false);
});

test('an unavailable approval route cannot be reported as resolved',async()=>{
 const sent=[],routes=new ApprovalRoutes({broadcast:m=>sent.push(m)});
 routes.register('writer',{id:5,method:'approval'},()=>false);
 await routes.reply({id:sent[0].id,result:{decision:'accept'}});
 assert.equal(routes.pending.size,1);
 assert.equal(sent.length,1);
});
