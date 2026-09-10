// restore.mjs — undo the in-place patch applied by apply.mjs.
//
// Looks for the most recent chunk-CTHP2I62.js.bak-* file written by
// apply.mjs (or any earlier manual backup the user dropped next to the
// chunk) and copies it back over the live chunk. Exits 0 if the live
// chunk is already at the unpatched state (OLD pattern present, NEW
// pattern absent).

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const CHUNK_REL = ['.minimax-code', 'releases', '0.3.10', 'node_modules', '@minimax-ai', 'code', 'chunks', 'chunk-CTHP2I62.js'];
const OLD = 't.usePlatformShell?Dva(a,bZ()):{executable:"/bin/sh",args:["-lc",a]}';
const NEW = '(t.usePlatformShell||process.platform==="win32")?Dva(a,bZ()):{executable:"/bin/sh",args:["-lc",a]}';

function chunkPath() {
  return path.join(os.homedir(), ...CHUNK_REL);
}

function main() {
  const chunk = chunkPath();
  if (!fs.existsSync(chunk)) {
    console.error(`FAIL: chunk not found at ${chunk}`);
    process.exit(1);
  }
  const live = fs.readFileSync(chunk, 'utf8');

  if (live.includes(NEW) && !live.includes(OLD)) {
    const dir = path.dirname(chunk);
    const base = path.basename(chunk);
    const baks = fs.readdirSync(dir)
      .filter(f => f.startsWith(base + '.bak-'))
      .sort();
    if (baks.length === 0) {
      console.error('FAIL: chunk is patched but no .bak file found next to it.');
      console.error('      Reinstall @minimax-ai/code@0.3.10 to get the unpatched chunk back.');
      process.exit(1);
    }
    const newest = baks[baks.length - 1];
    fs.copyFileSync(path.join(dir, newest), chunk);
    console.log('OK: restored from', newest);
    console.log('  chunk is now unpatched (NEW pattern removed).');
  } else if (live.includes(OLD) && !live.includes(NEW)) {
    console.log('OK: chunk is already unpatched, nothing to do.');
  } else {
    console.error('FAIL: chunk is in an unexpected state (OLD/NEW pattern combination).');
    console.error('      OLD present:', live.includes(OLD));
    console.error('      NEW present:', live.includes(NEW));
    console.error('      Inspect manually: ' + chunk);
    process.exit(2);
  }
}

main();
