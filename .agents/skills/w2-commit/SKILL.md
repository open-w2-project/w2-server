---
name: w2-commit
description: Commit and push paired changes across w2-server and the w2-client submodule, in order.
allowed-tools: Bash(git:*) Read Grep
disable-model-invocation: true
license: MIT
---

One `w2-commit` run produces **three commits in two repositories, in one fixed order**: the client
change in `w2-client`, then the server/web change here, then the pin bump alone. Git offers no
atomicity across repositories — `--atomic` is scoped to a single remote's refs — so the order plus
the `--recurse-submodules=check` gate at the end is the whole guarantee. A gitlink that names a
commit nobody can fetch is permanent breakage for everyone who clones; that check is what prevents it.

Commit messages are normal English prose, whatever style modes are active in the session.

## Steps

1. **Read the world.** Every value comes from the tree, none from this file:

   ```bash
   git config -f .gitmodules --get submodule.packages/apps/client.branch   # the pinned branch
   git config -f .gitmodules --get submodule.packages/apps/client.url      # upstream
   git config --get submodule.packages/apps/client.ignore                  # detection may be lying
   git -C packages/apps/client symbolic-ref -q --short HEAD                # non-zero ⇒ detached
   git -C packages/apps/client remote
   git -C packages/apps/client status --porcelain
   git -C packages/apps/client diff --cached --stat
   git status --porcelain=v2 --ignore-submodules=none
   ```

   An empty `--get` for the branch means the pin follows the remote HEAD; say so rather than
   assuming a name. Read the staged diffs on both sides — the messages in **w2-server messages**
   and **w2-client messages** are written from what actually changed.

   Done when the pinned branch, the upstream URL, the submodule's current branch, and both
   staging areas are known.

2. **Evaluate every gate in Refusals** against the tree as it now stands. A hard refusal ends the
   run with the fix printed and nothing written.

   Done when every row of that table has been evaluated, not just the ones that looked likely.

3. **Commit the client.** Write the message to **w2-client messages**.

   ```bash
   git -C packages/apps/client commit -m "<message>"
   git -C packages/apps/client rev-parse --short HEAD
   ```

   Done when that short SHA is in hand — the pin-bump body in step 4 quotes it.

4. **Commit the superproject, pin bump last.** Stage explicitly, path by path.

   ```bash
   git commit -m "<server/web message>"    # skip when this run has no server/web change
   git add packages/apps/client            # the gitlink alone
   git commit -m "<pin-bump message>"
   git show --stat HEAD
   ```

   Done when `git show --stat HEAD` lists exactly one path and it is `packages/apps/client`.

5. **Push, client first.** The order is the point: the second command refuses if the first has not
   happened.

   ```bash
   git -C packages/apps/client push -u <remote> <branch>
   git push --recurse-submodules=check
   ```

   Name the destination remote and branch of both pushes in the output before running them, so a
   surprising destination is visible rather than discovered afterwards. A non-zero exit from
   `check` means the gitlink is unfetchable — surface git's message verbatim; it names the fix.

   Done when both commands exit 0.

6. **Report.** The three commit subjects, the client branch and its remote, the pinned SHA before
   and after, and anything a gate reported without refusing.

   Done when each of those is stated.

## Refusals

| Situation | Detection | Behaviour |
| --- | --- | --- |
| Submodule on detached HEAD | `symbolic-ref -q --short HEAD` exits non-zero | **Refuse.** Print `git -C packages/apps/client switch -c <branch>` and stop. A commit made here is unreachable and gc-eligible. |
| Submodule on the pinned branch | that command prints the pinned branch | **Refuse.** Print the same `switch -c` — the staged index carries over. Branch naming belongs to the human; hand back the command with the name left blank. |
| Nothing staged on either side | `diff --cached --quiet` exits 0 in both repos | **Refuse.** Report what is unstaged instead of guessing what belongs in the commit. |
| Submodule dirty but unstaged | porcelain field 3 shows `.M`/`.U` while `diff --cached --quiet` exits 0 | **Report and ask.** Name the files; the human stages inside their own repo. |
| Gitlink already moved before this run | porcelain v2 field 3 shows `C` at step 1 | **Report and confirm.** The pin bump would import a commit this run did not create. |
| `submodule.<name>.ignore` is set | the `--get` returns a value | **Warn**, and pass `--ignore-submodules=none` on every status and diff — the default surfaces would be under-reporting. |

