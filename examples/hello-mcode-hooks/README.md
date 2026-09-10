# hello-mcode-hooks

A minimal Plugin that ships one Skill and one experimental `io.minimax.mcode` Hook entry under
the Agent Plugins 1.0 portable Hooks preview, conformant to the `@minimax-ai/code@0.3.10`
runtime hook schema and inherited unchanged by `@minimax-ai/code@0.3.11` (the only
0.3.10 -> 0.3.11 change is a 401-token retry fix; the hook schema, the `Ava`
dispatch wrapper, the `Fwe` allowlist, and the `Uwe` parser are byte-identical).
Re-verified on a 0.3.11 install at 2026-09-10.

## What this example demonstrates

- A Skill-only Agent Plugin (the "hello-hooks" Skill).
- A `hooks.json` document that targets every event in the 0.3.10 catalog
  (`PreToolUse`, `PostToolUse`, `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop`,
  `PreCompact`, `Notification`, `SubagentStart`, `SubagentStop`, `PermissionRequest`,
  `PermissionDenied`) with one `record.mjs` invocation each. In 0.3.10 the runtime
  auto-dispatches only the five `Fwe`-allowlist events
  (`PreToolUse`, `PostToolUse`, `SessionStart`, `SessionEnd`, `UserPromptSubmit`);
  the remaining seven load cleanly but never fire and are recorded for forward
  compatibility. See `proposals/hooks-detailed-spec.md` § "Empirical event catalog"
  for the per-event Fwe status.
- Atomic, cross-platform state file writes under the runtime-provided `PLUGIN_DATA` directory.
- Path resolution that uses runtime-injected environment values, not host-absolute literals.

This example is not a working integration; it is a structural reference for portable
Plugin authors writing Hooks against `@minimax-ai/code@0.3.10`. The companion proposal
in `proposals/hooks-detailed-spec.md` is still in review; registry validation does not
execute Hook code.

## Layout

```text
hello-mcode-hooks/
├── README.md
├── LICENSE
├── plugin.json
├── skills/
│   └── hello-hooks/
│       └── SKILL.md
└── io.minimax.mcode/
    └── hooks/
        ├── hooks.json
        └── scripts/
            └── record.mjs
```

## Hook entry

The `hooks.json` document is the 0.3.10 nested shape: each event value is an array of
matcher entries, and each matcher entry wraps a `hooks[]` array of command descriptors.
The descriptor's `command` is a single string passed to the platform shell; `matcher`
lives on the outer (matcher) entry, not the inner (command) descriptor; `timeout` is in
seconds (the runtime multiplies by 1000 internally).

```json
{
  "$schema": "https://minimax.io/schemas/mcode-hooks/0.1.0/hooks.schema.json",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "node ${PLUGIN_ROOT}/io.minimax.mcode/hooks/scripts/record.mjs --event PreToolUse --state ${PLUGIN_DATA}/state.json",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

The script reads the event payload from stdin (one UTF-8 JSON document, then EOF, as
proposed in `proposals/hooks.md` § "Observe-only runtime semantics") and appends a
compact record to `${PLUGIN_DATA}/state.json` using a staging-file rename. No tool input
rewriting, no permission decisions, no network access, no telemetry.

## Validation expectations

- `plugin.json` continues to target the published Agent Plugins 1.0 schema and remains
  valid under `scripts/validate.mjs`.
- `io.minimax.mcode/hooks/hooks.json` is recognized as an experimental client extension
  namespace. The validator accepts it but does not require it.
- The validator reports the full event catalog (12 portable + 3 streaming) as the
  closed-schema allowlist for the document root. Events outside the catalog are
  rejected; the 0.2.4 fields `args` / `env` / `cwd` / `pattern` / `regex` / `glob` /
  `once` / `timeoutMs` are rejected as closed-schema violations on inner descriptors
  so a Plugin migrating from 0.2.4 to 0.3.10 gets a clear error rather than a silent
  no-op.
- The script resolves all paths from `${PLUGIN_ROOT}` and `${PLUGIN_DATA}` only.

## Runtime install caveat

The 0.3.10 runtime reads `hooks.json` from
`${MINIMAX_DATA_DIR}/hooks/hooks.json` or
`${MINIMAX_DATA_DIR}/agents/<agentName>/hooks/hooks.json`, not from a Plugin's own
`io.minimax.mcode/hooks/hooks.json` directory. The Plugin registry accepts the
`io.minimax.mcode` namespace in `plugin.json` but the 0.3.10 hook-config parser does
not consult that field. A Plugin that wants its hooks to fire must install
`hooks.json` into one of the two Runtime-resolved locations; the `mcode-island`
v0.4.0 install step copies the bundled `hooks.json` there on marketplace install.

## Disclosure

This example contains:

- no credentials;
- no network access;
- no telemetry;
- no third-party services.

The same disclosure is repeated in `skills/hello-hooks/SKILL.md` per the
`hello-mcode-hooks` plugin convention.
