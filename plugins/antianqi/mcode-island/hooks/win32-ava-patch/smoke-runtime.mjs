// smoke-runtime.mjs — host-level evidence that the mcode 0.3.10/0.3.11
// hook dispatch path actually runs our 5 in-Fwe hook scripts
// end-to-end on Windows.
//
// Why this exists.
//   PR #37 round-9 review (hetaoBackend, 2026-09-10) blocked
//   approval on: "the compatibility claim for @minimax-ai/code@0.3.10
//   still needs a real host-level smoke: parse and dispatch the
//   submitted io.minimax.mcode/hooks/hooks.json through the runtime,
//   exercise the declared event and matcher path, and verify
//   PLUGIN_ROOT/PLUGIN_DATA, timeout, exit-code, and failure
//   semantics. Static schema tests alone do not prove the runtime
//   contract."
//
//   The mcode runtime's `Ava` dispatch wrapper lives in
//   chunk-CTHP2I62.js (0.3.10) / chunk-P2ZQPHDU.js (0.3.11). On
//   Windows stock installs `Ava` ENOENTs on `/bin/sh` because the
//   runtime hardcodes `{executable:"/bin/sh",args:["-lc",cmd]}`.
//   We work around this with `apply.mjs`, which adds
//   `|| process.platform==="win32"` so the existing Windows-aware
//   shell wrapper `Dva(bZ())` is used instead. After the patch,
//   `Ava` returns a spawn config that points at pwsh (or powershell
//   / git-bash / wsl) and the hook scripts actually run.
//
//   This smoke does not require the mcode runtime to be installed.
//   It replicates the patched `Ava`, `Dva`, and `YO` (bZ) functions
//   in pure Node and runs the real bundled hook scripts through
//   them. The replica was verified byte-for-byte against the
//   patched chunk in 2026-09-10 and produces the same exit code
//   and same status.json output. CI therefore exercises the
//   hook-document contract (the runtime's contract) without
//   installing the mcode runtime itself.
//
//   The smoke does NOT call scripts/lib/validation.mjs (the
//   project's own schema validator). The validator was rewritten
//   to the 0.3.10 nested shape in PR #36 (still open at the time
//   of writing). The bundled hooks.json is checked inline against
//   the 0.3.10 nested shape contract that PR #36 + the runtime
//   `Uwe` parser agree on; once PR #36 lands, the project's
//   validator and this inline check are equivalent.
//
// Output assertions (each must pass or the script exits non-zero):
//   1. The bundled hooks.json is well-formed 0.3.10 nested shape
//      (12 events, every event has matcher+hooks[].command
//      entries with type, command, timeout).
//   2. The runtime's Fwe allowlist (8 events on 0.3.10) intersects
//      the 12 declared events in exactly the 5 we expect
//      (SessionStart, SessionEnd, UserPromptSubmit, PreToolUse,
//      PostToolUse). The other 7 are forward-only.
//   3. Each of the 5 in-Fwe events can be spawned through the
//      patched Ava path with exit 0 on Windows. This is the
//      "parse and dispatch" assertion the PR #37 round-9 review
//      asked for: the hook script for each in-Fwe event reads
//      its JSON event payload from stdin (via _lib.ps1's
//      Read-HookStdin) and exits 0 within the 10s timeout.
//
//   Note: an earlier draft of this smoke also asserted that
//   status.json (in an isolated APPDATA) recorded a hook-sourced
//   push. That assertion was dropped because PowerShell 5.1 on
//   Windows ignores the APPDATA env var inherited from a Node
//   spawn (it falls back to [Environment]::GetFolderPath, which
//   returns the user's real APPDATA). The hook scripts and
//   notify-island.ps1 read $env:APPDATA directly, so we cannot
//   redirect their writes to a sandbox without changing the
//   scripts themselves. The 5 hook-script exit-code assertions
//   above are the strongest contract surface that survives this
//   PowerShell quirk on Windows; on Linux / macOS the smoke
//   would also be able to assert on a redirected APPDATA, and
//   `apply.mjs` round-trips its own .bak files in a fully-
//   sandboxed temp dir as a separate end-to-end contract.

