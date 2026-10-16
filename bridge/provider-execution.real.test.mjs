import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import {existsSync} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {StdioWorker} from './stdio-worker.mjs';
import {WriterRouter} from './writer-router.mjs';
import {withProviderExecution} from './provider-execution.mjs';
const binary=process.env.CODEX_BIN||[
 '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex',
 '/Applications/Codex.app/Contents/Resources/codex'].find(existsSync);
const staleModel={slug:'deepseek-fixture',display_name:'deepseek-fixture',description:'fixture',
 base_instructions:'Synthetic regression fixture.',supported_reasoning_levels:[],
 default_reasoning_level:'medium',default_reasoning_summary:'none',shell_type:'shell_command',
 visibility:'list',supported_in_api:true,priority:1,context_window:10000,
 max_context_window:10000,effective_context_window_percent:95,
 supports_reasoning_summaries:false,support_verbosity:false,
 supports_parallel_tool_calls:false,supports_search_tool:false,
 truncation_policy:{mode:'bytes',limit:10000},input_modalities:['text'],
 experimental_supported_tools:[],additional_speed_tiers:[],service_tiers:[]};
test('new writers follow provider switches and preserve explicit models despite a stale catalog',
 {skip:!binary,timeout:30000},async t=>{
 const home=await fs.mkdtemp(path.join(os.tmpdir(),'pocket-provider-exec-'));
 const workers=[];
 t.after(async()=>{for(const w of workers)if(!w.exited)await w.forceClose();
  await fs.rm(home,{recursive:true,force:true});});
 await fs.writeFile(path.join(home,'catalog.json'),JSON.stringify({models:[staleModel]}));
 const config='model="deepseek-fixture"\nmodel_provider="old"\nmodel_catalog_json="catalog.json"\n[model_providers.old]\nname="old"\nbase_url="http://127.0.0.1:9/v1"\nwire_api="responses"\n';
 await fs.writeFile(path.join(home,'config.toml'),config);
 let provider={id:'fixture',name:'fixture',model:'gpt-6-astra',baseURL:'http://127.0.0.1:9/v1',
  wireAPI:'responses',token:'synthetic-unusable-key'};
 const router=new WriterRouter({delay:60000,createWorker:callbacks=>{
  const worker=new StdioWorker({binary,cwd:home,env:{...process.env,CODEX_HOME:home},
   spawnProcess:withProviderExecution({readProvider:()=>provider}),...callbacks});
  workers.push(worker);return worker;
 }});
 t.after(()=>router.cancelTimers());
 let response;
 await router.route({id:1,method:'thread/start',params:{cwd:home,model:'gpt-6-sol'}},
  value=>{response=value;});
 assert.equal(response.error,undefined);
 const created=response.result,w=workers[0];
 assert.equal(created.model,'gpt-6-sol');
 assert.equal(created.modelProvider,'codexpocket_current');
 const cfg=(await w.request('config/read')).config;
 assert.equal(cfg.model,'gpt-6-astra');
 assert.equal(cfg.model_provider,'codexpocket_current');
 assert.equal(cfg.model_providers.codexpocket_current.base_url,provider.baseURL);
 const catalog=await w.request('model/list',{});
 assert.deepEqual(catalog.data.map(m=>m.id),['deepseek-fixture']);
 provider={...provider,id:'second',name:'Second',model:'gpt-6-sol',
  baseURL:'http://127.0.0.1:10/v1',token:'second-synthetic-key'};
 await router.route({id:2,method:'thread/start',params:{cwd:home,model:'gpt-6.1-sol'}},
  value=>{response=value;});
 assert.equal(response.error,undefined);
 assert.equal(response.result.model,'gpt-6.1-sol');
 assert.equal(response.result.modelProvider,'codexpocket_current');
 assert.equal(workers.length,2);
 const secondConfig=(await workers[1].request('config/read')).config;
 assert.equal(secondConfig.model,'gpt-6-sol');
 assert.equal(secondConfig.model_providers.codexpocket_current.base_url,'http://127.0.0.1:10/v1');
 const firstConfig=(await w.request('config/read')).config;
 assert.equal(firstConfig.model,'gpt-6-astra');
 assert.equal(firstConfig.model_providers.codexpocket_current.base_url,'http://127.0.0.1:9/v1');
 await w.request('thread/delete',{threadId:created.thread.id});
 await workers[1].request('thread/delete',{threadId:response.result.thread.id});
 await workers[1].closeIdle();
 await w.closeIdle();
 assert.equal(await fs.readFile(path.join(home,'config.toml'),'utf8'),config);
});
