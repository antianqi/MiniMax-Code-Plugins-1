# win32-ava-patch — local fix for the @minimax-ai/code@0.3.10+ hook dispatcher

A two-script workaround that makes Mode A (Hook-driven) actually fire on
Windows under `@minimax-ai/code@0.3.10` and `@minimax-ai/code@0.3.11`
(the latest release; the only 0.3.10 -> 0.3.11 change is a 401-token
retry fix, so the hook schema, the `Ava` dispatch wrapper, the `Fwe`
allowlist, and the `Uwe` parser are byte-identical between the two
releases; this patch is the same on either). The Plugin is correct,
the runtime is not.

## What this is

`@minimax-ai/code@0.3.10` ships a hook dispatcher (`Ava` in
`chunk-CTHP2I62.js:6553263`) that wraps the platform-aware shell in a
gated branch:

```js
let o = t.usePlatformShell
  ? Dva(a, bZ())                                       // Windows-aware path
  : { executable: "/bin/sh", args: ["-lc", a] };       // POSIX fallback
```

`usePlatformShell` defaults to `false`, so on every mcode release so far
the POSIX branch is taken — and `/bin/sh` does not exist on a stock
Windows install. The hook config parses fine, the runtime walks the
`Fwe` allowlist, `Kr.runEvent` calls `Ava`, `Ava` calls
`child_process.spawn("/bin/sh", ...)`, and that returns `ENOENT`. The
script is never started.

The runtime already has a complete Windows shell detector (`bZ` in
`chunk-U2NOFGEC.js`, exposed via `YO`): it tries `where pwsh`, the
fixed `C:\Program Files\PowerShell\7\pwsh.exe`, the WinPS 5 path, Git
Bash, and WSL bash, in that order. Everything needed for the Windows
path to work is in the runtime — `Ava` just never calls it on Windows.

This patch adds the missing platform branch. The change is one line
and ~30 bytes:

```js
// before
let o = t.usePlatformShell
  ? Dva(a, bZ())
  : { executable: "/bin/sh", args: ["-lc", a] };

// after
let o = (t.usePlatformShell || process.platform === "win32")
  ? Dva(a, bZ())
  : { executable: "/bin/sh", args: ["-lc", a] };
```

Behaviour after the patch:

| platform  | shell picked by `bZ()` (and used by `Ava`)                                  |
| --------- | ---------------------------------------------------------------------------- |
| Windows   | `where pwsh` → `pwsh.exe` (P7) → `powershell.exe` (P5) → Git Bash → WSL bash |
| macOS     | `/bin/sh -lc <command>` (unchanged)                                          |
| Linux     | `/bin/sh -lc <command>` (unchanged)                                          |

## Files

| file             | purpose                                                                    |
| ---------------- | -------------------------------------------------------------------------- |
| `apply.mjs`      | idempotent in-place patch. Re-runnable; safe on every machine.             |
| `restore.mjs`    | undo, using the `.bak-<timestamp>` file that `apply.mjs` writes.           |
| `test-apply.mjs` | negative-injection self-audit for the path-validation + atomic-write contract. Runs in a sandboxed temp dir, does not touch the real install. |
| `smoke-runtime.mjs` | host-level "parse and dispatch" smoke: validates the bundled hooks.json shape, asserts the 0.3.10 Fwe intersection, runs each in-Fwe hook script through a Node replica of the patched `Ava`. |
| `diff.txt`       | the exact 30-byte before/after for review.                                 |
| `README.md`      | this file.                                                                 |

## Usage

The script auto-detects every installed mcode release under
`~/.minimax-code/releases/*` and patches any whose `Ava` function still
contains the OLD pattern. Verified on 0.3.10 (`chunk-CTHP2I62.js`) and
0.3.11 (`chunk-P2ZQPHDU.js`); both share the same `Ava` function and
both get patched to the same +30 bytes at the same offset 6553220.

```cmd
:: Patch every installed mcode release (recommended):
node "%USERPROFILE%\MiniMax-Code-Plugins-1\plugins\antianqi\mcode-island\hooks\win32-ava-patch\apply.mjs"

:: Restrict to one release:
node apply.mjs --release 0.3.11
node apply.mjs --release 0.3.10 --release 0.3.11
```

Re-run after every mcode upgrade. `apply.mjs` is idempotent — running
it twice is a no-op the second time; running it on a release that
upstream has already fixed is silently skipped.

To undo (one release or all):

```cmd
node "%USERPROFILE%\MiniMax-Code-Plugins-1\plugins\antianqi\mcode-island\hooks\win32-ava-patch\restore.mjs"
node restore.mjs --release 0.3.10
```

## What `apply.mjs` does

1. Locates every `~/.minimax-code/releases/<version>/node_modules/@minimax-ai/code/chunks/chunk-*.js`
   that contains the OLD `Ava` pattern. (Or only the ones named in
   `--release <version>` if that flag was passed.)
2. For each candidate release, validates the version name against a
   strict semver regex and verifies the resolved directory realpath
   is the expected `base/<name>` — rejects `..`, absolute paths,
   drive letters, symlink escapes, and missing directories.