## w2-server messages

Conventional Commits v1.0.0.

```
<type>(<scope>): <imperative description>

[body: the non-obvious why, wrapped at 72]
```

Types `feat` `fix` `refactor` `perf` `docs` `test` `build` `ci` `chore` `revert`; `!` before the
colon marks a breaking change. Scopes come from the workspace layout: `server` `web` `client`
`docs` `skills` `spec` `build` `deps`. Imperative mood, lowercase after the colon, no trailing
period, subject ≤72 characters.

```
feat(server): decode the duel-request packet

Packet layout re-derived from Projects/TMProject/CPSock.cpp at 378561c
— cited, not copied; the client is GPL v3 and this crate is Apache-2.0.
```

```
chore(deps): pin nodemon to 3.1.14 at the root
```

**The pin bump** uses the same grammar with scope `client` always, and a type mirroring what the
client change *is*, so a protocol change reads as a feature on both sides of the history. Its body
is one sentence and three facts — short SHA, branch, upstream — because `git diff --submodule=log`
already renders the rest.

```
feat(client): send the duel request with the corrected struct

Pins packages/apps/client to a41aaeb on fix/duel-request-packet
(open-w2-project/w2-client).
```

## w2-client messages

The house style measured across that repo's history — 730 commits, no Conventional Commits subject
among them. Follow the history, not this repo's pattern.

```
<Verb> <what changed>[ in <Class>::<Function>]
```

English, sentence case, no type prefix, no colon, no trailing period. The verb tracks the kind of
change: `Implemented`, `Decompiled`, `Added`, `Removed` for new or moved code, `Fixed` or `Fix` for
repairs. **Name the C++ symbol** whenever one identifies the change — the tree is decompiled, so the
symbol is how the next reader finds the diff. Subject ≤72 characters; the history's mean is 41.

Bodies are rare there (2 of 730) and earn their place only for a non-obvious why. A wire-protocol
change is one of those: the server depends on the shape, and the pin-bump body points back here.

```
Decompiled TMFieldScene::CheckMerchant
```

```
Implemented CPSock::OnPacketDuelRequest

The old handler read the struct one field short, so the server's reply
was parsed at the wrong offset. Server side changes with it.
```

## Guardrails

- **Stage explicitly, path by path, in both repos.** `git commit -a` sweeps a moved gitlink into a
  content commit, which is exactly what the separate pin-bump commit exists to prevent.
- **The pin bump is its own commit**, containing the gitlink and nothing else, even when the server
  change is ready in the same run. That single-path invariant is what `--recurse-submodules=check`
  is checking on a shape it can reason about.
- **Leave staging inside the submodule to the human.** This skill owns the ordering and the
  messages; deciding what belongs in a commit in someone else's repository is theirs.
- **Leave `git submodule update` alone in all its forms.** The pin this run wants is already in the
  worktree. `--remote` deliberately targets a different commit, and `--force` is documented to throw
  away local changes.
- **Fix a bad message forward.** Amending creates a new commit, so amending a client commit whose
  SHA a pin bump already records orphans that gitlink. Before anything is pushed, redo the run.
- **Pass flags on the command that needs them**, leaving `push.recurseSubmodules` and
  `submodule.recurse` unset — writing those changes every future hand-typed `git push` and
  `git checkout` for everyone with the repo.
- **Cite client code by path and SHA in superproject bodies.** The client is GPL v3 and this repo is
  Apache-2.0; a reference carries the same information as a quotation and none of the risk.
