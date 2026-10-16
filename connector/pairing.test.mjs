import test from 'node:test';
import assert from 'node:assert/strict';
import {pairingURL,normalizeEndpoint} from './pairing.mjs';
test('pairing requires the users own secure external endpoint',()=>{
 for(const endpoint of ['', 'ws://pc/ws','wss://user:pass@pc/ws','wss://pc/ws?t=secret','wss://pc/ws#x'])
  assert.throws(()=>pairingURL({externalURL:endpoint,token:'abc',name:'PC'}));
 assert.equal(normalizeEndpoint('https://pc.example.com/'),'wss://pc.example.com/ws');
});
test('pair format is fixed and round-trips Unicode without exposing token in URL parameters',()=>{
 const url=new URL(pairingURL({externalURL:'wss://pc.example.com/ws',token:'abc',name:'我的电脑'}));
 assert.equal(url.protocol,'codexpocket:');assert.equal(url.hostname,'pair');
 assert.deepEqual(JSON.parse(Buffer.from(url.searchParams.get('data'),'base64url')),
  {version:1,endpoint:'wss://pc.example.com/ws',token:'abc',name:'我的电脑'});
 assert.equal(url.searchParams.size,1);
});
