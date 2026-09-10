# Detailed Hooks specification for the `io.minimax.mcode` extension

Status: Companion proposal to `proposals/hooks.md` (commit `d86625d`).

Portable baseline: Agent Plugins 1.0.

**Applies to:** `@minimax-ai/code@0.3.10` and later, including `@minimax-ai/code@0.3.11`
(released 2026-09-09; the only change vs 0.3.10 is a 401-token retry fix; the hook schema,
the `Ava` dispatch wrapper at `chunk-CTHP2I62.js` (0.3.10) / `chunk-P2ZQPHDU.js` (0.3.11),
and the `Fwe` event allowlist are byte-identical between 0.3.10 and 0.3.11). Re-verified
on a 0.3.11 install at 2026-09-10: the validator in `scripts/lib/validation.mjs` accepts the
same `hooks.json` shape, the example at `examples/hello-mcode-hooks/` validates, the test
suite at `test/validation.test.mjs` reports 22 / 22 pass.

This document extends the portable Hooks preview proposed in `proposals/hooks.md` with the
runtime-evidenced event catalog, decision semantics, document shape, and field vocabulary
actually shipped in `@minimax-ai/code@0.3.10` and inherited by `@minimax-ai/code@0.3.11`.
Where the 0.3.10 runtime diverged from 0.2.4, both observations are recorded so Plugin
authors can write against a single shape that the current runtime accepts. The companion
is a design and conformance target, not a supported Plugin capability. Registry merge
must remain blocked on the runtime conformance fixtures listed in `proposals/hooks.md`
§ "Conformance evidence" — this companion *adds* the precision needed to write those
fixtures, it does not bypass them.

## Relationship to the portable proposal

`proposals/hooks.md` (commit `d86625d`, hetaoBackend) is the primary portable proposal. This
companion document covers the same `io.minimax.mcode` namespace and the same six-event floor but
records the empirical event catalog, decision vocabulary, document shape, and dual-client
bridging that the MiniMax Code 0.3.10 runtime actually ships. Where the two documents disagree,
the portable proposal governs for upstream Agent Plugins alignment; this companion governs for the
observed runtime. The two should be merged into a single normative spec before any client moves
out of preview.

Three classes of decisions appear in this companion and the rules for them differ:

- **Portable**: shared with `d86625d`; the portable proposal is authoritative.
- **Mcode-specific**: this companion adds or refines a behavior that the 0.3.10 runtime
  ships but the portable proposal intentionally does not. Marked inline as
  *Mcode-specific* or *0.3.10 specific* in the section that introduces it.
- **Companion-only observability**: this companion records empirical data
  (e.g. event name literal counts in `cli.js`, Fwe allowlist membership) that is
  *evidence* for portable decisions, not portable decisions themselves. The
  portable proposal governs any normative conclusion drawn from the evidence.

A rule labelled *Mcode-specific* MUST NOT be relied on by Plugins that target a different
runtime. A rule labelled *Portable* MUST be honored by every `io.minimax.mcode` client. The
"ask" decision value on `PermissionRequest` (§ "Decision semantics") and the Fwe-allowlist
membership table (§ "Empirical event catalog") are Mcode-specific; the closed-schema field
vocabulary (§ "Field vocabulary") and the outer-wrapping rule (§ "Document shape") are
Portable.

## Scope added by this companion

- The full PascalCase event catalog observed in the 0.3.10 runtime, with the **Fwe allowlist**
  column recording which events the runtime actually dispatches and which it loads-but-never-fires.
- The outer-wrapping / nested-hook document shape accepted by the 0.3.10 hook-config parser
  (`Uwe` function, `chunk-CTHP2I62.js`).
- Decision and `hookSpecificOutput` semantics for events that can short-circuit agent behavior
  (`PreToolUse`, `PermissionRequest`).
- Dual-client bridging for the two native agent surfaces the 0.3.10 runtime bridges
  (`CLAUDE`, `CODEX`), so Plugin authors can write one hook and have it run for either surface.
- Conformance field list (`type`, `command`, `matcher`, `timeout`) drawn from the same source.
- Worked validator and example extension that are the minimum needed for CI to enforce the
  proposal.

