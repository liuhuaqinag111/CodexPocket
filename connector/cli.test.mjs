import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {fileURLToPath} from 'node:url';
const run=promisify(execFile),cli=fileURLToPath(new URL('./cli.mjs',import.meta.url));
test('init and offline status use isolated user data without credentials in output',async t=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'pocket-cli-'));
 t.after(()=>fs.rm(dir,{recursive:true,force:true}));
 const a=await run(process.execPath,[cli,'init','--data-dir',dir,'--name','Test PC']);
 assert.equal(JSON.parse(a.stdout).name,'Test PC');
 const token=(await fs.readFile(path.join(dir,'connector-token'),'utf8')).trim();
 assert.ok(!a.stdout.includes(token));
 const b=await run(process.execPath,[cli,'status','--data-dir',dir]);
 assert.equal(JSON.parse(b.stdout).running,false);assert.ok(!b.stdout.includes(token));
});
test('unknown command fails clearly instead of silently starting a service',async()=>{
 await assert.rejects(run(process.execPath,[cli,'unknown-command']),error=>
  error.code===1&&/未知命令/.test(error.stderr));
});
