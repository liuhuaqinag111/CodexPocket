import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {loadConfig} from './config.mjs';
import {ConnectorManager} from './processes.mjs';
async function freePort(){const server=net.createServer();await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const port=server.address().port;await new Promise(resolve=>server.close(resolve));return port;}
test('real isolated bridge and synthetic Codex start, initialize and shut down without orphan processes',async t=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'pocket-lifecycle-'));
 t.after(()=>fs.rm(dir,{recursive:true,force:true}));
 const config=await loadConfig({dataDir:dir});config.bridgePort=await freePort();config.upstreamPort=await freePort();
 const children=[],fixture=fileURLToPath(new URL('./fixtures/mock-codex.mjs',import.meta.url));
 const manager=new ConnectorManager(config,{discover:async()=>'/synthetic/codex',
  probe:async()=>({version:'synthetic',explicitStdio:false,wsAuth:false}),
  spawnProcess:(file,args,options)=>{
   const child=spawn(file==='/synthetic/codex'?process.execPath:file,
    file==='/synthetic/codex'?[fixture,...args]:args,{...options,env:{...options.env,CODEX_HOME:dir}});
   children.push(child);return child;
  }});
 t.after(()=>manager.stop());
 await manager.start();assert.equal(manager.status().running,true);
 const status=await (await fetch('http://127.0.0.1:'+config.bridgePort+'/status')).json();
 assert.equal(status.upstreamReady,true);assert.equal(status.writerWorkers,0);
 const pids=children.map(child=>child.pid);await manager.stop();
 assert.equal(manager.status().running,false);
 for(const pid of pids)assert.throws(()=>process.kill(pid,0));
});
