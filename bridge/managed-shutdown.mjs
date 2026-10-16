export function installManagedShutdown({workers,upstream,owner=process}) {
 let shuttingDown=false;
 async function shutdown() {
  if(shuttingDown)return;shuttingDown=true;
  await Promise.allSettled([...workers.entries.values()].map(entry=>entry.worker.forceClose()));
  try{upstream()?.terminate();}catch{}
  owner.exit(0);
 }
 owner.on('message',message=>{if(message?.command==='shutdown')void shutdown();});
 owner.once('disconnect',()=>void shutdown());
 return shutdown;
}
