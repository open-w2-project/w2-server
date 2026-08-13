# Research: the `w2-commit` skill (paired commits across the superproject and the client submodule)

Date: 2026-08-13. Repo: `/home/nrechdan/projects/w2-server`. All paths are absolute unless prefixed by the repo root.

Everything marked **MEASURED** was run against this working tree on this machine (git 2.53.0), read-only — no `commit`, `add`, `checkout`, `push` or `submodule update` was executed. Everything else is quoted from the source that owns it: a manpage installed on this machine (cited as `manpage(section)`, *section/option*), a file in this repo (cited as `path:line`), or a URL. §7 lists what could not be verified.

## Question / scope

Design a skill named `w2-commit` that commits changes in **both** this repo and its submodule `packages/apps/client` (`open-w2-project/w2-client`) in one coherent operation, and that **defines the commit-message pattern for each repo separately** — they are different repositories with different licences, different languages, and different existing histories.

The real question is not "what does the command sequence look like". It is **what git actually guarantees across two repositories** (nothing), and **whether the observed conventions of the two repos can share one message pattern** (they cannot).

---

## Verdict up front

**"One coherent operation" is achievable. "One commit" is not, and neither is atomicity.**

Git offers no transaction spanning two repositories. `git push --atomic` is scoped to *one remote's refs* — `git-push(1)`, *OPTIONS/--atomic*: "Use an atomic transaction on the remote side if available. Either all refs are updated, or on error, no refs are updated." Two repos means two remotes, so no atomicity is available at any layer. The standard mitigation is the one git itself ships: **fixed order, then verify** — commit in the submodule, publish it, record the gitlink, and let `git push --recurse-submodules=check` be the gate that refuses a superproject push whose gitlink points at a commit nobody else can fetch.

That resolves the apparent tension with `CLAUDE.md`. The rule at `CLAUDE.md:15-16` — "The pin bump stays its own commit in this repo, whose only content is the new pinned submodule commit" — is not in conflict with "commit both at once", because **the unit of coherence is the skill run, not the commit**. One `w2-commit` run produces up to three commits across two repos, in this order:

| # | Repo | Content | Message pattern |
| --- | --- | --- | --- |
| 1 | `w2-client` (submodule) | the client source change, on a **named branch** that is not `main` | w2-client house style (§3.3) |
| 2 | `w2-server` | the server/web/docs change | Conventional Commits (§3.2) |
| 3 | `w2-server` | **only** the gitlink `packages/apps/client` | Conventional Commits, `client` scope (§3.2) |

Commit 1 must exist before commit 3 can name it (§1.2). Commits 2 and 3 are separable in either order; putting 2 first keeps the pin bump adjacent to the push, where the `check` gate fires.

**Two message patterns, one per repo, is not a stylistic preference — it is forced by the evidence.** 730 non-merge commits in `w2-client` contain **zero** Conventional Commits subjects (MEASURED, §2.5). This repo's only commit-convention artefact is `git commit -m "chore: bump client"` at `README.md:104` — which *is* Conventional. Blending them would break the one convention each repo already has.

**One correction to `CLAUDE.md` falls out of the research and should be made before the skill is written.** `CLAUDE.md:19-21` says "`git submodule update` destroys uncommitted submodule changes with no warning and no way back." That is not what git does; the mechanism is different and the accurate version is *more* useful to the skill. See §1.5.

---

## 1. Git mechanics of submodule + superproject commits

### 1.1 What a gitlink is, and what `git add <submodule-path>` records — MEASURED

`gitsubmodules(7)`, *DESCRIPTION*:

> "the superproject tracks the submodule via a gitlink entry in the tree at `path/to/bar` and an entry in its `.gitmodules` file"
>
> "**The gitlink entry contains the object name of the commit that the superproject expects the submodule's working directory to be at.**"

One object name. Not a tree, not a diff, not the submodule's index. This repo demonstrates the point in its current state, because the submodule has **nine files staged in its own index** while the superproject's gitlink still names the submodule's `HEAD`:

```
$ git ls-files -s packages/apps/client
160000 378561c68b2f8a476850bf1f2cf2dbb71c1b31c6 0	packages/apps/client

$ git -C packages/apps/client rev-parse HEAD
378561c68b2f8a476850bf1f2cf2dbb71c1b31c6

$ git -C packages/apps/client diff --cached --name-only | head -3
Projects/TMProject/D3DEnumeration.cpp
Projects/TMProject/DXUtil.cpp
Projects/TMProject/NewApp.cpp
```

Mode `160000` is the gitlink mode. The staged blobs inside the submodule are invisible to it.

**Consequence, and it is the single most load-bearing fact for `w2-commit`:** `git add packages/apps/client` records the submodule's `HEAD` and nothing else. If the client edit is uncommitted — staged or not — `git add` on the submodule path is a **no-op for the index**, and a superproject commit made at that moment records the *old* pointer while the tree on disk shows the *new* code. Nothing errors. The divergence is silent.

The canonical sequence is in the manpage, `gitsubmodules(7)`, *WORKFLOW FOR A THIRD PARTY LIBRARY*:

```
# Occasionally update the submodule to a new version:
git -C <path> checkout <new-version>
git add <path>
git commit -m "update submodule to new version"
```

`git -C <path>` first, then `git add <path>`. That ordering is the whole mechanism.

### 1.2 Ordering: why the submodule commit must exist first

Because the gitlink is an object name, there is nothing to record until the submodule commit exists. Recording a gitlink and creating the commit it names cannot be reordered.

Recording a gitlink that points at a commit which exists **only locally** is the failure mode git spends the most documentation on. `git-fetch(1)`, *OPTIONS/--recurse-submodules*, names the resulting state precisely:

> "git fetch always attempts to fetch "changed" submodules, that is, **a submodule that has commits that are referenced by a newly fetched superproject commit but are missing in the local submodule clone**."

If that commit is missing from the submodule's remote too, the fetch cannot supply it and the checkout fails. Pro Git 7.11, *Publishing Submodule Changes* (<https://git-scm.com/book/en/v2/Git-Tools-Submodules>):

> "If we commit in the main project and push it up without pushing the submodule changes up as well, other people who try to check out our changes are going to be in trouble since they will have no way to get the submodule changes that are depended on. Those changes will only exist on our local copy."

This is not recoverable by the consumer — only by the author pushing the missing commit. A superproject commit that names an unreachable gitlink is a broken commit in the history *permanently*, even after the submodule commit is later pushed, if the submodule commit was rewritten or discarded in the meantime.

### 1.3 `git push --recurse-submodules` — exact semantics

`git-push(1)`, *OPTIONS/--no-recurse-submodules, --recurse-submodules=(check|on-demand|only|no)*:

> "May be used to make sure all submodule commits used by the revisions to be pushed are available on a remote-tracking branch. Possible values are:
>
> **check** — Git will verify that all submodule commits that changed in the revisions to be pushed are available on at least one remote of the submodule. If any commits are missing **the push will be aborted and exit with non-zero status**.
>
> **on-demand** — all submodules that changed in the revisions to be pushed will be pushed. If on-demand was not able to push all necessary revisions it will also be aborted and exit with non-zero status.
>
> **only** — all submodules will be pushed while the superproject is left unpushed.
>
> **no** — override the `push.recurseSubmodules` configuration variable when no submodule recursion is required."

Where `check` looks: `gitsubmodules(7)`, *THE CONFIGURATION OF SUBMODULES* — "The submodule's `$GIT_DIR/config` file would come into play when running `git push --recurse-submodules=check` in the superproject, as this would **check if the submodule has any changes not published to any remote**. The remotes are configured in the submodule as usual in the `$GIT_DIR/config` file."

