export function normalizeEndpoint(value) {
 if(!value)throw new Error('请先设置自己的 VPS 地址或启用 Tailscale');
 const url=new URL(value);
 if(url.protocol==='https:')url.protocol='wss:';
 if(url.protocol!=='wss:'||url.username||url.password||url.search||url.hash)
  throw new Error('连接地址必须是无账号、查询参数和片段的 HTTPS/WSS 地址');
 if(url.pathname==='/')url.pathname='/ws';
 return url.href;
}
export function pairingURL({externalURL,token,name,certificateSHA256}) {
 const data={version:1,endpoint:normalizeEndpoint(externalURL),token,name};
 if(!token)throw new Error('配对令牌不存在');
 if(certificateSHA256){
  if(!/^[a-fA-F0-9]{64}$/.test(certificateSHA256))throw new Error('证书指纹必须是 64 位十六进制');
  data.certificateSHA256=certificateSHA256.toLowerCase();
 }
 return 'codexpocket://pair?data='+Buffer.from(JSON.stringify(data)).toString('base64url');
}
