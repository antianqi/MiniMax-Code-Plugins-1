// restore.mjs — undo the in-place patch applied by apply.mjs.
//
// Version support.
//   Restores every release under ~/.minimax-code/releases/* that is
//   currently in the patched state (NEW present, OLD absent). Uses
//   the most recent chunk-<hash>.js.bak-* file written by apply.mjs.
//
//   --release <version>  restrict to one release (repeatable). Same
//                        strict validation as apply.mjs: the name must
//                        match a semver regex, the resolved path
//                        must exist as a directory, and its realpath
//                        must be the expected base/<name> (catches
//                        symlink escapes).
//   --force              error if a release is patched but no .bak
//                        is present.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const OLD = 't.usePlatformShell?Dva(a,bZ()):{executable:"/bin/sh",args:["-lc",a]}';
const NEW = '(t.usePlatformShell||process.platform==="win32")?Dva(a,bZ()):{executable:"/bin/sh",args:["-lc",a]}';

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
    if (e.code === 'ENOENT') return null;
    throw e;
  }
  const expected = path.join(baseReal, release);
  if (targetReal !== expected) {
    throw new Error(`Release path escapes base: ${targetReal} is not under ${expected}`);
  }
  if (!fs.statSync(targetReal).isDirectory()) {
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
    .filter((n) => RELEASE_NAME_RE.test(n))
    .sort();
}

function findChunkForRelease(release) {
  const releaseDir = resolveReleaseDir(release);
  if (!releaseDir) return null;
  const chunksDir = path.join(releaseDir, 'node_modules', '@minimax-ai', 'code', 'chunks');
  if (!fs.existsSync(chunksDir)) return null;
  const files = fs.readdirSync(chunksDir).filter((f) => f.startsWith('chunk-') && f.endsWith('.js'));
  for (const f of files) {
    const full = path.join(chunksDir, f);
    let realFull;
    try { realFull = fs.realpathSync(full); } catch { continue; }
    if (!realFull.startsWith(releaseDir + path.sep)) continue;
    let content;
    try { content = fs.readFileSync(realFull, 'utf8'); } catch { continue; }
    if (content.includes(OLD) || content.includes(NEW)) return realFull;
  }
  return null;
}

// Atomic same-directory copy: stage the .bak in a temp file, copy the
// original mode onto it, then rename over the live chunk. Mirrors
// apply.mjs's atomicWriteFileSync so a partial restore cannot leave
// the live chunk in a truncated state.
function atomicRestoreFromBak(live, bak) {
  const dir = path.dirname(live);
  const base = path.basename(live);
  const staging = path.join(dir, `${base}.staging-${process.pid}-${Date.now()}`);
  try {
    fs.copyFileSync(bak, staging);
    const bakStat = fs.statSync(bak);
    fs.chmodSync(staging, bakStat.mode);
    fs.renameSync(staging, live);
  } catch (e) {
    try { if (fs.existsSync(staging)) fs.unlinkSync(staging); } catch {}
    throw e;
  }
}

function restoreOne(chunkPath) {
  const live = fs.readFileSync(chunkPath, 'utf8');
  const dir = path.dirname(chunkPath);
  const base = path.basename(chunkPath);
  const result = { chunk: chunkPath, status: 'unknown' };

  if (live.includes(NEW) && !live.includes(OLD)) {
    const baks = fs.readdirSync(dir).filter((f) => f.startsWith(base + '.bak-')).sort();
    if (baks.length === 0) {
      result.status = 'no-backup';
      return result;
    }
    const newest = baks[baks.length - 1];
    atomicRestoreFromBak(chunkPath, path.join(dir, newest));
    result.status = 'restored';
    result.bak = newest;
    return result;
  }
  if (live.includes(OLD) && !live.includes(NEW)) {
    result.status = 'already-unpatched';
    return result;
  }
  result.status = 'unexpected-state';
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
    const r = restoreOne(chunk);
    r.release = rel;
    results.push(r);
  }

  for (const r of results) {
    const tag = (s) => ({ 'restored': 'OK restored', 'already-unpatched': 'OK unpatched', 'no-backup': 'WARN no-backup', 'no-chunk': 'INFO no-chunk', 'invalid': 'FAIL invalid', 'unexpected-state': 'FAIL unexpected' }[s] || s);
    const line = `${tag(r.status).padEnd(20)} ${r.release}`;
    const extra = r.status === 'restored' ? ` (from ${path.basename(r.bak)})` :
                   r.status === 'invalid' ? ` (${r.error})` : '';
    console.log(line + extra);
  }

  const errors = results.filter((r) => r.status === 'unexpected-state' || r.status === 'invalid').length;
  const noBackup = results.filter((r) => r.status === 'no-backup').length;
  if (errors > 0) process.exit(2);
  if (noBackup > 0 && force) process.exit(2);
}

main();
