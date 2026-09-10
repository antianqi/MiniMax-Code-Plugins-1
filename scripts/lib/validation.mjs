import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';

export const PLUGIN_SCHEMA = 'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json';
export const MCP_SCHEMA = 'https://agent-plugins.org/schemas/1.0.0/mcp.schema.json';
// Pinned by the proposal at proposals/hooks-detailed-spec.md. The
// round-4 review pointed out that the previous check accepted ANY
// non-empty string, which meant a plugin could claim a different
// schema than the proposal. Locking the URL means the validator
// can now reject drafts that don't match the published spec.
//
// This contract is the same on @minimax-ai/code@0.3.10 (the
// release that first shipped the nested shape) and on
// @minimax-ai/code@0.3.11 (the current latest; 0.3.11 only
// changes a 401-token retry fix; the hook schema, the Ava
// dispatch wrapper, the Fwe allowlist, and the Uwe parser are
// byte-identical). Re-verified on a 0.3.11 install at 2026-09-10.
export const HOOK_SCHEMA = 'https://minimax.io/schemas/mcode-hooks/0.1.0/hooks.schema.json';

const PLUGIN_NAME = /^(?!.*(?:--|\.\.))[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/u;
const OWNER_NAME = /^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$/u;
const SKILL_NAME = /^(?!.*--)[a-z0-9]+(?:-[a-z0-9]+)*$/u;
const PLUGIN_FIELDS = new Set([
  '$schema',
  'name',
  'version',
  'description',
  'author',
  'homepage',
  'repository',
  'license',
  'keywords',
  'extensions',
]);

export function assert(condition, message) {
  if (!condition) throw new Error(message);
}

export function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

export function parseJson(text, label) {
  assert(!text.startsWith('\uFEFF'), `${label}: UTF-8 BOM is not allowed`);
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`${label}: invalid JSON: ${error.message}`);
  }
}

export function validatePluginManifest(value, label = 'plugin.json') {
  assert(isRecord(value), `${label}: root must be an object`);
  assert(value.$schema === PLUGIN_SCHEMA, `${label}: unsupported $schema`);
  assert(typeof value.name === 'string' && value.name.length <= 64 && PLUGIN_NAME.test(value.name), `${label}: invalid name`);
  for (const key of Object.keys(value)) {
    assert(PLUGIN_FIELDS.has(key), `${label}: unknown field ${key}`);
  }
  for (const key of ['version', 'description', 'homepage', 'repository', 'license']) {
    assert(value[key] === undefined || typeof value[key] === 'string', `${label}: ${key} must be a string`);
  }
  if (value.author !== undefined) {
    assert(isRecord(value.author), `${label}: author must be an object`);
    for (const key of Object.keys(value.author)) {
      assert(['name', 'email', 'url'].includes(key), `${label}: unknown author field ${key}`);
      assert(typeof value.author[key] === 'string', `${label}: author.${key} must be a string`);
    }
  }
  if (value.keywords !== undefined) {
    assert(Array.isArray(value.keywords) && value.keywords.every((item) => typeof item === 'string'), `${label}: keywords must be strings`);
  }
  assert(value.extensions === undefined || isRecord(value.extensions), `${label}: extensions must be an object`);
  return value;
}

export function validateSkillText(text, expectedName, label = 'SKILL.md') {
  assert(text.startsWith('---\n'), `${label}: YAML frontmatter is required`);
  const end = text.indexOf('\n---\n', 4);
  assert(end > 4, `${label}: YAML frontmatter is not closed`);
  const frontmatter = text.slice(4, end);
  const name = frontmatter.match(/^name:\s*([^\n]+)$/mu)?.[1]?.trim();
  const description = frontmatter.match(/^description:\s*([^\n]+)$/mu)?.[1]?.trim();
  assert(name === expectedName, `${label}: frontmatter name must equal ${expectedName}`);
  assert(SKILL_NAME.test(name) && name.length <= 64, `${label}: invalid Skill name`);
  assert(Boolean(description) && description.length <= 1024, `${label}: description is required and must be at most 1024 characters`);
  assert(text.slice(end + 5).trim().length > 0, `${label}: instructions are required`);
  return { name, description };
}

