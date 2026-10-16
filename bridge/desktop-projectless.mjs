import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const methods=new Set(['thread/list','thread/search','thread/read','thread/resume',
 'thread/start','thread/fork']);

// Desktop owns this file. Read it at delivery time, including list cache hits.
export function withDesktopProjectless(message,method,
 file=path.join(process.env.CODEX_HOME||path.join(os.homedir(),'.codex'),'.codex-global-state.json')) {
 if(!methods.has(method)||!message?.result||message.error)return message;
 let ids;
 try{
  const state=JSON.parse(fs.readFileSync(file,'utf8'));
  const rows=state['projectless-thread-ids']??[];
  if(!Array.isArray(rows)||!rows.every(id=>typeof id==='string'))return message;
  ids=new Set(rows);
 }catch{return message;}
 const decorate=row=>row&&typeof row.id==='string'
  ? {...row,desktopProjectless:ids.has(row.id)}:row;
 const result={...message.result};
 if(Array.isArray(result.data))result.data=result.data.map(decorate);
 if(result.thread)result.thread=decorate(result.thread);
 return {...message,result};
}
