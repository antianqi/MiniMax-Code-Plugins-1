---
name: mcode-island
description: Push the user''s terminal out of focus to a Dynamic Island pill. On mcode 0.4.0+ reads `.claude-plugin/plugin.json` and fires PowerShell scripts at `${PLUGIN_ROOT}/io.minimax.mcode/hooks/scripts/<event>.ps1` for 12 events (SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PostToolUse, Stop, PreCompact, Notification, SubagentStart, SubagentStop, PermissionRequest, PermissionDenied) — no manual push. PermissionRequest returns `{"decision":"ask"}` so the runtime doesn''t auto-deny. No credentials/network/telemetry/third-party services required; the only optional outbound call is an opt-in 5-hour coding-plan usage fetch against `api.minimaxi.com/v1/coding_plan/remains` gated by a user-supplied `planApiToken` in `%APPDATA%\mcode-island\config.json`. On mcode 0.3.10/0.3.11 Mode A is dormant (deprecated `AGENT_PLUGINS_V1` returns `hooks: []`); Mode B (`notify-island.ps1`) is the fallback. Skill-only — no npm/MCP/package.json, pure PowerShell + WPF.
license: Apache-2.0
compatibility: Requires Windows 10/11 with PowerShell 5.1+ and the mcode-island widget running (started via `mcode-island start` or `autostart.ps1 -Enable`). Hook-driven mode additionally requires mcode 0.4.0+ (verified on `@minimax-ai/code@0.4.0` chunk-WYU2W43S.js) — earlier releases (0.3.10/0.3.11) had a different plugin manifest convention (`plugin.json` root → `Bre()` → `AGENT_PLUGINS_V1` → `hooks: []`) and the dispatcher (`Ava` with `usePlatformShell:false`) used `/bin/sh -lc` which ENOENTs on stock Windows, so on those versions only the Mode B fallback applies. No `install-hook.ps1` step is needed on 0.4.0+; the runtime reads the manifest's top-level `hooks` field directly and resolves `${PLUGIN_ROOT}` at dispatch time.
metadata:
  author: antianqi
  version: "0.5.0"
  hookSchema: CLAUDE
  mcodeMin: "0.4.0"
  events:
    - SessionStart
    - SessionEnd
    - UserPromptSubmit
    - PreToolUse
    - PostToolUse
    - Stop
    - PreCompact
    - Notification
    - SubagentStart
    - SubagentStop
    - PermissionRequest
    - PermissionDenied
  credentials: none
  network: none-required (opt-in 5h usage GET against api.minimaxi.com gated by user-supplied planApiToken)
  telemetry: none
  thirdPartyServices: none
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

### Mode A — Hook-driven (mcode 0.4.0+ with `.claude-plugin/` manifest)

When mcode 0.4.0+ reads the plugin's `.claude-plugin/plugin.json`, it pulls the
top-level `hooks` field and dispatches every event to the matching PowerShell
script. The agent does **not** need to push state manually.

**Manifest path priority (0.4.0 `YC` / `Bre` loader, idx=8909087):**

1. `plugin.json` (root) → `Bre()` → `AGENT_PLUGINS_V1` → **`hooks: []`** (this is why this plugin does NOT use root `plugin.json` on 0.4.0+)
2. `.minimax-plugin/plugin.json` → `aA()` → `LOCAL_MINIMAX` (supported)
3. `.claude-plugin/plugin.json` → `YC()` → `LOCAL_CLAUDE` ← **this plugin's choice**
4. `.codex-plugin/plugin.json` → `YC({kind:"CODEX"})` → `LOCAL_CODEX`

If root `plugin.json` exists, 0.4.0 stops at step 1 and never falls through to
2 / 3 / 4. So on 0.4.0+, **this plugin must NOT have a root `plugin.json`** —
only `.claude-plugin/plugin.json` is read.

**Hook schema (0.4.0 `yhe` parser, idx=4768442):** manifest-top-level `hooks`
is a `{<event>: [{matcher, hooks: [{type, command, args, shell, timeout}]}]}`
object. `command` is the executable name, `args` is the parameter array
(passed directly to `child_process.execFile(command, args, {shell:false})`),
`shell: "powershell"` tells the dispatcher to pick a Windows PowerShell
executable. The mcode 0.4.0 dispatcher (`runEvent` at idx=20051648 → `runner.run`
→ `d4e` shell picker at idx=4771071) does **not** use `/bin/sh -lc` on
Windows; the `/bin/sh` ENOENT bug from 0.3.10/0.3.11 is gone.

