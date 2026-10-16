import test from 'node:test';
import assert from 'node:assert/strict';
import {runtimePaths} from './runtime-paths.mjs';
test('all mutable bridge files use the connector dataDir without a HOME environment variable',()=>{
 const paths=runtimePaths({env:{CODEX_PHONE_DIR:'C:\\Data\\Codex Pocket'},platform:'win32',home:'C:\\Users\\test',temp:'C:\\Temp'});
 assert.equal(paths.usage,'C:\\Data\\Codex Pocket\\usage.json');
 assert.equal(paths.frames,'C:\\Data\\Codex Pocket\\frames.log');
 assert.equal(paths.uploads,'C:\\Temp\\codex-pocket');
});
test('legacy Mac installation keeps its data while portable mode can override it',()=>{
 assert.equal(runtimePaths({env:{},home:'/Users/test',temp:'/tmp',platform:'darwin'}).directory,'/Users/test/.codex/phone');
});
