---
name: mcode-island
description: Push the user's terminal out of focus to a Windows desktop Dynamic Island pill so the user can watch your work without switching back to mcode. On mcode 0.3.10+ with the `io.minimax.mcode` Hooks extension enabled, five tool lifecycle events fire scripts under `io.minimax.mcode/hooks/scripts/` automatically — the agent does not need to push states manually. Caveat: on mcode 0.3.10/0.3.11 the runtime spawns commands via `/bin/sh -lc` which ENOENTs on Windows, so Mode A does not actually fire on Windows until the runtime sets `usePlatformShell: true`; until then, fall back to Mode B (call `notify-island.ps1` directly, or apply the local `hooks/win32-ava-patch/apply.mjs` workaround). Run `install-hook.ps1` once after install to materialise the hook document in `${MINIMAX_DATA_DIR}/hooks/hooks.json` (the runtime does not read the Plugin's own `io.minimax.mcode/` path).

> **Caveat (mcode 0.3.10 and 0.3.11 on Windows):** the 0.3.10/0.3.11 hook
> dispatcher (`Ava` in `@minimax-ai/code@0.3.10`'s `chunk-CTHP2I62.js:6553163`
> and the byte-identical `@minimax-ai/code@0.3.11`'s
> `chunk-P2ZQPHDU.js:6553163`) spawns commands via `/bin/sh -lc` with
> `usePlatformShell: false`. `Node.spawn('/bin/sh', ...)` returns `ENOENT`
> on a stock Windows install (no Git Bash, no MSYS, no WSL shim), so even
> the 5 events that *would* dispatch will not actually fire on Windows
> 0.3.10 or 0.3.11. The hook document is correct and the install step
> succeeds, but no script will run until upstream sets
> `usePlatformShell: true` on Windows (or ships a Windows-aware shell
> wrapper). Track the upstream issue; use Mode B in the meantime.
> The shipped `hooks/win32-ava-patch/apply.mjs` is a local workaround
> that adds the missing `|| process.platform === "win32"` branch so the
> existing Windows-aware shell detector (`bZ` / `YO`) is actually used.
license: Apache-2.0
compatibility: Requires Windows 10/11 with PowerShell 5.1+ and the mcode-island widget running (started via `mcode-island start` or `autostart.ps1 -Enable`). Hook-driven mode additionally requires mcode 0.3.10+ (verified on 0.3.10 and 0.3.11; the hook schema, the `Ava` dispatch wrapper, the `Fwe` allowlist, and the `Uwe` parser are byte-identical between the two releases) with the `io.minimax.mcode` extension namespace accepted by the registry validator, AND `install-hook.ps1` having been run at least once to materialise the hook document in the runtime-resolved dataDir. On Windows 0.3.10/0.3.11, Mode A is currently non-functional without the shipped `hooks/win32-ava-patch/apply.mjs` workaround (an upstream `/bin/sh` dispatch bug); use Mode B if the workaround is not applied.
metadata:
  author: antianqi
  version: "0.4.0"
---

# mcode-island — 桌面灵动岛状态通知

让用户在不切回 mcode 窗口的情况下，从桌面顶部悬浮 pill 上看到你（agent）的实时工作状态。

## What it looks like

A 320×60 pill anchored to the top center of the primary display, always-on-top, dark
theme. Six states with distinct color and motion:

| state      | color          | icon | meaning                          |
| ---------- | -------------- | ---- | -------------------------------- |
| `idle`     | gray           | —    | waiting for user input           |
| `thinking` | yellow pulse   | —    | reasoning, no tool call yet      |
| `working`  | blue pulse     | ⚙    | actively running a tool          |
| `waiting`  | orange         | ?    | tool needs user approval / input |
| `done`     | green          | ✓    | step finished, more to do        |
| `error`    | red            | ✕    | tool or step failed              |

Click the pill to switch focus back to the originating terminal tab. Run
`mcode-island pin` from inside a terminal to fix the focus target explicitly
(useful when the auto-detected HWND is wrong, e.g. Windows Terminal multi-tab).

## Two ways to drive the pill

### Mode A — Hook-driven (mcode 0.3.10+ with `io.minimax.mcode`)