export function validateMcp(value, label = 'mcp.json') {
  assert(isRecord(value), `${label}: root must be an object`);
  assert(value.$schema === MCP_SCHEMA, `${label}: unsupported $schema`);
  assert(Object.keys(value).every((key) => ['$schema', 'mcpServers'].includes(key)), `${label}: unknown root field`);
  assert(isRecord(value.mcpServers), `${label}: mcpServers must be an object`);
  const entries = Object.entries(value.mcpServers);
  assert(entries.length <= 8, `${label}: MiniMax Code supports at most 8 MCP servers per plugin`);
  for (const [name, server] of entries) {
    assert(PLUGIN_NAME.test(name), `${label}: invalid MCP server name ${name}`);
    assert(isRecord(server), `${label}: MCP server ${name} must be an object`);
    if (server.type === 'stdio') {
      assert(typeof server.command === 'string' && server.command.length > 0 && (isBareCommand(server.command) || isContainedRelativePath(server.command)), `${label}: ${name} needs a bare executable or contained ./ path`);
      assert(server.args === undefined || (Array.isArray(server.args) && server.args.every((item) => typeof item === 'string')), `${label}: ${name}.args must be strings`);
      assert(server.env === undefined || (isRecord(server.env) && Object.entries(server.env).every(([key, item]) => !['PLUGIN_ROOT', 'PLUGIN_DATA'].includes(key) && typeof item === 'string')), `${label}: ${name}.env is invalid`);
      assert(
        server.cwd === undefined
          || (typeof server.cwd === 'string'
            && (isContainedRelativePath(server.cwd) || isContainedPluginPath(server.cwd))),
        `${label}: ${name}.cwd must be a contained ./ path (no '..', no '\\') or a path under \${PLUGIN_ROOT} or \${PLUGIN_DATA} (no '..', no '\\', no leading '/')`,
      );
      assert(Object.keys(server).every((key) => ['type', 'command', 'args', 'env', 'cwd'].includes(key)), `${label}: ${name} has unsupported fields`);
    } else if (server.type === 'streamable-http' || server.type === 'sse') {
      assert(typeof server.url === 'string' && isSafeRemoteUrl(server.url), `${label}: ${name}.url must be HTTPS or loopback HTTP without credentials or fragment`);
      assert(server.headers === undefined || (isRecord(server.headers) && Object.values(server.headers).every((item) => typeof item === 'string')), `${label}: ${name}.headers must contain strings`);
      assert(Object.keys(server).every((key) => ['type', 'url', 'headers'].includes(key)), `${label}: ${name} has unsupported fields`);
    } else {
      throw new Error(`${label}: ${name} uses unsupported transport ${String(server.type)}`);
    }
  }
  return entries.map(([name]) => name).sort();
}

function isBareCommand(value) {
  return !/[\\/]/u.test(value);
}

function isContainedRelativePath(value) {
  // ./foo/bar: every segment must be a non-empty name, no '..' anywhere,
  // no backslashes (which would be a Windows-only escape hatch).
  if (!value.startsWith('./') || value.includes('\\')) return false;
  const parts = value.split('/');
  // The first part is '.' (we just checked that), so we walk the rest.
  for (let i = 1; i < parts.length; i += 1) {
    if (parts[i] === '' || parts[i] === '..') return false;
  }
  return true;
}

// ${PLUGIN_ROOT}/foo/bar and ${PLUGIN_DATA}/foo/bar: the literal
// segment between '${...}' and the first '/' (or end-of-string) must
// not be '.' or '..' and must not contain a backslash. Same for every
// subsequent segment. This was the round-4 finding: the previous regex
// only checked the prefix, so '${PLUGIN_ROOT}/../../outside' passed.
function isContainedPluginPath(value) {
  const m = /^\$\{(PLUGIN_ROOT|PLUGIN_DATA)\}(?:\/(.*))?$/u.exec(value);
  if (!m) return false;
  if (m[2] === undefined) return true; // '${PLUGIN_ROOT}' alone is the root
  if (m[2].includes('\\')) return false;
  for (const seg of m[2].split('/')) {
    if (seg === '' || seg === '.' || seg === '..') return false;
  }
  return true;
}