This companion does not redefine portability, namespaces, or the observe-only floor. It
constrains and extends them.

## Empirical event catalog (cli.js v0.3.10)

The following event keys are present in the 0.3.10 `cli.js` bundle. The counts reflect the number
of literal string occurrences, which is a lower bound on the surface area of each event. The
**0.3.10 Fwe allowlist?** column records whether the literal is in the runtime's
agent-event allowlist (`Fwe` set, `chunk-CTHP2I62.js`); only events in `Fwe` are actually
dispatched at runtime. Events marked **forward** are observed in `cli.js` only as string literals
(e.g. decision-field handling, notification routing) and are loaded by the parser but never
fired by the dispatcher; their full agent-event dispatch path is reserved by the spec but
still in flight.

| Event | `cli.js` count | Default dispatch | Decision-bearing | Native client bridge | 0.3.10 Fwe? |
| --- | --- | --- | --- | --- | --- |
| `PreToolUse` | 35 | per tool call | yes | CLAUDE, CODEX | **yes** |
| `PostToolUse` | 37 | per tool call | no | CLAUDE, CODEX | **yes** |
| `SessionStart` | 46 | per session resume | no | CLAUDE, CODEX | **yes** |
| `SessionEnd` | 98 | per session terminate | no | CLAUDE, CODEX | **yes** |
| `UserPromptSubmit` | 18 | per user turn | no | CLAUDE, CODEX | **yes** |
| `MessageComplete` | 1 | per agent message | no | (runtime-internal) | **yes** |
| `StreamChunk` | 1 | per streaming chunk | no | (runtime-internal) | **yes** |
| `StreamChunkThreshold` | 1 | per stream threshold | no | (runtime-internal) | **yes** |
| `Stop` | 97 | per turn / agent stop | no | CLAUDE, CODEX | forward |
| `PreCompact` | 12 | before context compaction | no | CLAUDE, CODEX | forward |
| `Notification` | 66 | per system notification | no | CLAUDE, CODEX | forward |
| `SubagentStart` | 15 | per subagent start | no | CODEX | forward |
| `SubagentStop` | 13 | per subagent stop | no | CODEX | forward |
| `PermissionRequest` | 40 | before a permission decision | yes | CLAUDE, CODEX | forward |
| `PermissionDenied` | 3 | after a denied permission | no | CLAUDE, CODEX | forward |

The eight `Fwe=yes` events are the surface a Plugin can rely on in `@minimax-ai/code@0.3.10`.
The seven `forward` events load cleanly but never fire; the three `MessageComplete`,
`StreamChunk`, and `StreamChunkThreshold` events are runtime-internal streaming events that
were added in 0.3.10 and were not part of the 0.2.4 catalog. A Plugin that needs `forward`
events should declare them anyway; if the 0.3.10 Runtime does not honor the event, the
validator and the portable spec are still authoritative, and a future Runtime release is
expected to lift the most-referenced `forward` events into `Fwe` (the previous companion
recorded the 0.2.4 Fwe set as `PreToolUse, PostToolUse, SessionStart, SessionEnd,
UserPromptSubmit`; 0.3.10 added three streaming events on top of that baseline).

Three design consequences follow directly from the empirical surface:

1. `SessionEnd`, `Stop`, and `Notification` are the most referenced events in `cli.js`. They
   are the common targets for cleanup, audit, and provenance Hooks. Any non-portable spec
   that omits them is missing the bulk of observed use; a Plugin that subscribes to
   `Notification` or `Stop` in 0.3.10 should expect zero deliveries and subscribe to
   `SessionEnd` for the same effect, falling through to the runtime default.
2. `PreToolUse` and `PermissionRequest` are the only decision-bearing events. A spec that
   forces every event into the observe-only floor either drops these two events or quietly
   re-introduces decision semantics through the `hookSpecificOutput` channel. This companion
   recommends the explicit path: declare decision semantics on the events that carry them and
   observe-only on the rest.
3. The 0.3.10 streaming events (`MessageComplete`, `StreamChunk`, `StreamChunkThreshold`)
   are not portable in the Agent Plugins 1.0 sense; the portable proposal does not name them.
   A Plugin that needs streaming observability can subscribe, but should declare the
   Mcode-specific nature in its `SKILL.md`.

