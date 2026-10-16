import {WebSocketServer} from 'ws';
import readline from 'node:readline';
const args=process.argv.slice(2);
function reply(raw,send){const m=JSON.parse(raw);if(m.id===undefined)return;
 send(JSON.stringify({id:m.id,result:m.method==='thread/list'?{data:[],nextCursor:null}:{}}));}
if(args.includes('--listen')) {
 const url=new URL(args[args.indexOf('--listen')+1]);
 const server=new WebSocketServer({port:Number(url.port),host:url.hostname});
 server.on('connection',socket=>socket.on('message',raw=>reply(String(raw),message=>socket.send(message))));
} else readline.createInterface({input:process.stdin}).on('line',raw=>reply(raw,message=>console.log(message)));
