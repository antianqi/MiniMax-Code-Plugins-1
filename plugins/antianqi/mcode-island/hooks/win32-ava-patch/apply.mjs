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
//   --release <version>  restrict to one release (repeatable). The
//                        version value is matched against a strict
//                        semver regex and the resolved path is
//                        checked for containment under the release
//                        root (no ../, no absolute, no symlink escape).
//                        If you want to ignore this and write outside
//                        the boundary, you are using the wrong tool.
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
//   - Otherwise, applies the patch via an atomic staging-file + rename
//     (preserves the file mode of the original chunk). The first
//     time apply.mjs mutates a file, it copies the pre-patch bytes
//     to <name>.bak-<ISO-timestamp> next to the chunk; restore.mjs
//     uses that backup. The staging file is removed on any failure
//     so a partial write can never leave the live chunk in a
//     truncated state.
//
// Risk and durability.
//   - Touches node_modules; will be overwritten by the next
//     `npm install -g @minimax-ai/code`. Re-run after every upgrade.
//   - A backup of the original chunk is written next to it
//     (chunk-<hash>.js.bak-<timestamp>) the first time apply.mjs
//     mutates the file. restore.mjs uses that backup.
//   - The live chunk is only ever replaced by an atomic rename of a
//     same-directory staging file that already carries the chunk's
//     original permission mode. A process interrupt, ENOSPC, or any
//     other write-time failure leaves the original chunk byte-
//     identical to its pre-apply state.
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

// Strict semver-ish: X.Y.Z with optional -prerelease.tag. Rejects
// anything containing path separators, "..", absolute-path prefixes,
// or shell metacharacters, before the script ever touches a path.
const RELEASE_NAME_RE = /^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?$/;

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

// Validates a release name and resolves its absolute path, with
// containment under the release base. Rejects:
//   - any name not matching the semver regex (../, absolute paths,
//     drive letters, NUL bytes, etc. all fail the regex)
//   - any path that does not exist as a directory
//   - any directory whose realpath is not the expected base/<name>
//     (catches symlink escapes)
function resolveReleaseDir(release) {
  if (typeof release !== 'string' || !RELEASE_NAME_RE.test(release)) {
    throw new Error(`Invalid release name: ${JSON.stringify(release)} (must match ${RELEASE_NAME_RE})`);
  }
  const baseReal = fs.realpathSync(releaseBase());
  const target = path.join(baseReal, release);
  let targetReal;
  try {
    targetReal = fs.realpathSync(target);
  } catch (e) {
    if (e.code === 'ENOENT') return null;  // not installed; let caller decide
    throw e;
  }
  const expected = path.join(baseReal, release);
  if (targetReal !== expected) {
    throw new Error(`Release path escapes base: ${targetReal} is not under ${expected}`);
  }
  const st = fs.statSync(targetReal);
  if (!st.isDirectory()) {
    throw new Error(`Release path is not a directory: ${targetReal}`);
  }
  return targetReal;
}

function listReleases() {
  const base = releaseBase();
  if (!fs.existsSync(base)) return [];
  return fs.readdirSync(base, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .filter((n) => RELEASE_NAME_RE.test(n))  // defense in depth
    .sort();
}

function findChunkForRelease(release) {
  // validate first; throws on bad names so a malicious --release
  // value cannot reach the disk read path
  const releaseDir = resolveReleaseDir(release);
  if (!releaseDir) return null;
  const chunksDir = path.join(releaseDir, 'node_modules', '@minimax-ai', 'code', 'chunks');
  if (!fs.existsSync(chunksDir)) return null;
  const files = fs.readdirSync(chunksDir).filter((f) => f.startsWith('chunk-') && f.endsWith('.js'));
  for (const f of files) {
    const full = path.join(chunksDir, f);
    let realFull;
    try { realFull = fs.realpathSync(full); } catch { continue; }
    if (!realFull.startsWith(releaseDir + path.sep)) continue;  // belt + braces
    let content;
    try { content = fs.readFileSync(realFull, 'utf8'); } catch { continue; }
    if (content.includes(OLD) || content.includes(NEW)) return realFull;
  }
  return null;
}

// Atomic same-directory write: stage the new contents in a temp file
// that already carries the original target's permission mode, then
// rename over the target. If anything throws, the staging file is
// removed and the original target is left byte-identical.
function atomicWriteFileSync(target, data) {
  const dir = path.dirname(target);
  const base = path.basename(target);
  const staging = path.join(dir, `${base}.staging-${process.pid}-${Date.now()}`);
  try {
    fs.writeFileSync(staging, data, 'utf8');
    const targetStat = fs.statSync(target);
    fs.chmodSync(staging, targetStat.mode);
    fs.renameSync(staging, target);
  } catch (e) {
    try { if (fs.existsSync(staging)) fs.unlinkSync(staging); } catch {}
    throw e;
  }
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
  atomicWriteFileSync(chunkPath, patched);
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
    let chunk = null;
    try {
      chunk = findChunkForRelease(rel);
    } catch (e) {
      results.push({ release: rel, status: 'invalid', error: e.message });
      continue;
    }
    if (!chunk) {
      results.push({ release: rel, status: 'no-chunk' });
      continue;
    }
    const r = applyOne(chunk);
    r.release = rel;
    results.push(r);
  }

  for (const r of results) {
    const tag = (s) => ({ 'patched': 'OK patched', 'already-patched': 'OK already-patched', 'no-pattern': 'INFO no-pattern', 'no-chunk': 'INFO no-chunk', 'invalid': 'FAIL invalid', 'replace-failed': 'FAIL replace-failed' }[s] || s);
    const line = `${tag(r.status).padEnd(20)} ${r.release}`;
    const extra = r.status === 'patched' ? ` (size=${r.size}, offset=${r.offset}, bak=${path.basename(r.bak)})` :
                   r.status === 'invalid' ? ` (${r.error})` : '';
    console.log(line + extra);
  }

  const errors = results.filter((r) => r.status === 'replace-failed' || (r.status === 'no-pattern' && force) || r.status === 'invalid').length;
  if (errors > 0 && (force || results.some((r) => r.status === 'invalid' || r.status === 'replace-failed'))) {
    console.error(`FAIL: ${errors} release(s) could not be processed.`);
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