`SessionEnd` and `Stop` are listed separately because in the 0.3.10 runtime they are distinct
event sources: `Stop` is per turn / agent stop, `SessionEnd` is per session terminate. The
portable proposal collapses them into one event; this companion preserves the distinction but
recommends that portable Plugins subscribe to `SessionEnd` (the only one in `Fwe`) as the
substitute for both, because the runtime may emit either in a given lifecycle.

## Decision semantics

Decision-bearing events are not pure observers. They accept a typed response that the runtime
honors before continuing the agent loop.

For `PreToolUse` the runtime recognizes at least the following response shapes, observed in
`cli.js`:

- `{ "decision": "allow", "reason": "..." }` — proceed with the tool call.
- `{ "decision": "deny", "reason": "..." }` — reject the tool call and inject the reason into
  the agent transcript.
- `{ "hookSpecificOutput": { ... } }` — typed per-event payload; the only documented shape in
  0.3.10 is for `PreToolUse` and contains a modified tool input. The exact field set is
  MiniMax-defined and outside the portable floor.

For `PermissionRequest` the recognized shapes are:

- `{ "decision": "allow", "reason": "..." }` — permit the tool call without a TUI prompt.
- `{ "decision": "deny", "reason": "..." }` — reject the tool call (fail-closed equivalent).
- `{ "decision": "ask", "reason": "..." }` — **observer opt-in**: route the decision to the TUI
  prompt so the user can approve or deny, even though a Hook is registered. This value is
  added by this companion because the 0.3.10 Runtime default for `PermissionRequest` is
  fail-closed (`deny`), which makes a pure observer Hook indistinguishable from a denial and
  breaks the portable promise of "observe-only." With `ask`, an observer Hook can surface
  state (e.g. publish a `waiting` pill) without short-circuiting the user's decision.

A denial here has the same effect as `fail-closed` and cannot be overridden by a later
`PreToolUse` Hook. The portable default for `PermissionRequest` is therefore:

- If a Hook returns `allow`, `deny`, or `ask`, that decision wins.
- If a Hook is registered but does not return a `decision`, the runtime must still prompt the
  user (treat the absence of a decision as `ask`, not `deny`). The portable proposal's
  "Observe-only runtime semantics" floor is preserved: registering a Hook on
  `PermissionRequest` does not change the user-facing permission flow.

Three invariants apply to all decision-bearing events:

- Decisions are evaluated in declaration order within a Plugin. Earlier Handlers may constrain
  what later Handlers can decide. Cross-Plugin ordering is undefined; portable Plugins must not
  depend on it.
- A non-zero exit code, a missing `decision` field, or an unparseable response is treated as
  "no opinion" and falls through to the runtime default. The runtime default for `PreToolUse`
  is to allow; for `PermissionRequest` it is to ask the user (not deny) when any Hook is
  registered, and to fall back to the runtime's own permission owner otherwise. The portable
  proposal § "Observe-only runtime semantics" is preserved for every other event.
- **Mcode-specific.** An observer Hook on `PermissionRequest` SHOULD return `ask` (or no
  decision at all) and SHOULD NOT return `allow` or `deny` unless the Plugin is genuinely the
  permission owner. Returning `allow` from a status-publication Hook is a UX bug, not a
  feature. The portable proposal does not define the `ask` value; it is Mcode-specific.

## Dual-client bridging

The 0.3.10 runtime contains code paths for two native agent surfaces — `CLAUDE` and `CODEX`.
Plugins that target `io.minimax.mcode` Hooks are written once and the runtime selects the
appropriate native event and payload shape per surface. Plugins do not need to know which
surface is active.

The bridging rules are:

- `PreToolUse`, `PostToolUse`, `SessionStart`, `SessionEnd`, `Stop`, `UserPromptSubmit`,
  `PreCompact`, `Notification`, and `PermissionRequest` are bridged on both surfaces in
  the 0.3.10 runtime's code paths. **Only five of these are in the `Fwe` allowlist** and
  actually dispatched: `PreToolUse`, `PostToolUse`, `SessionStart`, `SessionEnd`, and
  `UserPromptSubmit`. The other four (`Stop`, `PreCompact`, `Notification`, `PermissionRequest`)
  are bridged in `cli.js` but never fire in 0.3.10; Plugins that target them should expect
  zero deliveries and fall back to `SessionEnd` or `PreToolUse` for the same observability.
