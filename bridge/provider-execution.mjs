import {spawn} from 'node:child_process';
import path from 'node:path';
import os from 'node:os';
import {readExecutionProvider} from './provider-catalog.mjs';

// Resolve CC Switch at worker creation time. The global CODEX_HOME is left
// untouched; only this child receives the selected provider override.
export function withProviderExecution({spawnProcess=spawn,
 readProvider=()=>readExecutionProvider(process.env.CC_SWITCH_DB
  ||path.join(os.homedir(),'.cc-switch','cc-switch.db'))}={}) {
 return (binary,args,options={})=>{
  let provider;
  try { provider=readProvider(); } catch {}
  if (!provider?.model || !provider.baseURL || !provider.token || provider.wireAPI !== 'responses')
   return spawnProcess(binary,args,options);
  let url;
  try { url=new URL(provider.baseURL); } catch { return spawnProcess(binary,args,options); }
  if (!['http:','https:'].includes(url.protocol) || url.username || url.password)
   return spawnProcess(binary,args,options);
  const json=JSON.stringify;
  const table=`{name=${json(provider.name||provider.id)},base_url=${json(provider.baseURL)},wire_api="responses",requires_openai_auth=false,env_key="CODEXPOCKET_PROVIDER_KEY"}`;
  return spawnProcess(binary,[...args,'-c',`model=${json(provider.model)}`,
   '-c','model_provider="codexpocket_current"',
   '-c',`model_providers.codexpocket_current=${table}`],
   {...options,env:{...(options.env||process.env),CODEXPOCKET_PROVIDER_KEY:provider.token}});
 };
}
