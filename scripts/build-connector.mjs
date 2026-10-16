import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
const run=promisify(execFile),nodeVersion='24.19.0';
const sourceRoot=fileURLToPath(new URL('../',import.meta.url));
async function walk(directory,prefix='') {
 const out=[];
 for(const entry of await fs.readdir(directory,{withFileTypes:true})) {
  const relative=path.posix.join(prefix,entry.name);
  if(entry.isSymbolicLink())throw new Error('打包源包含符号链接：'+relative);
  if(entry.isDirectory())out.push(...await walk(path.join(directory,entry.name),relative));
  else out.push(relative);
 }
 return out;
}
export async function packageFiles(root=sourceRoot) {
 if(root instanceof URL)root=fileURLToPath(root);
 const files=['package.json'];
 for(const file of await walk(path.join(root,'connector'),'connector'))
  if(!file.includes('/fixtures/')&&!/\.test\.mjs$/.test(file))files.push(file);
 const seen=new Set();
 async function dependency(file) {
  if(seen.has(file))return;seen.add(file);files.push(file);
  const text=await fs.readFile(path.join(root,file),'utf8');
  for(const match of text.matchAll(/(?:from\s*|import\s*)['"](\.[^'"]+)['"]/g)) {
   const target=path.posix.normalize(path.posix.join(path.posix.dirname(file),match[1]));
   if(!target.startsWith('bridge/'))throw new Error('桥接依赖越出允许目录：'+target);
   await dependency(target);
  }
 }
 await dependency('bridge/bridge.mjs');
 files.push('bridge/ui.html');
 for(const name of ['ws','qrcode-generator'])
  for(const file of await walk(path.join(root,'node_modules',name),'node_modules/'+name))
   if(!file.includes('/test/')&&!/\/sample\./.test(file))files.push(file);
 return files.map(file=>'app/'+file).sort();
}
export function validateRuntime(bytes,{platform,arch}) {
 if(!bytes.includes(Buffer.from('v'+nodeVersion)))throw new Error('运行环境必须是 Node '+nodeVersion);
 if(platform==='win32') {
  if(bytes.toString('ascii',0,2)!=='MZ'||bytes.readUInt16LE(bytes.readUInt32LE(0x3c)+4)!==0x8664||arch!=='x64')throw new Error('需要 Windows x64 Node 运行环境');
 }else if(bytes.readUInt32LE(0)!==0xfeedfacf||bytes.readUInt32LE(4)!==(arch==='arm64'?0x100000c:0x1000007))throw new Error('macOS 运行环境架构不匹配');
}
export async function packageMetadata(root=sourceRoot) {
 if(root instanceof URL)root=fileURLToPath(root);
 return ['THIRD_PARTY_NOTICES.md',...await walk(path.join(root,'licenses'),'licenses')];
}
export async function buildConnector({root=sourceRoot,platform=process.platform,arch=process.arch,
 runtime=process.execPath,output=path.join(sourceRoot,'outputs','connectors')}={}) {
 platform=({windows:'win32',macos:'darwin'})[platform]||platform;
 if(!['win32','darwin'].includes(platform)||!['x64','arm64'].includes(arch))throw new Error('支持 Windows x64、macOS x64/arm64');
 const version=JSON.parse(await fs.readFile(path.join(root,'package.json'),'utf8')).version;
 const name='CodexPocketConnector-'+version+'-'+(platform==='win32'?'windows':'macos')+'-'+arch;
 const temp=await fs.mkdtemp(path.join(os.tmpdir(),'pocket-package-'));
 const stage=path.join(temp,name);await fs.mkdir(stage);
 try {
  for(const file of await packageFiles(root)) {
   const target=path.join(stage,file);await fs.mkdir(path.dirname(target),{recursive:true});
   await fs.copyFile(path.join(root,file.slice(4)),target);
  }
  for(const file of await packageMetadata(root)) {
   const target=path.join(stage,file);await fs.mkdir(path.dirname(target),{recursive:true});
   await fs.copyFile(path.join(root,file),target);
  }
  const flavor=platform==='win32'?'windows':'macos';
  const service='service.'+(platform==='win32'?'ps1':'mjs');
  await fs.mkdir(path.join(stage,'packaging',flavor),{recursive:true});
  await fs.copyFile(path.join(root,'packaging',flavor,service),path.join(stage,'packaging',flavor,service));
  for(const command of ['Install','Start','Stop','Status','Uninstall']) {
   const file=command+(platform==='win32'?'.cmd':'.command');
   const source=await fs.readFile(path.join(root,'packaging',flavor,file),'utf8');
   await fs.writeFile(path.join(stage,file),platform==='win32'?source.replace(/\r?\n/g,'\r\n'):source,{mode:0o755});
  }
  if(platform==='win32') {
   const ps=path.join(stage,'packaging','windows','service.ps1');
   await fs.writeFile(ps,'\ufeff'+(await fs.readFile(ps,'utf8')).replace(/^\ufeff/,''));
  }
  const binary=path.join(stage,'runtime',platform==='win32'?'node.exe':'node');
  await fs.mkdir(path.dirname(binary));await fs.copyFile(runtime,binary);
  const header=Buffer.alloc(4),handle=await fs.open(binary);await handle.read(header,0,4,0);await handle.close();
  if(platform==='darwin'&&[0xcafebabe,0xcafebabf].includes(header.readUInt32BE(0))) {
   await run('/usr/bin/lipo',[runtime,'-thin',arch==='x64'?'x86_64':'arm64','-output',binary]);
  }
  await fs.chmod(binary,0o755);
  const bytes=await fs.readFile(binary);validateRuntime(bytes,{platform,arch});
  await fs.copyFile(path.join(root,'packaging','macos','Node-LICENSE.txt'),path.join(stage,'Node-LICENSE.txt'));
  await fs.copyFile(path.join(root,'LICENSE'),path.join(stage,'LICENSE'));
  await fs.writeFile(path.join(stage,'README.txt'),'CodexPocket Connector\n\n1. Extract this entire folder.\n2. Run Install'+(platform==='win32'?'.cmd':'.command')+'. No administrator account or separate Node installation is needed.\n3. Use your existing Codex setup: official account, API key, or CC Switch. API key / CC Switch setups do not require an official-account sign-in. Use your own Tailscale or VPS address in the dashboard.\n\nStart opens the dashboard. Stop stops this connector. Uninstall removes its startup entry and program while retaining your data.\nNode.js '+nodeVersion+' is included; license: Node-LICENSE.txt.\n');
  await fs.writeFile(path.join(stage,'build-info.json'),JSON.stringify({version,platform,arch,nodeVersion,
   runtimeSHA256:crypto.createHash('sha256').update(bytes).digest('hex'),files:await walk(stage)},null,2)+'\n');
  await fs.mkdir(output,{recursive:true});const zip=path.join(path.resolve(output),name+'.zip');
  await fs.rm(zip,{force:true});
  if(process.platform==='darwin')await run('/usr/bin/ditto',['-c','-k','--norsrc','--keepParent',stage,zip]);
  else if(process.platform==='win32')await run('tar.exe',['-a','-c','-f',zip,'-C',temp,name]);
  else await run('zip',['-q','-r',zip,name],{cwd:temp});
  return zip;
 }finally{await fs.rm(temp,{recursive:true,force:true});}
}
async function main() {
 const values={},args=process.argv.slice(2),keys={'--platform':'platform','--arch':'arch','--runtime':'runtime','--output':'output'};
 for(let n=0;n<args.length;n++) {
  if(!keys[args[n]]||!args[n+1])throw new Error('用法：node scripts/build-connector.mjs --platform windows|macos --arch x64|arm64 --runtime PATH [--output PATH]');
  values[keys[args[n]]]=args[++n];
 }
 console.log(await buildConnector(values));
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))
 main().catch(error=>{console.error(error.message);process.exitCode=1;});
