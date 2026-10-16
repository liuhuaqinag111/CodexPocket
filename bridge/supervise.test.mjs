import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

async function run(t,mode){
 const tmp=await fs.mkdtemp(path.join(os.tmpdir(),'pocket-supervisor-'));
 t.after(()=>fs.rm(tmp,{recursive:true,force:true}));
 await fs.copyFile(process.env.SUPERVISOR_UNDER_TEST||new URL('./supervise.sh',import.meta.url),path.join(tmp,'supervise.sh'));
 await fs.mkdir(path.join(tmp,'.codex'));
 await fs.writeFile(path.join(tmp,'.codex/cc-switch-model-catalog.json'),'{}');
 await fs.writeFile(path.join(tmp,'token'),'test-token');
 const prelude=await fs.readFile(new URL('./supervise-fixture.sh',import.meta.url),'utf8');
 const result=spawnSync('/bin/bash',['-c',prelude+'\nsource "$SCRIPT"'],{
  encoding:'utf8',timeout:5000,env:{...process.env,HOME:tmp,MODE:mode,
   TOKEN_FILE:path.join(tmp,'token'),SCRIPT:path.join(tmp,'supervise.sh')}});
 assert.equal(result.error,undefined);
 return result.stdout;
}
for(const mode of ['fd','catalog','health','occupied','status'])test('supervisor preserves processes during '+mode,async t=>{
 const output=await run(t,mode);
 assert.doesNotMatch(output,/SIGNAL/);
});
