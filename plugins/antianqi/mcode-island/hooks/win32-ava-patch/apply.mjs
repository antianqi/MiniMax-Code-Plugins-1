// apply.mjs — idempotent in-place patch for the @minimax-ai/code hook
// dispatcher's Ava spawn wrapper, so the runtime can spawn hook
// commands on Windows.
//
// Version support.
//   Patches every release under ~/.minimax-code/releases/* that ships
//   an Ava function containing the OLD pattern. Verified to work on
//   0.3.10 (chunk-CTHP2I62.js) and 0.3.11 (chunk-P2ZQPHDU.js); the
//   patch is +30 bytes in both. Future releases that keep the same
//   Ava function shape will be auto-detected and patched; releases
//   that ship a different shape (e.g. upstream finally adds the
//   platform branch) will be silently skipped.
//
//   --release <version>  restrict to one release (repeatable). If
//                        omitted, scans every release directory.
//
// Background.
//   mcode 0.3.x's hook dispatcher (Ava in chunk-CTHP2I62.js /
//   chunk-P2ZQPHDU.js) gates the Windows-aware shell wrapper Dva
//   behind a t.usePlatformShell flag that defaults to false. The
//   fallback path is
//       { executable: "/bin/sh", args: ["-lc", command] }
//   which on Windows returns ENOENT, so zero hook scripts actually
//   run. chunk-U2NOFGEC.js already has a complete Windows shell
//   detector (exported as bZ): pwsh via where.exe -> fixed pwsh
//   path -> WinPS 5 -> Git Bash -> WSL bash -> throw. All the
//   infrastructure is there; the Ava function just doesn't call it
//   on Windows.
//
//   This patch adds the missing platform branch:
//       OLD: t.usePlatformShell?Dva(a,bZ()):...
//       NEW: (t.usePlatformShell||process.platform==="win32")?Dva(a,bZ()):...
//
// Idempotency.
//   - If the OLD pattern is not present in a chunk, the script
//     assumes that release is already patched (or that the runtime
//     has been fixed upstream) and silently skips it.
//   - If the NEW pattern is already present, the chunk is recorded
//     as already-patched and the script does not write a duplicate
//     .bak.
//   - Otherwise, applies the patch, writes a .bak-<ISO-timestamp>
//     next to the chunk, and prints a one-line summary per chunk.
//
// Risk and durability.
//   - Touches node_modules; will be overwritten by the next
//     `npm install -g @minimax-ai/code`. Re-run after every upgrade.
//   - A backup of the original chunk is written next to it
//     (chunk-<hash>.js.bak-<timestamp>) the first time apply.mjs
//     mutates the file. restore.mjs uses that backup.
//
// Usage:
//   node apply.mjs                       # patch every release with the OLD pattern
//   node apply.mjs --release 0.3.11      # patch only 0.3.11
//   node apply.mjs --release 0.3.10 --release 0.3.11
//   node apply.mjs --force               # error if OLD pattern not found anywhere

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const OLD = 't.usePlatformShell?Dva(a,bZ()):{executable:"/bin/sh",args:["-lc",a]}';
const NEW = '(t.usePlatformShell||process.platform==="win32")?Dva(a,bZ()):{executable:"/bin/sh",args:["-lc",a]}';
const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

const argv = process.argv.slice(2);
const force = argv.includes('--force');
const releaseArgs = [];
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--release' && i + 1 < argv.length) {
    releaseArgs.push(argv[++i]);
  }
}

function releaseBase() {
  return path.join(os.homedir(), '.minimax-code', 'releases');
}

