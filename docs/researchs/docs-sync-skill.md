# Research: the `docs-sync` skill (docs regeneration + OpenSpec sync)

Date: 2026-08-12. Repo: `/home/nrechdan/projects/w2-server`. All paths are absolute unless prefixed by the repo root.

## Question / scope

Design a Claude Code skill named `docs-sync` that:

1. **Owns** `README.md` (root) and `CLAUDE.md` (root, does not exist yet) — it regenerates them.
2. **Invokes** the existing `openspec-sync-specs` skill (`/opsx:sync`).
3. Splits language: generated `README.md` is human-first **pt-BR, ELI5**; `CLAUDE.md`, the `SKILL.md` itself, its frontmatter and all agent-facing text are **en-EN**.

The research question is the **run order** (sync-then-docs vs docs-then-sync), the frontmatter and structure the repo's own conventions mandate, and any collision over ownership of `CLAUDE.md`.

## Verdict up front

**Sync first, then regenerate the docs.**

`openspec/specs/` is the state-of-the-world tree and `openspec/changes/*/specs/` are pending deltas that have not landed in it yet; regenerating docs before the sync reads a specs tree that does not contain the change you just applied, so the docs are stale the moment sync runs.

Two secondary reasons make the order strictly better rather than merely equal:

- **Fail fast.** Sync is agent-driven and has hard stop conditions — a non-zero or invalid `openspec instructions specs` response, a blocked capability retirement, a failing `openspec validate --specs` (`.claude/skills/openspec-sync-specs/SKILL.md:77-86`, `:114-131`, `:154-156`). Running it first means a failure aborts before `README.md`/`CLAUDE.md` are touched. Running it last means a failed sync leaves two rewritten doc files describing a state that never materialised.
- **Idempotence.** Sync is declared idempotent (`.claude/skills/openspec-sync-specs/SKILL.md:257`). Docs-then-sync would require a second `docs-sync` run to converge; sync-then-docs converges in one.

Ordering precedent in this repo: `openspec-archive-change` runs sync **before** the archive move, and states the failure mode of the other order explicitly — `.claude/skills/openspec-archive-change/SKILL.md:176`: "Never archive while a spec sync is still in flight — run the sync inline and verify the main specs before moving `changeRoot`."

---

## 1. Claude Code Agent Skills

### 1.1 Frontmatter schema

Two authorities, and they differ. Cite the right one for the right claim.