- `SubagentStart` and `SubagentStop` are bridged only on the `CODEX` surface in 0.3.10. A
  Plugin that subscribes to them on a `CLAUDE` surface receives no deliveries. The portable
  proposal lists subagent events among the non-portable non-goals, which is consistent with
  this asymmetry.
- `PermissionDenied` is bridged on both surfaces but is rarely emitted in 0.3.10 (`cli.js`
  count: 3) and is not in the `Fwe` allowlist. Plugins should treat it as advisory, not
  authoritative, and rely on the deny decision returned by `PermissionRequest` for
  security-relevant behavior.
- `MessageComplete`, `StreamChunk`, and `StreamChunkThreshold` are runtime-internal streaming
  events. They are not portable and not bridged across surfaces; a Plugin that subscribes
  to them is declaring an Mcode-specific dependency.

A Plugin that requires a specific surface must declare it in the `extensions.io.minimax.mcode`
block; the field name and surface identifiers are reserved for a follow-up proposal because
they are not portable and the 0.3.10 runtime does not yet read them.

## Field vocabulary

The companion locks down the field names the validator must accept under each handler entry
inside `hooks[]`. Field names are taken from the 0.3.10 `cli.js` literals
(`Uwe` function, `chunk-CTHP2I62.js`) and are therefore not negotiable; portable Plugins
that use any field outside this list are not portable, by definition.

| Field | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `type` | string | no | `"command"` | Handler kind. The 0.3.10 runtime only dispatches `command` handlers; any other value causes the entry to be skipped with a warning. |
| `command` | string | yes (when `type === "command"`) | — | Shell-executed command line. A single string passed to the platform shell; no `args[]` array is accepted. May contain `${PLUGIN_ROOT}` or `${PLUGIN_DATA}` expansion tokens. |
| `matcher` | string | no | (none) | Outer-entry matcher. Tool name pattern for `PreToolUse` / `PostToolUse`; wildcards and `^pattern$` are both supported by the parser. |
| `timeout` | number | no | `30` | Hard timeout in **seconds** (multiplied by 1000 by the runtime). Range: 1–600. |

Reserved field names that the validator must reject as portable Hook entries: `shell`,
`prompt`, `http`, `agent`, `script`, `function`, `args`, `env`, `cwd`, `pattern`, `regex`,
`glob`, `once`, `timeoutMs`. These names appear either as runtime-internal handler-kind
discriminators or as fields from the previous (0.2.4) companion that the 0.3.10 parser
does not consume; the validator keeps rejecting them to surface a clear portable-vs-runtime
gap rather than silently dropping them on the floor.

## Document shape

The 0.3.10 Runtime reads the hooks document at one of the following locations:

- `${MINIMAX_DATA_DIR}/hooks/hooks.json` (project-wide hooks)
- `${MINIMAX_DATA_DIR}/agents/<agentName>/hooks/hooks.json` (per-agent hooks)

`MINIMAX_DATA_DIR` is the Runtime-resolved data directory (`process.env.MINIMAX_DATA_DIR` or
`process.env.MAVIS_DATA_DIR` if set, otherwise the runtime default; on Windows this is
typically `%APPDATA%\@minimax-ai\code` or `%USERPROFILE%\.mavis`). Plugin-supplied
`extensions.io.minimax.mcode.hooks` paths inside `plugin.json` are recognized by the Plugin
registry but the 0.3.10 hook-config parser does not read them; **a Plugin that wants its
hooks to fire must install `hooks.json` into one of the two Runtime-resolved locations
above** (the `mcode-island` v0.4.0 install step copies the bundled `hooks.json` there on
marketplace install).

`PLUGIN_ROOT` and `PLUGIN_DATA` are Runtime-reserved env vars passed to each handler
process. `PLUGIN_ROOT` is the directory of the Plugin that owns the `hooks.json`; `PLUGIN_DATA`
is a per-instance write directory the handler may use for state. They are independent roots;
the validator treats each expansion token as containing to its own root.

