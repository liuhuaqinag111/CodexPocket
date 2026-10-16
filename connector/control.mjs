import http from 'node:http';
import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const staticFiles={
 '/':['./web/index.html','text/html; charset=utf-8'],
 '/assets/app.js':['./web/app.js','text/javascript; charset=utf-8'],
 '/style.css':['./web/style.css','text/css; charset=utf-8'],
 '/assets/style.css':['./web/style.css','text/css; charset=utf-8'],
};
function json(res,status,value){res.writeHead(status,{'content-type':'application/json; charset=utf-8'}).end(JSON.stringify(value));}
function equalToken(a,b) {const x=Buffer.from(a),y=Buffer.from(b);return x.length===y.length&&crypto.timingSafeEqual(x,y);}
async function bodyJSON(req) {
 const chunks=[];let size=0;
 for await(const chunk of req){size+=chunk.length;if(size>16384)throw Object.assign(new Error('配置内容过大'),{status:413});chunks.push(chunk);}
 const text=Buffer.concat(chunks).toString('utf8');
 let value;try{value=JSON.parse(text||'{}');}catch{throw Object.assign(new Error('JSON 格式无效'),{status:400});}
 if(!value||typeof value!=='object'||Array.isArray(value))throw new Error('配置必须是对象');
 return value;
}
export async function startControlServer({manager,adminToken,port=0}) {
 if(!adminToken)throw new Error('本机管理凭据不存在');
 const server=http.createServer((req,res)=>{void handle(req,res).catch(error=>{
  if(!res.headersSent)json(res,error.status||400,{error:manager.redact?.(error.message)||error.message});
  else res.end();
 });});
 let mutation=Promise.resolve();
 async function handle(req,res) {
  const address=server.address(),hosts=['127.0.0.1:'+address.port,'localhost:'+address.port];
  if(!hosts.includes(req.headers.host))return json(res,403,{error:'仅允许本机访问'});
  const origin=req.headers.origin;
  if(origin&&!hosts.map(host=>'http://'+host).includes(origin))return json(res,403,{error:'不允许跨站访问'});
  if(req.headers['sec-fetch-site']==='cross-site')return json(res,403,{error:'不允许跨站访问'});
  res.setHeader('cache-control','no-store');res.setHeader('x-content-type-options','nosniff');
  res.setHeader('referrer-policy','no-referrer');
  res.setHeader('content-security-policy',"default-src 'self'; connect-src 'self'; img-src 'self' data:; script-src 'self'; style-src 'self'; frame-ancestors 'none'; base-uri 'none'");
  const url=new URL(req.url,'http://127.0.0.1');
  if(url.pathname.startsWith('/api/')) {
   if(!equalToken(req.headers.authorization||'','Bearer '+adminToken))return json(res,401,{error:'请从电脑连接端打开控制面板'});
   if(req.method==='GET'&&url.pathname==='/api/status')return json(res,200,await manager.status());
   if(req.method==='GET'&&url.pathname==='/api/pair')return json(res,200,await manager.pair());
   const actions={'/api/start':()=>manager.start(),'/api/stop':()=>manager.stop(),
    '/api/tailscale':()=>manager.enableTailscale(),'/api/config':patch=>manager.configure(patch),
    '/api/shutdown':()=>manager.stop()};
   if(req.method!=='POST'||!Object.hasOwn(actions,url.pathname))return json(res,404,{error:'未找到操作'});
   if(!(req.headers['content-type']||'').startsWith('application/json'))return json(res,415,{error:'请使用 JSON 请求'});
   const body=await bodyJSON(req);
   const action=mutation.then(()=>actions[url.pathname](body));mutation=action.catch(()=>{});
   json(res,200,await action);
   if(url.pathname==='/api/shutdown')server.close();
   return;
  }
  if(req.method!=='GET')return json(res,404,{error:'未找到页面'});
  let file,type;
  if(url.pathname==='/assets/qrcode.js') {file=require.resolve('qrcode-generator');type='text/javascript; charset=utf-8';}
  else if(Object.hasOwn(staticFiles,url.pathname)) {
   const entry=staticFiles[url.pathname];file=new URL(entry[0],import.meta.url);type=entry[1];
  } else return json(res,404,{error:'未找到页面'});
  const content=await fs.readFile(file);res.writeHead(200,{'content-type':type}).end(content);
 }
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(port,'127.0.0.1',resolve);});
 return server;
}
