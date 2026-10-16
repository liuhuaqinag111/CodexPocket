import fs from 'node:fs/promises';
export async function syncDirectory(directory,{platform=process.platform,open=fs.open}={}) {
 if(platform==='win32')return;
 const descriptor=await open(directory,'r');
 try{await descriptor.sync();}finally{await descriptor.close();}
}
