import test from 'node:test';
import assert from 'node:assert/strict';
import {enableTailscale} from './tailscale.mjs';
test('does not overwrite existing services when both supported HTTPS ports are occupied',async()=>{
 const calls=[];
 await assert.rejects(enableTailscale({port:62113,run:async(_file,args)=>{
  calls.push(args);return {stdout:JSON.stringify(args[0]==='status'?
   {BackendState:'Running',Self:{DNSName:'pc.example.ts.net.'}}:
   {TCP:{443:{HTTPS:true},8443:{HTTPS:true}},Web:{
    'pc.example.ts.net:443':{Handlers:{'/':{Proxy:'http://127.0.0.1:8080'}}},
    'pc.example.ts.net:8443':{Handlers:{'/':{Proxy:'http://127.0.0.1:8081'}}}}})};
 }}),/已有/);
 assert.equal(calls.some(args=>args.includes('--bg')),false);
});
test('uses free 8443 without replacing another service on 443',async()=>{
 const domain='pc.example.ts.net',target='http://127.0.0.1:62113';
 const current={TCP:{443:{HTTPS:true}},Web:{[domain+':443']:{Handlers:{'/':{Proxy:'http://127.0.0.1:8080'}}}}};
 const before=JSON.stringify(current.Web[domain+':443']);let selected;
 const endpoint=await enableTailscale({port:62113,run:async(_file,args)=>{
  if(args[0]==='status')return {stdout:JSON.stringify({BackendState:'Running',Self:{DNSName:domain+'.'}})};
  if(args.includes('--bg')){selected=args.find(arg=>arg.startsWith('--https='));current.TCP[8443]={HTTPS:true};current.Web[domain+':8443']={Handlers:{'/':{Proxy:target}}};return {stdout:''};}
  return {stdout:JSON.stringify(current)};
 }});
 assert.equal(selected,'--https=8443');assert.equal(endpoint,'wss://'+domain+':8443/ws');
 assert.equal(JSON.stringify(current.Web[domain+':443']),before);
});
test('creates private HTTPS serve and returns secure pairing endpoint',async()=>{
 let serving=false;
 const endpoint=await enableTailscale({port:62113,run:async(_file,args)=>{
  if(args[0]==='status')return {stdout:JSON.stringify({BackendState:'Running',Self:{DNSName:'pc.example.ts.net.'}})};
  if(args.includes('--bg')){serving=true;assert.equal(args.at(-1),'http://127.0.0.1:62113');return {stdout:''};}
  return {stdout:JSON.stringify(serving?{TCP:{443:{HTTPS:true}},Web:{'pc.example.ts.net:443':{Handlers:{'/':{Proxy:'http://127.0.0.1:62113'}}}}}:{})};
 }});
 assert.equal(endpoint,'wss://pc.example.ts.net/ws');
});
test('already-owned 8443 remains valid beside other ports and Funnel services',async()=>{
 const calls=[],domain='pc.example.ts.net';
 const current={TCP:{443:{HTTPS:true},8443:{HTTPS:true},10000:{HTTPS:true}},Web:{
  [domain+':443']:{Handlers:{'/':{Proxy:'http://127.0.0.1:8080'}}},
  [domain+':8443']:{Handlers:{'/':{Proxy:'http://127.0.0.1:62113'}}},
  [domain+':10000']:{Handlers:{'/':{Proxy:'http://127.0.0.1:8090'}}}},AllowFunnel:{[domain+':10000']:true}};
 const endpoint=await enableTailscale({port:62113,run:async(_file,args)=>{
  calls.push(args);return {stdout:JSON.stringify(args[0]==='status'?{BackendState:'Running',Self:{DNSName:domain}}:current)};
 }});
 assert.equal(endpoint,'wss://'+domain+':8443/ws');
 assert.equal(calls.some(args=>args.includes('--bg')),false);
});
test('an otherwise-owned public Funnel route is not accepted for private pairing',async()=>{
 const domain='pc.example.ts.net',target='http://127.0.0.1:62113';
 const current={TCP:{443:{HTTPS:true}},Web:{[domain+':443']:{Handlers:{'/':{Proxy:target}}}},AllowFunnel:{[domain+':443']:true}};
 const endpoint=await enableTailscale({port:62113,run:async(_file,args)=>{
  if(args[0]==='status')return {stdout:JSON.stringify({BackendState:'Running',Self:{DNSName:domain}})};
  if(args.includes('--bg')){assert.ok(args.includes('--https=8443'));current.TCP[8443]={HTTPS:true};current.Web[domain+':8443']={Handlers:{'/':{Proxy:target}}};return {stdout:''};}
  return {stdout:JSON.stringify(current)};
 }});
 assert.equal(endpoint,'wss://'+domain+':8443/ws');assert.equal(current.AllowFunnel[domain+':443'],true);
});
