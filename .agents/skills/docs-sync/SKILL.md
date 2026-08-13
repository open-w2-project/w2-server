---
name: docs-sync
description: Sync OpenSpec specs, then regenerate README.md (pt-BR) and CLAUDE.md (en-EN).
allowed-tools: Bash(openspec:*) Read Edit Write Glob Grep Skill(openspec-sync-specs)
disable-model-invocation: true
license: MIT
compatibility: Requires openspec CLI.
---

`docs-sync` is a **rebuild**: `README.md` and `CLAUDE.md` are re-derived from the repo's current sources, not edited from what they already say. Both files belong to this skill — a run replaces them.

## Steps

1. **Sync the specs first.** Run the `openspec-sync-specs` workflow inline (agent-driven intelligent merge) for the change under work, and wait for it to finish. Do not delegate it to a background task — the later steps read `openspec/specs/` and would build the docs from a half-merged tree. If your agent can only run it by delegation, delegate synchronously and wait for the result. A sync reporting nothing to sync (no active change, or no delta specs) is a pass — continue to step 2. A sync that **fails ends the run**: report the failure and leave both docs as they are.

   Done when the sync has finished and reported its outcome.

2. **Read every source.** Open, in the tree as it now stands: `package.json` and every Yarn workspace's `package.json`; `Cargo.toml` and every Cargo workspace member's `Cargo.toml`; `.nvmrc`, `.yarnrc`, `.gitmodules`; `openspec/config.yaml`; every `openspec/specs/**/spec.md`; and `packages/apps/client/README.md`, which is the only source for the submodule's own licence and build terms — they are not derivable from this repo's manifests. Read them rather than recalling them — a `docs-sync` run's whole value is that it saw the current state.

   Done when every workspace member of both workspaces and every main spec is accounted for. An empty or absent `openspec/specs/` is a pass — the rebuild then runs on the environment alone.

3. **Write `CLAUDE.md`** to the CLAUDE.md contract below.

   Done when every rule in that contract holds for the file on disk.

4. **Write `README.md`** to the README contract below.

   Done when every rule in that contract holds for the file on disk.

5. **Report.** Name what the sync changed, which doc sections changed, what was carried forward instead of regenerated, every contradiction found between sources — separated into new ones and already-accepted ones, per **Accepted contradictions** below — and every `openspec/config.yaml` claim contradicted by what this run read or wrote.

   Done when each of those five is stated or explicitly reported as empty.

## README contract

Written in **pt-BR**, headings included (`Instalação`, `Como usar`, `Licença`). One README serves both audiences; if English is ever wanted, it becomes a second file `README.en.md` and this skill owns both.

Register is **ELI5**: short sentences, one idea each, every thing named in plain words before it is used.

- Yes: "O `packages/apps/server` é o servidor. Ele roda em Rust e escuta as conexões do cliente."
- Not: "Workspace member Rust expondo o protocolo W2 via binário `w2-server`."

Content:

- What this repo is, and the three packages under `packages/apps/`.
- Prerequisites and commands, with versions taken from the files read in step 2.
- The submodule clone instructions the current README carries (`git clone --recurse-submodules`, and `git submodule update --init` for an existing clone) — carry them forward; nobody derives them from the environment.

The README is where the derivable material belongs: layout, dependency lists, command listings.

## CLAUDE.md contract

Written in **en-EN**, under 200 lines, plain Markdown sections.

It holds what a lookup will not reveal: conventions, gotchas, rationale, and "always do X" rules that differ from tool defaults. Be specific — "Use 2-space indentation" over "Format code properly". Material Claude can derive from the codebase (directory layout, dependency lists, architecture overviews) lives in the README instead; `/doctor` proposes trimming it out of `CLAUDE.md` anyway.

Two pressure valves when the file grows: a multi-step procedure becomes a skill, and a rule that only matters in one area becomes a `paths:`-scoped file under `.claude/rules/`.

Keep the file free of `<!-- OPENSPEC:START -->` / `<!-- OPENSPEC:END -->` markers — `openspec init` and `openspec update` read that pair as a legacy artifact and strip the block between them. A machine-recognisable region, if one is ever needed, uses this skill's own marker text.

## Guardrails

- **Preserve human-authored sections.** A section in either file that this rebuild does not generate is carried forward verbatim and named in the report. `/init` is a second author for `CLAUDE.md`; its contributions arrive this way rather than being discarded silently.
- **`packages/apps/client` is a read-only submodule** and ships its own README. Describe it from this repo; write only outside it.
- **A synced spec is specified, not implemented.** Implementation claims come from `tasks.md` checkboxes and archive state. Docs sourced from `openspec/specs/` describe what is agreed, so word them that way.
- **Report contradictions, decide nothing.** Sources that disagree (two manifests naming different licenses, a spec describing what the code has not got) go to the human as a finding.
- **Accepted contradictions are re-checked, never suppressed.** The register below lists source claims already reviewed and deliberately left standing. For each, confirm the claim is still present and still says what the register says it says. Unchanged → count it under "known, accepted" and do not restate the analysis. **Reworded → report it as new**: the acceptance covered a specific claim, not a permanent exemption for that file. Gone → say so and propose striking it from the register, so the register self-cleans instead of accumulating entries about text nobody can find. Never register a claim by line number — submodule line numbers move on every pin bump.
- **`openspec/config.yaml` is read, never written.** Its `context:` block is machine-consumed — the spec tooling copies it into generated artifacts, so a stale claim there propagates silently into work nobody re-reads. Check every claim in it against the sources read in step 2 **and** against the `CLAUDE.md` this run just wrote, in both directions, and report each disagreement in step 5. Never edit it: `openspec update` also writes that file, and two owners is how content gets clobbered. The check stops here — `docs/` and other hand-written prose are human-read, and auditing them would make this skill an unbounded linter that fires every run.

## Accepted contradictions

Reviewed and deliberately left standing. Each is identified by its claim, not its location.

`packages/apps/client/README.md` — the submodule's own README, written for contributors
building it standalone on Windows with Visual Studio:

- **"can only be compiled for Windows using Visual Studio"** — true as written. `apenas` scopes
  the *target*, and this build does emit a Windows-only x86 binary using the Visual Studio
  toolchain. It contradicts `docs/setup-client-wsl2.md` only under the "only *on* Windows"
  reading, which the sentence does not actually make.
- **"you will need Visual Studio installed, with these components"** — false for the WSL2 route,
  which obtains the toolchain through the Visual Studio installer manifests without ever
  installing Visual Studio. Accurate for the audience this README addresses. Not flagged by the
  check itself, which compares claims against our prose rather than against our build.
- **"DirectX is included in the repository and properly configured"** — true for the x86
  configurations only; the vendored library directory is 32-bit and two of the four
  configurations order its headers ahead of the Windows SDK. Scoped by the paragraph two above
  it, which states that x64 needs the x64 DirectX dependency.
