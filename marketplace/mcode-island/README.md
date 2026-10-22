# mcode Dynamic Island

A Windows desktop status pill ("Dynamic Island") for MiniMax Code. It shows what the agent is
doing right now — thinking, running a tool, waiting for your approval, done or failed — so you can
follow the work without switching back to the terminal window.

![states](assets/state-working.png)

## Try it

```text
Open a desktop status pill so I can follow your progress without switching back to the terminal.
```

Expected result: a dark pill appears at the top center of your primary display, and it keeps
updating while the agent works.

## States

| state      | meaning                        |
| ---------- | ------------------------------ |
| `idle`     | waiting for your input         |
| `thinking` | reasoning, no tool call yet    |
| `working`  | actively running a tool        |
| `waiting`  | tool needs approval / input    |
| `done`     | step finished, more to do      |
| `error`    | tool or step failed            |

## Requirements

- Windows 10 or 11. Every script checks the platform first and exits with a clear message
  (`mcode-island supports Windows only`) anywhere else, instead of failing later inside WPF.
- PowerShell 5.1 or newer. The scripts in this package are pure ASCII and carry no byte-order
  mark, so they parse the same way on every code page.

## What is in this package

```
mcode-island/
├── .minimax-plugin/
│   └── plugin.json               # MiniMax Plugin V1 manifest (package entry point)
├── icon.png                      # 512x512 marketplace icon
├── skills/mcode-island/
│   └── SKILL.md                  # the skill: how the agent pushes state
├── mcode-island.ps1              # WPF widget
├── mcode-island.cmd              # CLI shim (start/stop/status/...)
├── start-island.ps1              # launch the widget
├── stop-island.ps1               # stop the widget
├── status-island.ps1             # print widget state
├── show-island.ps1               # re-raise the hidden widget
├── pin-island.ps1                # lock the focus target to the foreground window
├── autostart.ps1                 # register/unregister the Windows logon entry
├── notify-island.ps1             # state-push helper (the agent calls this)
├── wrap-tool.ps1                 # all-in-one state publisher for tool calls
├── mcode-status-detect.ps1       # runtime-state detector
├── start-detect-island.ps1       # start the detector
├── status-detect-island.ps1      # detector status
├── stop-detect-island.ps1        # stop the detector
├── scripts/lib/
│   ├── Protect-Text.ps1          # secret redaction helper
│   └── Status-Store.ps1          # cross-process status.json protocol
├── assets/                       # state screenshots
├── README.md
├── README.zh-CN.md
└── LICENSE                       # Apache-2.0
```

## Usage

Start the widget once (the agent can also do this for you):

```cmd
mcode-island
```

Then the agent pushes state as it works:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<plugin-root>\notify-island.ps1" -State working -Message "read source tree"
```

See `skills/mcode-island/SKILL.md` for the full workflow, including sub-step progress and the
`ask_user` wait case.

The state detector is optional. When it is running it reads the local MiniMax Code session
stream (`~/.minimax/v2/sessions`, or `$env:MINIMAX_DATA_DIR`) and infers the current state on its
own, which keeps the pill moving even when the agent does not push. It reads local files only.

## Autostart

`mcode-island autostart-on` writes two named values under
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run` (`mcode-island` and `mcode-island-detect`).
It creates the key only when it does not exist yet, writes only its own two values, and verifies
afterwards that every unrelated entry in that key is still there.

## Runtime data

All state lives under `%APPDATA%\mcode-island\` — `status.json`, `caller.json`, `config.json`,
`widget.pid`, `island.log`, `widget.log`. Nothing is uploaded.

## Disclosure

- **No credentials.** The package contains no token, key, secret or personal data, reads no
  credential from the environment, and stores none. There is no API client in this package.
- **No network.** The package makes no outbound request of any kind. The state detector reads
  local session files; the widget draws locally.
- **No telemetry.** No analytics, no crash reporting, no usage beaconing.
- **No third-party services.** No CDN, no update check, no phone-home. Everything runs locally.
- **No Hooks.** The package contains no client event extension and no event declaration. State is
  pushed by the agent and, optionally, inferred by the local detector.

## Relationship to the upstream plugin

This directory is the Marketplace submission build of `plugins/antianqi/mcode-island`. It is
generated from that source by `marketplace/build-marketplace-package.ps1` and differs in these ways,
all of them required by the Marketplace package rules:

1. the entry point is `.minimax-plugin/plugin.json`; the agent-plugins.org manifest and the
   Claude-format manifest are not part of a Marketplace package;
2. the client event extension and the development-only smoke/test scripts are not part of a
   Marketplace package;
3. package text files are UTF-8 **without** a BOM, and Windows PowerShell 5.1 parses a BOM-less
   `.ps1` with the ANSI code page. The scripts here are therefore ASCII-only, and the Chinese
   comments of the upstream copy are not shipped;
4. the user-facing text is English here; the Chinese UI, the Chinese console messages and the full
   Chinese documentation live in the upstream plugin and in `README.zh-CN.md` and
   `skills/mcode-island/SKILL.md`.

The hosted plugin in `plugins/antianqi/mcode-island` keeps its Chinese UI, its 5-hour usage
badge and its local installation flow.

## License

Apache-2.0. See `LICENSE`.