Pro Git 7.11 gives the exact refusal text:

```
$ git push --recurse-submodules=check
The following submodule paths contain changes that can
not be found on any remote:
  DbConnector

Please try

	git push --recurse-submodules=on-demand

or cd to the path and use

	git push

to push them to a remote.
```

and the ordering guarantee of `on-demand`: "Git went into the `DbConnector` module and pushed it before pushing the main project. **If that submodule push fails for some reason, the main project push will also fail.**"

Config: `git-config(1)`, *push.recurseSubmodules* — "May be `check`, `on-demand`, `only`, or `no`, with the same behavior as that of `push --recurse-submodules`. **If not set, `no` is used by default**, unless `submodule.recurse` is set (in which case a true value means `on-demand`)."

**Which is safe here: `check`.**

- `check` is read-only against `w2-client` — it verifies and refuses, it never writes to another repository's remote. It converts §1.2's silent, permanent breakage into a non-zero exit before anything leaves the machine.
- `on-demand` publishes to `open-w2-project/w2-client` as a *side effect* of pushing `w2-server`. That repo has a pull-request workflow — its own README asks contributors to "abrir um pull request" (`packages/apps/client/README.md`), and 116 of its commits are merge commits (MEASURED). A skill that pushes branches into it implicitly, from a different repo, under a different licence, is the wrong default.
- **Two important limits on `check`.** It inspects only "submodule commits that **changed** in the revisions to be pushed" — a superproject push that does not move the gitlink checks nothing. And it looks at the submodule's remotes, so an unfetched or stale remote-tracking state can change the answer.

**Do not set `push.recurseSubmodules` in config.** Neither the local repo nor `~/.gitconfig` sets it today (MEASURED, §2.1), and a config value makes every future `git push` behave differently for everyone with the repo checked out — including plain `git push` typed by hand outside the skill. Pass the flag explicitly on the one command that needs it.

### 1.4 There is no atomicity across two repositories — say it plainly

Git guarantees atomicity in exactly two places, and neither spans repos:

- **Ref updates on one remote.** `git-push(1)`, *OPTIONS/--atomic*: "Use an atomic transaction on the remote side if available. Either all refs are updated, or on error, no refs are updated. If the server does not support atomic pushes the push will fail." One remote, many refs.
- **`git switch -c`.** `git-switch(1)`, *OPTIONS/-c*: "This is the transactional equivalent of `git branch <new-branch>` … `git switch <new-branch>` … that is to say, the branch is not reset/created unless git switch is successful." One repo, two operations.

Nothing in `git-submodule(1)`, `gitsubmodules(7)`, `git-commit(1)` or `git-push(1)` offers a two-repository transaction, and `on-demand`'s guarantee is explicitly one-directional: submodule first, superproject aborts if the submodule push failed (Pro Git 7.11). The reverse — superproject succeeds, submodule push fails — cannot happen under `on-demand`, but the intermediate state (submodule pushed, superproject not) is reachable and is left as-is.

**The standard mitigation, and what `w2-commit` should implement:** ordered writes so that every intermediate state is *safe* rather than *broken*, plus a verification gate. Every intermediate state in the §5.1 sequence is a state where the published history is consistent and the unpublished work is recoverable — which is the strongest property available without a transaction.

### 1.5 `git submodule update` — the destructive behaviour, corrected

`CLAUDE.md:19-21` states: "`git submodule update` destroys uncommitted submodule changes with no warning and no way back." **The warning is right, the mechanism is wrong**, and the accurate mechanism matters because it changes which command `w2-commit` must fear.

What plain `git submodule update` does — `git-submodule(1)`, *update*, `checkout` procedure (the default: "If neither is given, a checkout is performed"):

> "the commit recorded in the superproject will be checked out in the submodule **on a detached HEAD**."

That checkout obeys the usual refusal. Pro Git 7.11, *Working on a Submodule*:

> "**If you haven't committed your changes in your submodule and you run a `submodule update` that would cause issues, Git will fetch the changes but not overwrite unsaved work in your submodule directory.**"
>
> ```
> error: Your local changes to the following files would be overwritten by checkout:
> 	scripts/setup.sh
> Please, commit your changes or stash them before you can switch branches.
> Aborting
> Unable to checkout 'c75e92a…' in submodule path 'DbConnector'
> ```

So uncommitted **worktree** changes are protected by default. The three genuinely lossy paths are these, and each is documented:

1. **`git submodule update --force`.** `git-submodule(1)`, *OPTIONS/-f, --force*: "When running update (only effective with the checkout procedure), **throw away local changes in submodules when switching to a different commit**; and always run a checkout operation in the submodule, even if the commit listed in the index of the containing repository matches the commit checked out in the submodule."
2. **`git submodule deinit --force`.** Same option entry: "When running `deinit` the submodule working trees will be removed even if they contain local changes."
3. **Commits made on a detached HEAD, then updated away.** This is the irrecoverable one, and it is about *commits*, not worktree dirt — see §1.6.

Two further notes for the skill:

- The last clause of the `--force` text implies the safety property the skill can rely on: **without `--force`, no checkout runs at all when the gitlink already matches the submodule's `HEAD`.** In the common `w2-commit` case (client edits uncommitted, gitlink unmoved) a plain `git submodule update` is a no-op.
- **`git submodule update --remote` is the dangerous variant, and this repo's README recommends it.** `git-submodule(1)`, *OPTIONS/--remote*: "Instead of using the superproject's recorded SHA-1 to update the submodule, use the status of the submodule's remote-tracking branch… **update --remote fetches the submodule's remote repository before calculating the SHA-1**." It deliberately targets a *different* commit, so the checkout is real and the clobber-refusal is the only thing standing between upstream `main` and the local edits. `README.md:102` publishes exactly that command as the routine way to update the client. That instruction predates the decision to author client changes here and is now a hazard (§2.6).
- **`submodule.recurse`** turns recursion on for a long list of commands by default — `git-config(1)`, *submodule.recurse*: "checkout, fetch, grep, pull, push, read-tree, reset, restore and switch are always supported." It is unset here (MEASURED). Leave it unset; setting it makes an ordinary `git checkout` in the superproject move the submodule.

### 1.6 Detached HEAD: how submodules get there, and how to commit on a named branch

**How they get there.** Every routine submodule command lands on a detached HEAD:

- `git submodule update` in the default `checkout` procedure — "checked out in the submodule **on a detached HEAD**" (`git-submodule(1)`, *update*).
- `git clone --recurse-submodules` — "This is equivalent to running `git submodule update --init --recursive <pathspec>` immediately after the clone is finished" (`git-clone(1)`, *OPTIONS/--recurse-submodules*), so it inherits the same behaviour.

The two update procedures that do **not** detach are `--merge` ("If this option is given, the submodule's HEAD will not be detached") and `--rebase` (same sentence), both `git-submodule(1)`, *OPTIONS*.

**Why `CLAUDE.md`'s "never detached HEAD" rule is right.** `git-checkout(1)`, *DETACHED HEAD*:

> "There is now a new commit e, but it is referenced only by HEAD."
>
> "It is important to realize that at this point nothing refers to commit f. **Eventually commit f (and by extension commit e) will be deleted by the routine Git garbage collection process, unless we create a reference before that happens.**"

Pro Git 7.11 states the submodule-specific version: "With no working branch tracking changes, that means **even if you commit changes to the submodule, those changes will quite possibly be lost the next time you run `git submodule update`**."

