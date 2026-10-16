import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {withDesktopProjectless} from './desktop-projectless.mjs';

function fixture(t,state){
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'desktop-projectless-'));
 t.after(()=>fs.rmSync(directory,{recursive:true,force:true}));
 const file=path.join(directory,'global-state.json');
 if(state!==undefined)fs.writeFileSync(file,JSON.stringify(state));
 return file;
}

test('missing or invalid desktop state leaves null project metadata unchanged',t=>{
 const file=fixture(t);
 const message={id:1,result:{data:[{id:'row',projectId:null}]}};
 assert.equal(withDesktopProjectless(message,'thread/list',file),message);
 for(const value of ['broken JSON',JSON.stringify({'projectless-thread-ids':['row',7]})]){
  fs.writeFileSync(file,value);
  assert.equal(withDesktopProjectless(message,'thread/list',file),message);
 }
});

test('search rows receive desktop membership without mutating cached or explicit metadata',t=>{
 const file=fixture(t,{'projectless-thread-ids':['row']});
 const message={id:1,result:{data:[{id:'row',projectId:'explicit'},{id:'legacy',projectId:null}]}};
 const before=structuredClone(message);
 assert.deepEqual(withDesktopProjectless(message,'thread/search',file),{id:1,result:{data:[
  {id:'row',projectId:'explicit',desktopProjectless:true},
  {id:'legacy',projectId:null,desktopProjectless:false}
 ]}});
 assert.deepEqual(message,before);
 assert.equal(withDesktopProjectless(message,'project/list',file),message);
});

test('errors are passed through without being decorated',t=>{
 const file=fixture(t,{'projectless-thread-ids':['row']});
 const error={id:1,error:{code:-1,message:'read failed'}};
 assert.equal(withDesktopProjectless(error,'thread/read',file),error);
});