When mcode accepts the `io.minimax.mcode` client extension, the runtime parses
the hook document and spawns the script under
`io.minimax.mcode/hooks/scripts/<event>.ps1` for every matching lifecycle
event. The agent does **not** need to push state manually.

The 0.3.10/0.3.11 hook parser (`Uwe` in `@minimax-ai/code@0.3.10`'s `chunk-CTHP2I62.js:6523134` and the byte-identical `@minimax-ai/code@0.3.11`'s `chunk-P2ZQPHDU.js:6523134`) expects a **nested
shape** per event: a top-level `{matcher, hooks:[{type, command, timeout}]}`
array, not the flat `{command, args, timeout}` shape that earlier plugin
drafts (PR #20) proposed. The bundled `io.minimax.mcode/hooks/hooks.json`
matches the 0.3.10 schema; the proposal text in `proposals/hooks-detailed-spec.md`
was rewritten in PR #36 to match.

| event              | script                            | pill state   | 0.3.10 / 0.3.11 dispatch |
| ------------------ | --------------------------------- | ------------ | ----------------------- |
| `SessionStart`     | `session-start.ps1`               | `idle`       | yes (`Fwe` set) |
| `SessionEnd`       | `session-end.ps1`                 | `idle`       | yes (`Fwe` set) |
| `UserPromptSubmit` | `user-prompt-submit.ps1`          | `thinking`   | yes (`Fwe` set) |
| `PreToolUse`       | `pre-tool-use.ps1`                | `working`    | yes (`Fwe` set) |
| `PostToolUse`      | `post-tool-use.ps1`               | `done`/`error` | yes (`Fwe` set) |
| `Stop`             | `stop.ps1`                        | `done`       | forward — not in 0.3.10 / 0.3.11 `Fwe` set |
| `PreCompact`       | `pre-compact.ps1`                 | `thinking`   | forward — not in 0.3.10 / 0.3.11 `Fwe` set |
| `Notification`     | `notification.ps1`                | `idle`       | forward — not in 0.3.10 / 0.3.11 `Fwe` set |
| `SubagentStart`    | `subagent-start.ps1` (CODEX only) | `working`    | forward — not in 0.3.10 / 0.3.11 `Fwe` set |
| `SubagentStop`     | `subagent-stop.ps1`  (CODEX only) | `done`       | forward — not in 0.3.10 / 0.3.11 `Fwe` set |
| `PermissionRequest`| `permission-request.ps1` (returns `{"decision":"ask"}` so the runtime's fail-closed default does not deny) | `waiting` | forward — not in 0.3.10 / 0.3.11 `Fwe` set |
| `PermissionDenied` | `permission-denied.ps1`           | `error`      | forward — not in 0.3.10 / 0.3.11 `Fwe` set |

**0.3.10 / 0.3.11 dispatch coverage is 5 / 12 events** — the runtime's `Fwe`
set allowlists exactly the 5 lifecycle events above plus the three stream
events (`MessageComplete`, `StreamChunk`, `StreamChunkThreshold`) that this
plugin does not register (the `Fwe` set is byte-identical in
`@minimax-ai/code@0.3.10`'s `chunk-CTHP2I62.js:1843` and
`@minimax-ai/code@0.3.11`'s `chunk-P2ZQPHDU.js:1843`). The other 7 events
are *forward-only* on 0.3.10 / 0.3.11: the `.ps1` files ship and the JSON
is valid, but the runtime silently skips them because the event name is
outside `Fwe`. When a future mcode release grows `Fwe`, those scripts
start firing with zero code change here.

Each script reads the JSON event payload from stdin, calls `notify-island.ps1`
with the appropriate state, and exits 0 (decision-bearing events also write a
JSON decision to stdout). Self-push filtering prevents the pill from churning
when the agent calls `notify-island.ps1` directly through Bash.

**The Plugin's `io.minimax.mcode/hooks/hooks.json` alone is not enough.** The
0.3.10 / 0.3.11 hook-config parser reads only
`${MINIMAX_DATA_DIR}/hooks/hooks.json` (project-wide) and
`${MINIMAX_DATA_DIR}/agents/<agent>/hooks/hooks.json` (per-agent). It does
not consult `plugin.json`'s `extensions.io.minimax.mcode.hooks` field, even
though the Plugin registry accepts the namespace. Run `install-hook.ps1`
once after install to copy the bundled document into the runtime-resolved
dataDir (it is idempotent and safe to re-run after every mcode upgrade):

```powershell
& "<plugin install dir>\install-hook.ps1"            # project-wide
& "<plugin install dir>\install-hook.ps1" -Agent mavis  # per-agent
```

The script also accepts `-DataDir <path>` to override `${MINIMAX_DATA_DIR}`
when the env var is not set. It is portable: it does not write any absolute
path into the document, it uses `%PLUGIN_ROOT%` in the spawned commands so
that whatever install location the Plugin landed in is the source of truth
once the runtime learns to read it.

> **Caveat (mcode 0.3.10 / 0.3.11 on Windows):** the 0.3.10 / 0.3.11 hook
> dispatcher (`Ava` in `@minimax-ai/code@0.3.10`'s `chunk-CTHP2I62.js:6553163`
> and the byte-identical `@minimax-ai/code@0.3.11`'s
> `chunk-P2ZQPHDU.js:6553163`) spawns commands via `/bin/sh -lc <command>`
> even on Windows, with `usePlatformShell: false` as the default.
> `Node.spawn('/bin/sh', ...)` returns `ENOENT` on a stock Windows install
> (no Git Bash, no MSYS, no WSL shim), so even the 5 events that *would*
> dispatch will not actually fire on Windows 0.3.10 / 0.3.11. The hook
> document is correct and the install step succeeds, but no script will
> run until upstream sets `usePlatformShell: true` on Windows (or ships
> a Windows-aware shell wrapper). The shipped
> `hooks/win32-ava-patch/apply.mjs` is a local-only patch that adds the
> missing `|| process.platform === "win32"` branch so the existing
> Windows-aware shell detector (`bZ` / `YO`) is actually used; apply it
> once and re-apply after every `npm install -g @minimax-ai/code`. Track
> the upstream issue; use Mode B in the meantime if the patch is not
> applied.

If you are running on a fixed runtime and the pill is updating itself before
you push anything, Mode A is active. Otherwise fall through to Mode B.

### Mode B — Agent-pushed (legacy, always works)

For older mcode, or when the `io.minimax.mcode` extension is not yet active
(registry validator has not accepted the namespace), or on Windows 0.3.10 /
0.3.11 where the runtime's `/bin/sh` spawn is broken (and
`hooks/win32-ava-patch/apply.mjs` has not been applied), the agent pushes
state through `notify-island.ps1` directly. The `mcode-status-detect.ps1`
detector also infers state from the runtime's `ledger.jsonl` /
`messages.jsonl`, so the pill will still move — your manual pushes just
sharpen the message and cover edge cases (notably `ask_user`).

| moment                                                | state     | example message                |
| ----------------------------------------------------- | --------- | ------------------------------ |
| receive user task, start reasoning                    | `thinking`| (none)                        |
| about to invoke any tool                              | `working` | `"bash: npm test"`            |
| tool returned 0, before reporting back                | `done`    | `"3 files modified"`          |
| tool needs approval (e.g. permission prompt)          | `waiting` | `"bash: needs approval"`       |
| about to call `ask_user` (user must pick)             | `waiting` | `"ask_user: 2 options"`       |
| user answered `ask_user`, resuming work                | `done`    | `"ask_user answered"`         |
| tool failed / threw / non-zero exit                   | `error`   | `"compile failed: missing import"` |
| conversation idle, waiting for user                   | `idle`    | (none)                        |

**`ask_user` is a special tool** — the detector cannot infer it is a "wait for
user" moment (it looks like any other tool call to the session log). When in
Mode B, the agent MUST push `waiting` immediately before invoking `ask_user`,
and `done` immediately after the user answers; otherwise the pill will sit in
`working` (yellow/blue) while the user is actually being asked to decide. In
Mode A, the same coverage comes for free because `ask_user` is a tool call
that fires `PreToolUse`/`PostToolUse`.

**Never push the same state twice in a row** — the widget de-duplicates by
state+message. Push only on transitions, or include a fresh message each time.

## Copyable example (agent side, Mode B)

The plugin ships a thin wrapper `wrap-tool.ps1` that **publishes state only**
(it does NOT execute the command). Run the command via mcode's own bash tool,
then call `wrap-tool.ps1` to publish the outcome:

```powershell
# Step 1: announce "working" before invoking mcode's bash tool
& "<plugin install dir>\wrap-tool.ps1" -Tool bash -Command "npm test" -Description "run tests"

# Step 2: after mcode's bash tool returns, publish the outcome
& "<plugin install dir>\wrap-tool.ps1" -Tool bash -Command "npm test" -ExitCode $LASTEXITCODE
```

`$LASTEXITCODE` is interpreted as: `0` → `done`, codes in `-WaitingExitCodes`
(default `[1]`) → `waiting`, anything else → `error`. The wrapper returns the
exit code unchanged so the calling shell still sees it.

The wrapper accepts `-Tool bash|read|write|edit|glob|grep|web|task|notebook` and
emits a tool-specific `done` message (e.g. `read C:\path`, `edited file.cs`,
`npm test 完成`) so the pill text is informative. For read/write/edit/glob/grep
the wrapper itself does not execute the command — mcode's own tool does; this
script only publishes the state.

For other tools (read/write/edit) — and for any state push that is not a single
command — call `notify-island.ps1` directly:

```powershell
$plugin = "<plugin install dir>"   # directory that contains notify-island.ps1
& "$plugin\notify-island.ps1" -State thinking
& "$plugin\notify-island.ps1" -State working  -Message "read source tree"
& "$plugin\notify-island.ps1" -State done     -Message "indexed 142 files"
& "$plugin\notify-island.ps1" -State error    -Message "compile failed: missing import"
& "$plugin\notify-island.ps1" -State waiting  -Message "permission prompt"
```

`<plugin install dir>` is the directory that contains `notify-island.ps1`.
Substitute the absolute path your user installed the plugin at. The Skill body
deliberately avoids hard-coded paths so any user / any install location works.

## Expected result

After each push (or after each hook fires), the widget on the user's primary
display updates within ~400 ms (one polling cycle). On click, the originating
terminal tab regains focus. The widget is intentionally hard to kill: Alt+F4
hides it, not closes it, and `mcode-island show` re-raises the hidden window
in under 1 second.

## User-side management

```cmd
mcode-island                  REM start the widget (idempotent)
mcode-island stop             REM stop the widget
mcode-island status           REM show PID + recent log
mcode-island show             REM re-raise hidden widget
mcode-island pin              REM lock focus target to current foreground window
mcode-island unpin            REM clear focus target
mcode-island autostart-on     REM register for Windows logon
mcode-island autostart-off    REM unregister
```

To enable login auto-start, the user runs once:

```powershell
& "<plugin install dir>\autostart.ps1" -Enable
```

This writes to `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` — no admin
rights required.

## Runtime data

All widget state lives under `%APPDATA%\mcode-island\`:

| file             | purpose                                               |
| ---------------- | ----------------------------------------------------- |
| `status.json`    | current state (widget polls this every 400 ms)        |
| `caller.json`    | originating terminal HWND / PID (for click-to-focus)  |
| `config.json`    | pill position, size, opacity (saved on drag)          |
| `widget.pid`     | widget process PID (used by start/stop/status)        |
| `island.log`     | append-only state transition history                  |
| `widget.log`     | widget internal debug log                             |
| `show.signal`    | transient file written by `mcode-island show`         |

No data leaves the local machine *unless* an opt-in 5-hour usage token is
configured. See the **Network access** + **Accounts** sections in
`README.md` for the exact host (`api.minimax.io/v1/coding_plan/remains`),
the rate limit (one GET per 60 s), and the storage locations
(`config.json:planApiToken` or env `MINIMAX_OAUTH_TOKEN` / `MINIMAX_API_KEY`).
When no token is configured the plugin makes no network requests at all.

## What is in this package

```
mcode-island/
├── plugin.json                       # plugin manifest (v0.4.0)
├── README.md                         # full user-facing docs
├── LICENSE                           # Apache-2.0
├── mcode-island.ps1                  # WPF widget main loop
├── mcode-island.cmd                  # CLI shim (start/stop/status/...)
├── start-island.ps1                  # launch the widget in STA
├── stop-island.ps1                   # stop the widget
├── status-island.ps1                 # print widget state
├── show-island.ps1                   # re-raise hidden widget
├── pin-island.ps1                    # lock focus target to foreground
├── autostart.ps1                     # register/unregister Windows logon
├── install-hook.ps1                  # copy hooks.json into ${MINIMAX_DATA_DIR} (Mode A, 0.3.10)
├── hooks/
│   └── win32-ava-patch/              # Windows 0.3.10 runtime workaround (see README)
│       ├── apply.mjs                 #   idempotent in-place patch
│       ├── restore.mjs               #   undo using .bak file
│       ├── diff.txt                  #   exact byte-level diff
│       └── README.md
├── notify-island.ps1                 # state-push helper (agents call this)
├── wrap-tool.ps1                     # all-in-one bash wrapper
├── mcode-status-detect.ps1           # runtime-state detector
├── io.minimax.mcode/                 # client extension (PR #36 spec, 0.3.10 nested schema)
│   └── hooks/
│       ├── hooks.json                # 12-event nested declaration
│       └── scripts/
│           ├── _lib.ps1              # shared helper
│           ├── session-start.ps1
│           ├── session-end.ps1
│           ├── user-prompt-submit.ps1
│           ├── pre-tool-use.ps1
│           ├── post-tool-use.ps1
│           ├── stop.ps1
│           ├── pre-compact.ps1
│           ├── notification.ps1
│           ├── subagent-start.ps1
│           ├── subagent-stop.ps1
│           ├── permission-request.ps1
│           └── permission-denied.ps1
├── skills/mcode-island/SKILL.md      # this file
└── assets/                           # screenshots used in the README
```

## Limitations and known constraints

- Windows 10/11 only (uses WPF, `user32`, and `kernel32` P/Invoke).
- Single widget per user session.
- Hook-driven mode requires mcode 0.3.10+ Runtime. The portable spec
  (`io.minimax.mcode` client extension) was aligned with the 0.3.10 nested
  shape in `MiniMax-Code-Plugins` PR #36; until the registry validator
  accepts the namespace, the hooks subdirectory is dormant and the plugin
  falls back to Mode B (agent-pushed + detector).
- On mcode 0.3.10 only 5 / 12 events dispatch (`SessionStart`, `SessionEnd`,
  `UserPromptSubmit`, `PreToolUse`, `PostToolUse`). The other 7 are forward
  events that the 0.3.10 `Fwe` set does not yet include; the `.ps1` files
  ship and will start firing when a future mcode release grows `Fwe`.
- On Windows 0.3.10, even those 5 events do not actually fire: the runtime
  spawns commands via `/bin/sh -lc` which ENOENTs on a stock Windows
  install. The hook document is correct and `install-hook.ps1` succeeds, but
  no script will run until upstream sets `usePlatformShell: true` on Windows.
  Track the upstream issue; use Mode B in the meantime.
  A local workaround is shipped at
  `hooks/win32-ava-patch/apply.mjs` — it adds the missing
  `process.platform === "win32"` branch in the runtime's `Ava` spawn wrapper
  (single line, +30 bytes, idempotent) so the existing Windows-aware shell
  detector (`bZ` / `YO`) is actually used. See `hooks/win32-ava-patch/README.md`
  for the full procedure. Re-run after every `npm install -g @minimax-ai/code`.
- `install-hook.ps1` only materialises the hook document in
  `${MINIMAX_DATA_DIR}/hooks/hooks.json`. Until the runtime learns to read
  `plugin.json`'s `extensions.io.minimax.mcode.hooks` field, you must run
  it once after install (and after every mcode upgrade that changes the
  bundled document).
- No hover-expand, no media-control integration yet — see the `v0.2` roadmap in
  the upstream issue tracker.
- `wrap-tool.ps1` is a **status publisher only** — it never executes the
  command itself (mcode's tool does). The agent still runs every read / write /
  edit through mcode and then calls `wrap-tool.ps1` to publish the outcome.
  This avoids shell-injection ambiguity from a prior `Invoke-Expression` design.