A commit made on a detached HEAD inside a submodule is therefore both invisible to `git push --recurse-submodules=check` (no branch, nothing to push) and a garbage-collection candidate. That is the state a `w2-commit` run must never leave behind, and the state it must refuse to start from.

**How to commit on a named branch from inside the submodule.** `git -C packages/apps/client switch -c <branch>` — `git-checkout(1)`, *DETACHED HEAD*, lists it as recovery option (1): "creates a new branch foo, which refers to commit f, and then updates HEAD to refer to branch foo. In other words, we'll no longer be in detached HEAD state after this command." It works both as recovery (already detached, commits made) and as prevention (branch before editing).

**The pinned branch is configuration, not a constant.** `.gitmodules:4` sets `branch = main`, and `gitmodules(5)`, *submodule.\<name\>.branch*: "A remote branch name for tracking updates in the upstream submodule. If the option is not specified, it defaults to the remote HEAD." `git-config(1)`, *submodule.\<name\>.branch*: "Set this option to override the value found in the `.gitmodules` file." The skill must **read** it, not hardcode `main`:

```
$ git config -f .gitmodules --get submodule.packages/apps/client.branch
main
```

`git submodule set-branch (-b|--branch) <branch> [--] <path>` changes it (`git-submodule(1)`, *set-branch*). `w2-commit` has no reason to.

### 1.7 Detecting submodule state from a script — MEASURED

Three questions the skill must answer without ambiguity: *is the submodule dirty*, *has its HEAD moved relative to the gitlink*, and *is it on a branch*. Each has a stable, scriptable answer.

**Dirty vs. moved, from the superproject, in one command.** `git-status(1)`, *OUTPUT/Porcelain Format Version 2*, documents a dedicated 4-character `<sub>` field on every entry:

> "`<sub>` — A 4 character field describing the submodule state. `N...` when the entry is not a submodule. `S<c><m><u>` when the entry is a submodule.
> • `<c>` is "C" if the commit changed; otherwise ".".
> • `<m>` is "M" if it has tracked changes; otherwise ".".
> • `<u>` is "U" if there are untracked changes; otherwise "."."

Against this working tree (MEASURED):

```
$ git status --porcelain=v2 -- packages/apps/client
1 AM S.M. 000000 160000 160000 0000000000000000000000000000000000000000 378561c68b2f8a476850bf1f2cf2dbb71c1b31c6 packages/apps/client
```

Field 3 is `S.M.`: submodule, commit **not** changed, tracked changes present, no untracked. That is precisely "the client has uncommitted edits and the pin has not moved" — the state `w2-commit` exists to resolve — read from one read-only command in the superproject. This is the detection primitive to build on; the alternatives below are for reporting, not for branching.

**The blunter surfaces, and their defaults.** All of these were run against the same tree (MEASURED):

```
$ git status --porcelain -- packages/apps/client
AM packages/apps/client

$ git status --porcelain --ignore-submodules=dirty -- packages/apps/client
A  packages/apps/client                       # worktree column cleared: only the gitlink is left

$ git status --porcelain --ignore-submodules=all -- packages/apps/client
                                               # nothing at all

$ git submodule status
 378561c68b2f8a476850bf1f2cf2dbb71c1b31c6 packages/apps/client (heads/main)
```

- `git-status(1)`, *OPTIONS/--ignore-submodules[=\<when\>]* and `git-diff(1)`, *OPTIONS/--ignore-submodules[=(none|untracked|dirty|all)]* share four values: `none` "will consider the submodule modified when it either contains untracked or modified files or its HEAD differs from the commit recorded in the superproject"; `untracked`; `dirty` "ignore all changes to the work tree of submodules, **only changes to the commits stored in the superproject are shown**"; `all` "hide all changes to submodules". `dirty` is the flag that isolates "the pin moved" from "the client is dirty".
- `git submodule status` prefixes the SHA with "`+` if the currently checked out submodule commit does not match the SHA-1 found in the index of the containing repository" (`git-submodule(1)`, *status*). Human-readable, and the parenthesised `(heads/main)` is `git describe` output, not a promise that HEAD is attached.
- **`submodule.<name>.ignore` can hide all of this and must be checked.** `git-config(1)`, *submodule.\<name\>.ignore*: "When set to "all", it will never be considered modified (but it will nonetheless show up in the output of status and commit **when it has been staged**)". Not set in this repo (MEASURED, §2.1), but a skill that trusts `git status` without checking is one config line away from silent wrongness. `git-status(1)` and `git-diff(1)` both note the setting is overridable on the command line — so the robust move is for the skill to **always pass `--ignore-submodules=none` explicitly** rather than rely on the default.

**Is the submodule on a branch, and which one** (MEASURED):

```
$ git -C packages/apps/client symbolic-ref -q --short HEAD
main
   exit=0
```

`git-symbolic-ref(1)`, *OPTIONS/-q, --quiet*: "Do not issue an error message if the `<name>` is not a symbolic ref but a detached HEAD; instead **exit with non-zero status silently**." That is the detached-HEAD gate: exit 0 and a name means attached; non-zero means detached. `git branch --show-current` is the human-facing equivalent — "Print the name of the current branch. **In detached HEAD state, nothing is printed**" (`git-branch(1)`, *OPTIONS/--show-current*) — but it exits 0 either way, so it is worse for a gate.

**Is the submodule commit published** (MEASURED):

```
$ git -C packages/apps/client branch -r --contains HEAD
  origin/HEAD -> origin/main
  origin/main
```

Empty output means the commit is on no remote-tracking branch. This is the cheap local check; it reads remote-tracking refs, which can be stale. The authoritative check is `git push --recurse-submodules=check` (§1.3), which contacts the remote.

**Prose surfaces worth showing the human, not parsing** (MEASURED):

```
$ git diff --submodule=log HEAD -- packages/apps/client
Submodule packages/apps/client contains modified content
Submodule packages/apps/client 0000000...378561c (new submodule)

$ git submodule summary
* packages/apps/client 0000000...378561c (376):
  > Merge pull request #21 from oFelipe27/fix-invisible-walls-unable-to-click-on-map
```

`git-diff(1)`, *OPTIONS/--submodule[=\<format\>]*: "`--submodule=short` … just shows the names of the commits at the beginning and end of the range. When `--submodule` or `--submodule=log` is specified, the log format is used. This format **lists the commits in the range like `git-submodule(1) summary` does**. When `--submodule=diff` is specified … an inline diff of the changes in the submodule contents. **Defaults to `diff.submodule` or the short format if the config option is unset.**" This matters for §3.4: git already renders the commit list, so the superproject message should not duplicate it.

### 1.8 `git commit` in the superproject with a dirty submodule

`git-commit(1)` does not mention submodules at all (MEASURED: zero matches for "submodule" in the manpage). The behaviour follows entirely from §1.1:

- With the submodule dirty but its `HEAD` unmoved, the gitlink is **unchanged**, so a superproject commit records the old pointer and says nothing about the client edits. Confirmed by the `--ignore-submodules=dirty` output in §1.7: with worktree dirt discounted, the entry has no worktree-column change to stage.
- `git commit -a` will pick up a **moved** gitlink, because `git-commit(1)`, *OPTIONS/-a, --all*: "Automatically stage files that have been modified and deleted". A moved gitlink is a modified tracked entry. This is the mechanism by which a stray `git commit -am …` silently folds a pin bump into a content commit and violates `CLAUDE.md:15-16`. **`w2-commit` should stage explicitly and never use `-a`.**
- `git add packages/apps/client` records whatever the submodule's `HEAD` is at that instant — including a detached-HEAD commit, and including an unpushed one. Git does not check either.

---

## 2. This repo, as it actually stands