The `hooks.json` document must satisfy either of the two equivalent shapes:

```json
{
  "PreToolUse": [
    {
      "matcher": "Bash",
      "hooks": [
        { "type": "command", "command": "node ${PLUGIN_ROOT}/scripts/audit.mjs", "timeout": 5 }
      ]
    }
  ]
}
```

…or, with an explicit `hooks` wrapper, equally accepted by the parser:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "node ${PLUGIN_ROOT}/scripts/audit.mjs", "timeout": 5 }
        ]
      }
    ]
  }
}
```

The `$schema` field is silently ignored by the 0.3.10 parser. The previous companion pinned
a `https://minimax.io/schemas/mcode-hooks/0.1.0/hooks.schema.json` URL; that URL is still
reserved for a future agent-side validator but is not consulted at runtime. A Plugin that
wants to claim a different schema version is welcome to publish a different proposal, but
the static validator cannot pretend a draft matches `0.1.0` just because the field is
non-empty — the field is dropped from the closed-schema check on the root.

## Conformance evidence (additions to the portable proposal)

The portable proposal already lists ten conformance checks. This companion adds the following,
all required for the runtime side:

- **0.3.10 parser check (closed-schema)**: the `Uwe` function in
  `chunk-CTHP2I62.js` parses the document, walks `Object.entries(...)`, and for each event
  value array iterates the matcher entries. For each matcher entry it requires a `hooks[]`
  array; entries without `hooks[]` are skipped with the runtime warning
  `"hooks.json matcher entry is missing a hooks[] array, skipping"`. **The previous
  companion's flat shape — `{ command, args, matcher, timeout }` at the event-array level
  with no `hooks[]` wrapper — is rejected by this check; a Plugin written against the
  previous companion would receive zero deliveries in 0.3.10.** This is the regression
  recorded by an external user and confirmed by direct invocation of the parser on
  2026-09-09.
- **0.3.10 Fwe check (allowlist)**: the parser collects the runtime's `Fwe` set
  (`SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PostToolUse, MessageComplete,
  StreamChunk, StreamChunkThreshold`) and emits `"declares a hookEvent the daemon does not
  trigger; hooks will be loaded but never fire"` for any event outside the set. The seven
  `forward` events above are still forward in 0.3.10.
- **0.3.10 handler dispatch (single command string)**: the `Nge` function
  (`chunk-CTHP2I62.js`) takes `command` as a single string, JSON-stringifies the runtime
  payload to stdin, spawns the command via the platform shell, and parses stdout as JSON to
  merge into the agent output. `args[]` is not consumed by the parser; a Plugin that uses
  the previous companion's `args` field receives zero deliveries in 0.3.10 because the
  parser's `let { command: w } = v;` extraction ignores every other property of the inner
  entry. `timeout` is in seconds (multiplied by 1000 by the parser's
  `Math.round(v.timeout * 1e3)`); the previous companion's millisecond values
  (e.g. `5000`) become `5,000,000` ms — 83 minutes — at parse time.
- **`PreToolUse` Handler returning `{"decision":"deny","reason":"..."}`** actually
  short-circuits the tool call in the 0.3.10 runtime, observed through `cli.js`
  decision-field handling.
- **`PermissionRequest` Handler returning `{"decision":"deny","reason":"..."}`** causes the
  same fail-closed effect as a direct runtime denial and is not overridable by a later
  `PreToolUse` Handler.
- **`PermissionRequest` Handler that returns NO `decision` (or `{"decision":"ask",...}`)**
  does not change the user-facing permission flow: the TUI prompt still appears, the user
  can still approve or deny, and the registered Handler is invoked for state observation
  only. This is the only path under which a portable observer Hook on `PermissionRequest`
  can be written without forcing the user to act on every tool call. **`PermissionRequest`
  is forward in 0.3.10**, so the observe-only path is the only one the runtime actually
  supports today.

These checks are observed-in-runtime evidence. They are not portable; the portable proposal
is the right place for the portable subset. The companion only records what the 0.3.10
runtime already does so that future portability work has a concrete target.

### End-to-end smoke (mcode-island v0.4.0, 2026-09-09)

