import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {startControlServer} from './control.mjs';
async function fixture(t) {
 const calls=[],manager={status:()=>({running:false,endpoint:null}),start:async()=>{calls.push('start');return {running:true};},
  stop:async()=>({running:false}),configure:async patch=>patch,pair:()=>({uri:'codexpocket://pair?data=test',name:'PC',endpoint:'wss://pc/ws'}),
  enableTailscale:async()=>({endpoint:'wss://pc.ts.net/ws'})};
 const server=await startControlServer({manager,adminToken:'private-admin'});
 t.after(()=>new Promise(resolve=>server.close(resolve)));
 return {base:'http://127.0.0.1:'+server.address().port,calls};
}
test('control API rejects unauthenticated and foreign browser requests',async t=>{
 const f=await fixture(t);
 assert.equal((await fetch(f.base+'/api/status')).status,401);
 assert.equal((await fetch(f.base+'/api/status',{headers:{authorization:'Bearer private-admin',origin:'https://attacker.example'}})).status,403);
 const foreignHost=await new Promise((resolve,reject)=>{
  const req=http.get(f.base+'/api/status',{headers:{authorization:'Bearer private-admin',host:'attacker.example'}},res=>{res.resume();resolve(res.statusCode);});
  req.on('error',reject);
 });
 assert.equal(foreignHost,403);
 const good=await fetch(f.base+'/api/status',{headers:{authorization:'Bearer private-admin',origin:f.base}});
 assert.equal(good.status,200);assert.equal((await good.json()).running,false);
});
test('authenticated local control can start, pair and configure Tailscale',async t=>{
 const f=await fixture(t),headers={authorization:'Bearer private-admin','content-type':'application/json'};
 assert.equal((await (await fetch(f.base+'/api/start',{method:'POST',headers,body:'{}'})).json()).running,true);
 assert.deepEqual(f.calls,['start']);
 assert.match((await (await fetch(f.base+'/api/pair',{headers})).json()).uri,/codexpocket:/);
 assert.equal((await (await fetch(f.base+'/api/tailscale',{method:'POST',headers,body:'{}'})).json()).endpoint,'wss://pc.ts.net/ws');
});
test('control rejects invalid or oversized JSON and never reads arbitrary static files',async t=>{
 const f=await fixture(t),headers={authorization:'Bearer private-admin','content-type':'application/json'};
 assert.equal((await fetch(f.base+'/api/config',{method:'POST',headers,body:'not json'})).status,400);
 assert.equal((await fetch(f.base+'/api/config',{method:'POST',headers,body:JSON.stringify({name:'x'.repeat(17000)})})).status,413);
 assert.equal((await fetch(f.base+'/assets/%2e%2e/config.mjs')).status,404);
});