function listReleases() {
  const base = releaseBase();
  if (!fs.existsSync(base)) return [];
  return fs.readdirSync(base, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .filter((n) => /^[0-9]+\.[0-9]+\.[0-9]+/.test(n))
    .sort();
}

function findChunkForRelease(release) {
  const chunksDir = path.join(releaseBase(), release, 'node_modules', '@minimax-ai', 'code', 'chunks');
  if (!fs.existsSync(chunksDir)) return null;
  const files = fs.readdirSync(chunksDir).filter((f) => f.startsWith('chunk-') && f.endsWith('.js'));
  for (const f of files) {
    const full = path.join(chunksDir, f);
    let content;
    try { content = fs.readFileSync(full, 'utf8'); } catch { continue; }
    if (content.includes(OLD) || content.includes(NEW)) return full;
  }
  return null;
}

function applyOne(chunkPath) {
  const content = fs.readFileSync(chunkPath, 'utf8');
  const result = { chunk: chunkPath, status: 'unknown' };

  if (content.includes(NEW)) {
    result.status = 'already-patched';
    return result;
  }
  if (!content.includes(OLD)) {
    result.status = 'no-pattern';
    return result;
  }

  // back up the original (only the first time, keep one newest .bak)
  const dir = path.dirname(chunkPath);
  const base = path.basename(chunkPath);
  const existingBaks = fs.readdirSync(dir).filter((f) => f.startsWith(base + '.bak-'));
  let bakPath = null;
  if (existingBaks.length === 0) {
    const stamp = new Date().toISOString().replace(/[:T]/g, '-').slice(0, 19);
    bakPath = path.join(dir, `${base}.bak-${stamp}`);
    fs.copyFileSync(chunkPath, bakPath);
  } else {
    bakPath = path.join(dir, existingBaks.sort().pop());
  }

  // apply
  const patched = content.replace(OLD, NEW);
  const newCount = (patched.match(new RegExp(escape(NEW), 'g')) || []).length;
  if (newCount !== 1) {
    result.status = 'replace-failed';
    return result;
  }
  fs.writeFileSync(chunkPath, patched, 'utf8');
  result.status = 'patched';
  result.bak = bakPath;
  result.size = fs.statSync(chunkPath).size;
  result.offset = patched.indexOf(NEW);
  return result;
}

function main() {
  const releases = releaseArgs.length > 0 ? releaseArgs : listReleases();
  if (releases.length === 0) {
    console.error('FAIL: no releases found at', releaseBase());
    process.exit(1);
  }

  const results = [];
  for (const rel of releases) {
    const chunk = findChunkForRelease(rel);
    if (!chunk) {
      results.push({ release: rel, status: 'no-chunk' });
      continue;
    }
    const r = applyOne(chunk);
    r.release = rel;
    results.push(r);
  }

  for (const r of results) {
    const tag = (s) => ({ 'patched': 'OK patched', 'already-patched': 'OK already-patched', 'no-pattern': 'INFO no-pattern', 'no-chunk': 'INFO no-chunk', 'replace-failed': 'FAIL replace-failed' }[s] || s);
    const line = `${tag(r.status).padEnd(20)} ${r.release}`;
    const extra = r.status === 'patched' ? ` (size=${r.size}, offset=${r.offset}, bak=${path.basename(r.bak)})` :
                   r.status === 'no-pattern' && force ? ' --force given; would be a problem' : '';
    console.log(line + extra);
  }

  const errors = results.filter((r) => r.status === 'replace-failed' || r.status === 'no-pattern').length;
  if (errors > 0 && force) {
    console.error(`FAIL: ${errors} release(s) could not be processed; --force was set so exiting 2.`);
    process.exit(2);
  }
  if (results.every((r) => r.status === 'no-chunk' || r.status === 'no-pattern' || r.status === 'already-patched')) {
    console.log('\nNothing to do. (Either every release is already patched, or none contain the OLD pattern.)');
  }
  if (results.some((r) => r.status === 'patched')) {
    console.log('\nNext steps:');
    console.log('  1. Restart any running mcode / mcode-island widget so the new chunks are loaded.');
    console.log('  2. Re-run install-hook.ps1 if you have not already.');
    console.log('  3. Trigger a tool call. island.log should show a "working ::" entry without the');
    console.log('     "[detect]" prefix within ~400 ms (one widget poll cycle).');
    console.log('  4. To undo: node restore.mjs');
  }
}

main();