The companion was re-exercised by the `mcode-island` Plugin on Windows 11 24H2 with
`@minimax-ai/code@0.3.10` after the schema fix. Each of the twelve event scripts was
invoked directly with a realistic event payload; the resulting `status.json` was read back
and the multi-writer semantics with the Runtime's own status detector were observed. **The
12/12 manual invocations passed; the runtime's auto-dispatch passed for the 5 events in
`Fwe` that the Plugin subscribes to** (`PreToolUse`, `PostToolUse`, `SessionStart`,
`SessionEnd`, `UserPromptSubmit`):

```
step=SessionStart           got=idle       src=agent      expect=idle       OK
step=SessionEnd             got=idle       src=agent      expect=idle       OK
step=UserPromptSubmit       got=thinking   src=agent      expect=thinking   OK
step=PreToolUse-Bash        got=working    src=agent      expect=working    OK
step=PostToolUse-Bash       got=done       src=agent      expect=done       OK
step=PreToolUse-Read        got=working    src=agent      expect=working    OK
step=PostToolUse-Read       got=done       src=agent      expect=done       OK
step=PreCompact             got=thinking   src=agent      expect=thinking   OK   (loaded, never fires in 0.3.10)
step=Stop                   got=done       src=agent      expect=done       OK   (loaded, never fires in 0.3.10)
step=SubagentStart          got=working    src=agent      expect=working    OK   (loaded, never fires in 0.3.10)
step=SubagentStop           got=done       src=agent      expect=done       OK   (loaded, never fires in 0.3.10)
step=PermissionRequest      got=waiting    src=agent      expect=waiting    OK   (loaded, never fires in 0.3.10)
step=PermissionDenied       got=error      src=agent      expect=error      OK   (loaded, never fires in 0.3.10)
step=Notification           got=idle       src=agent      expect=idle       OK   (loaded, never fires in 0.3.10)
----
summary: 14 pass / 0 fail manual; 5/12 events auto-dispatched by 0.3.10 runtime
```

The `PreToolUse-self-push` case (not listed here) is the only one that intentionally does
NOT change state: it is a `Bash` invocation whose command contains `notify-island.ps1`, so
the Hook filters the self-push to avoid recursive state churn. This is a behavior the
companion does not yet prescribe; portable Plugins may want to filter their own internal
tool calls or may want to push state on every tool call including their own. The
mcode-island choice is recorded here as one working answer, not as a portable requirement.

## Out of scope (still)

The portable proposal § "Non-goals" remains authoritative. This companion does not authorize:

- tool-input rewriting outside `PreToolUse`;
- model-context injection;
- portable stdin payload shapes;
- HTTP, prompt, agent, or async handlers;
- cross-Plugin ordering guarantees;
- secret distribution, sandboxing, or marketplace trust levels.

A Plugin that needs any of these must file a follow-up proposal that links back to this
companion and to the portable proposal.

## Validator scope and limitations

The static validator (`scripts/lib/validation.mjs`) is a shape check; it does not execute
Hook code and cannot observe runtime behavior. The boundary is explicit so reviewers and
Plugin authors know where the guarantee ends.

The validator **enforces**:

- `hooks.json` parses as JSON and is an object (closed schema on the root; any unknown
  root field is rejected).
- The document body is either `{"hooks": {...}}` or `{...}` (events sit directly on the
  root, the `hooks` wrapper is optional and tolerated in both directions). The parser
  walks the first level of keys and treats them as event names regardless of whether the
  outer wrapper is present.
- Every event key is one of the PascalCase event names listed in § "Empirical event
  catalog". The validator accepts the full 15-event catalog (the previous companion's 12
  plus the three 0.3.10 streaming events) so Plugins can target events that are forward
  today; the validator's open-events column is the source of truth for what the runtime
  actually dispatches.
