# CLAUDE.md

Project layout, dependency lists and commands live in `README.md`. This file holds only
what reading the code will not tell you.

## The client submodule

`packages/apps/client` is a git submodule of `open-w2-project/w2-client`: a decompiled C++
client for With Your Destiny. It targets Windows and is a Visual Studio / MSBuild project,
though it does not need Windows to build — see "Building it" below. It is under active
development alongside the server — but in its own repository, not this one.

- Client changes may be authored from this repo, directly in the submodule working tree, and
  committed there on a named branch — never on detached HEAD, never straight onto the pinned
  branch (`.gitmodules` sets `branch = main`). Pick the branch name yourself; nothing in this
  repo names branches in a repository it does not own.
- **`/w2-commit` owns commits that touch both sides.** It is the skill for the paired case, and
  it fixes the order: the client commit, then the server/web commit, then the pin bump alone,
  then the client push followed by `git push --recurse-submodules=check`. That check is the only
  thing standing between a pin bump and a gitlink nobody can fetch — git has no atomicity across
  two repositories, so order plus that gate is the whole guarantee. Both commit-message patterns
  live in that skill.
- The pin bump is its own commit, whose only content is the new pinned submodule commit. It is
  never folded into the server change, even when both are ready in the same run.
- `git submodule update` refuses to clobber uncommitted submodule changes — it stops with
  "error: Your local changes … would be overwritten by checkout". The paths that do destroy work
  are `--force`, `git submodule deinit --force`, and commits made on a detached HEAD, which go
  unreachable the moment you switch away. Run `git -C packages/apps/client status` before any of
  those, and before `--remote`, which deliberately targets a different commit.
- The wire protocol is defined on both sides and both sides move. Packet structs and opcodes
  live in `Projects/TMProject/CPSock.cpp`, `Basedef.h`, and `Enums.h` — read the pinned commit
  before shaping a packet on the server side, and read it again after a bump.
- When a protocol change needs both sides, land the client change in `w2-client` first, then
  bump the pin here in the same run as the matching server change. The server must never target
  a protocol shape the pinned client does not have.
- The decompiled code does not follow this repo's conventions. Don't take its style as a model
  for new Rust or TypeScript here, and keep cleanup work in the `w2-client` repo.
- **The client is GPL v3; this repo is Apache-2.0.** Reading `CPSock.cpp` to learn the wire
  format is the intended use and the bullet above tells you to do it. Copying from it is not:
  no struct, no constant table, no enum body, no "translated" line-by-line port into Rust.
  Re-derive the shape from what the bytes must be, and cite the file rather than pasting it.

### Building it

The client builds **from inside WSL2**, on ext4, with no Windows and no Visual Studio: the real
MSVC v142 toolchain runs under Wine (msvc-wine). `scripts/build-client.sh` drives it and
`yarn dev:app:client` watches. Setup is `docs/setup-client-wsl2.md`; the evidence and the
measurements are in `docs/researchs/wsl2-client-build-watcher.md` §11.

- Building is not editing. The build writes only to gitignored output directories, so a build
  on its own leaves the submodule clean.
- Only `Release|x86` (the solution's name for the project's `Release|Win32`) is known to build.
  `Debug|x64` puts the vendored 2002 DirectX headers ahead of the Windows SDK, whose old
  `basetsd.h` then breaks `<windows.h>`. Fix that in `w2-client` before using it.
- `dev:app:client` is inside the `yarn:dev:*` glob **on purpose**, so a C++ error takes the web
  and server dev processes down with it and `yarn dev` needs the toolchain. That was the user's
  explicit call — don't quietly rename it out of the glob.
- The toolchain is not redistributable (Visual Studio licence), so it cannot go in a shared CI
  image. Don't propose one.

## Dependency versions are pinned exactly

`.yarnrc` sets `--add.exact true`, so `yarn add` writes `16.3.0`, not `^16.3.0`. Keep it that
way: no `^`, `~`, or ranges in any `package.json`. If you hand-edit a version, write the exact
number.

This is Yarn 1 (classic) with workspaces — not Berry. There is no `.yarnrc.yml`, no PnP, and
no `yarn workspaces foreach`. Install from the repo root (`yarn install`); to add a package to
one workspace use `yarn workspace @app/web add <pkg>` from the root.

Only `packages/apps/server` and `packages/apps/web` are Yarn workspaces. The client submodule
has no `package.json` and must not be given one — anything it needs from Node tooling is
driven from the root `package.json` and `scripts/`.

## Rust

- New crates go under `packages/apps/` and get added to the `members` list in the root
  `Cargo.toml`.
- Crate manifests inherit shared metadata: write `edition.workspace = true`,
  `version.workspace = true`, and so on rather than repeating the literal values. Only `name`
  and the actual dependencies are crate-local.
- Edition 2024, MSRV 1.97. Don't reach for features newer than the pinned `rust-version`
  without bumping it in the root `Cargo.toml` first.