`${PLUGIN_ROOT}` (and the aliases `${CLAUDE_PLUGIN_ROOT}`,
`${CODEX_PLUGIN_ROOT}`, `${MINIMAX_PLUGIN_ROOT}`) is expanded to the
plugin's absolute root path at dispatch time (`T4e` at idx=4813929:
`e.replace(/\$\{([A-Z][A-Z0-9_]*)\}/gu, ...)`). The replacement preserves
backslashes on Windows.

| event              | script                            | pill state          | 0.4.0 dispatch |
| ------------------ | --------------------------------- | ------------------- | -------------- |
| `SessionStart`     | `session-start.ps1`               | `idle`              | yes            |
| `SessionEnd`       | `session-end.ps1`                 | `idle`              | yes            |
| `UserPromptSubmit` | `user-prompt-submit.ps1`          | `thinking`          | yes            |
| `PreToolUse`       | `pre-tool-use.ps1`                | `working`           | yes            |
| `PostToolUse`      | `post-tool-use.ps1`               | `done` / `error`    | yes            |
| `Stop`             | `stop.ps1`                        | `done`              | yes            |
| `PreCompact`       | `pre-compact.ps1`                 | `thinking`          | yes            |
| `Notification`     | `notification.ps1`                | `idle`              | yes            |
| `SubagentStart`    | `subagent-start.ps1`              | `working`           | yes            |
| `SubagentStop`     | `subagent-stop.ps1`               | `done`              | yes            |
| `PermissionRequest`| `permission-request.ps1` (returns `{"decision":"ask"}`) | `waiting` | yes            |
| `PermissionDenied` | `permission-denied.ps1`           | `error`             | forward — event name is reserved in the manifest for forward compatibility; the 0.4.0 dispatcher's `l4e` table at idx=4769486 does not yet include it. When a future mcode release adds the event, the script starts firing with zero code change. |

**Coverage on 0.4.0 is 11 / 12 events** — the `Fwe`/`l4e` table has expanded
vs 0.3.10/0.3.11's 5 events. The remaining `PermissionDenied` is shipped
forward-only and will pick up automatically when the runtime grows.

**No `install-hook.ps1` is needed on 0.4.0+.** The runtime reads the
plugin's own manifest directly. The 0.3.10/0.3.11 caveat (the runtime
required the hook document to be materialised in `${MINIMAX_DATA_DIR}/hooks/hooks.json`
via `install-hook.ps1` because the `Bre()`/`Uwe` parsers did not consult
`plugin.json`'s `extensions.io.minimax.mcode` field) is gone. Drop the
plugin into `$HOME/.minimax/plugins/mcode-island/` and the hooks fire.

**No `win32-ava-patch/` is needed on 0.4.0+.** The 0.4.0 dispatcher
(`d4e` → `R4e`) uses `child_process.execFile` directly, not
`child_process.spawn("/bin/sh", ["-lc", ...])` with `usePlatformShell:false`.
The Windows ENOENT bug that 0.3.10/0.3.11 had (and that the local
`hooks/win32-ava-patch/apply.mjs` worked around by adding a
`|| process.platform === "win32"` branch to the 8.4 MB `Ava` chunk)
does not exist in the 0.4.0 source.

Each script reads the JSON event payload from stdin, calls `notify-island.ps1`
with the appropriate state, and exits 0. The single decision-bearing event
(`PermissionRequest`) also writes a JSON decision to stdout
(`{"decision":"ask"}`) so the runtime's fail-closed default does not deny
the prompt — the pill becomes a pure observer, never an auto-allow/deny.

Self-push filtering prevents the pill from churning when the agent calls
`notify-island.ps1` directly through Bash in Mode B.

If you are running on mcode 0.4.0+ and the pill is updating itself before
you push anything, Mode A is active. Otherwise fall through to Mode B.

### Mode B — Agent-pushed (always works)

For older mcode, or when the `.claude-plugin/` manifest is not yet accepted
(registry validator has not allowed the new convention), or any time Mode A
is dormant, the agent pushes state through `notify-island.ps1` directly. The
`mcode-status-detect.ps1` detector also infers state from the runtime's
`ledger.jsonl` / `messages.jsonl`, so the pill will still move — your manual
pushes just sharpen the message and cover edge cases (notably `ask_user`).

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

**`ask_user` is a special tool** — the detector cannot infer it is a "wait
for user" moment (it looks like any other tool call to the session log).
When in Mode B, the agent MUST push `waiting` immediately before invoking
`ask_user`, and `done` immediately after the user answers; otherwise the
pill will sit in `working` (yellow/blue) while the user is actually being
asked to decide. In Mode A, the same coverage comes for free because
`ask_user` is a tool call that fires `PreToolUse` / `PostToolUse`.