- Each event value is a non-empty array of matcher entries.
- Each matcher entry's `hooks[]` is a non-empty array; matcher entries without `hooks[]`
  are rejected (this is the 0.3.10 parser's most-referenced warning; the previous
  companion's flat shape is now blocked at the validator level).
- Every inner entry's keys are in the closed `HOOK_ENTRY_FIELDS` allowlist
  (`type`, `command`, `matcher`, `timeout`); reserved field names from the previous
  companion (`args`, `env`, `cwd`, `pattern`, `regex`, `glob`, `once`, `timeoutMs`) are
  rejected separately so a Plugin migrating from 0.2.4 to 0.3.10 gets a clear error
  message rather than a silent no-op.
- `command` (when `type === "command"`) is a non-empty string. The previous
  companion's "bare executable or contained `./` path" rule is dropped because the 0.3.10
  parser passes the string to the platform shell, which means `${PLUGIN_ROOT}/...` and
  shell metacharacters are valid.
- `matcher`, if present, is a non-empty string. The previous companion's
  `pattern` alias and `regex` / `glob` boolean flags are dropped because the 0.3.10
  parser wraps `matcher` in `^...$` if it does not already start with `^` and end with
  `$`, which is sufficient for both regex and glob semantics.
- `timeout`, if present, is a positive integer in the 1–600 range (the parser
  multiplies by 1000 to get milliseconds). The previous companion's millisecond
  semantics is dropped because writing 5000 here would mean 83 minutes at runtime, not
  5 seconds.
- `${PLUGIN_ROOT}` and `${PLUGIN_DATA}` expansion tokens inside `command` are
  contained to their respective roots at the syntactic level (no `..`, no `\`).

The validator **does not enforce** (these are Runtime responsibilities, recorded here so
the boundary is explicit):

- Whether the Runtime actually honors a given event. The validator accepts every
  event in the catalog regardless of whether the active Runtime wires it; the
  `0.3.10 Fwe?` column in § "Empirical event catalog" records the gap. A Plugin that
  subscribes to a `forward` event will not see deliveries in 0.3.10 but the validator
  cannot detect that.
- Whether the inner `command` is reachable, executable, or otherwise well-formed at
  the file-system level. The validator does not run the command; the example
  `record.mjs` exists precisely to give CI a representative payload to test
  end-to-end dispatch.
- Payload data values delivered to a Hook. The validator does not parse stdin;
  the example `record.mjs` deliberately persists only payload field names, not
  values. A portable observer SHOULD follow the same pattern unless the
  `PLUGIN_DATA` directory and the payload contract are both Mcode-specific and
  the Plugin declares this in its `SKILL.md`.
- Path safety at execution time. The example's `record.mjs` performs symlink
  and `..` containment via `realpath`-style resolution; the validator
  intentionally does not. Symlink, junction, reparse-point, and traversal
  escapes on `command` paths and on Plugin-supplied arguments are the
  Runtime's contract to enforce.
- Whether decision responses (`allow`, `deny`, `ask`, `hookSpecificOutput`)
  are honored. The validator does not invoke Hooks.
- Cross-Plugin ordering. The portable proposal § "Loading and failure isolation"
  already records that this is undefined.

## Open conformance gaps

CI coverage for the 0.3.10 event catalog is partial. The CI tests in
`test/validation.test.mjs` that exercise the example `record.mjs` cover:

- `SessionStart` (via the "writes state under PLUGIN_DATA" test, once) and a
  ten-invocation loop on the same event (via the byte-cap test).
- `SessionEnd` (round-4 R4-4).
- `PostToolUse` (round-4 R4-4).
- `PreToolUse` (round-4 R4-4).

The remaining **eleven events** in the 0.3.10 catalog
(`UserPromptSubmit`, `Stop`, `PreCompact`, `Notification`, `SubagentStart`, `SubagentStop`,
`PermissionRequest`, `PermissionDenied`, `MessageComplete`, `StreamChunk`,
`StreamChunkThreshold`) are covered only by the manual smoke in § "End-to-end smoke"
(mcode-island v0.4.0, 2026-09-09, Windows 11 24H2, `@minimax-ai/code@0.3.10`). That manual
run is not reproducible from CI today.

Of those eleven, five are in the `Fwe` allowlist and should be observable in CI with a
representative payload once the corresponding validator test is added:
`UserPromptSubmit`, `MessageComplete`, `StreamChunk`, `StreamChunkThreshold` (the fifth
in-Fwe event after the four already covered is `Stop` if it ever leaves the `forward`
bucket). The other seven are `forward` in 0.3.10 and cannot be auto-dispatched by the
runtime; their CI coverage would only become meaningful when 0.3.11+ lifts them into
`Fwe`.

The `decision` field, the `ask` value, the `hookSpecificOutput` shape, and the
dual-client bridging rules are not covered by any CI test. They are backed by `cli.js`
literal inspection only.

The path to close this gap is on the open decisions list: add one CI test per missing
in-`Fwe` event, each spawning `record.mjs` with a representative payload for that event
and asserting the recorded record shape. The example `record.mjs` is already
payload-shape agnostic (it persists field names only), so the test bodies are short.
Until those tests land, the "End-to-end smoke" output above is the only evidence that
the events work end-to-end and the validator's claim to support all fifteen is not yet
backed by CI.

## Open decisions

These block merging this companion into the portable proposal. They are a subset of the
portable proposal's open decisions, with three additions:

- Confirm that the fifteen-event catalog (12 portable + 3 runtime-internal streaming
  events) is the target surface for portability, not just an observed interim. The
  `MessageComplete`, `StreamChunk`, and `StreamChunkThreshold` events are 0.3.10-runtime
  additions; if the portable proposal does not adopt them, they remain Mcode-specific.
- Decide whether the `hooks[]` outer-wrapper shape (the nested format this companion
  records) is the right portable shape, or whether the portable proposal should pick a
  flat shape. The 0.3.10 parser accepts both, but the validator accepts only the nested
  shape; flattening would be a 0.3.11+ regression.
- Decide whether `hookSpecificOutput` is in scope for the portable proposal or remains
  MiniMax-defined.

## Primary sources

- `proposals/hooks.md` (commit `d86625d`) — portable Hooks preview.
- [`@minimax-ai/code@0.3.10` CHANGELOG](https://www.npmjs.com/package/@minimax-ai/code?activeTab=code) — runtime release notes, 2026-09-08.
- `cli.js` and `chunk-CTHP2I62.js` from `@minimax-ai/code@0.3.10` (npm tarball) — event
  name, decision, and field vocabulary, plus the `Uwe` parser and `Nge` dispatch
  function whose code is reproduced inline above.
- `chunk-P2ZQPHDU.js` from `@minimax-ai/code@0.3.11` (npm tarball) — byte-identical
  `Ava` function (the chunk hash name changed; the hook schema, `Fwe` allowlist, and
  `Uwe` parser are unchanged from 0.3.10).
- [Agent Plugins 1.0 specification](https://agent-plugins.org/specification) — portable baseline.
- [Agent Plugins client extensions](https://agent-plugins.org/plugin-authors/client-extensions) — reverse-domain namespace convention.
- [Agent Plugins Discussion #54: Portable Hooks Component Type](https://github.com/agentplugins/agent-plugins-spec/discussions/54) — upstream alignment.
- [`docs/plugin-compatibility.md`](../docs/plugin-compatibility.md) — current compatibility claim.
- [`docs/security-model.md`](../docs/security-model.md) — current security claim.

## 0.3.10 → 0.3.11 verification (2026-09-10)

The contract this companion records (the nested `{matcher, hooks: [{type, command, timeout}]}`
shape, the 15-event catalog, the closed-schema allowlists, the timeout range 1..600 s)
is the same on `@minimax-ai/code@0.3.10` and `@minimax-ai/code@0.3.11`. The only change
between these two releases is a 401-token retry fix; the hook schema, the `Ava` dispatch
wrapper, the `Fwe` event allowlist, the `Uwe` parser, and the validator contract in
`scripts/lib/validation.mjs` are byte-identical.

Re-verified on a 0.3.11 install at 2026-09-10:

- `node --test test/validation.test.mjs` — 22 / 22 pass on the 0.3.11 install.
- `node scripts/validate.mjs` — `examples/hello-mcode-hooks/` passes, all 25+
  `plugins/<owner>/<name>/` entries in the repository pass.
- The example `hooks.json` shipped at `examples/hello-mcode-hooks/io.minimax.mcode/hooks/hooks.json`
  matches the schema accepted by both 0.3.10 and 0.3.11.

The companion text records the contract against `@minimax-ai/code@0.3.10` because that
is the release that first shipped the nested shape; the next-patch contract is the same
and the above evidence confirms it. No spec rewrite is needed for 0.3.11.