- The workspace uses `resolver = "3"`.
- `[workspace.package]` sets `publish = false` and `license = "Apache-2.0"`. This is not a
  crates.io package and is not meant to become one — `publish = false` is the deliberate
  counterpart to the root `package.json`'s `"private": true`, not an oversight to helpfully
  remove.

## TypeScript / web

The web workspace runs a near-maximal strict config. These flags change how you have to write
code, so keep them in mind rather than fighting the compiler afterwards:

- `noUncheckedIndexedAccess` — `arr[0]` and `obj[key]` are `T | undefined`. Narrow before use;
  do not paper over it with `!` unless the invariant is genuinely local and obvious.
- `verbatimModuleSyntax` — type-only imports must say so: `import { type DocumentProps }` or
  `import type { GetStaticProps }`. A plain `import` of a type is a build error.
- `noPropertyAccessFromIndexSignature` — reach index-signature members with `obj["key"]`, not
  `obj.key`.
- `noUnusedLocals` / `noUnusedParameters` — unused bindings fail the build, not just lint.
- `noEmit` is on: `tsc` is a type-checker here. Next builds the output.

Other web conventions:

- Import from `_/…` for anything under `src/` (`paths` maps `_/*` → `./src/*`). Prefer it over
  long relative chains.
- This is the **Pages Router** (`src/pages`), not the App Router. Don't add `src/app/`,
  server components, or `"use client"` directives.
- Page and document modules export an anonymous arrow function as default
  (`export default () => (...)`). Follow that shape for new pages instead of named function
  declarations.
- Prettier's `printWidth` is 180. Do not reflow code to 80 or 100 columns — that produces a
  diff Prettier will undo.
- ESLint is flat-config (`eslint.config.mts`) with the `jsx-runtime` React preset: no
  `import React from "react"` at the top of `.tsx` files.
- The only script the web workspace defines is `dev`. There is no `build`, `lint`, `test`, or
  `typecheck` script — run the tools directly (`yarn workspace @app/web exec tsc`) rather than
  inventing a script name that does not exist.

## Dev loop

`yarn dev` from the root runs all three apps under `concurrently` with `--kill-others-on-fail`,
so a compile error in the Rust server or the C++ client takes the web dev server down with it.
When you are only touching one side, run that side's script alone (`yarn dev:app:server` /
`yarn dev:app:web` / `yarn dev:app:client`) so a failure in another app doesn't interrupt you.

`concurrently` picks its processes with the `yarn:dev:*` glob, so the name of a script decides
whether it joins `yarn dev`. Adding a `dev:*` script to the root `package.json` puts it in the
dev loop for everyone, including people who cannot run it.

The server's watcher is `nodemon` watching `Cargo.toml` and `src/` and re-running `cargo run`
— not `cargo watch`. Adding a new watched path means editing the `dev` script in
`packages/apps/server/package.json`.

The client's watcher is also `nodemon`, configured in the **root** `package.json`. Unlike the
server, its intermediate build output lands inside the watched tree
(`Projects/TMProject/Release/`), so the extension filter and the `-i` ignore are load-bearing:
widen them carelessly and the build retriggers itself forever. The linked binary lands outside
it, at `packages/apps/client/Release/TMProject.exe`.

## Spec-driven workflow (OpenSpec)

This repo is spec-driven: behaviour is agreed in `openspec/` before it is implemented.

- Propose work with `/opsx:propose`, implement with `/opsx:apply`, archive with
  `/opsx:archive`. The CLI is not installed globally — invoke it via the workspace binary
  (`yarn openspec …` / `npx openspec …`).
- `openspec/specs/` describes what is **agreed**, not what is **built**. Implementation status
  comes from a change's `tasks.md` checkboxes and from archive state. Never read a main spec
  as a claim that the code exists.
- Shared project context for spec generation lives in `openspec/config.yaml`. Update it there
  when the stack or the ground rules change — it is what the spec tooling reads.
- Local dev tooling (build scripts, watchers) is not product behaviour and does not need a
  change proposal. `scripts/build-client.sh` and the `dev:app:client` watcher were added this
  way, deliberately.

## These docs are generated

`README.md` and `CLAUDE.md` are rebuilt from the repo's current sources by the `docs-sync`
skill. Run it (`/docs-sync`) after changing manifests, versions, or specs, rather than
hand-patching the docs and letting them drift. Hand-written sections are carried forward by
the rebuild, so adding one is fine — just expect the generated ones to be replaced.

`docs/setup-client-wsl2.md` and `docs/researchs/` are **not** generated. Edit them directly.

Skills authored by hand live in `.agents/skills/<name>/`, with `.claude/skills/<name>` as a
symlink into that tree. The OpenSpec ones are generated and exist as real directories in both.

Do not add the legacy OpenSpec HTML-comment marker pair (an `OPENSPEC` start/end comment) to
this file. `openspec init` and `openspec update` treat that pair as a legacy artifact and
delete everything between them.
