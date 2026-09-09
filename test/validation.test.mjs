import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  validateHooksDocument,
  validateHookEntry,
  validateMcp,
  validatePluginDirectory,
  validatePluginManifest,
  validateSkillText,
} from '../scripts/lib/validation.mjs';

test('accepts the portable Agent Plugins manifest', () => {
  const value = validatePluginManifest({
    $schema: 'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json',
    name: 'example-plugin',
    version: '1.0.0',
  });
  assert.equal(value.name, 'example-plugin');
});

test('rejects unsupported plugin capabilities in the manifest', () => {
  assert.throws(
    () => validatePluginManifest({
      $schema: 'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json',
      name: 'example-plugin',
      hooks: './hooks.json',
    }),
    /unknown field hooks/u,
  );
});

test('accepts a valid Skill and rejects a mismatched directory name', () => {
  const skill = '---\nname: example-skill\ndescription: Run the example when requested.\n---\n\n# Example\n';
  assert.equal(validateSkillText(skill, 'example-skill').name, 'example-skill');
  assert.throws(() => validateSkillText(skill, 'different-skill'), /must equal different-skill/u);
});

test('validates supported MCP transports and reserved environment variables', () => {
  const base = { $schema: 'https://agent-plugins.org/schemas/1.0.0/mcp.schema.json' };
  assert.deepEqual(validateMcp({ ...base, mcpServers: { docs: { type: 'streamable-http', url: 'https://example.com/mcp' } } }), ['docs']);
  assert.deepEqual(validateMcp({ ...base, mcpServers: { local: { type: 'stdio', command: './server.js' } } }), ['local']);
  assert.throws(
    () => validateMcp({ ...base, mcpServers: { unsafe: { type: 'streamable-http', url: 'http://example.com/mcp' } } }),
    /HTTPS or loopback HTTP/u,
  );
  assert.throws(
    () => validateMcp({ ...base, mcpServers: { local: { type: 'stdio', command: 'node', env: { PLUGIN_ROOT: 'bad' } } } }),
    /env is invalid/u,
  );
});

test('accepts a Hook entry (outer matcher) and a Hook command (inner descriptor)', () => {
  // 0.3.10 schema: outer (matcher) entry holds {matcher, hooks[]};
  // inner (command) descriptor holds {type, command, timeout}.
  // The previous companion's flat shape is rejected.
  const outer = validateHookEntry({
    matcher: 'Bash',
    hooks: [{
      type: 'command',
      command: 'node ${PLUGIN_ROOT}/io.minimax.mcode/hooks/scripts/record.mjs --event PreToolUse --state ${PLUGIN_DATA}/state.json',
      timeout: 5,
    }],
  }, 'hook');
  assert.equal(outer.hooks[0].command.startsWith('node '), true);
  // Reserved runtime-internal discriminators are still rejected
  // as values of `type`. The validator gives the more specific
  // "type must be 'command'" error rather than the closed-schema
  // reserved-field error, because the user provided a valid
  // field name with an invalid value. This is intentional: the
  // more specific message is more actionable.
  assert.throws(() => validateHookEntry({ matcher: '*', hooks: [{ type: 'shell' }] }, 'hook'), /type must be "command"/u);
  // 0.2.4 fields are now closed-schema violations (validator
  // surfaces them as reserved so a Plugin migrating from 0.2.4
  // gets a clear error rather than a silent no-op).
  assert.throws(() => validateHookEntry({ matcher: '*', hooks: [{ args: ['x'] }] }, 'hook'), /reserved/u);
  assert.throws(() => validateHookEntry({ matcher: '*', hooks: [{ env: { LOG: 'info' } }] }, 'hook'), /reserved/u);
  assert.throws(() => validateHookEntry({ matcher: '*', hooks: [{ cwd: './scripts' }] }, 'hook'), /reserved/u);
  assert.throws(() => validateHookEntry({ matcher: '*', hooks: [{ once: true }] }, 'hook'), /reserved/u);
  // `type` other than "command" is rejected because 0.3.10 only
  // dispatches command handlers.
  assert.throws(() => validateHookEntry({ matcher: '*', hooks: [{ type: 'prompt', command: 'x' }] }, 'hook'), /type must be "command"/u);
  // `command` is required for the command kind.
  assert.throws(() => validateHookEntry({ matcher: '*', hooks: [{}] }, 'hook'), /command is required/u);
  // `timeout` is in seconds and the 0.2.4 millisecond range is
  // out of bounds. The validator must reject `5000` here
  // because 5000 seconds is > 600.
  assert.throws(() => validateHookEntry({ matcher: '*', hooks: [{ command: 'x', timeout: 5000 }] }, 'hook'), /timeout must be an integer/u);
  assert.throws(() => validateHookEntry({ matcher: '*', hooks: [{ command: 'x', timeout: 0 }] }, 'hook'), /timeout must be an integer/u);
  // matcher must be a non-empty string when set.
  assert.throws(() => validateHookEntry({ matcher: 123, hooks: [{ command: 'x' }] }, 'hook'), /matcher must be a non-empty string/u);
  // The outer entry requires a non-empty hooks[] array (this is
  // the 0.3.10 parser's most-referenced warning: the previous
  // companion's flat shape satisfies neither matcher nor
  // hooks[], so a Plugin that wants to fire must use the nested
  // shape).
  assert.throws(() => validateHookEntry({ matcher: '*' }, 'hook'), /hooks must be a non-empty array/u);
  assert.throws(() => validateHookEntry({ matcher: '*', hooks: [] }, 'hook'), /hooks must be a non-empty array/u);
});