function isSafeRemoteUrl(value) {
  try {
    const url = new URL(value);
    if (url.username || url.password || url.hash) return false;
    if (url.protocol === 'https:') return true;
    if (url.protocol !== 'http:') return false;
    const host = url.hostname.replace(/^\[|\]$/gu, '').toLowerCase();
    return host === 'localhost' || host === '::1' || /^127(?:\.\d{1,3}){3}$/u.test(host);
  } catch {
    return false;
  }
}

export const CLIENT_EXTENSION_NAMESPACES = Object.freeze(['io.minimax.mcode']);
// The 0.3.10 PascalCase event catalog: 12 portable events (the
// 0.2.4 catalog preserved) plus 3 0.3.10 runtime-internal streaming
// events (MessageComplete / StreamChunk / StreamChunkThreshold).
// The `Fwe` allowlist is a runtime-side question (see the spec
// table); the validator accepts every event in the catalog so a
// Plugin can target events that are `forward` today.
const KNOWN_HOOK_EVENTS = new Set([
  'PreToolUse',
  'PostToolUse',
  'SessionStart',
  'SessionEnd',
  'Stop',
  'UserPromptSubmit',
  'PreCompact',
  'Notification',
  'SubagentStart',
  'SubagentStop',
  'PermissionRequest',
  'PermissionDenied',
  'MessageComplete',
  'StreamChunk',
  'StreamChunkThreshold',
]);
// The closed-schema allowlist for the document root. The 0.3.10
// parser accepts either the `{"hooks": {...}}` wrapper or events
// directly on the root, so we allow both. The optional `$schema`
// is silently ignored by the runtime but kept here for
// forward-contract use; it must match the proposal URL if present.
const HOOK_DOCUMENT_FIELDS = new Set([
  '$schema',
  'hooks',
  ...KNOWN_HOOK_EVENTS,
]);
// The closed-schema allowlist for an outer (matcher) entry. The
// 0.3.10 parser walks each matcher entry and requires a
// non-empty `hooks[]` array; `matcher` is optional.
const HOOK_MATCHER_FIELDS = new Set(['matcher', 'hooks']);
// The closed-schema allowlist for an inner (command) descriptor.
// The 0.3.10 parser only consumes `type` / `command` / `timeout`
// from the inner entry; everything else is dropped on the floor.
// We reject the previous companion's fields here so a Plugin
// migrating from 0.2.4 to 0.3.10 gets a clear error rather than
// a silent no-op.
const HOOK_COMMAND_FIELDS = new Set(['type', 'command', 'timeout']);
// Field names the 0.3.10 parser does not consume (either
// runtime-internal discriminators or 0.2.4-only fields). The
// validator surfaces these as a closed-schema violation when they
// appear in a hook entry, with a message that points at the
// spec field-vocabulary table. `type` is intentionally NOT in
// this set: it is a regular field on the inner command
// descriptor (see HOOK_COMMAND_FIELDS) whose value is checked
// separately.
const HOOK_RESERVED_FIELDS = new Set([
  'shell',
  'prompt',
  'http',
  'agent',
  'script',
  'function',
  'args',
  'env',
  'cwd',
  'pattern',
  'regex',
  'glob',
  'once',
  'timeoutMs',
]);
// `timeout` is in seconds in the 0.3.10 schema (the parser
// multiplies by 1000 internally). 1s..600s covers the
// "tool-call lifetime" floor through the "compaction pass" ceiling
// with margin.
const HOOK_TIMEOUT_DEFAULT = 30;
const HOOK_TIMEOUT_MIN = 1;
const HOOK_TIMEOUT_MAX = 600;

