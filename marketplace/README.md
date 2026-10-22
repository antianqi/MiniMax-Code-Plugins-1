# Marketplace packages

Submission packages for the MiniMax Plugin Marketplace live here, one directory per plugin.

Each package directory is a self-contained [MiniMax Plugin V1](https://open.feishu.cn/) package:

```
marketplace/<plugin-name>/
├── .minimax-plugin/plugin.json    # package entry point (MiniMax Plugin V1 manifest)
├── icon.png                       # 512x512 square icon
├── skills/<skill-name>/SKILL.md
└── ...                            # files referenced by the skill
```

The directory name must equal the `name` field in `.minimax-plugin/plugin.json`, and the package
must contain at least one capability (App / MCP / Skill). Capabilities that are not included stay
as empty arrays in the manifest.

## Why a package lives next to the hosted plugin

`plugins/<owner>/<plugin>` is the repository-side plugin, published in the agent-plugins.org
format. The Marketplace accepts a different package format, so the two cannot be the same tree:

- the Marketplace entry point is `.minimax-plugin/plugin.json`, not `plugin.json`;
- the Marketplace does not accept Hooks, so the `io.minimax.mcode/` client extension and the
  `hooks` block of the Claude-format manifest stay out of the package;
- Marketplace packages are UTF-8 **without** a BOM, and Windows PowerShell 5.1 parses a BOM-less
  `.ps1` with the ANSI code page. The package therefore ships ASCII-only scripts, with the
  Chinese UI expressed through the upstream plugin and the Chinese documentation in
  `README.zh-CN.md` and `skills/<skill-name>/SKILL.md`;
- a package must not read a credential or call an API. Anything that needs the user's identity
  goes through App/Connector integration, so the 5h-usage module and the token helper are not
  part of the package;
- a package is Windows-only, and every script says so and checks it.

## Rebuilding a package

```powershell
pwsh -File marketplace/build-marketplace-package.ps1            # rebuild
pwsh -File marketplace/build-marketplace-package.ps1 -Check     # verify it is in sync
```

The builder copies the runtime files out of the hosted plugin, applies the encoding
transformations, decodes the obfuscated literals into plain strings, injects the Windows-only
guard, generates `icon.png`, and then verifies the result. It fails the build when:

- the output directory holds a file the builder does not produce (stale output);
- a `.ps1` does not parse;
- a file carries a UTF-8 BOM or a non-ASCII byte;
- a script misses the Windows-only guard;
- the package would contain a credential, an API endpoint, an outbound call, a Hook token, an
  obfuscated literal or a dependency on the MiniMax Code CLI.

`-Check` rebuilds into memory and reports the files that drifted, which is what CI should run.

The hand-written parts of a package — `.minimax-plugin/plugin.json`,
`skills/<skill-name>/SKILL.md`, `README.md` and `README.zh-CN.md` — are **not** generated. Edit
them directly; the builder only owns the runtime files and the icon.

## Auditing a package

```powershell
pwsh -File marketplace/audit-marketplace-package.ps1 -PackageDir marketplace/mcode-island
```

The audit checks the package against the submission rules: entry point and manifest schema,
directory name equals the manifest name, icon is a square PNG, Skill frontmatter is complete,
every text file is UTF-8 without a BOM, every script is ASCII-only and parses, every script
carries the Windows guard, no Hook material, no credential, no API endpoint, no obfuscated
literal, no hardcoded host path, no symlink, no LFS pointer, and the file count / size /
path-depth limits. It exits non-zero on the first violation, so it can run as a CI step.

## Submitting

The package is submitted through the
[Plugin submission form](https://vrfi1sk8a0.feishu.cn/share/base/form/shrcnbnpeor3z72fUkeHzrOE7vb)
as a GitHub source: point the repository URL at this repository, the ref at the branch or tag that
holds the package, and the subdirectory at `marketplace/<plugin-name>`. The guide is the
[MiniMax Plugin 开发与上架指南](https://vrfi1sk8a0.feishu.cn/wiki/QlTLwbAGNiACwLkWI85cFxHzn4L).