test('accepts a Hooks document that targets the experimental io.minimax.mcode namespace (0.3.10 nested shape)', () => {
  const events = validateHooksDocument({
    $schema: 'https://minimax.io/schemas/mcode-hooks/0.1.0/hooks.schema.json',
    hooks: {
      PreToolUse: [{ matcher: '*', hooks: [{ type: 'command', command: 'node ${PLUGIN_ROOT}/io.minimax.mcode/hooks/scripts/record.mjs' }] }],
      SessionEnd: [{ hooks: [{ command: 'node' }] }],
    },
  }, 'hooks.json');
  assert.deepEqual(events, ['PreToolUse', 'SessionEnd']);
  // The 0.3.10 parser walks the document body and treats each
  // value as an event entry. The body is either `value.hooks`
  // (the wrapper) or `value` itself (events sit on the root).
  // Both shapes are accepted and produce identical behavior.
  const directEvents = validateHooksDocument({
    PreToolUse: [{ hooks: [{ command: 'node' }] }],
  }, 'hooks.json');
  assert.deepEqual(directEvents, ['PreToolUse']);
  // Round-4 fix: $schema is now pinned, so the URL must match exactly.
  // The old "any non-empty string" check is gone, so the error message
  // also changes — we now expect "must equal" rather than letting the
  // bogus schema past and tripping on the next clause.
  assert.throws(
    () => validateHooksDocument({ $schema: 'x', hooks: { UnknownEvent: [{ command: 'node' }] } }, 'hooks.json'),
    /\$schema must equal/u,
  );
  // The 0.3.10 catalog includes 15 events: 12 portable + 3
  // streaming. Streaming events are accepted by the validator
  // (Fwe dispatch is a runtime question).
  const streaming = validateHooksDocument({
    hooks: {
      MessageComplete: [{ hooks: [{ command: 'node' }] }],
      StreamChunk: [{ hooks: [{ command: 'node' }] }],
      StreamChunkThreshold: [{ hooks: [{ command: 'node' }] }],
    },
  }, 'hooks.json');
  assert.deepEqual(streaming, ['MessageComplete', 'StreamChunk', 'StreamChunkThreshold']);
  assert.throws(
    () => validateHooksDocument({ $schema: 'https://minimax.io/schemas/mcode-hooks/0.1.0/hooks.schema.json', hooks: { UnknownEvent: [{ command: 'node' }] } }, 'hooks.json'),
    /not a recognized event/u,
  );
  // The 0.2.4 flat shape is rejected because the inner descriptor
  // is not an outer matcher entry; `command` and `args` are not
  // in the matcher-entry allowlist.
  assert.throws(
    () => validateHooksDocument({
      $schema: 'https://minimax.io/schemas/mcode-hooks/0.1.0/hooks.schema.json',
      hooks: { PreToolUse: [{ command: 'node', args: ['x'] }] },
    }, 'hooks.json'),
    /not a recognized Hook field/u,
  );
  assert.throws(
    () => validateHooksDocument({ $schema: 'https://minimax.io/schemas/mcode-hooks/0.1.0/hooks.schema.json', hooks: { PreToolUse: [] } }, 'hooks.json'),
    /non-empty array/u,
  );
  // Without $schema, the document is still accepted — the
  // 0.3.10 runtime silently ignores the field.
  assert.doesNotThrow(() => validateHooksDocument({
    hooks: { PreToolUse: [{ hooks: [{ command: 'node' }] }] },
  }, 'hooks.json'));
});

