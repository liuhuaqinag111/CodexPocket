import test from 'node:test';
import assert from 'node:assert/strict';
import {discoverCodex,probeCodex,runtimeEnvironment} from './discovery.mjs';
import path from 'node:path';
test('Windows finds native codex.exe with spaces using where.exe without a shell',async()=>{
 const target='C:\\Program Files\\Codex\\codex.exe',calls=[];
 const binary=await discoverCodex({platform:'win32',env:{},home:'C:\\Me',exists:p=>p===target,
  run:async(file,args)=>{calls.push([file,args]);return {stdout:target+'\r\n'};}});
 assert.equal(binary,target);assert.deepEqual(calls[0],['where.exe',['codex.exe']]);
});
test('explicit missing CLI reports installation requirement instead of launching npm shims',async()=>{
 await assert.rejects(discoverCodex({codexPath:'/missing/codex',exists:()=>false}),/Codex/);
});
test('probe verifies websocket support and chooses default stdio when no --stdio flag exists',async()=>{
 const result=await probeCodex('/codex',{run:async(_file,args)=>({stdout:args[0]==='--version'?'codex-cli 0.120.0':'--listen <URL> --ws-auth <TOKEN>'})});
 assert.deepEqual(result.appServerArgs,['app-server','--listen']);
 assert.equal(result.explicitStdio,false);assert.match(result.version,/0.120/);
});
test('Mac launchd discovers common CLI installs even with a minimal PATH',async()=>{
 for(const target of ['/usr/local/bin/codex','/opt/homebrew/bin/codex','/Users/test/.local/bin/codex',
  '/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex',
  '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex']) {
  assert.equal(await discoverCodex({platform:'darwin',env:{PATH:'/usr/bin:/bin'},home:'/Users/test',exists:p=>p===target}),target);
 }
});
test('child runtime PATH supports node shebangs and never mutates global or caller environment',()=>{
 const original=process.env.PATH,env={Path:'/usr/bin:/bin',HOME:'/fixture/home',CODEX_HOME:'/fixture/codex'};
 const child=runtimeEnvironment(env);
 assert.equal(child.PATH.split(path.delimiter)[0],path.dirname(process.execPath));
 assert.equal(child.HOME,env.HOME);assert.equal(child.CODEX_HOME,env.CODEX_HOME);
 assert.equal(child.Path,undefined);assert.equal(env.Path,'/usr/bin:/bin');
 assert.equal(process.env.PATH,original);
});
