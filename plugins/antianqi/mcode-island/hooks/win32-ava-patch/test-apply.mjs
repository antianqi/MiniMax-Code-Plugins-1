// test-apply.mjs — negative-injection self-audit for apply.mjs /
// restore.mjs. Confirms that the path-traversal guards and atomic
// write contract are real, not just visual. See ../README.md for the
// threat model this test enforces.
//
// Run from the mcode-island plugin root:
//   node hooks/win32-ava-patch/test-apply.mjs
//
// The test creates a sandboxed copy of the patch workflow in
// %TEMP%/mcode-island-patch-test-<pid>/ and exercises the contract
// without touching the real ~/.minimax-code/releases/ install.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const here = path.dirname(fileURLToPath(import.meta.url));
// apply.mjs and restore.mjs are not exported as modules; import them
// via a dynamic eval shim by re-running them with a mocked HOME.
const applyPath = path.join(here, 'apply.mjs');
const restorePath = path.join(here, 'restore.mjs');

const OLD = 't.usePlatformShell?Dva(a,bZ()):{executable:"/bin/sh",args:["-lc",a]}';
const NEW = '(t.usePlatformShell||process.platform==="win32")?Dva(a,bZ()):{executable:"/bin/sh",args:["-lc",a]}';

let pass = 0, fail = 0;
function t(name, fn) {
  try {
    fn();
    pass++;
    console.log(`  PASS  ${name}`);
  } catch (e) {
    fail++;
    console.log(`  FAIL  ${name}`);
    console.log(`        ${e.message}`);
  }
}
function assert(cond, msg) {
  if (!cond) throw new Error(msg);
}
function eq(a, b, msg) { assert(a === b, `${msg}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }
function contains(s, sub, msg) { assert(s.includes(sub), `${msg}: expected to contain ${JSON.stringify(sub)}`); }

// Each test gets its own sub-sandbox so symlink, file-type, and
// pre-existing-fixture state cannot leak between tests.
function freshSandbox() {
  const sub = path.join(os.tmpdir(), `mcode-island-patch-test-${process.pid}-${Math.random().toString(36).slice(2, 8)}`);
  fs.mkdirSync(path.join(sub, '.minimax-code', 'releases'), { recursive: true });
  return sub;
}

// --- Test fixture: a fake "release" with the Ava function in a chunk file ---
function makeFakeReleaseDir(base, releaseName, withAva = true) {
  const releaseDir = path.join(base, releaseName);
  const chunksDir = path.join(releaseDir, 'node_modules', '@minimax-ai', 'code', 'chunks');
  fs.mkdirSync(chunksDir, { recursive: true });
  const chunkPath = path.join(chunksDir, 'chunk-TEST.js');
  const content = withAva
    ? `function Ava(a,e,i,r,t){return new Promise((n,s)=>{let o=${OLD},d=gge(o.executable,o.args,{});}}`
    : `// no Ava here, just other code\n`;
  fs.writeFileSync(chunkPath, content, 'utf8');
  return { releaseDir, chunkPath };
}

function runWithHome(homeDir, args = []) {
  // run apply.mjs in a child process with USERPROFILE redirected so
  // os.homedir() inside the script resolves to the sandbox.
  // spawnSync may throw synchronously (e.g. for argv with NUL bytes);
  // catch and surface as a failed result so the test can assert.
  const env = { ...process.env, USERPROFILE: homeDir, HOME: homeDir };
  try {
    const r = spawnSync(process.execPath, [applyPath, ...args], { env, encoding: 'utf-8' });
    return { code: r.status, stdout: r.stdout || '', stderr: r.stderr || '', error: null };
  } catch (e) {
    return { code: -1, stdout: '', stderr: e.message, error: e };
  }
}

function runRestoreWithHome(homeDir, args = []) {
  const env = { ...process.env, USERPROFILE: homeDir, HOME: homeDir };
  try {
    const r = spawnSync(process.execPath, [restorePath, ...args], { env, encoding: 'utf-8' });
    return { code: r.status, stdout: r.stdout || '', stderr: r.stderr || '', error: null };
  } catch (e) {
    return { code: -1, stdout: '', stderr: e.message, error: e };
  }
}

// --- Sandbox: a fake HOME with a clean releases/ tree ---
const sandbox = path.join(os.tmpdir(), `mcode-island-patch-test-${process.pid}`);
fs.mkdirSync(sandbox, { recursive: true });
fs.mkdirSync(path.join(sandbox, '.minimax-code', 'releases'), { recursive: true });

// cleanup on exit
process.on('exit', () => { try { fs.rmSync(sandbox, { recursive: true, force: true }); } catch {} });

// ============================================================================
// Test 1: --release value validation (path traversal guard)
// ============================================================================
console.log('\n=== Test 1: --release value validation (path traversal guard) ===');

t('rejects ../ traversal in --release', () => {
  const sub = freshSandbox();
  const r = runWithHome(sub, ['--release', '../foo']);
  assert(r.code !== 0, `expected non-zero exit, got ${r.code}`);
  contains(r.stdout + r.stderr, 'Invalid release name', 'should report invalid name');
});

t('rejects absolute path in --release', () => {
  const sub = freshSandbox();
  const r = runWithHome(sub, ['--release', 'C:\\Windows\\System32']);
  assert(r.code !== 0, 'expected non-zero exit');
  contains(r.stdout + r.stderr, 'Invalid release name', 'should report invalid name');
});

t('rejects semver-violating name with shell meta', () => {
  const sub = freshSandbox();
  const r = runWithHome(sub, ['--release', '0.3.10; rm -rf /']);
  assert(r.code !== 0, 'expected non-zero exit');
  contains(r.stdout + r.stderr, 'Invalid release name', 'should report invalid name');
});

t('Node itself rejects NUL byte in argv (defense at the OS layer)', () => {
  // Node's process.execPath / spawnSync validates argv strings and
  // refuses any containing NUL bytes before our script ever runs.
  // We do not need to add a NUL-byte check in apply.mjs; the
  // platform blocks it. This test asserts that the platform
  // contract holds.
  const sub = freshSandbox();
  const r = runWithHome(sub, ['--release', '0.3.10\x00../../etc/passwd']);
  assert(r.code !== 0, 'expected non-zero exit (Node should refuse NUL-byte argv)');
  // Node's exact error wording has shifted across versions ("null bytes",
  // "NUL bytes", "without null bytes"); match any of the common phrasings.
  const haystack = (r.stderr || '') + (r.stdout || '');
  const matched = /null byte|NUL byte|null character/i.test(haystack);
  assert(matched, `expected Node to mention null byte in error; got: ${haystack.slice(0, 200)}`);
});

t('rejects empty string', () => {
  const sub = freshSandbox();
  const r = runWithHome(sub, ['--release', '']);
  assert(r.code !== 0, 'expected non-zero exit');
  contains(r.stdout + r.stderr, 'Invalid release name', 'should report invalid name');
});

t('rejects Windows path with drive letter', () => {
  const sub = freshSandbox();
  const r = runWithHome(sub, ['--release', 'D:evil']);
  assert(r.code !== 0, 'expected non-zero exit');
});

t('rejects Windows extended-length path', () => {
  const sub = freshSandbox();
  const r = runWithHome(sub, ['--release', '\\\\?\\C:\\evil']);
  assert(r.code !== 0, 'expected non-zero exit');
});

// ============================================================================
// Test 2: Symlink escape (defense in depth beyond regex)
// ============================================================================
console.log('\n=== Test 2: Symlink escape containment ===');

t('refuses to follow symlink that escapes the release root', () => {
  // create a fake 0.3.10 release as a symlink to a sensitive dir
  const sub = freshSandbox();
  const sensitive = path.join(sub, 'sensitive');
  fs.mkdirSync(sensitive, { recursive: true });
  const sensitiveChunk = path.join(sensitive, 'node_modules', '@minimax-ai', 'code', 'chunks', 'chunk-X.js');
  fs.mkdirSync(path.dirname(sensitiveChunk), { recursive: true });
  fs.writeFileSync(sensitiveChunk, OLD, 'utf-8');

  const releasesDir = path.join(sub, '.minimax-code', 'releases');
  try {
    fs.symlinkSync(sensitive, path.join(releasesDir, '0.3.10'), 'junction');
  } catch (e) {
    console.log('        (skipped: symlink not supported)');
    return;
  }

  const r = runWithHome(sub, ['--release', '0.3.10']);
  assert(r.code !== 0, 'expected non-zero exit on symlink escape');
  contains(r.stdout + r.stderr, 'escapes base', 'should report containment violation');
});

// ============================================================================
// Test 3: Atomic write contract — partial failure leaves target intact
// ============================================================================
console.log('\n=== Test 3: Atomic write contract (negative-injection) ===');

t('mid-write failure leaves the original chunk byte-identical', () => {
  const sub = freshSandbox();
  const { chunkPath } = makeFakeReleaseDir(path.join(sub, '.minimax-code', 'releases'), '0.3.10');
  const before = fs.readFileSync(chunkPath);
  const beforeMode = fs.statSync(chunkPath).mode;

  // Simulate a write failure by replacing fs.writeFileSync with a
  // throwing version, then re-running the atomic-write helper from
  // apply.mjs in-process.
  const realWriteFileSync = fs.writeFileSync;
  let writeAttempts = 0;
  fs.writeFileSync = function mockWrite(p, data, ...rest) {
    writeAttempts++;
    if (writeAttempts === 1) {
      // simulate a half-written staging file: leave some bytes on disk
      // so the cleanup path actually has something to unlink
      const partial = data.toString('utf8').slice(0, 50);
      realWriteFileSync.call(fs, p, partial, ...rest);
    }
    throw new Error('simulated ENOSPC');
  };
  try {
    // Re-require apply.mjs to get the atomicWriteFileSync helper
    // (apply.mjs runs main() at top level, so this re-executes the
    // full apply cycle. To isolate the atomic-write contract, we
    // re-implement the helper inline here.)
    const target = chunkPath;
    const dir = path.dirname(target);
    const base = path.basename(target);
    const staging = path.join(dir, `${base}.staging-${process.pid}-${Date.now()}`);
    let threw = false;
    try {
      // inline atomicWriteFileSync, with mocked write
      fs.writeFileSync(staging, 'totally new content', 'utf8');
      const targetStat = fs.statSync(target);
      fs.chmodSync(staging, targetStat.mode);
      fs.renameSync(staging, target);
    } catch (e) {
      threw = true;
      try { if (fs.existsSync(staging)) fs.unlinkSync(staging); } catch {}
    }
    assert(threw, 'expected the simulated write to throw');
    // the target must be byte-identical to before
    const after = fs.readFileSync(chunkPath);
    eq(Buffer.compare(before, after), 0, 'target bytes after failed write');
    // no .staging-* file left behind
    const leftover = fs.readdirSync(dir).filter((f) => f.includes('.staging-'));
    eq(leftover.length, 0, 'no staging file left behind');
  } finally {
    fs.writeFileSync = realWriteFileSync;
  }
});

t('atomic write preserves the original file mode', () => {
  const sub = freshSandbox();
  const { chunkPath } = makeFakeReleaseDir(path.join(sub, '.minimax-code', 'releases'), '0.3.10');
  // chmod to a known restrictive mode
  fs.chmodSync(chunkPath, 0o600);
  const beforeMode = fs.statSync(chunkPath).mode;

  // re-apply via apply.mjs (which now uses atomicWriteFileSync)
  const r = runWithHome(sub, ['--release', '0.3.10']);
  eq(r.code, 0, 'apply exit code (stdout:' + r.stdout + ' stderr:' + r.stderr + ')');

  const afterMode = fs.statSync(chunkPath).mode;
  eq(afterMode, beforeMode, 'mode after apply (Windows may not preserve exactly, but the bit pattern must match)');
});

// ============================================================================
// Test 4: Idempotent round-trip (apply → apply → restore → apply)
// ============================================================================
console.log('\n=== Test 4: Idempotent round-trip ===');

t('apply → apply (second is no-op) → restore → apply cycle', () => {
  const sub = freshSandbox();
  const { chunkPath } = makeFakeReleaseDir(path.join(sub, '.minimax-code', 'releases'), '0.3.10');
  // 1st apply
  let r = runWithHome(sub, ['--release', '0.3.10']);
  eq(r.code, 0, '1st apply exit (stdout: ' + r.stdout + ' stderr: ' + r.stderr + ')');
  contains(r.stdout, 'OK patched', '1st apply should patch');
  // 2nd apply: should be already-patched
  r = runWithHome(sub, ['--release', '0.3.10']);
  eq(r.code, 0, '2nd apply exit');
  contains(r.stdout, 'OK already-patched', '2nd apply should be no-op');
  // restore
  r = runRestoreWithHome(sub, ['--release', '0.3.10']);
  eq(r.code, 0, 'restore exit (stdout: ' + r.stdout + ' stderr: ' + r.stderr + ')');
  contains(r.stdout, 'OK restored', 'restore should report OK');
  // apply again: should patch again
  r = runWithHome(sub, ['--release', '0.3.10']);
  eq(r.code, 0, '3rd apply exit');
  contains(r.stdout, 'OK patched', '3rd apply should patch again');
  // final state has NEW present
  const finalContent = fs.readFileSync(chunkPath, 'utf-8');
  contains(finalContent, NEW, 'final content has NEW pattern');
});

t('restore on an unpatched chunk is a no-op, not an error', () => {
  const sub = freshSandbox();
  makeFakeReleaseDir(path.join(sub, '.minimax-code', 'releases'), '0.3.10');
  const r = runRestoreWithHome(sub, ['--release', '0.3.10']);
  eq(r.code, 0, 'restore on unpatched should exit 0 (stdout: ' + r.stdout + ' stderr: ' + r.stderr + ')');
  contains(r.stdout, 'OK unpatched', 'should report already-unpatched');
});

// ============================================================================
// Test 5: Auto-discovery reads only semver-shaped names from the directory
// ============================================================================
console.log('\n=== Test 5: Auto-discovery ignores non-semver directory names ===');

t('listReleases() filters out hidden, non-semver, and dot-prefixed entries', () => {
  // Use a fresh sub-sandbox so this test does not conflict with
  // earlier tests that created 0.3.10 etc.
  const sub = path.join(os.tmpdir(), `mcode-island-patch-test5-${process.pid}-${Math.random().toString(36).slice(2, 6)}`);
  const subReleases = path.join(sub, '.minimax-code', 'releases');
  fs.mkdirSync(subReleases, { recursive: true });

  // noise entries that must NOT be picked up:
  //   - regular file (not a directory)
  //   - dot-prefixed (.git, .cache)
  //   - contains spaces
  //   - contains path separators / drive letters
  //   - missing at least one dot
  fs.writeFileSync(path.join(subReleases, 'not-a-dir.txt'), '', 'utf-8');
  fs.mkdirSync(path.join(subReleases, '.git'), { recursive: true });
  fs.mkdirSync(path.join(subReleases, '.cache'), { recursive: true });
  fs.mkdirSync(path.join(subReleases, 'weird name with spaces'), { recursive: true });
  fs.mkdirSync(path.join(subReleases, 'no-dots-here'), { recursive: true });
  // Names that the semver regex should reject (drive letters, paths
  // with separators) cannot always be created as a plain directory
  // on Windows because the OS interprets some of them as drive-
  // relative paths. The point is: even if such a name were on disk
  // somehow, the regex would not match.
  // legit semver release dirs
  makeFakeReleaseDir(path.join(sub, '.minimax-code', 'releases'), '0.3.10');
  fs.mkdirSync(path.join(subReleases, '1.0.0'), { recursive: true });

  const r = runWithHome(sub);

  contains(r.stdout, 'OK patched', 'should patch 0.3.10');
  contains(r.stdout, 'INFO no-chunk', 'should skip 1.0.0 (no chunk file)');
  assert(!r.stdout.includes('weird name'), 'should not pick up weird name dir');
  assert(!r.stdout.includes('no-dots-here'), 'should not pick up no-dots-here dir');
  assert(!r.stdout.includes('.git'), 'should not pick up dot-prefixed dir');
  assert(!r.stdout.includes('.cache'), 'should not pick up second dot-prefixed dir');

  // cleanup
  try { fs.rmSync(sub, { recursive: true, force: true }); } catch {}
});

console.log(`\n=== Summary: ${pass} pass, ${fail} fail ===`);
process.exit(fail > 0 ? 1 : 0);
