import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {loadConfig} from '../connector/config.mjs';
import {ConnectorManager} from '../connector/processes.mjs';

async function freePort() {
 const server=net.createServer();
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const port=server.address().port;
 await new Promise(resolve=>server.close(resolve));return port;
}

test('portable bridge isolates mutable files and exits gracefully through IPC',async t=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'pocket-portable-'));
 t.after(()=>fs.rm(dir,{recursive:true,force:true}));
 const dataDir=path.join(dir,'Data'),home=path.join(dir,'Home');await fs.mkdir(home);
 const config=await loadConfig({dataDir});
 config.bridgePort=await freePort();config.upstreamPort=await freePort();
 await fs.writeFile(path.join(dataDir,'usage.json'),JSON.stringify({fixture:{usage:{total:7}}}));
 const children=[],fixture=fileURLToPath(new URL('../connector/fixtures/mock-codex.mjs',import.meta.url));
 const manager=new ConnectorManager(config,{discover:async()=>'/synthetic/codex',
  probe:async()=>({version:'synthetic',explicitStdio:false,wsAuth:false}),
  spawnProcess:(file,args,options)=>{
   const child=spawn(file==='/synthetic/codex'?process.execPath:file,
    file==='/synthetic/codex'?[fixture,...args]:args,{...options,cwd:home,
     env:{...options.env,HOME:home,CODEX_HOME:dir,CC_SWITCH_DB:path.join(dir,'absent.db')}});
   children.push(child);return child;
  }});
 t.after(()=>manager.stop());await manager.start();
 const base='http://127.0.0.1:'+config.bridgePort;
 const headers={Authorization:'Bearer '+config.token};
 const usage=await (await fetch(base+'/usage?threadId=fixture',{headers})).json();
 assert.equal(usage.usage?.total,7);
 const frames=await fetch(base+'/framelog',{method:'POST',headers,body:'fixture frame'});
 assert.equal(frames.status,200);
 assert.equal(await fs.readFile(path.join(dataDir,'frames.log'),'utf8'),'fixture frame');
 const uploaded=await (await fetch(base+'/upload?name=fixture.jpg',{
  method:'POST',headers,body:'image fixture'})).json();
 assert.equal(path.dirname(uploaded.path),path.join(dataDir,'uploads'));
 assert.equal(await fs.readFile(uploaded.path,'utf8'),'image fixture');
 const page=await fetch(base+'/',{headers});assert.equal(page.status,200);
 assert.match(await page.text(),/CodexPocket/);
 await assert.rejects(fs.access(path.join(home,'.codex','phone')));
 const bridge=children[1];await manager.stop();
 assert.equal(bridge.exitCode,0);assert.equal(bridge.signalCode,null);
});
