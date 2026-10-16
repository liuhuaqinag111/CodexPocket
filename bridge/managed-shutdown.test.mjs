import test from 'node:test';
import assert from 'node:assert/strict';
import {EventEmitter} from 'node:events';
import {installManagedShutdown} from './managed-shutdown.mjs';
test('managed shutdown awaits only its own writer processes before exit',async()=>{
 const owner=new EventEmitter(),order=[];
 owner.exit=code=>order.push('exit:'+code);
 const workers={entries:new Map([['one',{worker:{forceClose:async()=>{await Promise.resolve();order.push('writer');}}}]])};
 installManagedShutdown({workers,owner,upstream:()=>({terminate:()=>order.push('upstream')})});
 owner.emit('message',{command:'shutdown'});await new Promise(resolve=>setImmediate(resolve));
 assert.deepEqual(order,['writer','upstream','exit:0']);
});