**Never push the same state twice in a row** — the widget de-duplicates by
state+message. Push only on transitions, or include a fresh message each
time.

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

The wrapper accepts `-Tool bash|read|write|edit|glob|grep|web|task|notebook`
and emits a tool-specific `done` message (e.g. `read C:\path`,
`edited file.cs`, `npm test 完成`) so the pill text is informative. For
read/write/edit/glob/grep the wrapper itself does not execute the
command — mcode's own tool does; this script only publishes the state.

For other tools (read/write/edit) — and for any state push that is not a
single command — call `notify-island.ps1` directly:

```powershell
$plugin = "<plugin install dir>"   # directory that contains notify-island.ps1
& "$plugin\notify-island.ps1" -State thinking
& "$plugin\notify-island.ps1" -State working  -Message "read source tree"
& "$plugin\notify-island.ps1" -State done     -Message "indexed 142 files"
& "$plugin\notify-island.ps1" -State error    -Message "compile failed: missing import"
& "$plugin\notify-island.ps1" -State waiting  -Message "permission prompt"
```

`<plugin install dir>` is the directory that contains `notify-island.ps1`.
Substitute the absolute path your user installed the plugin at. The Skill
body deliberately avoids hard-coded paths so any user / any install location
works.

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

This writes to `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` — no
admin rights required.

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

**No data leaves the local machine unless an opt-in 5-hour usage token is
configured.** When `config.json:planApiToken` is set, the detector calls
`GET https://api.minimaxi.com/v1/coding_plan/remains` at most once per
60 s; the response is rendered as a small badge on the pill. When no token
is present, the detector makes no network request at all. No
`telemetry`, no `analytics`, no third-party services, no auto-update
checks, no error reporting.

## What is in this package

```
mcode-island/
├── .claude-plugin/
│   └── plugin.json                # CLAUDE manifest (0.4.0+), top-level hooks
├── README.md                      # full user-facing docs
├── LICENSE                        # Apache-2.0
├── mcode-island.ps1               # WPF widget main loop
├── mcode-island.cmd               # CLI shim (start/stop/status/...)
├── start-island.ps1               # launch the widget in STA
├── stop-island.ps1                # stop the widget
├── status-island.ps1              # print widget state
├── show-island.ps1                # re-raise hidden widget
├── pin-island.ps1                 # lock focus target to foreground
├── autostart.ps1                  # register/unregister Windows logon
├── notify-island.ps1              # state-push helper (agents call this)
├── wrap-tool.ps1                  # all-in-one bash wrapper
├── mcode-status-detect.ps1        # runtime-state detector (Mode B fallback)
├── start-detect-island.ps1        # detector launcher (kept alongside widget)
├── stop-detect-island.ps1         # detector stopper
├── set-token.ps1                  # write planApiToken into config.json
├── io.minimax.mcode/
│   └── hooks/
│       └── scripts/
│           ├── _lib.ps1           # shared helper
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
├── skills/mcode-island/SKILL.md   # this file
└── assets/                        # screenshots used in the README
```

The legacy `plugin.json` (root), `io.minimax.mcode/hooks/hooks.json`,
`install-hook.ps1`, and `hooks/win32-ava-patch/` files from the 0.3.10/0.3.11
era are intentionally **not** shipped. See `README.md → "Migrating from
0.3.x"` for the upgrade notes.

## Limitations and known constraints

- Windows 10/11 only (uses WPF, `user32`, and `kernel32` P/Invoke).
- Single widget per user session.
- Hook-driven mode requires mcode 0.4.0+ (the release that introduced
  the CLAUDE manifest convention). On 0.3.10/0.3.11, root `plugin.json`
  takes priority in the manifest loader and the runtime returns
  `hooks: []` — Mode A is dormant; Mode B is the always-works fallback.
- `PermissionDenied` is registered forward-only. The 0.4.0 dispatcher's
  `l4e` table (idx=4769486) does not yet include it; the script ships
  and will start firing when a future mcode release adds the event.
- No hover-expand, no media-control integration yet — see the `v0.2`
  roadmap in the upstream issue tracker.
- `wrap-tool.ps1` is a **status publisher only** — it never executes
  the command itself (mcode's tool does). The agent still runs every
  read / write / edit through mcode and then calls `wrap-tool.ps1` to
  publish the outcome. This avoids shell-injection ambiguity from a
  prior `Invoke-Expression` design.
