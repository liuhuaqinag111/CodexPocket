import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {normalizeEndpoint} from './pairing.mjs';

export function defaultDataDir({platform=process.platform,env=process.env,home=os.homedir()}={}) {
 if(env.CODEX_POCKET_DATA_DIR)return path.resolve(env.CODEX_POCKET_DATA_DIR);
 if(platform==='win32')return path.win32.join(env.LOCALAPPDATA||path.win32.join(home,'AppData','Local'),'CodexPocketConnector');
 if(platform==='darwin')return path.join(home,'Library','Application Support','CodexPocketConnector');
 return path.join(env.XDG_DATA_HOME||path.join(home,'.local','share'),'CodexPocketConnector');
}
async function credential(file) {
 try {await fs.writeFile(file,crypto.randomBytes(32).toString('hex'),{flag:'wx',mode:0o600});}
 catch(error){if(error.code!=='EEXIST')throw error;}
 const value=(await fs.readFile(file,'utf8')).trim();
 if(!/^[a-f0-9]{64}$/.test(value))throw new Error('连接端凭据损坏：'+path.basename(file));
 if(process.platform!=='win32')await fs.chmod(file,0o600);
 return value;
}
export async function loadConfig({dataDir=defaultDataDir()}={}) {
 dataDir=path.resolve(dataDir);
 await fs.mkdir(dataDir,{recursive:true,mode:0o700});
 const configFile=path.join(dataDir,'connector.json');
 let saved={};
 try{saved=JSON.parse(await fs.readFile(configFile,'utf8'));}
 catch(error){if(error.code!=='ENOENT')throw error;}
 const tokenFile=path.join(dataDir,'connector-token');
 const adminTokenFile=path.join(dataDir,'connector-admin-token');
 const config={name:os.hostname(),externalURL:'',bridgePort:63713,upstreamPort:63715,
  ...saved,dataDir,configFile,tokenFile,adminTokenFile};
 config.token=await credential(tokenFile);config.adminToken=await credential(adminTokenFile);
 for(const key of ['bridgePort','upstreamPort'])if(!Number.isInteger(config[key])||config[key]<1024||config[key]>65535)
  throw new Error('端口必须在 1024–65535 之间');
 if(config.bridgePort===config.upstreamPort)throw new Error('桥接和上游端口不能相同');
 if(config.externalURL)config.externalURL=normalizeEndpoint(config.externalURL);
 return config;
}
export async function saveConfig(config,patch) {
 const allowed=['name','externalURL','codexPath','bridgePort','upstreamPort','certificateSHA256'];
 if(Object.keys(patch).some(key=>!allowed.includes(key)))throw new Error('未知配置字段');
 const next={...config,...patch};
 next.name=String(next.name).trim().slice(0,100)||os.hostname();
 next.externalURL=next.externalURL?normalizeEndpoint(next.externalURL):'';
 if(next.certificateSHA256&&!/^[a-fA-F0-9]{64}$/.test(next.certificateSHA256))throw new Error('证书指纹无效');
 for(const key of ['bridgePort','upstreamPort'])if(!Number.isInteger(next[key])||next[key]<1024||next[key]>65535)
  throw new Error('端口必须在 1024–65535 之间');
 if(next.bridgePort===next.upstreamPort)throw new Error('桥接和上游端口不能相同');
 const saved=Object.fromEntries(allowed.filter(key=>next[key]!==undefined).map(key=>[key,next[key]]));
 const temporary=config.configFile+'.'+crypto.randomUUID()+'.tmp';
 await fs.writeFile(temporary,JSON.stringify(saved,null,2)+'\n',{mode:0o600});
 await fs.rename(temporary,config.configFile);
 Object.assign(config,next);return config;
}
