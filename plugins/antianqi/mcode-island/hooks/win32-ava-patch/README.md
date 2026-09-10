# win32-ava-patch — local fix for the @minimax-ai/code@0.3.10 hook dispatcher

A two-script workaround that makes Mode A (Hook-driven) actually fire on
Windows under `@minimax-ai/code@0.3.10`. The Plugin is correct, the
runtime is not.

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

| file         | purpose                                                                    |
| ------------ | -------------------------------------------------------------------------- |
| `apply.mjs`  | idempotent in-place patch. Re-runnable; safe on every machine.             |
| `restore.mjs`| undo, using the `.bak-<timestamp>` file that `apply.mjs` writes.           |
| `diff.txt`   | the exact 30-byte before/after for review.                                 |
| `README.md`  | this file.                                                                 |

## Usage

```cmd
:: One-time per mcode 0.3.10 install (or after every npm install -g @minimax-ai/code):
node "%USERPROFILE%\MiniMax-Code-Plugins-1\plugins\antianqi\mcode-island\hooks\win32-ava-patch\apply.mjs"
```

Re-run after every mcode upgrade. `apply.mjs` is idempotent — running
it twice is a no-op the second time.

To undo:

```cmd
node "%USERPROFILE%\MiniMax-Code-Plugins-1\plugins\antianqi\mcode-island\hooks\win32-ava-patch\restore.mjs"
```

## What `apply.mjs` does

1. Locates `$USERPROFILE/.minimax-code/releases/0.3.10/node_modules/@minimax-ai/code/chunks/chunk-CTHP2I62.js`.
2. Reads the file as UTF-8.
3. If the new pattern is already present, exits 0 (idempotent re-apply).
4. If the old pattern is absent and `--force` was not passed, prints an
   info message and exits 0 (caller probably already patched or on a
   different runtime version).
5. Otherwise, copies the original to `chunk-CTHP2I62.js.bak-<ISO-timestamp>`
   (only on the first mutating run; subsequent re-applies reuse the
   existing `.bak`), then replaces the OLD line with the NEW line and
   writes the file back.
6. Prints the new size, the offset of the patched line, and the next
   steps (restart mcode / mcode-island widget, run `install-hook.ps1`,
   trigger a tool call to confirm `island.log` shows a non-`[detect]`
   "working ::" entry within ~400 ms).

## When to remove

When `@minimax-ai/code@0.3.11` (or any later release) ships with the
same one-line fix upstream. Detect by running `apply.mjs`; if it
prints "OK: patch already applied", the upstream has either not fixed
it yet or the runtime version has been replaced. Confirm by checking
`npm view @minimax-ai/code version` and reading the chunk for the
`process.platform === "win32"` substring.

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

## Risk

- **Touches `node_modules`.** `npm install -g @minimax-ai/code` will
  overwrite the chunk; re-run `apply.mjs` after every upgrade.
- **Targets exactly 0.3.10.** Other runtime versions may not have the
  same line / same offset; `apply.mjs` will detect the missing OLD
  pattern and refuse to silently damage the file.
- **No credential, no network, no telemetry.** The patch is a local
  string replacement.
- **No upstream contract violation.** The patched branch calls
  existing runtime functions (`Dva`, `bZ`) that the runtime ships in
  the same chunk bundle; no foreign code is injected.

## What this is NOT

- This is **not** a fix for the wider `Fwe` set coverage problem
  (only 5 of 12 plugin-declared events are dispatched on 0.3.10). That
  is a separate runtime change and will need an upstream `Fwe` set
  expansion.
- This is **not** a substitute for filing the upstream issue. The
  patch is local-only; other Windows users still hit the bug until
  mcode 0.3.11 ships.