function rejectUnknownFields(record, allowed, label) {
  for (const key of Object.keys(record)) {
    if (HOOK_RESERVED_FIELDS.has(key)) {
      throw new Error(`${label}: ${key} is a reserved internal discriminator and is not allowed in a portable Hook entry`);
    }
    if (!allowed.has(key)) {
      throw new Error(`${label}: ${key} is not a recognized Hook field; expected one of ${[...allowed].sort().join(', ')}`);
    }
  }
}

// Validate an inner (command) descriptor. The 0.3.10 parser
// requires `command` when `type === "command"` (the only type
// the parser dispatches today); `matcher` lives on the outer
// entry, not here.
export function validateHookCommand(value, label) {
  assert(isRecord(value), `${label}: hook command must be an object`);
  rejectUnknownFields(value, HOOK_COMMAND_FIELDS, label);
  const type = value.type === undefined ? 'command' : value.type;
  assert(type === 'command', `${label}: type must be "command" in @minimax-ai/code@0.3.10 (the only dispatched handler kind); got ${JSON.stringify(type)}`);
  assert(typeof value.command === 'string' && value.command.length > 0, `${label}: command is required and must be a non-empty string`);
  if (value.timeout !== undefined) {
    assert(Number.isInteger(value.timeout) && value.timeout >= HOOK_TIMEOUT_MIN && value.timeout <= HOOK_TIMEOUT_MAX, `${label}: timeout must be an integer between ${HOOK_TIMEOUT_MIN} and ${HOOK_TIMEOUT_MAX} seconds (the 0.3.10 parser multiplies by 1000)`);
  }
  return { ...value, type, command: value.command, timeout: value.timeout === undefined ? HOOK_TIMEOUT_DEFAULT : value.timeout };
}

// Validate an outer (matcher) entry. The 0.3.10 parser requires
// `hooks[]`; `matcher` is optional. This is the structural shape
// that 0.2.4 flat entries did not satisfy.
export function validateHookEntry(value, label) {
  assert(isRecord(value), `${label}: hook entry must be an object`);
  rejectUnknownFields(value, HOOK_MATCHER_FIELDS, label);
  if (value.matcher !== undefined) {
    assert(typeof value.matcher === 'string' && value.matcher.length > 0, `${label}: matcher must be a non-empty string`);
  }
  assert(Array.isArray(value.hooks) && value.hooks.length > 0, `${label}: hooks must be a non-empty array of command descriptors`);
  for (let i = 0; i < value.hooks.length; i += 1) {
    validateHookCommand(value.hooks[i], `${label}: hooks[${i}]`);
  }
  return value;
}

// Validate the full hooks document. The 0.3.10 parser walks
// `Object.entries` over the body and treats each value as an event
// entry. The body is either `value.hooks` (the wrapper) or
// `value` itself (events sit on the root). Both shapes are
// accepted and produce identical behavior.
export function validateHooksDocument(value, label) {
  assert(isRecord(value), `${label}: root must be an object`);
  rejectUnknownFields(value, HOOK_DOCUMENT_FIELDS, label);
  // The 0.3.10 runtime silently ignores `$schema`; the validator
  // accepts it for forward contract but does not require it. When
  // present, it must match the proposal URL exactly so a Plugin
  // cannot claim a draft matches `0.1.0` just because the field
  // is non-empty.
  if (value.$schema !== undefined) {
    assert(value.$schema === HOOK_SCHEMA, `${label}: $schema must equal ${HOOK_SCHEMA} when set`);
  }
  const body = 'hooks' in value ? value.hooks : value;
  assert(isRecord(body), `${label}: hooks body must be an object (either the 'hooks' wrapper or the document root)`);
  const events = [];
  for (const [eventName, entries] of Object.entries(body)) {
    assert(KNOWN_HOOK_EVENTS.has(eventName), `${label}: ${eventName} is not a recognized event; expected one of ${[...KNOWN_HOOK_EVENTS].sort().join(', ')}`);
    assert(Array.isArray(entries) && entries.length > 0, `${label}: ${eventName} must be a non-empty array of matcher entries`);
    for (let i = 0; i < entries.length; i += 1) {
      validateHookEntry(entries[i], `${label}: ${eventName}[${i}]`);
    }
    events.push(eventName);
  }
  assert(events.length > 0, `${label}: at least one event entry is required`);
  return events.sort();
}

