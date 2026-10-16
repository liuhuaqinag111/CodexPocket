import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
const files = ['bridge', 'connector'].flatMap(directory => fs.readdirSync(directory)
  .filter(name => name.endsWith('.test.mjs') && !name.endsWith('.real.test.mjs'))
  .map(name => `${directory}/${name}`))
  .filter(file => process.platform !== 'win32' ||
    !['bridge/bridge.integration.test.mjs', 'bridge/supervise.test.mjs'].includes(file));
files.push('scripts/build-connector.test.mjs');
files.sort();
const result = spawnSync(process.execPath, ['--test', ...files], { stdio: 'inherit' });
process.exitCode = result.status ?? 1;