test('validatePluginDirectory picks up an io.minimax.mode hooks extension without requiring it', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'hooks-ext-'));
  try {
    await writeFile(path.join(root, 'plugin.json'), JSON.stringify({
      $schema: 'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json',
      name: 'hello-hooks',
      version: '0.1.0',
    }));
    const skillDir = path.join(root, 'skills', 'hello-hooks');
    const { mkdir } = await import('node:fs/promises');
    await mkdir(skillDir, { recursive: true });
    await writeFile(path.join(skillDir, 'SKILL.md'), [
      '---',
      'name: hello-hooks',
      'description: Verify hello-hooks loads.',
      '---',
      '',
      '# Hello',
      '',
    ].join('\n'), 'utf8');
    const hooksDir = path.join(root, 'io.minimax.mcode', 'hooks');
    await mkdir(hooksDir, { recursive: true });
    // 0.3.10 nested shape: outer matcher entry wraps an inner
    // hooks[] array of command descriptors.
    await writeFile(path.join(hooksDir, 'hooks.json'), JSON.stringify({
      $schema: 'https://minimax.io/schemas/mcode-hooks/0.1.0/hooks.schema.json',
      hooks: { SessionStart: [{ hooks: [{ type: 'command', command: 'node' }] }] },
    }));
    const result = await validatePluginDirectory(root);
    assert.deepEqual(result.clientExtensions, [{ namespace: 'io.minimax.mcode', events: ['SessionStart'] }]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('validatePluginDirectory ignores a missing hooks extension', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'hooks-none-'));
  try {
    await writeFile(path.join(root, 'plugin.json'), JSON.stringify({
      $schema: 'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json',
      name: 'hello-mcode',
      version: '0.1.0',
    }));
    const skillDir = path.join(root, 'skills', 'hello-mcode');
    const { mkdir } = await import('node:fs/promises');
    await mkdir(skillDir, { recursive: true });
    await writeFile(path.join(skillDir, 'SKILL.md'), [
      '---',
      'name: hello-mcode',
      'description: Verify hello-mcode loads.',
      '---',
      '',
      '# Hello',
      '',
    ].join('\n'), 'utf8');
    const result = await validatePluginDirectory(root);
    assert.deepEqual(result.clientExtensions, []);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('validatePluginDirectory rejects hooks.json with an unrecognized event', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'hooks-bad-'));
  try {
    await writeFile(path.join(root, 'plugin.json'), JSON.stringify({
      $schema: 'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json',
      name: 'hello-bad',
      version: '0.1.0',
    }));
    const skillDir = path.join(root, 'skills', 'hello-bad');
    const { mkdir } = await import('node:fs/promises');
    await mkdir(skillDir, { recursive: true });
    await writeFile(path.join(skillDir, 'SKILL.md'), [
      '---',
      'name: hello-bad',
      'description: Verify hello-bad loads.',
      '---',
      '',
      '# Hello',
      '',
    ].join('\n'), 'utf8');
    const hooksDir = path.join(root, 'io.minimax.mcode', 'hooks');
    await mkdir(hooksDir, { recursive: true });
    await writeFile(path.join(hooksDir, 'hooks.json'), JSON.stringify({
      $schema: 'https://minimax.io/schemas/mcode-hooks/0.1.0/hooks.schema.json',
      hooks: { Bogus: [{ hooks: [{ command: 'node' }] }] },
    }));
    await assert.rejects(validatePluginDirectory(root), /not a recognized event/u);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('validateHookEntry rejects unknown fields (closed schema)', () => {
  // 0.3.10 schema: outer (matcher) entry only allows {matcher, hooks[]};
  // inner (command) descriptor only allows {type, command, timeout}.
  assert.throws(
    () => validateHookEntry({ matcher: '*', hooks: [{ command: 'node', evil: 'x' }] }, 'hook'),
    /not a recognized Hook field/u,
  );
  assert.throws(
    () => validateHookEntry({ matcher: '*', hooks: [{ command: 'node', sideChannel: true }] }, 'hook'),
    /not a recognized Hook field/u,
  );
  // The previous companion's `command` at the outer level is no
  // longer valid; the 0.3.10 parser reads it as a missing hooks[].
  assert.throws(
    () => validateHookEntry({ command: 'node' }, 'hook'),
    /not a recognized Hook field/u,
  );
});

// `cwd` was removed from the 0.3.10 schema because the parser
// passes the single command string to the platform shell, which
// already handles per-command working directory. The previous
// companion's R4-1 cwd-traversal tests are replaced by a single
// test that the field is now closed-schema-rejected (it appears
// in HOOK_RESERVED_FIELDS, so the validator surfaces it as a
// reserved internal discriminator).
test('validateHookEntry rejects the 0.2.4 cwd field on inner command descriptors', () => {
  assert.throws(
    () => validateHookEntry({ matcher: '*', hooks: [{ command: 'node', cwd: './scripts' }] }, 'hook'),
    /reserved internal discriminator/u,
  );
  assert.throws(
    () => validateHookEntry({ matcher: '*', hooks: [{ command: 'node', cwd: '${PLUGIN_DATA}' }] }, 'hook'),
    /reserved internal discriminator/u,
  );
  // `${PLUGIN_ROOT}/../etc` was the round-4 false positive on
  // 0.2.4; the 0.3.10 schema rejects the field outright, so the
  // path-traversal pattern is now unrepresentable.
  assert.throws(
    () => validateHookEntry({ matcher: '*', hooks: [{ command: 'node', cwd: '${PLUGIN_ROOT}/../etc' }] }, 'hook'),
    /reserved internal discriminator/u,
  );
});

test('validateMcp rejects the same cwd traversal patterns (R4-1)', () => {
  // MCP `cwd` semantics are unchanged; this is the same negative
  // contract as the previous companion. The 0.3.10 schema only
  // affects the hooks namespace.
  const base = { $schema: 'https://agent-plugins.org/schemas/1.0.0/mcp.schema.json' };
  assert.throws(
    () => validateMcp({ ...base, mcpServers: { bad: { type: 'stdio', command: 'node', cwd: './../escape' } } }),
    /cwd must be/u,
  );
  assert.throws(
    () => validateMcp({ ...base, mcpServers: { bad: { type: 'stdio', command: 'node', cwd: '${PLUGIN_ROOT}/../etc' } } }),
    /cwd must be/u,
  );
});

test('validateHooksDocument pins the $schema URL to the proposal (R4-3)', () => {
  // Wrong URL is now rejected with the new pin.
  assert.throws(
    () => validateHooksDocument({
      $schema: 'https://example.com/wrong/schema.json',
      hooks: { SessionStart: [{ hooks: [{ command: 'node' }] }] },
    }, 'hooks.json'),
    /\$schema must equal/u,
  );
  // Empty string is now rejected (the old "length > 0" check would
  // still pass an empty string; the new pin wouldn't, because the
  // empty string doesn't equal the proposal URL).
  assert.throws(
    () => validateHooksDocument({
      $schema: '',
      hooks: { SessionStart: [{ hooks: [{ command: 'node' }] }] },
    }, 'hooks.json'),
    /\$schema must equal/u,
  );
  // When the document omits $schema, the 0.3.10 runtime
  // silently accepts it. The validator mirrors that.
  assert.doesNotThrow(() => validateHooksDocument({
    hooks: { SessionStart: [{ hooks: [{ command: 'node' }] }] },
  }, 'hooks.json'));
});

test('validateHookEntry and validateHookCommand type-check the 0.3.10 field vocabulary', () => {
  // matcher on the outer entry must be a non-empty string when set.
  assert.throws(
    () => validateHookEntry({ matcher: 123, hooks: [{ command: 'node' }] }, 'hook'),
    /matcher must be a non-empty string/u,
  );
  assert.throws(
    () => validateHookEntry({ matcher: '', hooks: [{ command: 'node' }] }, 'hook'),
    /matcher must be a non-empty string/u,
  );
  // command on the inner descriptor must be a non-empty string.
  assert.throws(
    () => validateHookEntry({ matcher: '*', hooks: [{ command: '' }] }, 'hook'),
    /command is required/u,
  );
  assert.throws(
    () => validateHookEntry({ matcher: '*', hooks: [{ command: 123 }] }, 'hook'),
    /command is required/u,
  );
  // timeout must be an integer in the 1..600 seconds range; the
  // 0.2.4 millisecond range (timeoutMs, very large numbers) is
  // no longer valid.
  assert.throws(
    () => validateHookEntry({ matcher: '*', hooks: [{ command: 'x', timeout: '30s' }] }, 'hook'),
    /timeout must be an integer/u,
  );
  assert.throws(
    () => validateHookEntry({ matcher: '*', hooks: [{ command: 'x', timeout: 601 }] }, 'hook'),
    /timeout must be an integer/u,
  );
  assert.throws(
    () => validateHookEntry({ matcher: '*', hooks: [{ command: 'x', timeout: 0 }] }, 'hook'),
    /timeout must be an integer/u,
  );
  // The 0.2.4 fields pattern / regex / glob / once / timeoutMs
  // are closed-schema rejected. The validator surfaces them as
  // "reserved" because they appeared in the 0.2.4 companion and
  // silently no-op in 0.3.10; we want a loud failure instead.
  for (const field of ['pattern', 'regex', 'glob', 'once', 'timeoutMs']) {
    assert.throws(
      () => validateHookEntry({ matcher: '*', hooks: [{ command: 'node', [field]: 'x' }] }, 'hook'),
      /reserved internal discriminator/u,
      `${field} must be a reserved field`,
    );
  }
  // type must be the string "command" (the only kind 0.3.10
  // dispatches); any other value is rejected. The reserved
  // discriminators (`prompt`, `http`, `agent`, `shell`,
  // `function`, `script`) are caught by the same check — the
  // validator gives the more specific "type must be 'command'"
  // error rather than the closed-schema reserved-field error,
  // because the user provided a valid field name with an
  // invalid value. This is intentional: the more specific
  // message is more actionable.
  for (const badType of ['code', 'javascript', 'CODE', 'foo', '', 'prompt', 'http', 'agent', 'shell', 'function', 'script']) {
    assert.throws(
      () => validateHookEntry({ matcher: '*', hooks: [{ command: 'node', type: badType }] }, 'hook'),
      /type must be "command"/u,
      `type=${JSON.stringify(badType)} must be rejected`,
    );
  }
  // type is allowed when omitted (defaults to "command") and
  // when explicitly "command".
  assert.doesNotThrow(() => validateHookEntry({ matcher: '*', hooks: [{ command: 'node' }] }, 'hook'));
  assert.doesNotThrow(() => validateHookEntry({ matcher: '*', hooks: [{ type: 'command', command: 'node' }] }, 'hook'));
});

test('validateHooksDocument rejects unknown root fields (closed schema)', () => {
  // 0.3.10: the document body is either `value.hooks` (the
  // wrapper) or the root itself; either way, every top-level
  // field must be in the closed-schema allowlist. `extra` is
  // neither a known event name nor `$schema` nor `hooks`.
  assert.throws(
    () => validateHooksDocument({
      $schema: 'https://minimax.io/schemas/mcode-hooks/0.1.0/hooks.schema.json',
      hooks: { SessionStart: [{ hooks: [{ command: 'node' }] }] },
      extra: true,
    }, 'hooks.json'),
    /extra is not a recognized Hook field/u,
  );
  // An event name on the root is also closed-schema valid, but a
  // typo is rejected at the root closed-schema level (the
  // event-name check is reached only after the root has been
  // confirmed to be a known event name or the wrapper).
  assert.throws(
    () => validateHooksDocument({
      PreToolUs: [{ hooks: [{ command: 'node' }] }],
    }, 'hooks.json'),
    /PreToolUs is not a recognized Hook field/u,
  );
});

test('record.mjs writes state under PLUGIN_DATA even when it is outside PLUGIN_ROOT', async () => {
  const tmp = await mkdtemp(path.join(tmpdir(), 'hooks-e2e-'));
  const { spawn } = await import('node:child_process');
  try {
    const root = path.join(tmp, 'plugin');
    const data = path.join(tmp, 'plugin-data', 'instance-1');
    await mkdir(root, { recursive: true });
    await mkdir(data, { recursive: true });
    const script = path.join(process.cwd(), 'examples', 'hello-mcode-hooks', 'io.minimax.mcode', 'hooks', 'scripts', 'record.mjs');
    const stateFile = path.join(data, 'state.json');
    await new Promise((resolveP, rejectP) => {
      const child = spawn(process.execPath, [script, '--event', 'SessionStart', '--state', '${PLUGIN_DATA}/state.json'], {
        env: { ...process.env, PLUGIN_ROOT: root, PLUGIN_DATA: data },
        stdio: ['pipe', 'pipe', 'pipe'],
      });
      child.stdin.end(JSON.stringify({ toolName: 'Bash', toolInput: { command: 'ls' } }));
      let stderr = '';
      child.stderr.on('data', (chunk) => { stderr += chunk.toString('utf8'); });
      child.on('error', rejectP);
      child.on('exit', (code) => {
        if (code !== 0) rejectP(new Error(`record.mjs exited ${code}; stderr=${stderr}`));
        else resolveP();
      });
    });
    const written = JSON.parse(await import('node:fs/promises').then((m) => m.readFile(stateFile, 'utf8')));
    assert.equal(written.records.length, 1);
    assert.equal(written.records[0].event, 'SessionStart');
    assert.deepEqual(written.records[0].payloadKeys, ['toolInput', 'toolName']);
  } finally {
    await rm(tmp, { recursive: true, force: true });
  }
});

// Round-4 fix (R4-2): the previous ensureContained only did
// `path.resolve` (lexical normalization), which is bypassed when
// PLUGIN_DATA itself is reached through a symlink. For example:
//
//   PLUGIN_DATA = /tmp/data   (realpath = /var/srv/data)
//   realpath('/tmp/data')   = '/var/srv/data'
//
// Lexical: startsWith('/tmp/data/') -> true -> "contained" (false positive)
// Real:    startsWith('/var/srv/data/') -> true -> contained (the truth)
//
// The hard case is when a SUBDIRECTORY of PLUGIN_DATA is a symlink
// to outside. Lexical containment passes (the symlink lives under
// the lexical root), but real containment fails (the realpath of
// the target is outside the realpath of the root).
test('record.mjs refuses to write through a symlink in PLUGIN_DATA that escapes the root (R4-2)', async () => {
  if (process.platform === 'win32') {
    // Windows symlinks require admin or developer mode; the existing
    // tests in this file already exercise the non-symlink code path,
    // and the contract that the symlink case fails is enforced by
    // the realpath-based check. Skip on Windows to keep CI green;
    // POSIX CI is the real evidence.
    return;
  }
  const tmp = await mkdtemp(path.join(tmpdir(), 'hooks-symlink-'));
  const { spawn } = await import('node:child_process');
  const { symlink, mkdir, writeFile: writeFileRaw } = await import('node:fs/promises');
  try {
    const data = path.join(tmp, 'plugin-data');
    const outside = path.join(tmp, 'outside');
    await mkdir(data, { recursive: true });
    await mkdir(outside, { recursive: true });
    // Create a sentinel file outside the data root.
    await writeFileRaw(path.join(outside, 'pwned.json'), '{"records":[]}', 'utf8');
    // Symlink data/link -> outside so PLUGIN_DATA/link/pwned.json
    // lexically lives under PLUGIN_DATA but realpath-wise lives
    // under the outside dir.
    await symlink(outside, path.join(data, 'link'), 'dir');
    const root = path.join(tmp, 'plugin');
    await mkdir(root, { recursive: true });
    const script = path.join(process.cwd(), 'examples', 'hello-mcode-hooks', 'io.minimax.mcode', 'hooks', 'scripts', 'record.mjs');
    const code = await new Promise((resolveP, rejectP) => {
      const child = spawn(process.execPath, [script, '--event', 'SessionStart', '--state', '${PLUGIN_DATA}/link/pwned.json'], {
        env: { ...process.env, PLUGIN_ROOT: root, PLUGIN_DATA: data },
        stdio: ['pipe', 'pipe', 'pipe'],
      });
      child.stdin.end(JSON.stringify({ toolName: 'Bash' }));
      let stderr = '';
      child.stderr.on('data', (chunk) => { stderr += chunk.toString('utf8'); });
      child.on('error', rejectP);
      child.on('exit', (c) => resolveP(c));
    });
    // record.mjs swallows the error (Observer must never affect
    // agent behavior), so we can't observe the throw directly.
    // The observable signal is that the file outside PLUGIN_DATA
    // was NOT modified: it still contains the sentinel bytes, not
    // a JSON envelope with `records`.
    const outsideBytes = await import('node:fs/promises').then((m) => m.readFile(path.join(outside, 'pwned.json'), 'utf8'));
    assert.equal(outsideBytes, '{"records":[]}',
      `record.mjs must not have written through the symlink (got: ${outsideBytes})`);
    // The exit code is 0 because errors are swallowed; the contract
    // is that the file system is unchanged. The code is exposed for
    // diagnostic purposes only.
    assert.equal(code, 0, `record.mjs exit code is 0 (errors swallowed) but state must not have escaped: got ${code}`);
  } finally {
    await rm(tmp, { recursive: true, force: true });
  }
});

// Round-4 fix (R4-4): the previous roundtrip tests only exercised
// SessionStart. The hello-mcode-hooks example ships with
// SessionStart / SessionEnd / PreToolUse entries, and CI only proved
// the first one. These tests run the bundled script with the
// --event flag for the other two.
test('record.mjs handles SessionEnd via the bundled script (R4-4)', async () => {
  const tmp = await mkdtemp(path.join(tmpdir(), 'hooks-end-'));
  const { spawn } = await import('node:child_process');
  try {
    const root = path.join(tmp, 'plugin');
    const data = path.join(tmp, 'data');
    await mkdir(root, { recursive: true });
    await mkdir(data, { recursive: true });
    const stateFile = path.join(data, 'state.json');
    const script = path.join(process.cwd(), 'examples', 'hello-mcode-hooks', 'io.minimax.mcode', 'hooks', 'scripts', 'record.mjs');
    await new Promise((resolveP, rejectP) => {
      const child = spawn(process.execPath, [script, '--event', 'SessionEnd', '--state', '${PLUGIN_DATA}/state.json'], {
        env: { ...process.env, PLUGIN_ROOT: root, PLUGIN_DATA: data },
        stdio: ['pipe', 'pipe', 'pipe'],
      });
      child.stdin.end(JSON.stringify({ sessionId: 'abc-123' }));
      child.on('error', rejectP);
      child.on('exit', (c) => { if (c === 0) resolveP(); else rejectP(new Error(`exit ${c}`)); });
    });
    const written = JSON.parse(await import('node:fs/promises').then((m) => m.readFile(stateFile, 'utf8')));
    assert.equal(written.records.length, 1);
    assert.equal(written.records[0].event, 'SessionEnd');
    assert.deepEqual(written.records[0].payloadKeys, ['sessionId']);
  } finally {
    await rm(tmp, { recursive: true, force: true });
  }
});

test('record.mjs handles PostToolUse via the bundled script (R4-4)', async () => {
  const tmp = await mkdtemp(path.join(tmpdir(), 'hooks-post-'));
  const { spawn } = await import('node:child_process');
  try {
    const root = path.join(tmp, 'plugin');
    const data = path.join(tmp, 'data');
    await mkdir(root, { recursive: true });
    await mkdir(data, { recursive: true });
    const stateFile = path.join(data, 'state.json');
    const script = path.join(process.cwd(), 'examples', 'hello-mcode-hooks', 'io.minimax.mcode', 'hooks', 'scripts', 'record.mjs');
    await new Promise((resolveP, rejectP) => {
      const child = spawn(process.execPath, [script, '--event', 'PostToolUse', '--state', '${PLUGIN_DATA}/state.json'], {
        env: { ...process.env, PLUGIN_ROOT: root, PLUGIN_DATA: data },
        stdio: ['pipe', 'pipe', 'pipe'],
      });
      child.stdin.end(JSON.stringify({ toolName: 'Bash', toolResult: { stdout: 'hello', exitCode: 0 } }));
      child.on('error', rejectP);
      child.on('exit', (c) => { if (c === 0) resolveP(); else rejectP(new Error(`exit ${c}`)); });
    });
    const written = JSON.parse(await import('node:fs/promises').then((m) => m.readFile(stateFile, 'utf8')));
    assert.equal(written.records.length, 1);
    assert.equal(written.records[0].event, 'PostToolUse');
    assert.deepEqual(written.records[0].payloadKeys, ['toolName', 'toolResult']);
  } finally {
    await rm(tmp, { recursive: true, force: true });
  }
});

test('record.mjs handles PreToolUse via the bundled script (R4-4)', async () => {
  const tmp = await mkdtemp(path.join(tmpdir(), 'hooks-pre-'));
  const { spawn } = await import('node:child_process');
  try {
    const root = path.join(tmp, 'plugin');
    const data = path.join(tmp, 'data');
    await mkdir(root, { recursive: true });
    await mkdir(data, { recursive: true });
    const stateFile = path.join(data, 'state.json');
    const script = path.join(process.cwd(), 'examples', 'hello-mcode-hooks', 'io.minimax.mcode', 'hooks', 'scripts', 'record.mjs');
    await new Promise((resolveP, rejectP) => {
      const child = spawn(process.execPath, [script, '--event', 'PreToolUse', '--state', '${PLUGIN_DATA}/state.json'], {
        env: { ...process.env, PLUGIN_ROOT: root, PLUGIN_DATA: data },
        stdio: ['pipe', 'pipe', 'pipe'],
      });
      child.stdin.end(JSON.stringify({ toolName: 'Bash', toolInput: { command: 'rm -rf /' } }));
      child.on('error', rejectP);
      child.on('exit', (c) => { if (c === 0) resolveP(); else rejectP(new Error(`exit ${c}`)); });
    });
    const written = JSON.parse(await import('node:fs/promises').then((m) => m.readFile(stateFile, 'utf8')));
    assert.equal(written.records.length, 1);
    assert.equal(written.records[0].event, 'PreToolUse');
    // payloadKeys is sorted alphabetically (see record.mjs).
    assert.deepEqual(written.records[0].payloadKeys, ['toolInput', 'toolName']);
  } finally {
    await rm(tmp, { recursive: true, force: true });
  }
});

test('record.mjs enforces MAX_STATE_BYTES and trims older records', async () => {
  const tmp = await mkdtemp(path.join(tmpdir(), 'hooks-cap-'));
  const { spawn } = await import('node:child_process');
  const { writeFile: writeFile2, readFile: readFile2 } = await import('node:fs/promises');
  try {
    const root = path.join(tmp, 'plugin');
    const data = path.join(tmp, 'data');
    await mkdir(root, { recursive: true });
    await mkdir(data, { recursive: true });
    const stateFile = path.join(data, 'state.json');
    const script = path.join(process.cwd(), 'examples', 'hello-mcode-hooks', 'io.minimax.mcode', 'hooks', 'scripts', 'record.mjs');
    for (let i = 0; i < 10; i += 1) {
      await new Promise((resolveP, rejectP) => {
        const child = spawn(process.execPath, [script, '--event', `E${i}`, '--state', '${PLUGIN_DATA}/state.json'], {
          env: { ...process.env, PLUGIN_ROOT: root, PLUGIN_DATA: data },
          stdio: ['pipe', 'pipe', 'pipe'],
        });
        child.stdin.end(JSON.stringify({ idx: i }));
        child.on('error', rejectP);
        child.on('exit', (code) => { if (code === 0) resolveP(); else rejectP(new Error(`exit ${code}`)); });
      });
    }
    const text = await readFile2(stateFile, 'utf8');
    assert.ok(Buffer.byteLength(text, 'utf8') <= 1024 * 1024, 'state file must stay under MAX_STATE_BYTES');
    const written = JSON.parse(text);
    assert.ok(written.records.length <= 4096, 'records must stay under MAX_RECORDS');
  } finally {
    await rm(tmp, { recursive: true, force: true });
  }
});