**Agent Skills open standard** (<https://agentskills.io/specification>) — the portable subset:

| Field | Required | Constraint |
| --- | --- | --- |
| `name` | Yes | 1–64 chars; lowercase `a-z`, `0-9`, hyphens only; no leading/trailing hyphen; no consecutive hyphens; **must match the parent directory name** |
| `description` | Yes | 1–1024 chars, non-empty |
| `license` | No | license name or bundled file reference |
| `compatibility` | No | max 500 chars |
| `metadata` | No | string→string map |
| `allowed-tools` | No | space-separated string; marked **Experimental** |

**Claude Code** (<https://code.claude.com/docs/en/skills>) accepts all six plus its own extensions, and relaxes the standard's rules:

- "All fields are optional. Only `description` is recommended so Claude knows when to use the skill."
- `name`: "Display name shown in skill listings. Defaults to the directory name." In a **personal or project skill, `name` sets only the display label — the command still comes from the directory or file name.** Only in a *plugin* skill does `name` set the command segment.
- `description`: "the combined `description` and `when_to_use` text is truncated at **1,536 characters** in the skill listing." (Note: this is Claude Code's listing cap, not the standard's 1024-char field cap. Stay under 1024 to remain spec-valid.)
- Claude Code extensions relevant here: `disable-model-invocation`, `user-invocable`, `disallowed-tools`, `model`, `effort`, `context: fork`, `agent`, `background`, `hooks`, `paths`, `arguments`, `argument-hint`, `shell`.
- Extensions break portability: uploading to claude.ai / the Skills API errors with `Unexpected key(s) in SKILL.md frontmatter … Allowed properties are: allowed-tools, compatibility, description, license, metadata, name`.

The repo's existing OpenSpec skills use exactly the spec-portable set — `name`, `description`, `allowed-tools`, `license`, `compatibility`, `metadata` (`.claude/skills/openspec-sync-specs/SKILL.md:1-11`).

### 1.2 Where skills live, and how `/name` is produced

<https://code.claude.com/docs/en/skills>:

| Location | Path | Scope |
| --- | --- | --- |
| Personal | `~/.claude/skills/<skill-name>/SKILL.md` | all your projects |
| Project | `.claude/skills/<skill-name>/SKILL.md` | this project only |
| Plugin | `<plugin>/skills/<skill-name>/SKILL.md` | where the plugin is enabled |

Precedence: enterprise > personal > project; a skill at any level overrides a bundled skill of the same name; a skill beats a same-named `.claude/commands/` file.

Two facts that matter for `docs-sync`:

- **Skills and commands are the same thing now.** "A file at `.claude/commands/deploy.md` and a skill at `.claude/skills/deploy/SKILL.md` both create `/deploy` and work the same way." This explains the repo's duplication: `.claude/commands/opsx/*.md` and `.claude/skills/openspec-*/SKILL.md` are two deliveries of the same OpenSpec workflows, generated by `openspec init` (`node_modules/@fission-ai/openspec/dist/core/init.js:589-590`: "Generates skill files and slash commands for each selected tool, honoring the configured delivery mode (skills, commands, or both)").
- **Symlinks are supported.** "A `<skill-name>` entry in the enterprise, personal, or project locations can be a symlink to a directory elsewhere on disk. Claude Code follows the symlink and reads `SKILL.md` from the target directory." This is the existing repo convention for hand-managed skills: `.claude/skills/grilling`, `research`, `writing-for-agents` are symlinks into `../../.agents/skills/`, while the OpenSpec-generated ones are real directories in both trees (`.agents/skills/.openspec-target` contains `agents`).

### 1.3 Progressive disclosure and size

- <https://agentskills.io/specification>: metadata ≈100 tokens loaded at startup for all skills; the `SKILL.md` body loads on activation, "**< 5000 tokens recommended**"; `scripts/`, `references/`, `assets/` load only when required. "Keep your main `SKILL.md` under 500 lines." "Keep file references one level deep from `SKILL.md`."
- <https://code.claude.com/docs/en/skills>: same 500-line tip; "Reference supporting files from `SKILL.md` so Claude knows what each file contains and when to load it."
- **Skill content lifecycle** (Claude Code only, and load-bearing for `docs-sync`): "the rendered `SKILL.md` content enters the conversation as a single message and stays there for the rest of the session… Claude Code does not re-read the skill file on later turns, so write guidance that should apply throughout a task as standing instructions rather than one-time steps." Re-invoking a skill whose rendered content is unchanged adds only a short "already loaded" note.

### 1.4 Can a skill invoke another skill? (the crux)

**The docs never state it as a supported pattern in prose.** They are silent on skill→skill composition as a feature. What they *do* document, and what therefore constitutes the actual mechanism:

- **The `Skill` tool exists and Claude can call it.** <https://code.claude.com/docs/en/skills>, "Restrict Claude's skill access": "By default, Claude can invoke any skill that doesn't have `disable-model-invocation: true` set… A few built-in commands are also available through the Skill tool, including `/init` and `/security-review`." Permission syntax is `Skill(name)` for exact match, `Skill(name *)` for prefix match. Denying `Skill` in `/permissions` disables all skills.
- **Reachability is governed by `disable-model-invocation`, not by who is calling.** "`disable-model-invocation: true` … removes the skill from Claude's context entirely" and "The `user-invocable` field only controls menu visibility, not Skill tool access. Use `disable-model-invocation: true` to block programmatic invocation."
- The repo's own `writing-for-agents` states the same rule from the authoring side: a model-invoked skill "keeps a `description`, so the agent can fire it autonomously — **and other skills can reach it**", whereas a user-invoked skill "strips the description from the agent's reach: only the human typing its name can invoke it, and **no other skill can**" (`.agents/skills/writing-for-agents/SKILL-MECHANICS.md:9-10`).

**Consequence for `docs-sync`:** `openspec-sync-specs` is model-invocable — it has a `description` and no `disable-model-invocation` (`.claude/skills/openspec-sync-specs/SKILL.md:2-3`) — so it *is* reachable from another skill via the `Skill` tool. The invocation itself is expressed the way this repo already expresses it: as a prose instruction in the calling skill's body. Verbatim precedent, `.claude/skills/openspec-archive-change/SKILL.md:120`:

> Then run the `openspec-sync-specs` workflow inline (agent-driven intelligent merge) for change '<name>' … and wait for it to finish. … Do not delegate it to a background task … If your agent can only run it by delegation, delegate synchronously and wait for the result.

That is the authoritative pattern to copy. Note the explicit **inline, synchronous, wait-for-completion** requirement — the same hazard applies to `docs-sync`: reading `openspec/specs/` while a sync is still writing it yields docs built from a half-merged tree.

---

## 2. CLAUDE.md / memory

All from <https://code.claude.com/docs/en/memory>.

### 2.1 Hierarchy and lookup

Load order, broadest to most specific (so later entries appear later in context):

| Scope | Location |
| --- | --- |
| Managed policy | macOS `/Library/Application Support/ClaudeCode/CLAUDE.md`; Linux/WSL `/etc/claude-code/CLAUDE.md`; Windows `C:\Program Files\ClaudeCode\CLAUDE.md` |
| User | `~/.claude/CLAUDE.md` |
| Project | `./CLAUDE.md` **or** `./.claude/CLAUDE.md` |
| Local | `./CLAUDE.local.md` (gitignore it) |

`CLAUDE.local.md` is **not deprecated** in current docs — it "loads alongside `CLAUDE.md` and is treated the same way", with a documented worktree caveat (a gitignored local file exists only in the worktree that created it; import `@~/.claude/…` instead to share across worktrees).

Lookup: Claude Code walks **up** the directory tree from cwd, collecting `CLAUDE.md` and `CLAUDE.local.md` at each level; all discovered files are **concatenated, not overridden**, root-down. Files in **subdirectories** are not loaded at launch — they load when Claude reads a file in that subdirectory.

`AGENTS.md` is **not read by Claude Code**. The documented bridge is `@AGENTS.md` as the first line of `CLAUDE.md`, or `ln -s AGENTS.md CLAUDE.md`. This repo has no root `AGENTS.md`, so no bridge is needed.

### 2.2 `@path` imports

- Syntax `@path/to/import`; relative paths resolve against **the file containing the import**, not cwd.
- "Imported files can recursively import other files, with a **maximum depth of four hops**."
- "**Import parsing skips Markdown code spans and fenced code blocks.** To mention a path in your CLAUDE.md without importing it, wrap it in backticks: writing `` `@README` `` keeps the text literal, while `@README` outside backticks imports the file."
- Imports do **not** save context: "imported files still load and enter the context window at launch."
- An import resolving outside the working directory triggers a one-time approval dialog for project-level memory files.

### 2.3 What belongs in CLAUDE.md, and how big

- "**Size**: target **under 200 lines** per CLAUDE.md file. Longer files consume more context and reduce adherence."
- "Keep it to facts Claude should hold in every session: build commands, conventions, project layout, 'always do X' rules. If an entry is a multi-step procedure or only matters for one part of the codebase, move it to a [skill] or a [path-scoped rule] instead."
- CLAUDE.md is loaded into the context window at the start of **every** session, and is "delivered as a user message after the system prompt, not as part of the system prompt itself."
- Specificity beats vagueness: "Use 2-space indentation" over "Format code properly".
- **Block-level HTML comments are stripped** before injection ("`<!-- maintainer notes -->`"), so a marker-style comment costs no context but is also invisible to Claude. Comments inside code blocks are preserved.
- `/doctor` "proposes trims for a checked-in CLAUDE.md: it **cuts content Claude can derive from the codebase, such as directory layouts, dependency lists, and architecture overviews**, and keeps pitfalls, rationale, and conventions that differ from tool defaults."
- Project-root CLAUDE.md survives `/compact` (re-read from disk); nested ones and `paths:`-scoped rules do not.

### 2.4 `/init`

"Run `/init` to generate a starting CLAUDE.md automatically. Claude analyzes your codebase and creates a file with build commands, test instructions, and project conventions it discovers. **If a CLAUDE.md already exists, `/init` suggests improvements rather than overwriting it.**" `/init` also reads Cursor rules (`.cursor/rules/`, `.cursorrules`) and Copilot rules (`.github/copilot-instructions.md`) and folds relevant parts in. With `CLAUDE_CODE_NEW_INIT=1`, `/init` becomes an interactive multi-phase flow that also reads `AGENTS.md`, `.devin/rules/`, `.windsurf/rules/`, `.clinerules`, and presents a reviewable proposal before writing.

`/init` is also reachable through the `Skill` tool (see 1.4). It is **not** something `docs-sync` should call: it is an analyse-and-propose flow with its own interaction model, and calling it would produce a second author for a file `docs-sync` claims to own.

---

## 3. OpenSpec

Upstream: <https://github.com/Fission-AI/OpenSpec>. Installed locally as `@fission-ai/openspec@1.8.0` (`package.json` devDependencies; `npx openspec --version` → `1.8.0`).

### 3.1 CLI surface (verified by running it)

`openspec --help` reports: `init`, `update`, `list`, `view`, `change`, `archive`, `spec`, `config`, `schema`, `store`, `doctor`, `context`, `workset`, `validate`, `show`, `feedback`, `completion`, `status`, `instructions`, `templates`, `schemas`, `new`, `help`.

There is **no `openspec sync` command**. Sync is purely an agent-driven skill workflow — `.claude/skills/openspec-sync-specs/SKILL.md:15`: "This is an **agent-driven** operation - you will read delta specs and directly edit main specs to apply the changes."

Flags recorded:

- `openspec init [path]` — `--tools <tools>` (accepts `all`, `none`, or a comma list including `claude` and `agents`), `--force`, `--profile`, `--no-animation`, `--copilot-cloud` / `--no-copilot-cloud`.
- `openspec update [path]` — "Update OpenSpec instruction files"; only `--force`.
- `openspec list` — `--specs`, `--changes`, `--sort`, `--json`, `--store <id>`.
- `openspec status` — `--change <id>`, `--schema <name>`, `--json`, `--store <id>`.

Current repo state: `openspec list --specs` → `No specs found.`; `openspec list` → `No active changes found.`; `openspec context` → root `w2-server`, "No references declared". Only `openspec/config.yaml` exists — `openspec/specs/` and `openspec/changes/` have not been created yet.

### 3.2 Lifecycle: what sync does vs archive

Upstream README (<https://raw.githubusercontent.com/Fission-AI/OpenSpec/main/README.md>) documents explore → propose → apply → archive, with `openspec/specs/` as the main requirements tree and `openspec/changes/` as in-flight delta work, archived to `openspec/changes/archive/`. The upstream README does **not** document `sync` as a separate stage — "Specs updated" is presented as an outcome of archiving.

The local skills fill that in and are the more precise source:

- **Sync** merges delta → main and leaves the change active. `.claude/skills/openspec-sync-specs/SKILL.md:248`: "Main specs are now updated. **The change remains active - archive when implementation is complete.**"
- **Archive** does the same merge (prompting first) *and* moves `changeRoot` out of active. `.claude/skills/openspec-archive-change/SKILL.md:113-120` shows the prompt options ("Sync now (recommended)" / "Archive without syncing") and then runs `openspec-sync-specs` inline before the move.
- So sync is the *idempotent, repeatable* half of archive. That is exactly what a docs-regeneration skill wants: it can run any number of times mid-implementation without retiring the change.

Delta specs carry operation headers (`## ADDED / MODIFIED / REMOVED / RENAMED Requirements`, `SKILL.md:167-204`); main specs must contain none of them — "after syncing, every requirement lives under a single `## Requirements` section" (`SKILL.md:208`). Main specs live at `<planningHome.root>/openspec/specs/<capability-path>/spec.md` (`SKILL.md:43`, `:97`).

### 3.3 Is `openspec/specs/` the right source for docs generation?

Yes, and it is the *only* tree with the right shape. Deltas are diffs against an unstated base and carry operation headers; a doc generator reading them would be reading a changelog, not a state description. Main specs are the normalised, header-free, purpose-plus-requirements form (`SKILL.md:206-224`) — the state of the world.

This is the whole argument for **sync first**: main specs only reflect a change after sync (or archive) has merged it. Regenerating README/CLAUDE.md from `openspec/specs/` before syncing describes the world as it was before the change landed.

**Caveat worth stating in the note and in the skill:** sync merges specs, not code. A synced main spec asserts the requirement is *specified*, not *implemented* — `openspec-archive-change` gates on `tasks.md` checkboxes for implementation state (`.claude/skills/openspec-archive-change/SKILL.md:83-92`). If the generated docs claim "implemented", that claim comes from tasks/archive state, not from the specs tree.

### 3.4 Does OpenSpec generate or manage README / AGENTS.md / CLAUDE.md?

**Not in 1.8.0.** Verified against the installed package:

- `openspec init` writes skill files and slash commands into each selected tool's directory plus `openspec/config.yaml` (`node_modules/@fission-ai/openspec/dist/core/init.js:589-590`, `:630`, `:647`, `:712`). Grepping `dist/core/init.js` for `AGENTS.md` returns nothing.
- Across the whole `dist/`, `CLAUDE.md` appears only in `legacy-cleanup` (5 hits, all in `core/legacy-cleanup.{js,d.ts}`).
- `openspec update` is described only as "Update OpenSpec instruction files".

Historically it *did* manage a marked block — see collision risks below.

---

## 4. Collision risks (anything else that writes CLAUDE.md)

### 4.1 OpenSpec's legacy `<!-- OPENSPEC:START -->` block — real, and it cuts the other way

`node_modules/@fission-ai/openspec/dist/core/config.js:16-19`:

```js
export const OPENSPEC_MARKERS = {
    start: '<!-- OPENSPEC:START -->',
    end: '<!-- OPENSPEC:END -->'
};
```

`OPENSPEC_MARKERS` is imported by exactly one non-shell-completion module: `core/legacy-cleanup.js:10`. That module is headed "Legacy cleanup module for detecting and removing OpenSpec artifacts **from previous init versions** during the migration to the skill-based workflow" (`legacy-cleanup.js:1-4`), and lists the files that used to carry the block (`legacy-cleanup.js:15-24`):

```js
export const LEGACY_CONFIG_FILES = [
    'CLAUDE.md', 'CLINE.md', 'CODEBUDDY.md', 'COSTRICT.md',
    'QODER.md', 'IFLOW.md', 'AGENTS.md', // root AGENTS.md (not openspec/AGENTS.md)
    'QWEN.md',
];
```

Deletion is explicitly ruled out — `legacy-cleanup.js:495`: "Config files like CLAUDE.md, AGENTS.md are **NEVER** deleted"; `:523`: "Config files (CLAUDE.md, AGENTS.md, etc.) are NEVER in the removals list. They always go to the updates list where **only markers are removed**". `init.js:320-322` confirms auto-cleanup runs unprompted under `--force` or non-interactively, on the reasoning that "config file cleanup only removes markers (never deletes files), so auto-cleanup is safe."

**Two conclusions, both actionable:**

1. `docs-sync` owning `CLAUDE.md` wholesale does **not** fight OpenSpec 1.8.0 — OpenSpec no longer writes that file.
2. `docs-sync` must **not** emit an `<!-- OPENSPEC:START -->…<!-- OPENSPEC:END -->` block (nor any block using those markers) into `CLAUDE.md`. The next `openspec init`/`openspec init --force`/`openspec update` would detect it as a legacy artifact and silently strip it. If `docs-sync` wants a machine-recognisable region, use its own marker text, e.g. `<!-- SYND:START -->`.

### 4.2 Claude Code `/init` — soft collision, two authors for one file

`/init` generates `CLAUDE.md` and, when one exists, "suggests improvements rather than overwriting it" (<https://code.claude.com/docs/en/memory>). So it will not clobber `docs-sync`'s output in one shot, but it is a second author with a different notion of what belongs there, and its suggestions will drift the file away from whatever `docs-sync` regenerates next. **Recommendation: `docs-sync` owns the file; the repo should not run `/init` for `CLAUDE.md` maintenance.** If someone does, `docs-sync`'s next run overwrites it — so the skill should say so out loud in its output, not silently discard work.

### 4.3 `/doctor` trim proposals — a design constraint, not a fight

`/doctor` "cuts content Claude can derive from the codebase, such as directory layouts, dependency lists, and architecture overviews". A `docs-sync`-generated `CLAUDE.md` that dumps the package tree and the dependency list is a file `/doctor` will immediately propose deleting most of. This agrees exactly with the repo's own rule (`.agents/skills/writing-for-agents/SKILL.md:79`): the environment (`package.json` scripts, config files, directory layout, `--help` output) is itself a source of truth, and a document restating it is a **cache** that "earn[s] its load only when the lookup is expensive." **Design implication: `CLAUDE.md` gets the conventions, gotchas and rationale; the README (human audience) gets the layout and the commands.**

### 4.4 Auto memory — no collision

Auto memory lives in `~/.claude/projects/<project>/memory/MEMORY.md` and topic files, machine-local, never in `CLAUDE.md` (<https://code.claude.com/docs/en/memory>). `docs-sync` should leave it alone.

### 4.5 `.claude/rules/` — no collision, and a pressure valve

`.claude/rules/*.md` load at launch with the same priority as `.claude/CLAUDE.md`, and `paths:`-scoped rules load only when Claude touches matching files. If the CLAUDE.md `docs-sync` produces starts pushing 200 lines, path-scoped rules (`packages/apps/server/**`, `packages/apps/web/**`) are the documented escape hatch — not a longer CLAUDE.md.

### 4.6 The existing README's hand-written content

Current `README.md:1-10` is 11 lines and its entire substance is the submodule clone instruction (`git clone --recurse-submodules`, `git submodule update --init`). Wholesale regeneration will destroy it unless the skill carries it forward. It is also exactly the kind of gotcha nobody derives from the environment. **`docs-sync` must preserve it** (and it belongs in the pt-BR README).

### 4.7 The submodule is read-only

`openspec/config.yaml:9-14`: `packages/apps/client` is a submodule of `open-w2-project/w2-client`, "a read-only protocol reference … **Never edit or commit inside it from this repo**". `docs-sync` must never write `packages/apps/client/README.md` — and note that submodule already ships its own pt-BR README (`packages/apps/client/README.md:1-4`).

---

## 5. pt-BR ELI5 README — convention

Light research, as scoped.

`standard-readme` (<https://raw.githubusercontent.com/RichardLitt/standard-readme/main/spec.md>) is the only widely-referenced formal README spec and it addresses this directly:

- Translated files are named with a BCP 47 tag: `README.de.md`. "`README.md` is reserved for English" — **when multiple language versions exist**.
- "If there is only one README and the language is not English, then a different language in the text is permissible without needing to specify the BCP tag."
- "If the README is in another language, the titles must be translated into that language."
- Required sections: Title, Short Description, Table of Contents, Install, Usage, Contributing, License. Optional: Banner, Badges, Long Description, Security, Background, API, Maintainers, Thanks, Extra.

**Recommendation: a single pt-BR `README.md`, no `README.pt-BR.md` split.** It is explicitly permitted, it is what the sibling `w2-client` repo already does (`packages/apps/client/README.md` is pt-BR), and a split immediately creates the drift problem `docs-sync` exists to prevent — two files to regenerate, one of which nobody reads. If English is ever needed, add `README.en.md` then and let `docs-sync` own both. Per the spec, section headings in the generated README must be in pt-BR (`Instalação`, `Como usar`, `Licença`), which is consistent with the requested language split: pt-BR headings live in the README, en-EN headings live in `CLAUDE.md` and `SKILL.md`.

---

## 6. Concrete recommendation for the `docs-sync` SKILL.md

### 6.1 Location

`/home/nrechdan/projects/w2-server/.agents/skills/docs-sync/SKILL.md`, with a symlink `.claude/skills/docs-sync -> ../../.agents/skills/docs-sync`.

Rationale: matches how every hand-managed skill in this repo is already installed (`grilling`, `research`, `writing-for-agents` are symlinks into `.agents/skills/`), keeps the vendor-neutral `.agents/` tree authoritative (`.agents/skills/.openspec-target` = `agents`), and Claude Code explicitly follows skill symlinks. The directory name must be `docs-sync` because the invocable `/docs-sync` comes from the directory, not the `name` field.

Do **not** also add `.claude/commands/docs-sync.md`. That path is OpenSpec-generated territory here, and a skill already beats a same-named command anyway.

### 6.2 Frontmatter

```yaml
---
name: docs-sync
description: Regenerate the repo docs after an OpenSpec sync — sync delta specs into main specs, then rewrite README.md (pt-BR) and CLAUDE.md (en-EN) from the synced state.
allowed-tools: Bash(openspec:*) Read Edit Write Glob Grep Skill(openspec-sync-specs)
disable-model-invocation: true
license: MIT
compatibility: Requires openspec CLI.
---
```

Notes on each choice:

- `name: docs-sync` — valid under the standard (lowercase, 9 chars, hyphen allowed) and matches the parent directory as the spec requires.
- **`disable-model-invocation: true`.** This is what the repo's own authoring rules mandate. `SKILL-MECHANICS.md:12`: "Pick model-invocation only when the agent must reach the skill on its own, or another skill must. If it only ever fires by hand, make it user-invoked and pay no context load." `docs-sync` rewrites two tracked files and mutates `openspec/specs/` — a side-effecting workflow the human triggers, the same class the Claude Code docs name for this flag ("workflows with side effects or that you want to control timing, like `/commit`, `/deploy`"). With the flag set, the `description` becomes human-facing (`SKILL-MECHANICS.md:10`), so the text above should be trimmed to a plain one-line summary with the trigger list stripped — e.g. `description: Sync OpenSpec specs, then regenerate README.md (pt-BR) and CLAUDE.md (en-EN).`
  - **Direction check:** the dependency runs `docs-sync → openspec-sync-specs`, not the reverse. `openspec-sync-specs` is model-invocable, so `docs-sync` can reach it regardless of `docs-sync`'s own invocation mode. Nothing needs to reach `docs-sync`.
- `allowed-tools` — `Bash(openspec:*)` matches every OpenSpec skill in the repo; Read/Edit/Write/Glob/Grep cover reading the environment and writing the two docs. **`Skill(openspec-sync-specs)` is partly unverified**: `Skill(name)` is documented as *permission-rule* syntax, and `allowed-tools` takes tool permission rules, but no doc page shows a `Skill(...)` entry inside `allowed-tools`. If it misbehaves, drop it — the sync will simply prompt once, which is harmless.
- `license` / `compatibility` — matched to the OpenSpec skills' house style; both are spec fields Claude Code accepts without acting on.
- Skip `metadata` unless you want a version stamp; skip `model`, `effort`, `context: fork`. In particular **do not use `context: fork`** — a forked subagent returns a summary, and `docs-sync`'s value is that the sync's outcome is visible in the same context that then writes the docs.

### 6.3 Ordered steps

1. **Sync first.** Run the `openspec-sync-specs` workflow **inline and synchronously** for the selected change; wait for it to finish; do not background it. Copy the archive skill's phrasing (`.claude/skills/openspec-archive-change/SKILL.md:120`), including the "if you can only run it by delegation, delegate synchronously and wait" fallback. If sync reports nothing to sync (no active change, or no delta specs), that is not an error — continue to step 2. If sync *fails*, stop; write nothing.
2. **Read the environment, do not trust cached copies.** Re-derive from source every time: `package.json` (workspaces, scripts), `Cargo.toml` (workspace members, edition, rust-version), `packages/apps/*/package.json` and `Cargo.toml`, `.nvmrc`, `.yarnrc`, `.gitmodules`, and `openspec/specs/**/spec.md` as it now stands. This step is what makes the docs a *rebuild* rather than an *edit*.
3. **Write `CLAUDE.md` (en-EN).** Under 200 lines. Conventions, gotchas, and rationale — not derivable dumps. No `OPENSPEC:` markers. If the file already exists, preserve any human-authored section the skill did not generate.
4. **Write `README.md` (pt-BR, ELI5).** Headings in pt-BR. Carry forward the existing submodule clone instructions verbatim in substance (`README.md:5-10`). Cover: what this repo is, the three packages, the node/yarn/rust prerequisites, and `yarn dev`.
5. **Report.** Name what sync changed, which doc sections changed, and anything preserved rather than regenerated.

Steps 1 and 2 have a real risk of premature completion — the agent can see steps 3–5 and rush the legwork of step 2. `writing-for-agents` prescribes sharpening the completion criterion before splitting (`SKILL.md:49`): give step 2 an exhaustive bound ("every workspace member and every main spec accounted for"), not a vague one ("understand the project").

### 6.4 Section outline

```
frontmatter
one-line purpose
Steps  (1-5 above, ordered, each with its completion criterion)
README contract      — pt-BR, ELI5, required sections, what to carry forward
CLAUDE.md contract   — en-EN, <200 lines, what belongs and what /doctor will strip
Guardrails
```

Keep it one file. Split into `references/` only if the two contracts outgrow the 500-line / ~5000-token budget — which, given the two contracts are the whole content, they should not.

### 6.5 Writing-style rules the repo binds you to

From `.agents/skills/writing-for-agents/SKILL.md`, treat as mandatory for the eventual `SKILL.md`:

- **Prompt the positive, not the prohibition** (`:74`). "Write the README in pt-BR", not "don't write the README in English" — a negation "drags the forbidden behaviour into context and makes it *more* available". This matters unusually much here: the language split is precisely the kind of rule people write as a ban.
- **Single source of truth** (`:78`). One authoritative statement of the language split; do not restate it under every heading.
- **Cache only expensive lookups** (`:79`). Do not restate `package.json` scripts inside the skill; instruct the agent to read them.
- **Leading words** (`:63-72`). `docs-sync` is a coined word and recruits no pretraining priors, so the body must define it once, clearly, and then use it as a token.
- **Completion criteria carry demand** (`:47-52`). "Every workspace member accounted for" beats "describe the project".
- **Standing instructions, not one-time steps** — because the rendered `SKILL.md` stays in context for the whole session and is never re-read (<https://code.claude.com/docs/en/skills>, "Skill content lifecycle").

### 6.6 What the generated README actually has to describe

Derived from the manifests, for scoping the ELI5:

- Yarn workspaces root, `packages/apps/server` + `packages/apps/web` (`package.json`); Cargo workspace, `members = ["packages/apps/server"]`, `resolver = "3"`, `edition = "2024"`, `rust-version = "1.97"` (`Cargo.toml`).
- `@app/server`: Rust binary `w2-server`, dev loop `nodemon` watching `Cargo.toml`/`src` → `cargo run`.
- `@app/web`: Next.js 16.3, React 19.2, TypeScript 6, `next dev --turbo`, ESLint + Prettier.
- `packages/apps/client`: git submodule of `open-w2-project/w2-client`, C++ / MSBuild / Windows-only, read-only protocol reference — never edit from this repo (`.gitmodules`, `openspec/config.yaml:9-14`).
- Prereqs: Node `v24.18.1` (`.nvmrc`), Yarn configured with `--add.exact true` (`.yarnrc`), a Rust toolchain ≥ 1.97.
- Root scripts: `yarn dev` fans out to both apps via `concurrently`.
- Licensing is inconsistent and worth flagging to a human, not silently papering over: root `package.json` says `Apache-2.0` while `Cargo.toml` carries no license field.

---

## 7. Open questions / not verified

- **`Skill(...)` inside `allowed-tools`.** Documented as permission-rule syntax; not documented as an `allowed-tools` entry. Unverified — treat as best-effort.
- **Whether `docs-sync` should also drive `openspec archive`.** Out of scope as briefed, but the boundary matters: sync leaves the change active, archive retires it. Keeping `docs-sync` at sync means it is safe to run mid-implementation, which is almost certainly what you want from a docs command.
- **Doc generation from an empty specs tree.** `openspec/specs/` does not exist yet in this repo (`openspec list --specs` → "No specs found."). The first several `docs-sync` runs will have no spec input at all, so the docs will be derived entirely from the environment. Not a blocker, but the skill needs a defined behaviour for the empty case rather than discovering it at runtime.
- **Whether OpenSpec plans to reintroduce CLAUDE.md management.** Verified absent in 1.8.0 by reading the installed `dist/`; upstream roadmap not checked. Re-verify on the next `@fission-ai/openspec` bump — a returning marker block is the one change that would break `docs-sync`'s ownership of the file.
- **ELI5 register in pt-BR.** No standard exists for "explain like the reader is 5" and none was found. `standard-readme` constrains structure and translated headings; the register is a house style decision the skill itself must define with examples, since nothing external will pin it down.