### 2.1 Observed state — MEASURED

```
$ git log --oneline -20
d45aa0f Initial commit

$ git show --stat --oneline d45aa0f
d45aa0f Initial commit
 LICENSE   | 201 ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
 README.md |   1 +

$ git branch -vv
* main d45aa0f [origin/main] Initial commit

$ git remote -v
origin	git@github.com:open-w2-project/w2-server.git (fetch)
origin	git@github.com:open-w2-project/w2-server.git (push)
```

The whole repo except `LICENSE` and a one-line `README.md` is **staged and uncommitted** — 60 entries in `git status --short`, including `CLAUDE.md`, `package.json`, `Cargo.toml`, all three apps, `docs/`, `openspec/`, `scripts/` and both skill trees. `w2-commit`'s first real run will therefore be an unusually large one.

`.gitmodules` (the whole file):

```
[submodule "packages/apps/client"]
	path = packages/apps/client
	url = https://github.com/open-w2-project/w2-client.git
	branch = main
```

```
$ git config -f .gitmodules --list
submodule.packages/apps/client.path=packages/apps/client
submodule.packages/apps/client.url=https://github.com/open-w2-project/w2-client.git
submodule.packages/apps/client.branch=main
```

Submodule state:

```
$ git submodule status
 378561c68b2f8a476850bf1f2cf2dbb71c1b31c6 packages/apps/client (heads/main)

$ git -C packages/apps/client status
On branch main
Your branch is up to date with 'origin/main'.

Changes to be committed:
	modified:   Projects/TMProject/D3DEnumeration.cpp
	modified:   Projects/TMProject/DXUtil.cpp
	modified:   Projects/TMProject/NewApp.cpp
	modified:   Projects/TMProject/TMProject.h
	modified:   Projects/TMProject/TMProject.rc
	modified:   Projects/TMProject/framework.h
	modified:   Projects/TMProject/pch.h
	modified:   Projects/TMProject/targetver.h
	modified:   README.md

$ git -C packages/apps/client branch -a
* main
  remotes/origin/HEAD -> origin/main
  remotes/origin/main

$ git -C packages/apps/client remote -v
origin	https://github.com/open-w2-project/w2-client.git (fetch)
origin	https://github.com/open-w2-project/w2-client.git (push)
```

**The submodule is attached, but it is on `main` — the pinned branch — with nine files staged.** `CLAUDE.md:13-15` forbids committing there ("never straight onto the pinned branch"). So `w2-commit`'s very first job on this tree is to refuse, and to hand back `git -C packages/apps/client switch -c <branch>` (§5.2). Note that `switch -c` carries the staged index across, so nothing is lost.

Relevant git config — **all defaults, nothing set** (MEASURED, `git config --list --show-origin`, filtered):

```
file:/home/nrechdan/.gitconfig	user.name=Nelson Faiçal Rechdan
file:/home/nrechdan/.gitconfig	user.email=rechdanfr@gmail.com
file:.git/config	submodule.packages/apps/client.url=https://github.com/open-w2-project/w2-client.git
file:.git/config	submodule.packages/apps/client.active=true
```

No `push.recurseSubmodules`, no `submodule.recurse`, no `status.submoduleSummary`, no `diff.submodule`, no `submodule.<name>.ignore`, no `submodule.<name>.branch` override, no `commit.template`, no `core.autocrlf`. The skill can therefore assume documented defaults — and should still pass its detection flags explicitly (§1.7).

### 2.2 The rules `CLAUDE.md` binds `w2-commit` to

Verbatim, `CLAUDE.md:13-33`:

> - Client changes may be authored from this repo, directly in the submodule working tree, and committed there on a named branch — **never on detached HEAD, never straight onto the pinned branch**. The pin bump stays its own commit in this repo, whose only content is the new pinned submodule commit.
> - **Commits inside the submodule are on hold right now.** That repo's commit-message convention is owned by **a skill that does not exist yet**, so client edits currently sit uncommitted in the working tree. This is a temporary state with a real expiry: `git submodule update` destroys uncommitted submodule changes with no warning and no way back. Run `git -C packages/apps/client status` before any command that could update the submodule.
> - The wire protocol is defined on both sides and both sides move. Packet structs and opcodes live in `Projects/TMProject/CPSock.cpp`, `Basedef.h`, and `Enums.h` — read the pinned commit before shaping a packet on the server side, and read it again after a bump.
> - When a protocol change needs both sides, land the client change in `w2-client` first, then bump the pin here **in the same commit as (or before)** the matching server change. The server must never target a protocol shape the pinned client does not have.
> - The decompiled code does not follow this repo's conventions. Don't take its style as a model for new Rust or TypeScript here, and keep cleanup work in the `w2-client` repo.
> - **The client is GPL v3; this repo is Apache-2.0.** Reading `CPSock.cpp` to learn the wire format is the intended use and the bullet above tells you to do it. Copying from it is not: no struct, no constant table, no enum body, no "translated" line-by-line port into Rust. Re-derive the shape from what the bytes must be, and cite the file rather than pasting it.

"a skill that does not exist yet" is `w2-commit`. Landing it retires that bullet.

The GPL/Apache separation is confirmed on both sides: `package.json:6` is `"license": "Apache-2.0"`, `Cargo.toml` `[workspace.package]` sets `license = "Apache-2.0"` (`CLAUDE.md:77`), and the submodule declares GPL v3 in its README — "The code is under the [GNU GPL v3](https://www.gnu.org/licenses/gpl-3.0.html)" (`packages/apps/client/README.md`; there is **no `LICENSE` file** in the submodule — MEASURED, the README is the only licence statement).

### 2.3 The tension, and how it resolves

Two of those bullets contradict each other:

- `CLAUDE.md:15-16` — "The pin bump stays its own commit in this repo, **whose only content** is the new pinned submodule commit."
- `CLAUDE.md:25-27` — "bump the pin here **in the same commit as** (or before) the matching server change."

A commit cannot both contain only the gitlink and also contain the server change. **Recommendation: the `:15-16` rule wins, and `:25-27` should be reduced to "before".** Reasons, in order of weight:

1. `:15-16` is a hard, checkable invariant (`git show --stat` on a pin bump lists exactly one path); "in the same commit as" is a scheduling preference.
2. A separate pin bump is the only shape under which `git push --recurse-submodules=check` gives a clean signal — `check` inspects "submodule commits that changed in the revisions to be pushed", and a one-path commit makes the reviewed unit and the checked unit identical.
3. It matches git's own documented workflow (`gitsubmodules(7)`, *WORKFLOW FOR A THIRD PARTY LIBRARY*), which commits the gitlink alone.
4. It matches the shape already published in this repo's README (`README.md:101-105`).

The constraint `:25-27` genuinely protects — "The server must never target a protocol shape the pinned client does not have" — is satisfied by **ordering**, not by co-location: pin bump before the server change, in the same push. `w2-commit` should produce commit 3 (pin) and commit 2 (server) in one run and push them together, so no pushed revision of `main` ever has a server change ahead of its client pin.

This is an edit `/docs-sync` should make to `CLAUDE.md`, not a hand-patch — `CLAUDE.md:151-154`.

### 2.4 What commit convention already exists here — almost nothing

Searched for, and **absent** (MEASURED):

| Artefact | Result |
| --- | --- |
| `.gitmessage` / any commit template | absent; `git config --get commit.template` exits 1 |
| commitlint / `.commitlintrc*` / husky | absent from the repo tree |
| `.git/hooks/*` | only the 14 `*.sample` files git ships |
| `CONTRIBUTING.md`, PR template | absent in both repos |
| Convention text in `openspec/config.yaml` | none — its `context:` block describes the stack and the submodule rules only |
| Convention text in `CLAUDE.md` | none — it says the convention "is owned by a skill that does not exist yet" |

