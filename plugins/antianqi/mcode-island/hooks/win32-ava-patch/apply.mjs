// apply.mjs — idempotent in-place patch for the @minimax-ai/code@0.3.10
// hook dispatcher's Ava spawn wrapper, so the runtime can spawn hook
// commands on Windows.
//
// Background.
//   mcode 0.3.10's hook dispatcher (Ava in chunk-CTHP2I62.js:6553263)
//   gates the Windows-aware shell wrapper Dva behind a t.usePlatformShell
//   flag that defaults to false. The fallback path is
//       { executable: "/bin/sh", args: ["-lc", command] }
//   which on Windows returns ENOENT, so zero hook scripts actually run.
//
//   chunk-U2NOFGEC.js already has a complete Windows shell detector
//   (exported as bZ): pwsh via where.exe -> fixed pwsh path -> WinPS 5
//   -> Git Bash -> WSL bash -> throw. All the infrastructure is there.
//   The Ava function just doesn't call it on Windows.
//
//   This patch adds the missing platform branch:
//       OLD: t.usePlatformShell?Dva(a,bZ()):...
//       NEW: (t.usePlatformShell||process.platform==="win32")?Dva(a,bZ()):...
//
//   After the patch:
//     - macOS / Linux: unchanged (still /bin/sh -lc)
//     - Windows:       goes through Dva + the platform-aware bZ(), which
//                       finds pwsh / powershell / Git-Bash / WSL bash and
//                       runs the command via whichever is available.
//
// Idempotency.
//   - If the OLD pattern is not present, the script assumes the patch is
//     already applied (or the runtime is a different version) and exits 0.
//   - If the NEW pattern is already present (idempotent re-apply), exits 0.
//   - Otherwise, applies the patch, writes the file, prints a one-line
//     summary.
//
// Risk and durability.
//   - Touches node_modules; will be overwritten by the next
//     `npm install -g @minimax-ai/code`. Re-run after every upgrade.
//   - The chunk is a single-line change (+30 bytes). If mcode 0.3.10 is
//     replaced by 0.3.11+ that fixes the bug upstream, remove this patch
//     and uninstall the win32-ava-patch directory.
//   - A backup of the original chunk is written next to it
//     (chunk-CTHP2I62.js.bak-<timestamp>) the first time apply.mjs
//     mutates the file. restore.mjs uses that backup.
//
// Usage:
//   node apply.mjs
//   # or, after a global mcode upgrade:
//   node apply.mjs --force    # apply even if the OLD pattern is absent

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const CHUNK_REL = ['.minimax-code', 'releases', '0.3.10', 'node_modules', '@minimax-ai', 'code', 'chunks', 'chunk-CTHP2I62.js'];

const OLD = 't.usePlatformShell?Dva(a,bZ()):{executable:"/bin/sh",args:["-lc",a]}';
const NEW = '(t.usePlatformShell||process.platform==="win32")?Dva(a,bZ()):{executable:"/bin/sh",args:["-lc",a]}';

const force = process.argv.includes('--force');

function chunkPath() {
  // os.homedir() is the most portable source on Windows; env vars may
  // be unset if the script is launched via a bare `node` invocation
  // (no PowerShell / cmd shell to inject USERPROFILE).
  return path.join(os.homedir(), ...CHUNK_REL);
}

function main() {
  const chunk = chunkPath();
  if (!fs.existsSync(chunk)) {
    console.error(`FAIL: chunk not found at ${chunk}`);
    console.error('      (is mcode 0.3.10 installed at $USERPROFILE\\.minimax-code ?)');
    process.exit(1);
  }

  const orig = fs.readFileSync(chunk, 'utf8');

  if (orig.includes(NEW)) {
    console.log('OK: patch already applied (NEW pattern found at offset', orig.indexOf(NEW), ')');
    process.exit(0);
  }

  if (!orig.includes(OLD)) {
    if (force) {
      console.error('WARN: OLD pattern not found, --force given; aborting to avoid silent damage');
      process.exit(2);
    }
    console.error('INFO: OLD pattern not found in this chunk.');
    console.error('      Either the patch is already applied, or this is a different mcode version.');
    console.error('      Re-run with --force only if you are certain the runtime still has the bug.');
    process.exit(0);
  }

  // back up the original (only the first time, keep one newest .bak)
  const bakGlob = fs.readdirSync(path.dirname(chunk))
    .filter(f => f.startsWith(path.basename(chunk) + '.bak-'));
  if (bakGlob.length === 0) {
    const stamp = new Date().toISOString().replace(/[:T]/g, '-').slice(0, 19);
    const bak = `${chunk}.bak-${stamp}`;
    fs.copyFileSync(chunk, bak);
    console.log('backup:', bak);
  } else {
    console.log('backup already exists:', bakGlob[0]);
  }

  // apply
  const patched = orig.replace(OLD, NEW);
  if ((patched.match(new RegExp(NEW.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))) || []).length !== 1) {
    console.error('FAIL: replacement did not produce exactly 1 NEW match');
    process.exit(1);
  }
  fs.writeFileSync(chunk, patched, 'utf8');
  const delta = fs.statSync(chunk).size - Buffer.byteLength(orig, 'utf8');
  console.log('OK: patch applied');
  console.log('  chunk:', chunk);
  console.log('  offset of NEW:', patched.indexOf(NEW));
  console.log('  size delta:', delta, 'bytes');
  console.log('');
  console.log('Next steps:');
  console.log('  1. Restart any running mcode / mcode-island widget so the new chunk is loaded.');
  console.log('  2. Re-run install-hook.ps1 if you have not already.');
  console.log('  3. Trigger a tool call. island.log should show a "working ::" entry without the');
  console.log('     "[detect]" prefix within ~400 ms (one widget poll cycle).');
  console.log('  4. To undo: node restore.mjs');
}

main();