export async function validateClientExtensions(root) {
  const found = [];
  for (const namespace of CLIENT_EXTENSION_NAMESPACES) {
    const hooksPath = path.join(root, namespace, 'hooks', 'hooks.json');
    let text;
    try {
      text = await readFile(hooksPath, 'utf8');
    } catch (error) {
      if (error.code === 'ENOENT') continue;
      throw error;
    }
    const events = validateHooksDocument(parseJson(text, hooksPath), hooksPath);
    found.push({ namespace, events });
  }
  return found;
}

export async function validatePluginDirectory(root) {
  const manifestPath = path.join(root, 'plugin.json');
  const manifest = validatePluginManifest(parseJson(await readFile(manifestPath, 'utf8'), manifestPath), manifestPath);
  const skills = [];
  const skillsRoot = path.join(root, 'skills');
  let children = [];
  try {
    children = await readdir(skillsRoot, { withFileTypes: true });
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  assert(children.filter((item) => item.isDirectory()).length <= 64, `${skillsRoot}: MiniMax Code supports at most 64 Skills per plugin`);
  for (const child of children.filter((item) => item.isDirectory()).sort((a, b) => a.name.localeCompare(b.name))) {
    const skillPath = path.join(skillsRoot, child.name, 'SKILL.md');
    validateSkillText(await readFile(skillPath, 'utf8'), child.name, skillPath);
    skills.push(child.name);
  }
  let mcpServers = [];
  const mcpPath = path.join(root, 'mcp.json');
  try {
    mcpServers = validateMcp(parseJson(await readFile(mcpPath, 'utf8'), mcpPath), mcpPath);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  const clientExtensions = await validateClientExtensions(root);
  assert(skills.length + mcpServers.length > 0, `${root}: plugin must expose at least one Skill or MCP server`);
  return { manifest, skills: skills.sort(), mcpServers, clientExtensions };
}

export async function validateHostedPluginDirectory(root, { owner, pluginName }) {
  assert(OWNER_NAME.test(owner), `${root}: invalid GitHub owner directory ${owner}`);
  assert(PLUGIN_NAME.test(pluginName) && pluginName.length <= 64, `${root}: invalid Plugin directory ${pluginName}`);
  await assertNoSymlinks(root);
  const result = await validatePluginDirectory(root);
  assert(result.manifest.name === pluginName, `${root}: plugin.json name must equal directory name ${pluginName}`);
  assert(typeof result.manifest.license === 'string' && result.manifest.license.length > 0, `${root}: plugin.json must declare a license`);
  for (const file of ['README.md', 'LICENSE']) {
    const contents = await readFile(path.join(root, file), 'utf8');
    assert(contents.trim().length > 0, `${root}: ${file} must not be empty`);
  }
  for (const file of await listTextContractFiles(root)) {
    const contents = await readFile(file, 'utf8');
    assert(!/\bTODO\b/u.test(contents), `${file}: replace every TODO before submission`);
  }
  return { id: `${owner}/${pluginName}`, ...result };
}

async function assertNoSymlinks(root) {
  for (const child of await readdir(root, { withFileTypes: true })) {
    const file = path.join(root, child.name);
    assert(!child.isSymbolicLink(), `${file}: symlinks are not allowed in hosted Plugins`);
    if (child.isDirectory()) await assertNoSymlinks(file);
  }
}

async function listTextContractFiles(root) {
  const files = [];
  for (const child of await readdir(root, { withFileTypes: true })) {
    const file = path.join(root, child.name);
    if (child.isDirectory()) files.push(...await listTextContractFiles(file));
    else if (child.isFile() && (child.name.endsWith('.md') || ['plugin.json', 'mcp.json'].includes(child.name))) files.push(file);
  }
  return files;
}