3. Reads the chunk as UTF-8.
4. If the new pattern is already present, exits 0 (idempotent re-apply).
5. If the old pattern is absent, prints `INFO no-pattern` and skips
   (caller probably already patched or on a different runtime version).
6. Otherwise, copies the original to
   `chunk-<hash>.js.bak-<ISO-timestamp>` (only on the first mutating
   run; subsequent re-applies reuse the existing `.bak`), then
   **atomically** swaps in the patched content:
   - stage the new bytes in the same directory (so `rename` is
     atomic on the same filesystem)
   - copy the original chunk's permission mode onto the staging file
   - `rename(staging, target)` — instant
   - on any failure mid-write, delete the staging file and leave the
     original chunk byte-identical to its pre-apply state
7. Prints the new size, the offset of the patched line, and the next
   steps (restart mcode / mcode-island widget, run `install-hook.ps1`,
   trigger a tool call to confirm `island.log` shows a non-`[detect]`
   "working ::" entry within ~400 ms).

## Safety guarantees (host-installation mutation)

The script enforces four non-negotiable contracts. Every guarantee
has a corresponding negative-injection test in `test-apply.mjs`.

| guarantee | implementation | test |
| --------- | --------------- | ---- |
| `--release` value cannot escape the release root | semver regex + `realpath` containment check | Test 1 (7 cases) |
| symlink release dirs are rejected at runtime | `realpathSync` returns canonical path; mismatch with `base/<name>` is fatal | Test 2 |
| mid-write failure leaves the live chunk byte-identical | same-directory staging file + `rename`, with `unlink` cleanup on throw | Test 3 (2 cases) |
| apply → apply → restore → apply round-trip is consistent | every step's exit code and post-state are checked | Test 4 (2 cases) |
| `listReleases()` ignores non-semver and dot-prefixed entries | regex filter after `readdirSync` | Test 5 |

Run the suite from the mcode-island Plugin root:

```cmd
node "%USERPROFILE%\MiniMax-Code-Plugins-1\plugins\antianqi\mcode-island\hooks\win32-ava-patch\test-apply.mjs"
```

Expected output: `13 pass, 0 fail`.

## When to remove

When `@minimax-ai/code` ships the same one-line fix upstream. Detect
by running `apply.mjs`; if every release prints `OK already-patched`
without you having run it, the upstream has been fixed. Confirm by
reading any chunk for the `process.platform === "win32"` substring.

(0.3.10 and 0.3.11 both still have the bug; the upstream CHANGELOG
for 0.3.11 only mentions a 401-token fix and is silent on
hooks / Windows.)

## Empirical evidence (this machine, 2026-09-10)

Before the patch:

```
$ node repro-ava.mjs
err.code    = ENOENT
err.path    = /bin/sh
err.message = spawn /bin/sh ENOENT
```

After the patch (replicated `Ava` with the new branch, called with the
real `pre-tool-use.ps1` from the mcode-island Plugin):

```
shell: { shell: 'C:\\Users\\Administrator\\pwsh7_6\\pwsh.exe',
         args: [ '-NoProfile', '-NonInteractive', '-Command' ],
         type: 'pwsh' }
command: powershell -NoProfile -ExecutionPolicy Bypass -File
         "C:\Users\Administrator\.minimax\plugins\mcode-island\io.minimax.mcode\hooks\scripts\pre-tool-use.ps1"
exit code: 0
stdout:    (empty)
stderr:    (empty)
PASS: Dva(bZ()) path works on Windows 0.3.10
```

`island.log` then shows a `working :: tool` entry without the
`[detect]` prefix, ~2 s after the test starts, confirming the chain
`Ava → Dva(bZ()) → pwsh.exe → pre-tool-use.ps1 → notify-island.ps1 →
status.json` runs end-to-end.

**Re-verified on mcode 0.3.11** (chunk-P2ZQPHDU.js, same Ava function
byte-identical to 0.3.10). Upstream 0.3.11's CHANGELOG only mentions
a 401-token fix; the hook dispatcher bug is unfixed. The patch from
this directory applies cleanly to 0.3.11 and produces the same +
30 bytes at the same offset 6553220.

## Risk

- **Touches `node_modules`.** `npm install -g @minimax-ai/code` will
  overwrite the chunk; re-run `apply.mjs` after every upgrade.
- **Targets 0.3.10 and 0.3.11** (both have the same `Ava` function at
  the same byte offset). Other runtime versions may not have the
  same line / same offset; `apply.mjs` will detect the missing OLD
  pattern and refuse to silently damage the file.
- **No credential, no network, no telemetry.** The patch is a local
  string replacement.
- **No upstream contract violation.** The patched branch calls
  existing runtime functions (`Dva`, `bZ`) that the runtime ships in
  the same chunk bundle; no foreign code is injected.

## What this is NOT

- This is **not** a fix for the wider `Fwe` set coverage problem
  (only 5 of 12 plugin-declared events are dispatched on 0.3.10 and
  on 0.3.11; both releases share the same `Fwe` allowlist of 8 names).
  That is a separate runtime change and will need an upstream `Fwe`
  set expansion.
- This is **not** a substitute for filing the upstream issue. The
  patch is local-only; other Windows users still hit the bug until
  mcode 0.3.11 ships.
