import os from 'node:os';
import path from 'node:path';
export function runtimePaths({env=process.env,platform=process.platform,home=os.homedir(),temp=os.tmpdir()}={}) {
 const p=platform==='win32'?path.win32:path.posix;
 const directory=env.CODEX_PHONE_DIR||p.join(home,'.codex','phone');
 return {directory,usage:p.join(directory,'usage.json'),frames:p.join(directory,'frames.log'),
  submissions:env.SUBMISSION_DIR||p.join(directory,'submissions'),
  uploads:env.UPLOAD_DIR||p.join(temp,'codex-pocket'),ipa:env.IPA_PATH||p.join(home,'Desktop','CodexPocket.ipa')};
}