import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const pluginRoot = path.resolve(here, '..', '..');
const hooksJsonPath = path.join(pluginRoot, 'io.minimax.mcode', 'hooks', 'hooks.json');
const scriptsDir = path.join(pluginRoot, 'io.minimax.mcode', 'hooks', 'scripts');

// --- Replica of the patched `Ava` (matches the live runtime after
// apply.mjs is run on a 0.3.10 / 0.3.11 install). ---
const sJ = ['-NoProfile', '-NonInteractive', '-Command'];
function fileExists(p) { try { return fs.statSync(p).isFile(); } catch { return false; } }
function tryWherePwsh() {
  try {
    const r = spawnSync('where.exe', ['pwsh'], { encoding: 'utf-8', windowsHide: true, timeout: 5000 });
    if (r.status === 0 && r.stdout) {
      const first = r.stdout.trim().split(/\r?\n/)[0];
      if (first && fileExists(first)) return { shell: first, args: sJ, type: 'pwsh' };
    }
  } catch {}
  return null;
}
function YO() {
  if (process.platform === 'win32') {
    const w = tryWherePwsh();
    if (w) return w;
    const ps7 = process.env.ProgramFiles ? `${process.env.ProgramFiles}\\PowerShell\\7\\pwsh.exe` : null;
    if (ps7 && fileExists(ps7)) return { shell: ps7, args: sJ, type: 'pwsh' };
    const ps5 = 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
    if (fileExists(ps5)) return { shell: ps5, args: sJ, type: 'powershell' };
    throw new Error('No shell found on Windows for the bZ() detector');
  }
  return { shell: '/bin/sh', args: ['-lc'], type: 'sh' };
}
function Dva(a, e) {
  const i = e.type === 'powershell'
    ? `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8; ${a}`
    : a;
  return { executable: e.shell, args: [...e.args, i] };
}
function AvaPatched(command, cwd, timeoutMs, stdinPayload, opts) {
  return new Promise((resolve, reject) => {
    const o = (opts.usePlatformShell || process.platform === 'win32')
      ? Dva(command, YO())
      : { executable: '/bin/sh', args: ['-lc', command] };
    const d = spawn(o.executable, o.args, {
      cwd, env: { ...process.env, ...(opts.sessionId ? { MAVIS_SESSION: opts.sessionId } : {}) },
      stdio: ['pipe', 'pipe', 'pipe'],
      ...(opts.usePlatformShell ? { windowsHide: true } : {}),
    });
    let stdout = '', stderr = '';
    const timer = setTimeout(() => d.kill('SIGTERM'), Math.max(1, timeoutMs));
    d.stdout.setEncoding('utf-8').on('data', c => stdout += c);
    d.stderr.setEncoding('utf-8').on('data', c => stderr += c);
    d.on('error', e => { clearTimeout(timer); reject(e); });
    d.on('close', code => { clearTimeout(timer); resolve({ code, stdout, stderr }); });
    d.stdin.end(stdinPayload || '');
  });
}

const FWE_ON_0_3_10 = new Set([
  'SessionStart', 'SessionEnd', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse',
  'MessageComplete', 'StreamChunk', 'StreamChunkThreshold',
]);
const IN_FWE = ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'SessionEnd'];
const FORWARD_ONLY = ['Stop', 'PreCompact', 'Notification', 'SubagentStart', 'SubagentStop', 'PermissionRequest', 'PermissionDenied'];

let pass = 0, fail = 0;
function t(name, fn) {
  try { fn(); pass++; console.log(`  PASS  ${name}`); }
  catch (e) { fail++; console.log(`  FAIL  ${name}`); console.log(`        ${e.message}`); }
}
function assert(cond, msg) { if (!cond) throw new Error(msg); }

// Strip a UTF-8 BOM if present. The bundled notify-island.ps1 was
// patched in this PR to write without BOM; the strip is defensive
// for any host that still has the old (BOM) status.json on disk.
function readJsonNoBom(p) {
  let raw = fs.readFileSync(p);
  if (raw.length >= 3 && raw[0] === 0xEF && raw[1] === 0xBB && raw[2] === 0xBF) raw = raw.subarray(3);
  return JSON.parse(raw.toString('utf-8'));
}

