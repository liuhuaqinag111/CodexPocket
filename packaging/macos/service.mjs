import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {fileURLToPath} from 'node:url';
const run=promisify(execFile),label='app.codexpocket.connector';
const xml=s=>String(s).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
export function servicePlan({home=os.homedir(),uid=process.getuid(),packageDir,
 dataDir=process.env.CODEX_POCKET_DATA_DIR||path.join(home,'Library','Application Support','CodexPocketConnector')}={}) {
 const installDir=path.join(dataDir,'program'),node=path.join(installDir,'runtime','node');
 const cli=path.join(installDir,'app','connector','cli.mjs');
 const args=[node,cli,'start','--data-dir',dataDir];
 const plistPath=path.join(home,'Library','LaunchAgents',label+'.plist');
 const searchPath=[path.dirname(node),'/usr/local/bin','/opt/homebrew/bin',process.env.PATH||'/usr/bin:/bin:/usr/sbin:/sbin'].join(':');
 const environment='<key>EnvironmentVariables</key><dict><key>PATH</key><string>'+xml(searchPath)+'</string></dict>';
 const tail='<key>RunAtLoad</key><true/><key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict><key>ThrottleInterval</key><integer>10</integer><key>StandardOutPath</key><string>'+xml(path.join(dataDir,'service.log'))+'</string><key>StandardErrorPath</key><string>'+xml(path.join(dataDir,'service-error.log'))+'</string></dict></plist>\n';
 const plist='<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>'+ '<key>Label</key><string>'+label+'</string><key>ProgramArguments</key><array>'+args.map(a=>'<string>'+xml(a)+'</string>').join('')+'</array>';

 return {label,domain: "gui/"+uid,installDir,dataDir,node,cli,args,plistPath,plist:plist.replace('</array>','</array>'+environment)+tail,packageDir};
}
const exists=async p=>fs.access(p).then(()=>true,()=>false);
export function ownsService(plan,output) {
 const lines=output.split('\n').map(line=>line.trim());
 return lines.includes('program = '+plan.node)&&lines.includes(plan.cli);
}
async function optional(file,args){try{return await run(file,args)}catch(error){return {error}}}
async function cli(plan,command){return run(plan.node,[plan.cli,command,"--data-dir",plan.dataDir]);}
async function stop(plan){
 const loaded=await optional('/bin/launchctl',['print',plan.domain+'/'+plan.label]);
 if(!loaded.error&&!ownsService(plan,loaded.stdout))throw new Error('同名服务不属于这个连接端，已停止操作');
 await optional(plan.node,[plan.cli,"stop","--data-dir",plan.dataDir]);
 if(!loaded.error)await run('/bin/launchctl',['bootout',plan.domain+'/'+plan.label]);
}
async function start(plan) {
 const loaded=await optional('/bin/launchctl',['print',plan.domain+'/'+plan.label]);
 if(loaded.error)await run('/bin/launchctl',['bootstrap',plan.domain,plan.plistPath]);
 else if(!ownsService(plan,loaded.stdout))throw new Error('同名服务不属于这个连接端');
 await run('/bin/launchctl',['kickstart',plan.domain+'/'+plan.label]);
 for(let n=0;n<30;n++) {
  try{await cli(plan,'dashboard');return;}catch(error){if(n===29)throw error;}
  await new Promise(resolve=>setTimeout(resolve,200));
 }
}
async function main() {
 const action=process.argv[2]||'start';
 const packageDir=fileURLToPath(new URL('../../',import.meta.url));
 const p=servicePlan({packageDir});
 if(action==='plan')return console.log(JSON.stringify(p,null,2));
 if(process.platform!=='darwin')throw new Error('这个安装包适用于 macOS');
 if(!['install','start','stop','status','uninstall'].includes(action))throw new Error('未知操作');
 const marker=path.join(p.installDir,'.codexpocket-program');
 if(await exists(p.installDir)&&!await exists(marker))throw new Error('安装目录不属于 CodexPocket，未修改任何文件');
 if(await exists(p.plistPath)&&!(await fs.readFile(p.plistPath,'utf8')).includes('<string>'+xml(p.cli)+'</string>'))throw new Error('同名 LaunchAgent 不属于这个连接端');
 if(action==='install') {
  await stop(p);
  await fs.mkdir(p.dataDir,{recursive:true,mode:0o700});
  if(path.resolve(packageDir)!==path.resolve(p.installDir)) {
   await fs.rm(p.installDir,{recursive:true,force:true});
   await fs.cp(packageDir,p.installDir,{recursive:true});
  }
  await fs.writeFile(marker,'CodexPocket Connector\n',{mode:0o600});
  await fs.mkdir(path.dirname(p.plistPath),{recursive:true});
  await fs.writeFile(p.plistPath,p.plist,{mode:0o600});
  await start(p);
  console.log('安装完成，已启动电脑连接端；数据保存在 '+p.dataDir);return;
 }
 if(action==='uninstall') {
  await stop(p);await fs.rm(p.plistPath,{force:true});
  if(await exists(marker))await fs.rm(p.installDir,{recursive:true,force:true});
  console.log('已卸载连接端，用户数据保留在 '+p.dataDir);return;
 }
 if(action==='stop'){await stop(p);console.log('电脑连接端已停止');return;}
 if(action==='status'){console.log((await cli(p,'status')).stdout);return;}
 if(!await exists(marker))throw new Error('请先双击 Install.command');
 await start(p);
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))
 main().catch(error=>{console.error(error.message);process.exitCode=1;});
