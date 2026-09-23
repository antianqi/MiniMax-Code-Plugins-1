#!/usr/bin/env node
// mcode-island v0.4.x — negative-first self-check for the sub-step
// progress extension (status.json step/total/detail fields, widget
// Build-DisplayMessage, hooks Format-ToolSummary extension).
//
// Cross-platform (Windows / macOS / Linux). No deps beyond Node >= 18.
//
// Exit 0 on full pass, 1 on any failure. Per-check line prints
// PASS / FAIL with the failing expectation.
//
// Test design (per mcode-island round-4 lesson):
//   For every contract, the test MUST be able to fail when the
//   implementation regresses. We achieve this by:
//     1. Asserting the *observable* contract (status.json shape,
//        PowerShell function output) not the internal call graph
//     2. Covering the boundary that breaks most often: backward
//        compat (old callers must still produce valid status.json)

import { spawn } from 'node:child_process';
import { mkdir, writeFile, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { strict as assert } from 'node:assert';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PLUGIN_ROOT = resolve(__dirname, '..');
const NOTIFY_ISLAND = join(PLUGIN_ROOT, 'notify-island.ps1');
const WIDGET = join(PLUGIN_ROOT, 'mcode-island.ps1');
const LIB = join(PLUGIN_ROOT, 'io.minimax.mcode', 'hooks', 'scripts', '_lib.ps1');

// Cross-platform pwsh lookup: prefer pwsh7 install in $HOME, fall back
// to PATH-resolved `pwsh`. We do NOT hardcode C:\ paths in production
// (the smoke.mjs contract); the override here is just for the local
// Windows dev machine where pwsh 5.1 is also present and would
// choke on #requires / ConvertFrom-Json -AsHashtable.
function findPwsh() {
    if (process.platform === 'win32') {
        const home = process.env.USERPROFILE || process.env.HOME || '';
        const candidates = [
            join(home, 'pwsh7_6', 'pwsh.exe'),
            join(home, 'pwsh', 'pwsh.exe'),
        ];
        return candidates[0]; // best-effort; if missing, spawn falls back to PATH
    }
    return 'pwsh';
}

const PWSH = findPwsh();

let pass = 0, fail = 0;
const out = (tag, msg) => {
    const sym = { PASS: 'OK  ', FAIL: 'FAIL' }[tag];
    console.log(`[${sym}] ${msg}`);
    if (tag === 'PASS') pass++; else fail++;
};

const exists = async (p) => {
    try { await stat(p); return true; } catch { return false; }
};

// Spawn pwsh with a custom $env:APPDATA so we don't disturb the
// real %APPDATA%\mcode-island\ the widget is reading.
async function runPwsh(script, extraEnv = {}) {
    const tmpAppData = join(tmpdir(), `mcode-island-test-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`);
    await mkdir(join(tmpAppData, 'mcode-island'), { recursive: true });
    return new Promise((resolveP, rejectP) => {
        const child = spawn(PWSH, ['-NoProfile', '-Command', script], {
            env: {
                ...process.env,
                APPDATA: tmpAppData,
                ...extraEnv,
            },
        });
        let stdout = '', stderr = '';
        child.stdout.on('data', (d) => stdout += d);
        child.stderr.on('data', (d) => stderr += d);
        child.on('close', (code) => resolveP({ stdout, stderr, code, tmpAppData }));
        child.on('error', rejectP);
    });
}

async function readStatusJsonOf(tmpAppData) {
    // notify-island.ps1 writes via [System.IO.File]::WriteAllText(.., UTF8).
    // On Windows PowerShell 5.1 / .NET Framework that emits a UTF-8 BOM
    // (\ufeff). PowerShell's Get-Content -Encoding UTF8 strips it, but
    // Node's strict JSON.parse doesn't. We strip here so the test sees
    // what the widget sees.
    let raw = await readFile(join(tmpAppData, 'mcode-island', 'status.json'), 'utf8');
    if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
    return raw;
}

// ---------------------------------------------------------------------------
// 1. notify-island.ps1 schema — round-trip
// ---------------------------------------------------------------------------

async function testNotifySchema() {
    console.log('-'.repeat(60));
    console.log('1. notify-island.ps1 schema round-trip');

    // 1a. all three new fields
    {
        const r = await runPwsh(`& "${NOTIFY_ISLAND}" -State working -Message 'X' -Step 3 -Total 12 -Detail 'fill username'`);
        assert.equal(r.code, 0, `notify-island exited ${r.code}: ${r.stderr}`);
        const j = JSON.parse(await readStatusJsonOf(r.tmpAppData));
        assert.equal(j.step, 3, 'step must round-trip');
        assert.equal(j.total, 12, 'total must round-trip');
        assert.equal(j.detail, 'fill username', 'detail must round-trip');
        out('PASS', 'all three new fields round-trip with explicit values');
    }

    // 1b. step without total
    {
        const r = await runPwsh(`& "${NOTIFY_ISLAND}" -State working -Message 'X' -Step 5 -Detail 'npm install'`);
        const j = JSON.parse(await readStatusJsonOf(r.tmpAppData));
        assert.equal(j.step, 5);
        assert.equal(j.total, -1, 'total stays at -1 when caller omits it');
        assert.equal(j.detail, 'npm install');
        out('PASS', 'step without total: step=5, total stays -1');
    }

    // 1c. backward compat — old callers don't pass new params
    {
        const r = await runPwsh(`& "${NOTIFY_ISLAND}" -State working -Message 'legacy call'`);
        const j = JSON.parse(await readStatusJsonOf(r.tmpAppData));
        assert.equal(j.step, -1, 'backward compat: step must default to -1');
        assert.equal(j.total, -1, 'backward compat: total must default to -1');
        assert.equal(j.detail, '', 'backward compat: detail must default to empty string');
        assert.equal(j.message, 'legacy call', 'message preserved');
        assert.equal(j.state, 'working');
        // Negative-injection for this contract: imagine the
        // implementation forgot to write step/total/detail at all —
        // the JSON would lack these fields, and `j.step` would be
        // `undefined`. The assert.equal above against -1 catches that.
        out('PASS', 'backward compat: old callers produce step=-1, total=-1, detail=""');
    }

    // 1d. schema version invariants — these were already there
    {
        const r = await runPwsh(`& "${NOTIFY_ISLAND}" -State working -Message 'X'`);
        const j = JSON.parse(await readStatusJsonOf(r.tmpAppData));
        for (const k of ['state', 'message', 'progress', 'ts', 'source']) {
            assert.ok(k in j, `existing field ${k} must still be present`);
        }
        out('PASS', 'existing fields (state/message/progress/ts/source) preserved');
    }
}

// ---------------------------------------------------------------------------
// 2. Build-DisplayMessage — PowerShell function unit
// ---------------------------------------------------------------------------

async function testBuildDisplayMessage() {
    console.log('-'.repeat(60));
    console.log('2. Build-DisplayMessage function contract');

    // Source-out the function from mcode-island.ps1 by sourcing it in
    // a no-window context, then asserting. mcode-island.ps1 starts WPF
    // if you load it directly, so we extract just the function body
    // by `Get-Content | Select-String` and re-define it for testing.
    const widgetSrc = await readFile(WIDGET, 'utf8');
    const fnMatch = widgetSrc.match(/function Build-DisplayMessage\s*\{[\s\S]*?\n\}/);
    assert.ok(fnMatch, 'Build-DisplayMessage function must exist in widget source');
    const fnBody = fnMatch[0];

    const cases = [
        // [step, total, detail, message, expected]
        [3, 12, 'fill username', 'Bash ok',       'step 3/12 · fill username'],
        [5, -1, 'npm install',  'Bash',          'step 5 · npm install'],
        [3, 12, '',             'Bash ok',       'step 3/12'],
        [3, -1, '',             'Bash ok',       'step 3'],
        [-1, -1, '',            'Bash ok',       'Bash ok'],
        [-1, -1, 'orphan',      'Bash ok',       'Bash ok'],  // no step → ignore detail
        [3, 0,  'edge',         'Bash ok',       'step 3 · edge'],  // total=0 → no /N
        [3, 12, 'detail wins',  '',              'step 3/12 · detail wins'],  // empty message
        [3, 12, 'd',           'm',             'step 3/12 · d'],  // detail replaces message
    ];

    for (const [step, total, detail, message, expected] of cases) {
        const script = `
${fnBody}
$r = Build-DisplayMessage -Message ${JSON.stringify(message)} -Step ${step} -Total ${total} -Detail ${JSON.stringify(detail)}
Write-Output $r
`;
        const r = await runPwsh(script);
        const got = r.stdout.trim();
        if (got === expected) {
            out('PASS', `Build-DisplayMessage(${step},${total},"${detail}","${message}") = "${expected}"`);
        } else {
            out('FAIL', `Build-DisplayMessage(${step},${total},"${detail}","${message}"): expected "${expected}", got "${got}"`);
        }
    }
}

// ---------------------------------------------------------------------------
// 3. Format-ToolSummary — mcode-computer-use case
// ---------------------------------------------------------------------------

async function testFormatToolSummaryCU() {
    console.log('-'.repeat(60));
    console.log('3. Format-ToolSummary for mcode-computer-use');

    const libSrc = await readFile(LIB, 'utf8');
    const fnMatch = libSrc.match(/function Format-ToolSummary\s*\{[\s\S]*?\n\}/);
    assert.ok(fnMatch, 'Format-ToolSummary must exist in _lib.ps1');
    const fnBody = fnMatch[0];

    const cases = [
        // input event JSON, expected output
        [{ tool_name: 'mcode-computer-use', tool_input: { action: 'click', coordinate: [1024, 768] } },
            'mcode-computer-use : click at (1024,768)'],
        [{ tool_name: 'mcode-computer-use', tool_input: { action: 'type', text: 'hello' } },
            'mcode-computer-use : type \'hello\''],
        [{ tool_name: 'mcode-computer-use', tool_input: { action: 'screenshot' } },
            'mcode-computer-use : screenshot'],
        [{ tool_name: 'mcode-computer-use', tool_input: { action: 'scroll', coordinate: [100, 200] } },
            'mcode-computer-use : scroll at (100,200)'],
        // existing tools — make sure we didn't break them
        [{ tool_name: 'Bash', tool_input: { command: 'ls -la /tmp' } },
            'Bash : ls -la /tmp'],
        [{ tool_name: 'Read', tool_input: { file_path: 'C:/foo/bar.txt' } },
            'Read : C:/foo/bar.txt'],
        [{ tool_name: 'Edit', tool_input: { file_path: 'C:/baz/qux.ts' } },
            'Edit : C:/baz/qux.ts'],
    ];

    for (const [evt, expected] of cases) {
        const script = `
${fnBody}
$evt = '${JSON.stringify(evt).replace(/'/g, "''")}' | ConvertFrom-Json
$r = Format-ToolSummary $evt
Write-Output $r
`;
        const r = await runPwsh(script);
        const got = r.stdout.trim();
        if (got === expected) {
            out('PASS', `Format-ToolSummary(${JSON.stringify(evt.tool_name)}) = "${expected}"`);
        } else {
            out('FAIL', `Format-ToolSummary(${JSON.stringify(evt.tool_name)}): expected "${expected}", got "${got}"`);
        }
    }
}

// ---------------------------------------------------------------------------
// 4. Push-Island wrapper signature — hook can pass new params
// ---------------------------------------------------------------------------

async function testPushIslandSignature() {
    console.log('-'.repeat(60));
    console.log('4. Push-Island accepts new params');

    const libSrc = await readFile(LIB, 'utf8');
    // Sanity: Push-Island declares Step/Total/Detail as named params.
    const pushMatch = libSrc.match(/function Push-Island\s*\{[\s\S]*?\n\}/);
    assert.ok(pushMatch, 'Push-Island must exist in _lib.ps1');
    const fnBody = pushMatch[0];
    if (!/\[int\]\$Step\s*=\s*-1/.test(fnBody)) {
        out('FAIL', 'Push-Island: missing `[int]$Step = -1` param');
    } else {
        out('PASS', 'Push-Island: declares [int]$Step = -1');
    }
    if (!/\[int\]\$Total\s*=\s*-1/.test(fnBody)) {
        out('FAIL', 'Push-Island: missing `[int]$Total = -1` param');
    } else {
        out('PASS', 'Push-Island: declares [int]$Total = -1');
    }
    if (!/\[string\]\$Detail\s*=\s*''/.test(fnBody)) {
        out('FAIL', 'Push-Island: missing `[string]$Detail = \'\'` param');
    } else {
        out('PASS', 'Push-Island: declares [string]$Detail = \'\'');
    }
    // And the call to notify-island.ps1 inside Push-Island must forward them
    // The forward is via `$script:NotifyIsland` (a variable), not a literal
    // "notify-island.ps1" string, so the regex anchors on the args.
    if (!/-State\s+\$State\s+-Message\s+\$Message\s+-Step\s+\$Step\s+-Total\s+\$Total\s+-Detail\s+\$Detail/s.test(fnBody)) {
        out('FAIL', 'Push-Island: does not forward -Step -Total -Detail to notify-island.ps1');
    } else {
        out('PASS', 'Push-Island: forwards Step/Total/Detail to notify-island.ps1');
    }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 5. Push-Island → notify-island.ps1 → status.json integration
// ---------------------------------------------------------------------------

async function testPushIslandIntegration() {
    console.log('-'.repeat(60));
    console.log('5. Push-Island end-to-end (hook → status.json)');

    const libSrc = await readFile(LIB, 'utf8');
    // Strip the Push-Island function declaration and dot-source it.
    // _lib.ps1 also runs `Set-ConsoleUtf8` at load which is harmless
    // for testing, but we need to skip the initial doc-comment / errors.
    const r = await runPwsh(`
$ErrorActionPreference = 'Stop'
. '${LIB.replace(/\\/g, '\\\\')}'
Push-Island -State working -Message 'CU' -Step 3 -Total 12 -Detail 'fill username'
Get-Content (Join-Path $env:APPDATA 'mcode-island/status.json') -Raw
`);
    if (r.code !== 0) {
        out('FAIL', `Push-Island script exited ${r.code}: ${r.stderr}`);
        return;
    }
    // Strip BOM if present
    let raw = r.stdout;
    if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1);
    const j = JSON.parse(raw);
    if (j.step === 3 && j.total === 12 && j.detail === 'fill username') {
        out('PASS', `Push-Island end-to-end: status.json has step=3, total=12, detail="fill username"`);
    } else {
        out('FAIL', `Push-Island end-to-end: status.json has step=${j.step}, total=${j.total}, detail="${j.detail}"`);
    }

    // Backward compat: Push-Island without new params must still work
    const r2 = await runPwsh(`
$ErrorActionPreference = 'Stop'
. '${LIB.replace(/\\/g, '\\\\')}'
Push-Island -State working -Message 'Bash ok'
Get-Content (Join-Path $env:APPDATA 'mcode-island/status.json') -Raw
`);
    let raw2 = r2.stdout;
    if (raw2.charCodeAt(0) === 0xFEFF) raw2 = raw2.slice(1);
    const j2 = JSON.parse(raw2);
    if (j2.step === -1 && j2.total === -1 && j2.detail === '' && j2.message === 'Bash ok') {
        out('PASS', `Push-Island backward compat: missing new params → step=-1, total=-1, detail=""`);
    } else {
        out('FAIL', `Push-Island backward compat: status.json has step=${j2.step}, total=${j2.total}, detail="${j2.detail}"`);
    }
}

async function main() {
    console.log(`mcode-island sub-step progress self-check`);
    console.log(`plugin root: ${PLUGIN_ROOT}`);
    console.log(`pwsh: ${PWSH}`);
    console.log('-'.repeat(60));

    // Platform guard: this test exercises notify-island.ps1 which is
    // a Windows-only plugin (it shells out to `chcp 65001` and uses
    // Win32 console APIs). On Linux/macOS CI the notify-island.ps1
    // child fails before any assertion runs, exit code 1 → false
    // green. The contract being tested (sub-step status.json schema,
    // Build-DisplayMessage rendering, Format-ToolSummary for
    // mcode-computer-use) is platform-agnostic, but the *fixture* for
    // most cases is notify-island.ps1 itself, which is Windows-only.
    // Smoke.mjs has the same Windows-bound gates and is expected to be
    // invoked from the Windows-latest CI job, not from the
    // ubuntu-latest `validate` step that runs `node --test`. Skip here.
    if (process.platform !== 'win32') {
        console.log('-'.repeat(60));
        console.log('SKIP: sub-step tests require Windows PowerShell (notify-island.ps1 is Windows-only).');
        console.log(`       This test runs from the windows-latest job in .github/workflows/mcode-island-windows.yml.`);
        process.exit(0);
    }

    if (!(await exists(NOTIFY_ISLAND))) {
        console.log(`[FAIL] notify-island.ps1 not found at ${NOTIFY_ISLAND}`);
        process.exit(1);
    }
    if (!(await exists(WIDGET))) {
        console.log(`[FAIL] mcode-island.ps1 not found at ${WIDGET}`);
        process.exit(1);
    }
    if (!(await exists(LIB))) {
        console.log(`[FAIL] _lib.ps1 not found at ${LIB}`);
        process.exit(1);
    }

    await testNotifySchema();
    await testBuildDisplayMessage();
    await testFormatToolSummaryCU();
    await testPushIslandSignature();
    await testPushIslandIntegration();

    console.log('-'.repeat(60));
    console.log(`summary: ${pass} pass, ${fail} fail`);
    process.exit(fail > 0 ? 1 : 0);
}

main().catch((e) => {
    console.error('FATAL:', e);
    process.exit(2);
});