import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {defaultDataDir,loadConfig,saveConfig} from './config.mjs';

test('Windows data stays in LOCALAPPDATA without changing CODEX_HOME',()=>{
 assert.equal(defaultDataDir({platform:'win32',env:{LOCALAPPDATA:'C:\\Users\\test\\AppData\\Local'},home:'C:\\Users\\test'}),
  path.win32.join('C:\\Users\\test\\AppData\\Local','CodexPocketConnector'));
});
test('initialization creates stable, separate private random credentials',async t=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'pocket-config-'));
 t.after(()=>fs.rm(dir,{recursive:true,force:true}));
 const a=await loadConfig({dataDir:dir}),b=await loadConfig({dataDir:dir});
 assert.match(a.token,/^[a-f0-9]{64}$/);assert.equal(a.token,b.token);
 assert.notEqual(a.token,a.adminToken);assert.equal(a.externalURL,'');
 if(process.platform!=='win32')assert.equal((await fs.stat(a.tokenFile)).mode&0o777,0o600);
 await saveConfig(a,{name:'My PC',externalURL:'wss://pc.example.com/ws'});
 assert.equal((await loadConfig({dataDir:dir})).name,'My PC');
});
