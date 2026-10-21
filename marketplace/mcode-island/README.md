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
├── set-token.ps1                 # manage the optional 5h-usage token
├── scripts/lib/
│   ├── Get-5hUsage.ps1           # opt-in 5h usage lookup
│   └── Protect-Text.ps1          # secret redaction helper
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

## Runtime data

All state lives under `%APPDATA%\mcode-island\` — `status.json`, `caller.json`, `config.json`,
`widget.pid`, `island.log`, `widget.log`. Nothing is uploaded.

## Disclosure

- **No credentials.** The package contains no token, key, secret or personal data. The optional
  5-hour usage token is supplied by the user at runtime and stored locally in
  `%APPDATA%\mcode-island\config.json`.
- **No network by default.** With no token configured the plugin makes no network request at all.
  With a token configured, the detector performs one `GET` per 60 seconds against
  `https://api.minimaxi.com/v1/coding_plan/remains`.
- **No telemetry.** No analytics, no crash reporting, no usage beaconing of any kind.
- **No third-party services.** No CDN, no update check, no phone-home. Everything runs locally.

## Relationship to the upstream plugin

This directory is the Marketplace submission build of `plugins/antianqi/mcode-island`. It is
generated from that source (see `marketplace/build-marketplace-package.ps1`) and differs in three
ways, all required by the Marketplace package rules:

1. the client-extension directory, the Claude-format manifest (`.claude-plugin/`),
   the agent-plugins.org manifest and the development-only smoke/test scripts are excluded;
2. every `.ps1` / `.cmd` file is ASCII-only and UTF-8 **without** a BOM, so Windows PowerShell 5.1
   can parse it without a code-page dependency (the upstream copy keeps the BOM and the Chinese
   comments);
3. the user-facing Chinese text in the widget survives as XML numeric character references and
   `([char]0x..)` code points instead of literal UTF-8.

The Chinese UI, the Chinese console messages and the full Chinese documentation are preserved;
`README.zh-CN.md` and `skills/mcode-island/SKILL.md` are the Chinese-facing documents.

## License

Apache-2.0. See `LICENSE`.