**Present, and it is the only datum:** `README.md:101-105`, in the pt-BR section *"Atualizar o jogo (`client`)"*:

```bash
git submodule update --remote packages/apps/client
git add packages/apps/client
git commit -m "chore: bump client"
```

`chore: bump client` is Conventional Commits shape. It is one example, it is machine-generated by `docs-sync`, and it is the closest thing this repo has to a stated convention — which is a point in favour of §3.2's recommendation and against inventing something new.

`openspec/config.yaml`'s own commented example even suggests the phrase "We use conventional commits" as sample project context (`openspec/config.yaml`, the `# Example:` block) — a hint from the tooling, not a decision by this repo.

### 2.5 The `w2-client` history — MEASURED

846 commits total, **730 non-merge**. Style measurements across all 730 non-merge subjects:

| Measurement | Value |
| --- | --- |
| Subjects matching Conventional Commits (`type(scope)!: desc`) | **0** |
| Subjects starting with a `[Bracket]` prefix | 4 |
| Subjects ending with a period | 5 |
| Non-merge commits with a non-empty body | **2** |
| Mean subject length | 41.2 chars |
| Max subject length | 262 chars |
| Subjects over 50 chars | 154 |
| Subjects that look pt-BR | 1 |

First-word frequency, top of the distribution:

```
201 Implemented      13 Started      7 Removed
127 Decompiled       13 Some         7 More
 99 Fix              12 Descompiled  4 Updated
 37 Fixed            10 Finished     4 Changed
 29 Added            10 Change       3 Small
```

Verbatim examples, spanning the range (MEASURED, `git -C packages/apps/client log --oneline`):

```
a41aaeb fix request packet duel
5e8ef0c fixed wrong variable name of rgb color tones
4c4dc95 fix invisible walls "unable to click" on map
9108edd Closing files after use
d12d234 [BASE_CanEquip] renamed for better understanding
62d9e4d [SGrid] Otimizações no código, Criação da função HasSoulSkill() para StructMob
415bee3 [SGrid] Fix Equip item Celestial/Soul
7947fea Fixed sending the MSG_ApplyBonus packet using wrong structure
4f91b5b Implemented BASE_CanRefine
ac8b2ac Fix weapon check to unsigned int instead int
cbc71ab Code review in BASE_GetBonusItemAbility and BASE_GetBonusItemAbilityNosanc
b52fb69 Decompiled CItemMix::BASE_ReadMixList and CItemMix::BASE_WriteMixItemList
e0398cd Removed unused code
94b3a2d Fixed minimap texture (thanks francisco)
```

The two non-merge bodies, in full:

```
9108edd Closing files after use
        Some files remain locked until the application is closed because the _close method is never called.

e0398cd Removed unused code
        This code should not exist!!!!
```

**The pattern that emerges** — and it is remarkably consistent for 730 commits with no written rule:

- English, sentence case, no type prefix, no colon, no trailing period.
- A verb, then what changed, then — very often — the exact C++ symbol: `BASE_CanRefine`, `CItemMix::BASE_ReadMixList`, `MSG_ApplyBonus`, `TMHuman::SetAnimation`. This is not decoration; the tree is decompiled, so the diff alone is frequently unreadable and the symbol name is how a reader finds the change.
- Verb tense is split by *kind of change*, not arbitrary: new code is past-tense (`Implemented` 201, `Decompiled` 127, `Added` 29, `Removed` 7), repairs split between `Fix` (99) and `Fixed` (37).
- Bodies are for the non-obvious *why* and essentially nothing else — 2 in 730.
- `[Class]` bracket prefix exists but is a 4-in-730 minority: permitted, not required.

