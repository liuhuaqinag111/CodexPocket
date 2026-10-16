import test from 'node:test';
import assert from 'node:assert/strict';
import {syncDirectory} from './durable-files.mjs';
test('Windows persists the file without attempting unsupported directory fsync',async()=>{
 await syncDirectory('C:\\data',{platform:'win32',open:async()=>assert.fail('directory open is unsupported on Windows')});
});
test('Unix directory fsync closes the descriptor even if sync fails',async()=>{
 let closed=false;
 await assert.rejects(syncDirectory('/data',{platform:'darwin',open:async()=>({sync:async()=>{throw new Error('disk');},close:async()=>{closed=true;}})}),/disk/);
 assert.equal(closed,true);
});
