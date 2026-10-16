import test from 'node:test';
import assert from 'node:assert/strict';
import {EventEmitter} from 'node:events';
import {PassThrough} from 'node:stream';
import path from 'node:path';
import fs from 'node:fs/promises';
import os from 'node:os';
import {ConnectorManager} from './processes.mjs';
function fixture(overrides={}) {
 const children=[],calls=[];
 const config={dataDir:'/fixture/data',tokenFile:'/fixture/token',token:'private-token',adminToken:'private-admin',
  bridgePort:63713,upstreamPort:63715,name:'PC',externalURL:'',configFile:'/fixture/config'};
 const manager=new ConnectorManager(config,{discover:async()=>'/fixture/codex',
  probe:async()=>({version:'test',explicitStdio:false,wsAuth:true}),checkPorts:async()=>{},wait:async()=>{},
  spawnProcess:(file,args,options)=>{const child=new EventEmitter();child.stdout=new PassThrough();child.stderr=new PassThrough();
   child.exitCode=null;child.kill=()=>{child.exitCode=0;child.emit('exit',0);return true;};
   children.push(child);calls.push({file,args,options});return child;},...overrides});
 return {manager,children,calls,config};
}
test('owns exactly two loopback children and preserves CODEX_HOME/provider environment',async()=>{
 const f=fixture();await Promise.all([f.manager.start(),f.manager.start()]);
 assert.equal(f.calls.length,2);assert.equal(f.manager.status().running,true);
 assert.ok(f.calls[0].args.includes('ws://127.0.0.1:63715'));
 assert.equal(f.calls[1].options.env.BIND,'127.0.0.1');
 assert.equal(f.calls[1].options.env.CODEX_HOME,process.env.CODEX_HOME);
 assert.equal(f.calls[0].options.env.PATH.split(path.delimiter)[0],path.dirname(process.execPath));
 assert.equal(f.calls[1].options.env.CODEX_APP_SERVER_STDIO,'default');
 assert.equal(f.calls[1].options.env.SUBMISSION_DIR,path.join(f.config.dataDir,'submissions'));
 assert.equal(f.calls[1].options.env.IPA_PATH,path.join(f.config.dataDir,'CodexPocket.ipa'));
 await f.manager.stop();assert.ok(f.children.every(child=>child.exitCode===0));
});
test('failed bridge readiness stops only owned children and retains failure',async()=>{
 const f=fixture({wait:async(url)=>{if(url.endsWith('/status'))throw new Error('bridge did not initialize');}});
 await assert.rejects(f.manager.start(),/did not initialize/);
 assert.equal(f.children.length,2);assert.ok(f.children.every(child=>child.exitCode===0));
 assert.equal(f.manager.status().running,false);assert.match(f.manager.status().error,/initialize/);
});
test('a conflicting port never kills another app or launches children',async()=>{
 const f=fixture({checkPorts:async()=>{throw new Error('port already used');}});
 await assert.rejects(f.manager.start(),/port already used/);assert.equal(f.children.length,0);
});
test('unexpected child failure stops sibling, and logs never reveal credentials',async()=>{
 const f=fixture();await f.manager.start();
 f.children[0].stderr.write('private-token private-admin');
 assert.ok(!JSON.stringify(f.manager.status()).includes('private-token'));
 f.children[0].exitCode=2;f.children[0].emit('exit',2);
 await new Promise(resolve=>setTimeout(resolve,10));
 assert.equal(f.children[1].exitCode,0);assert.equal(f.manager.status().running,false);
});
test('credentials split across stderr chunks are redacted as one log line',async()=>{
 const f=fixture();await f.manager.start();
 f.children[0].stderr.write('connection private-');
 assert.equal(f.manager.status().logs.length,0);
 f.children[0].stderr.write('token private-admin\n');
 assert.deepEqual(f.manager.status().logs,['Codex: connection [redacted] [redacted]']);
 await f.manager.stop();
});
test('CC Switch custom provider starts without official login and preserves config plus environment',async t=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'pocket-custom-provider-'));
 const custom={CODEX_HOME:dir,OPENAI_BASE_URL:'https://relay.example/v1',OPENAI_API_KEY:'SYNTHETIC_KEY',
  HTTP_PROXY:'http://127.0.0.1:18888',HTTPS_PROXY:'http://127.0.0.1:18888'};
 const previous=Object.fromEntries(Object.keys(custom).map(key=>[key,process.env[key]]));
 t.after(async()=>{for(const [key,value] of Object.entries(previous)) {
  if(value===undefined)delete process.env[key];else process.env[key]=value;
 }await fs.rm(dir,{recursive:true,force:true});});
 Object.assign(process.env,custom);
 const file=path.join(dir,'config.toml'),source='model_provider = "cc-switch"\n[model_providers.cc-switch]\nbase_url = "http://127.0.0.1:15721/v1"\nexperimental_bearer_token = "PROXY_MANAGED"\nrequires_openai_auth = false\n';
 await fs.writeFile(file,source);
 const f=fixture();await f.manager.start();
 for(const call of f.calls)for(const [key,value] of Object.entries(custom))assert.equal(call.options.env[key],value,key);
 assert.ok(f.calls.every(call=>!call.args.includes('login')));
 assert.equal(await fs.readFile(file,'utf8'),source);
 await assert.rejects(fs.access(path.join(dir,'auth.json')),{code:'ENOENT'});
 await f.manager.stop();
});