Branch names, recovered from merge subjects (MEASURED; the `user/` part is GitHub's fork prefix, not the branch):

```
tmdrop  citemmix  basedef  renderdevice  scontrolcontainer  texturemanager
tmhuman  tmobject  tmscene  tmsky  tmmesh  tmskinmesh  cframe  d3ddevice
github-actions
fix/locked-file  fix/not-loading-scene
fix-invisible-walls-unable-to-click-on-map
fixed-wrong-variable-name-of-rgb-color-tones
```

Dominant shape: **the lowercased C++ class or subsystem being worked on**. A `fix/<kebab>` minority exists. Nothing is written down anywhere; §6 makes this a user decision.

The repo's README states its conventions and stops short of commits — it covers hungarian variable naming, PascalCase class names, and then: "Como não temos um documento que dite todas as regras, caso surja uma dúvida, procure no código algum exemplo do que você está tentando fazer" (`packages/apps/client/README.md`). Reading the history for the pattern is literally what that repo tells you to do.

### 2.6 Documents that must change when `w2-commit` lands

Four claims currently say the opposite of what the skill will make true. All are generated or machine-consumed, so they change via `/docs-sync`, not by hand (`CLAUDE.md:149-156`):

1. `CLAUDE.md:17-21` — "Commits inside the submodule are on hold right now… a skill that does not exist yet". Retired by `w2-commit`.
2. `openspec/config.yaml`, `context:` block — "**do not commit them there yet**: that repo's commit convention is not settled, so edits stay uncommitted for now." Same retirement. `docs-sync`'s own guardrail already says this file is "read, never written" by that skill and that disagreements are *reported* (`.agents/skills/docs-sync/SKILL.md:68`) — so retiring this claim is a human edit that `docs-sync` will flag, not perform.
3. `README.md:102` — `git submodule update --remote packages/apps/client` as the routine client-update step. Dangerous under the new workflow (§1.5) and no longer the normal path.
4. `README.md:119` — `packages/apps/client/   # submódulo: o jogo em C++ (só leitura)`. "Read-only" contradicts `CLAUDE.md:13`.

Also note `CLAUDE.md:25-27` per §2.3, and `CLAUDE.md:19-21` per §1.5.

---

## 3. The commit-message convention

### 3.1 Conventional Commits v1.0.0 — what the spec actually says

<https://www.conventionalcommits.org/en/v1.0.0/>. The spec is RFC 2119-keyed: "The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in [RFC 2119]."

Structure:

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

The rules that bind:

- **1.** "Commits MUST be prefixed with a type, which consists of a noun, `feat`, `fix`, etc., followed by the OPTIONAL scope, OPTIONAL `!`, and REQUIRED terminal colon and space."
- **2/3.** `feat` for "new functionality to an application or library"; `fix` for "a bug repair".
- **4.** A scope "MAY be provided after a type. A scope MUST consist of a noun describing a section of the codebase surrounded by parenthesis, e.g., `fix(parser):`".
- **6.** "A longer commit body MAY be provided after the short description… The body MUST begin one blank line after the description."
- **11/13.** Breaking changes via a `!` before the colon or a `BREAKING CHANGE:` footer; "if used, the footer MAY be omitted".
- **14.** "Types other than `feat` and `fix` MAY be used in your commit messages, e.g., *docs: update ref docs.*"
- **15.** "The units of information that make up Conventional Commits MUST NOT be treated as case sensitive… with the exception of BREAKING CHANGE which MUST be uppercase."

Notably the spec pins no subject-length limit. That comes from git itself — `git-commit(1)`, *DISCUSSION*: "it's a good idea to begin the commit message with a single short (**no more than 50 characters**) line summarizing the change, followed by a blank line and then a more thorough description."

On adoption into an existing history, the FAQ is permissive rather than prescriptive: "Do all my contributors need to use the Conventional Commits specification? No! If you use a squash based workflow on Git lead maintainers can clean up the commit messages as they're merged."

### 3.2 Fit for `w2-server`: **yes**

- The repo has one commit ("Initial commit"). There is no history to contradict.
- The only convention artefact that exists here is already Conventional: `chore: bump client` (`README.md:104`).
- The stack is where the convention is native — a `package.json` root, Yarn workspaces, a Next.js app. Contributors arriving from that ecosystem expect it.
- The tooling on this machine already assumes it: the installed `caveman-commit` skill's entire rule set is Conventional Commits (`~/.claude/plugins/marketplaces/caveman/plugins/caveman/skills/caveman-commit/SKILL.md`), and `openspec/config.yaml`'s commented example offers "We use conventional commits" as sample context.
- Scopes have obvious, environment-derived values: the two Yarn workspaces and the submodule path.

**Recommended scope vocabulary**, all derivable from the tree so the skill can validate rather than memorise: `server`, `web`, `client`, `docs`, `skills`, `spec`, `build`, `deps`. `client` is reserved for the pin bump.

### 3.3 Fit for `w2-client`: **no**

Zero of 730 non-merge subjects are Conventional (§2.5). Imposing it would:

- make every new commit visually foreign in `git log` next to 730 that are not;
- break the one thing that history *does* consistently do, which is name the C++ symbol in the subject — Conventional's `<scope>` slot is a poor fit for `CItemMix::BASE_ReadMixList`, and cramming it there costs the 50-char budget twice over;
- contradict `packages/apps/client/README.md`'s own instruction to derive conventions by reading the code;
- and, most simply, impose this repo's taste on a repo that is not this repo — the same reasoning `CLAUDE.md:28-29` already applies in the other direction ("The decompiled code does not follow this repo's conventions").

**Per-repo patterns, not one blended pattern.** See §5.3 for both, filled in.

### 3.4 Referencing the submodule commit from the superproject message

What git already surfaces, so the message does not have to (§1.7, MEASURED):

- `git diff --submodule=log` and `git submodule summary` print the **full list of submodule commits** in the range, with subjects.
- `git log -p` on the pin bump shows the gitlink transition `-Subproject commit <old>` / `+Subproject commit <new>`.
- `status.submoduleSummary` (`git-config(1)`: "If this is set to a non-zero number or true… a summary of commits for modified submodules will be shown") and `diff.submodule` (`git-config(1)`: "Defaults to `short`") make this the default rendering for anyone who opts in.

So **re-listing the client commits in the superproject message is duplication** — it will be wrong the moment anyone rebases the client branch, and git renders it better anyway. What git does *not* surface, and what therefore earns its place in the message:

| Fact | Why the message must carry it | Surfaced by git? |
| --- | --- | --- |
| Which upstream repo | The gitlink is a bare SHA; `.gitmodules` is a separate file | No |
| Which **branch** the commit is on | A SHA does not name its branch; needed to find the PR | No |
| **Why** the pin moved | Intent is never in a SHA | No |
| The paired server commit, if any | Cross-repo causality | No |
| The list of client commits | — | **Yes** — omit |
| The old→new SHA pair | — | **Yes** — but the new short SHA is cheap and makes the subject searchable |

**Recommendation:** subject carries what the client change *does*; body carries short SHA + branch + `open-w2-project/w2-client`. One line, three facts. Cite `CPSock.cpp` / `Basedef.h` / `Enums.h` by path when the change is protocol-shaped — `CLAUDE.md:33` already says "cite the file rather than pasting it", which is both the licence-safe and the useful move.

### 3.5 Register: normal English, not caveman

The caveman skill installed on this machine carves out exactly this case — `~/.claude/plugins/marketplaces/caveman/plugins/caveman/skills/caveman/SKILL.md:78`, *Boundaries*:

> "Code/commits/PRs: **write normal**. "stop caveman" or "normal mode": revert. Level persist until changed or session end."

The ponytail skill draws the same line: "Ponytail governs what you build, not how you talk (pair with Caveman for terse prose)" (`ponytail` SKILL, *Boundaries*).

**So: commit messages produced by `w2-commit` are normal English prose, in both repos, regardless of the session's active style modes.** `w2-commit` should state this as a standing instruction in its body, because the modes are session-scoped and the skill's rendered content stays in context alongside them.

Language, separately: **English in both repos**. `w2-client`'s history is English at 729/730 subjects (MEASURED) despite a pt-BR README; `w2-server`'s pt-BR is scoped to `README.md` alone by the `docs-sync` contract (`.agents/skills/docs-sync/SKILL.md:36`, `:53`).

---

## 4. House rules `w2-commit` must satisfy

### 4.1 Location and mirroring — verified

```
$ ls -la .claude/skills
lrwxrwxrwx  docs-sync -> ../../.agents/skills/docs-sync
lrwxrwxrwx  grilling -> ../../.agents/skills/grilling
lrwxrwxrwx  research -> ../../.agents/skills/research
lrwxrwxrwx  writing-for-agents -> ../../.agents/skills/writing-for-agents
drwxr-xr-x  openspec-apply-change/     (real dir)
drwxr-xr-x  openspec-archive-change/   (real dir)
…
```

Confirmed: hand-managed skills are **symlinks** from `.claude/skills/<name>` into `../../.agents/skills/<name>`; the OpenSpec-generated ones are real directories duplicated in both trees. `.agents/skills/.openspec-target` contains `agents`.

**So `w2-commit` is authored at `/home/nrechdan/projects/w2-server/.agents/skills/w2-commit/SKILL.md` with a symlink `.claude/skills/w2-commit -> ../../.agents/skills/w2-commit`** — matching `docs-sync`, the most recent hand-authored precedent (`docs/researchs/docs-sync-skill.md` §6.1). The directory name must be `w2-commit`, since the invocable `/w2-commit` comes from the directory, not the `name` field. Do not add `.claude/commands/w2-commit.md`; that tree is OpenSpec-generated territory here.

`skills-lock.json` tracks only the three skills vendored from `mattpocock/skills` (`grilling`, `research`, `writing-for-agents`). `docs-sync` is absent from it, so hand-authored skills are not registered there — `w2-commit` should not be either.

### 4.2 Frontmatter

Follow `docs-sync` exactly (`.agents/skills/docs-sync/SKILL.md:1-8`), which is the local precedent and already spec-portable:

```yaml
---
name: w2-commit
description: Commit paired changes across w2-server and the w2-client submodule, in order.
allowed-tools: Bash(git:*) Read Grep
disable-model-invocation: true
license: MIT
---
```

`disable-model-invocation: true` is the right call and the repo's own rules mandate it. `SKILL-MECHANICS.md:12`: "Pick model-invocation only when the agent must reach the skill on its own, or another skill must. If it only ever fires by hand, make it user-invoked and pay no context load." `w2-commit` writes history in two repositories — the human triggers it, and nothing else needs to reach it. With the flag set, "the `description` becomes human-facing — a one-line summary, trigger lists stripped" (`SKILL-MECHANICS.md:10`), which is why the description above carries no trigger list.

### 4.3 Writing rules from `writing-for-agents`

Mandatory for the eventual `SKILL.md`, all from `.agents/skills/writing-for-agents/SKILL.md`:

- **Prompt the positive** (`:74`): "steering by prohibition drags the forbidden behaviour into context and makes it *more* available". This bites unusually hard here, because half of what `w2-commit` does is refuse. Write "commit on a named branch that is not the pinned branch", not "never commit on `main`". Reserve bare prohibition for the hard guardrails, and pair each with its positive target.
- **Single source of truth** (`:78`): state the two message patterns once each. Do not restate the pin-bump rule under every step.
- **The environment is a source of truth** (`:79`): the pinned branch comes from `git config -f .gitmodules --get …`, the upstream URL from the same place, the scope vocabulary from the workspace list. Instruct the agent to read them; do not cache `main` or the URL into the skill body, where they go stale on a `set-branch` or a remote move.
- **Completion criteria carry demand** (`:47-52`): `docs-sync` writes an explicit "Done when…" under every step (`.agents/skills/docs-sync/SKILL.md:16`, `:20`, `:24`, `:28`, `:32`). Match that shape. For the gates, the strong criterion is exhaustive — "every gate in *Refusals* evaluated against the tree as it now stands" — not "state looks fine".
- **Sprawl** (`:43`): keep it one file. The two message patterns plus the gates plus the sequence fit; `docs-sync` does comparable work in 89 lines.
- **Standing instructions, not one-time steps**: the rendered `SKILL.md` enters context once and is not re-read, so §3.5's register rule and the "explicit staging, never `-a`" rule are standing instructions, not step 4 footnotes.

---

## 5. Recommendation for `w2-commit`

### 5.1 The command sequence

Every command below is read-only until the numbered write steps. `$SM` = `packages/apps/client`; `$BR` = the pinned branch read from `.gitmodules`, never hardcoded.

**Phase 0 — read the world.**

```bash
BR=$(git config -f .gitmodules --get submodule.packages/apps/client.branch)
URL=$(git config -f .gitmodules --get submodule.packages/apps/client.url)
git status --porcelain=v2 --ignore-submodules=none -- packages/apps/client
git -C packages/apps/client symbolic-ref -q --short HEAD      # exit != 0 ⇒ detached
git -C packages/apps/client status --porcelain
git -C packages/apps/client diff --cached --stat
git status --short                                             # superproject staging
```

**Phase 1 — gates.** Evaluate every gate in §5.2. Any hard refusal ends the run with the fix printed; nothing is written.

**Phase 2 — commit the client (write #1).**

```bash
git -C packages/apps/client commit -m "<w2-client message, §5.3>"
NEW=$(git -C packages/apps/client rev-parse --short HEAD)
```

**Phase 3 — verify publishability, do not publish.**

```bash
git -C packages/apps/client branch -r --contains HEAD    # empty ⇒ unpublished
```

Empty is **expected** on a fresh topic branch and is not a failure — it is the reason phase 5 exists.

**Phase 4 — commit the superproject (writes #2 and #3), pin bump last.**

```bash
git commit -m "<w2-server message, §5.3>"          # explicit staging only; never -a
git add packages/apps/client                        # the gitlink alone
git commit -m "<pin-bump message, §5.3>"
git show --stat HEAD                                # verify: exactly one path
```

The `git show --stat` check is the enforcement of `CLAUDE.md:15-16`. Exactly one path, and it is `packages/apps/client`.

**Phase 5 — report the push commands; run neither.**

```
Client branch <branch> is not on any remote yet. To publish, in order:

  git -C packages/apps/client push -u origin <branch>
  git push --recurse-submodules=check

The second command refuses if the first has not happened.
```

`check` is the gate (§1.3). It is safe to *recommend* because it is read-only against `w2-client`.

### 5.2 Gates — what to detect, and what to refuse

| Gate | Detection (read-only) | Behaviour |
| --- | --- | --- |
| Submodule on **detached HEAD** | `git -C $SM symbolic-ref -q --short HEAD` exits non-zero | **Hard refuse.** Print `git -C $SM switch -c <branch>` and stop. Commits made here are gc-eligible (§1.6). |
| Submodule on the **pinned branch** | that command prints `$BR` | **Hard refuse.** `CLAUDE.md:13-15`. Print `git -C $SM switch -c <branch>`; the staged index carries over. **This is the current state of this tree** (§2.1). |
| **Nothing staged anywhere** | `git -C $SM diff --cached --quiet` exits 0 **and** `git diff --cached --quiet` exits 0 | **Hard refuse.** Nothing to commit; say what is unstaged instead of guessing. |
| Submodule **dirty but unstaged**, client change intended | porcelain v2 field 3 is `S.M.` / `S..U` while `diff --cached --quiet` exits 0 | **Report, ask.** Do not `git add -A` inside someone else's repo — name the files and let the human stage. |
| **Gitlink moved without a client commit this run** | field 3 has `<c>` = `C` on entry to phase 1 | **Report.** Someone already moved the submodule HEAD; the pin bump would import a commit this run did not create. Confirm before proceeding. |
| Client commit **not on any remote** at phase 3 | `git -C $SM branch -r --contains HEAD` empty | **Not a failure.** Record it and drive phase 5. Escalate to a refusal only if the human asked the skill to push. |
| **Superproject push attempted with an unpublished gitlink** | `git push --recurse-submodules=check` exits non-zero | Git's own gate. Surface its message verbatim; it already names the fix. |
| **`submodule.<name>.ignore` set** | `git config --get submodule.packages/apps/client.ignore` | **Warn.** Detection surfaces may be lying (§1.7). Pass `--ignore-submodules=none` regardless. |
| `.gitmodules` **branch unset** | the `--get` returns empty | Fall back to the remote HEAD per `gitmodules(5)`, and say so rather than assuming `main`. |

### 5.3 The two message patterns

**Pattern A — `w2-server` (this repo): Conventional Commits v1.0.0.**

```
<type>(<scope>): <imperative description>

[body: why, wrapped at 72]

[footers]
```

- Types: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `build`, `ci`, `chore`, `revert`. Breaking: `!` before the colon (spec rule 13).
- Scopes, from the environment: `server`, `web`, `client`, `docs`, `skills`, `spec`, `build`, `deps`.
- Imperative mood, lowercase after the colon, no trailing period, subject ≤50 chars where it fits and ≤72 always (`git-commit(1)`, *DISCUSSION*).
- Body only for a non-obvious *why*.

Examples:

```
feat(server): decode the duel-request packet

Pairs with the client change pinned in the following commit. Packet
layout re-derived from Projects/TMProject/CPSock.cpp at 378561c —
not copied; the client is GPL v3 and this crate is Apache-2.0.
```

```
docs(skills): add the w2-commit skill

Retires the "commits inside the submodule are on hold" bullet in
CLAUDE.md and the matching claim in openspec/config.yaml.
```

```
chore(deps): pin nodemon to 3.1.14 at the root
```

**Pattern A′ — the pin bump.** Same grammar, always scope `client`, always exactly one path staged. The type mirrors what the client change *is*, so a protocol feature reads as a feature on both sides of the changelog.

```
feat(client): send the duel request with the corrected struct

Pins packages/apps/client to a41aaeb on fix/duel-request-packet
(open-w2-project/w2-client).
```

```
fix(client): stop the map click-through on invisible walls

Pins packages/apps/client to 4c4dc95 on fix-invisible-walls
(open-w2-project/w2-client).
```

```
chore(client): bump the pin to 378561c

Pins packages/apps/client to 378561c on main
(open-w2-project/w2-client). Routine upstream sync, no protocol change.
```

The body is one sentence and three facts — short SHA, branch, upstream — because everything else is already rendered by `git diff --submodule=log` (§3.4).

**Pattern B — `w2-client` (the submodule): the observed house style.**

```
<Verb> <what changed>[ in <Class>::<Function>]
```

- English, sentence case, **no type prefix, no colon, no trailing period**.
- Verb by kind of change, matching the measured distribution (§2.5): `Implemented` / `Decompiled` / `Added` / `Removed` for new or moved code, `Fixed` (or the equally established `Fix`) for repairs.
- **Name the C++ symbol** when one identifies the change. The tree is decompiled; the symbol is how the next reader finds it.
- Subject ≤50 chars where it fits, ≤72 always. The history's mean is 41.2 (MEASURED), so this is descriptive, not restrictive.
- A body only for a non-obvious *why* — 2 of 730 commits have one. **A wire-protocol change is one of those cases**, because `w2-server` depends on the shape and the pin-bump body will point back here.
- An optional `[Class]` prefix exists in the history (4 of 730). Permitted; the plain form is the default.

Examples:

```
Fixed the duel request packet structure
```

```
Implemented CPSock::OnPacketDuelRequest

The old handler read the struct one field short, so the server's
reply was parsed at the wrong offset. Server side changes with it.
```

```
Decompiled TMFieldScene::CheckMerchant
```

### 5.4 What `w2-commit` should NOT do

- **Not push.** Pushing to `w2-client` publishes to a different repository, under a different licence, whose README asks for pull requests. The skill verifies publishability and prints the two commands in order (§5.1 phase 5). This also matches the local precedent: `caveman-commit`'s *Boundaries* — "Does not run `git commit`, does not stage files, does not amend."
- **Not run `git submodule update` in any form.** It is the one command that can move the submodule's HEAD out from under the work, `--remote` targets a *different* commit and so does real damage (§1.5), and `--force` is documented to "throw away local changes". `w2-commit` has no reason to touch it: the pin it wants is already in the worktree.
- **Not amend.** `git-commit(1)`, *OPTIONS/--amend*: "Replace the tip of the current branch by **creating a new commit**." Amending a client commit whose SHA a superproject gitlink already records orphans that gitlink — the superproject then points at a commit no branch reaches, which is §1.2's permanent breakage arriving by a different door. If a message needs fixing before anything is pushed, redo the run; after a pin bump exists, fix it forward.
- **Not write git config.** No `push.recurseSubmodules`, no `submodule.recurse`. Both change the behaviour of every future hand-typed `git push` / `git checkout` for everyone with the repo (§1.3, §1.5). Pass flags on the command that needs them.
- **Not use `git commit -a`.** It stages a moved gitlink into a content commit (§1.8) and silently violates `CLAUDE.md:15-16`.
- **Not stage inside the submodule on its own.** Report unstaged client files and let the human choose; the skill's job is the ordering and the messages, not deciding what belongs in someone else's commit.
- **Not fold the pin bump into the server commit**, even when both are ready in the same run — §2.3.
- **Not claim to police the licence boundary.** The GPL/Apache-2.0 risk in `CLAUDE.md:30-33` is about *code* crossing from `CPSock.cpp` into Rust, and no commit-time check detects a re-typed struct. What the skill can honestly do is two cheap things: keep the two commits' contents in their own repos (which git enforces anyway), and instruct the superproject body to **cite** client files by path and SHA rather than quote them — which `CLAUDE.md:33` already asks for.

### 5.5 Suggested section outline

```
frontmatter                (§4.2)
one-line purpose           — three commits, two repos, one order
Steps                      — phases 0-5 (§5.1), each with a "Done when…"
Refusals                   — the gate table (§5.2)
w2-server messages         — pattern A + A′ with examples (§5.3)
w2-client messages         — pattern B with examples (§5.3)
Guardrails                 — §5.4, phrased positively per writing-for-agents:74
```

Standing instructions to place outside the step list, because the rendered file is read once: commit messages are normal English regardless of active style modes (§3.5); staging is always explicit; the pinned branch and upstream URL are read from `.gitmodules` every run.

---

## 6. Open questions the user must decide

1. **Does `w2-commit` push?** Recommendation: no — verify and print. If it should, the flag is `git push --recurse-submodules=check` on the superproject *after* an explicit client push; `on-demand` should stay off the table (§1.3).
2. **Branch-name pattern in `w2-client`.** The history offers three shapes with no written rule: lowercased class/subsystem (`tmdrop`, `citemmix`, `renderdevice` — the plurality), `fix/<kebab>`, and bare `<kebab-summary>` (§2.5). Pick one, or let the skill propose and the human confirm. This is upstream taste, not ours.
3. **Does the skill create the client branch, or refuse and hand back the command?** Creating it is cheap and `switch -c` carries the staged index. Refusing keeps branch naming a human call in a repo we do not own. §5.2 assumes refuse-and-hand-back; either is defensible.
4. **`CLAUDE.md:25-27` vs `:15-16`.** §2.3 recommends "before", not "in the same commit as". Confirm, then let `/docs-sync` make the edit.
5. **Does `w2-commit` cover the degenerate cases** — a server-only change, a client-only change, a pin bump with no local client work? Recommendation: yes, as short-circuit paths through the same gates; a skill that only handles the paired case will be worked around on the days it does not apply.
6. **Verb tense in `w2-client`.** §5.3 pattern B recommends past tense with `Fix` accepted, following the measured split. This deliberately contradicts git's own imperative convention and pattern A — confirm that the inconsistency between the two repos is wanted, because it is the whole point of having two patterns.
7. **Retiring the "commits are on hold" claims** in `CLAUDE.md:17-21` and `openspec/config.yaml` (§2.6). `docs-sync` reports disagreements in `openspec/config.yaml` but never writes it, so that one is a deliberate human edit.
8. **The first run is not a normal run.** 60 staged entries, the submodule staged on the pinned branch (§2.1). Decide whether that lands as one "Initial commit"-style superproject commit or a split, before the skill is pointed at it.

---

## 7. Open questions / not verified

- **Which ref `push --recurse-submodules=on-demand` pushes is not documented.** `git-push(1)` says only "all submodules that changed in the revisions to be pushed will be pushed". Pro Git's transcript shows `stable -> stable`, i.e. the submodule's current branch, but no manpage states it and nothing documents the detached-HEAD case. Moot under the §5.4 recommendation, which never uses `on-demand`.
- **`git submodule update`'s clobber-refusal has no manpage sentence.** The protection is stated in Pro Git 7.11 and implied by `git-submodule(1)`'s `--force` text ("throw away local changes… when switching to a different commit"), not asserted directly in any manpage. §1.5 rests on those two plus the absence of any contrary statement. Not reproduced here — doing so would require writing git state.
- **The `+` prefix on `git submodule status` was not observed**, because this tree's gitlink currently matches the submodule HEAD. Cited from `git-submodule(1)`, *status* only.
- **`git add packages/apps/client` was not executed** (read-only constraint). §1.1's conclusion is derived from the measured index/HEAD divergence plus `gitsubmodules(7)`'s gitlink definition and workflow snippet. The inference is tight, but it is an inference.
- **Whether `Skill(...)` is valid inside `allowed-tools`** — same caveat the `docs-sync` note recorded (`docs/researchs/docs-sync-skill.md` §7). `w2-commit` needs no `Skill(...)` entry, so it does not arise.
- **The `w2-client` upstream may have moved** past the pinned `378561c`. All history measurements are against the pinned commit as checked out, with no fetch performed. Re-measure after a pin bump before treating §2.5's numbers as current.
- **No CI enforces either pattern.** `w2-client` ships two GitHub Actions workflows (`msbuild.yml`, `manual_workflow.yml`) and neither lints commit messages; `w2-server` has no workflows at all. Both patterns are conventions upheld by the skill and by review, not by a gate.
- **The 116 merge commits in `w2-client` were not analysed for message style.** They are GitHub's generated "Merge pull request #N from user/branch" text, so their shape is a property of the platform rather than of the project, and `w2-commit` never produces one.