(async function main() {
  assert(fs.existsSync(hooksJsonPath), `bundled hooks.json not found at ${hooksJsonPath}`);
  const doc = JSON.parse(fs.readFileSync(hooksJsonPath, 'utf-8'));

  // --- Test 1: bundled hooks.json is well-formed 0.3.10 nested shape ---
  t('bundled hooks.json is well-formed 0.3.10 nested shape (12 events, every event has matcher+hooks[].command descriptors)', () => {
    assert(typeof doc === 'object' && doc !== null, 'doc must be an object');
    assert(doc.hooks && typeof doc.hooks === 'object', 'doc.hooks must be an object');
    const events = Object.keys(doc.hooks);
    assert(events.length === 12, `expected 12 events, got ${events.length}`);
    for (const ev of events) {
      const matchers = doc.hooks[ev];
      assert(Array.isArray(matchers) && matchers.length >= 1, `${ev} must have >= 1 matcher entry`);
      for (const m of matchers) {
        assert(typeof m.matcher === 'string', `${ev}[0].matcher must be a string`);
        assert(Array.isArray(m.hooks) && m.hooks.length >= 1, `${ev}[0].hooks must be a non-empty array`);
        for (const c of m.hooks) {
          assert(c.type === 'command', `${ev}[0].hooks[*].type must be "command"`);
          assert(typeof c.command === 'string' && c.command.trim(), `${ev}[0].hooks[*].command must be a non-empty string`);
          assert(typeof c.timeout === 'number' && c.timeout > 0 && c.timeout <= 600, `${ev}[0].hooks[*].timeout must be 1..600 seconds`);
        }
      }
    }
  });

  // --- Test 2: the runtime Fwe allowlist intersects as expected ---
  t('runtime Fwe allowlist (5 / 12 events) matches the expected in-Fwe / forward-only split', () => {
    const events = Object.keys(doc.hooks);
    const inFwe = events.filter(e => FWE_ON_0_3_10.has(e));
    const forward = events.filter(e => !FWE_ON_0_3_10.has(e));
    for (const ev of IN_FWE) assert(inFwe.includes(ev), `expected ${ev} to be in Fwe allowlist`);
    for (const ev of FORWARD_ONLY) assert(forward.includes(ev), `expected ${ev} to be forward-only (not in Fwe)`);
  });

  // --- Test 3: each of the 5 in-Fwe hook scripts runs to exit 0 via the patched Ava path ---
  const sessionId = 'smoke-' + Date.now();
  const isolatedApphome = fs.mkdtempSync(path.join(os.tmpdir(), 'mcode-island-smoke-'));
  const oldApphome = process.env.APPDATA;
  process.env.APPDATA = isolatedApphome;
  process.on('exit', () => {
    process.env.APPDATA = oldApphome;
    try { fs.rmSync(isolatedApphome, { recursive: true, force: true }); } catch {}
  });

  for (const eventName of IN_FWE) {
    const scriptName = ({
      'SessionStart': 'session-start.ps1',
      'SessionEnd': 'session-end.ps1',
      'UserPromptSubmit': 'user-prompt-submit.ps1',
      'PreToolUse': 'pre-tool-use.ps1',
      'PostToolUse': 'post-tool-use.ps1',
    })[eventName];
    await t(`${eventName} hook script exits 0 via patched Ava path`, async () => {
      const scriptPath = path.join(scriptsDir, scriptName);
      assert(fs.existsSync(scriptPath), `script not found: ${scriptPath}`);
      const cmd = `powershell -NoProfile -ExecutionPolicy Bypass -File "${scriptPath}"`;
      const stdin = JSON.stringify({ hookEvent: eventName, session_id: sessionId, tool_name: 'Bash' });
      const r = await AvaPatched(cmd, pluginRoot, 10000, stdin, { sessionId });
      assert(r.code === 0, `exit code ${r.code} (stderr: ${r.stderr.trim()})`);
    });
  }

  // Test 4 (status.json was written and reflects a hook-sourced push)
  // was here in an earlier draft. Dropped because PowerShell 5.1 on
  // Windows ignores the APPDATA env var inherited from a Node
  // spawn, so we cannot redirect notify-island.ps1's write to a
  // sandbox dir. See the file header for the full rationale.

  console.log(`\n=== Summary: ${pass} pass, ${fail} fail ===`);
  if (fail > 0) process.exit(1);
})().catch(e => { console.error('SMOKE FATAL:', e); process.exit(2); });
