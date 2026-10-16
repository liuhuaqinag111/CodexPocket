import test from 'node:test';
import assert from 'node:assert/strict';
import {withProviderExecution} from './provider-execution.mjs';

const provider={id:'fixture',name:'Fixture',fingerprint:'a',model:'gpt-6-astra',
 modelProvider:'custom',baseURL:'http://127.0.0.1:9/v1',wireAPI:'responses',token:'private-key'};
function capture(readProvider){
 let sent;
 const spawnProcess=(...args)=>{sent=args;return 'child';};
 return {spawn:withProviderExecution({readProvider,spawnProcess}),get sent(){return sent;}};
}
test('no provider keeps existing spawn arguments and environment',()=>{
 const c=capture(()=>null), args=['app-server','--stdio'], options={env:{CODEX_HOME:'/same'}};
 assert.equal(c.spawn('codex',args,options),'child');
 assert.equal(c.sent[1],args);assert.equal(c.sent[2],options);
});
test('provider overrides belong only to the child and credentials stay in env',()=>{
 const c=capture(()=>provider), args=['app-server','--stdio'];
 const options={env:{CODEX_HOME:'/same',HOME:'/home',KEEP:'yes'},cwd:'/work'};
 c.spawn('codex',args,options);
 assert.deepEqual(args,['app-server','--stdio']);
 assert.equal(options.env.CODEXPOCKET_PROVIDER_KEY,undefined);
 assert.equal(c.sent[2].env.CODEX_HOME,'/same');
 assert.equal(c.sent[2].env.KEEP,'yes');
 assert.equal(c.sent[2].env.CODEXPOCKET_PROVIDER_KEY,'private-key');
 assert.ok(c.sent[1].includes('model="gpt-6-astra"'));
 assert.ok(c.sent[1].includes('model_provider="codexpocket_current"'));
 assert.ok(c.sent[1].some(x=>x.includes('env_key="CODEXPOCKET_PROVIDER_KEY"')));
 assert.equal(JSON.stringify(c.sent[1]).includes('private-key'),false);
});
test('each new child resolves current provider without changing an earlier snapshot',()=>{
 let active=provider;
 const c=capture(()=>active);
 c.spawn('codex',['app-server'],{env:{CODEX_HOME:'/same'}});
 const old=c.sent;
 active={...provider,model:'gpt-6-sol',token:'new-key',baseURL:'https://new.test/v1'};
 c.spawn('codex',['app-server'],{env:{CODEX_HOME:'/same'}});
 assert.ok(old[1].includes('model="gpt-6-astra"'));
 assert.equal(old[2].env.CODEXPOCKET_PROVIDER_KEY,'private-key');
 assert.ok(c.sent[1].includes('model="gpt-6-sol"'));
 assert.equal(c.sent[2].env.CODEXPOCKET_PROVIDER_KEY,'new-key');
});
for(const value of [null,{}, {...provider,wireAPI:'chat'}, {...provider,baseURL:'ftp://bad'},
 {...provider,token:''}, {...provider,baseURL:'https://user:pass@host.test'}])
 test('unsupported provider snapshot preserves original behavior '+JSON.stringify(value?.baseURL),()=>{
  const c=capture(()=>value),args=['app-server'],options={env:{CODEX_HOME:'/same'}};
  c.spawn('codex',args,options);assert.equal(c.sent[1],args);assert.equal(c.sent[2],options);
 });
