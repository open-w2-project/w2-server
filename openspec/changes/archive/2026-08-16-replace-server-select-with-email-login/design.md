## Context

See `proposal.md` — Why. Constraints that shape the approach:

- **The client is decompiled C++ under active cleanup.** Its conventions are not this repo's, and
  large swathes of the login path are dead: the credential-mangling block, `CheckPKNonePK`, the
  keyword rolling formulas, `m_cConnected`. Removing them is a side effect of this change, not its
  purpose, but it is free while the surrounding code is being rewritten anyway.
- **Struct layouts are derived, not measured.** Every offset and `sizeof` in
  `docs/researchs/client-server-list.md` §4, §5 was computed from the MSVC 32-bit ABI by reading the
  source; the client was never compiled to check them (§9.3). This change moves those layouts, so it
  is the moment to make the compiler prove them.
- **The UI resource is not in this repository.** `TMScene::LoadRC("UI\\SelServerScene2.txt")` rewrites
  the name and reads `UI\SelServerScene2.bin` (`TMScene.cpp:291-307`), a binary asset that lives in a
  game install. Control geometry, the identity field's character limit and its pixel width all come
  from there (`UIBinary.h:102-119`). So does every user-facing string, via `UI\strdef.bin`.
- **The only build path is msvc-wine under WSL2**, `Release|x86` only. There is no test harness in
  the client repository; a compile plus a manual run against the local server is the whole
  verification story.
- **The server does not implement login.** `packages/apps/server/src/main.rs` accepts TCP on 8281 and
  discards everything. Nothing on that side pins the current wire shape.

## Goals / Non-Goals

**Goals:**

- Make the login path self-contained: no data files, no HTTP fetch, no selection step.
- Fix the wire shape now, while it is free to change, and make the compiler verify it.
- Leave the client's naming honest — nothing called "select server" should survive.

**Non-Goals:**

- Editing `UI\SelServerScene2.bin` or `UI\strdef.bin`. Everything this change needs is reachable by
  overriding control properties in code after `LoadRC` and by reusing existing string indices.
- Broader cleanup of the decompiled client. Only code that the removals make unreachable or
  uncompilable is touched.
- Any server or web change. Capacity, account storage and password handling are the server's
  problem, in a later change.

## Decisions

### Renames keep their numeric values

`TM_LOGIN_STATE = 3` and `ESCENE_LOGIN = 0x7532` already exist and are referenced nowhere. The live
values are `TM_SELECTSERVER_STATE = 7` and `ESCENE_SELECT_SERVER = 0x7534`.

Rename the live values in place — keeping 7 and `0x7534` — and delete the two orphans.

*Alternative rejected:* repoint every call site at the existing 3 / `0x7532` and delete 7 / `0x7534`.
Identical end state, but it churns the numeric values of a scene id that is also written into
`m_dwID`, for no gain.

`ESCENE_SELECT_SERVER` is read by five places that have nothing to do with server selection
(`EventTranslator.cpp:269`, `TMSkillMeteorStorm.cpp:531`, `TMFieldScene.cpp:545`, `TMGround.cpp:2768`,
`TMHuman.cpp:3043`) — they gate rendering and input on "am I in the pre-game scene". Pure rename.

### The disconnect guard is allowed to go live

`TMScene.cpp:863,878` reads `if (m_eSceneType != ESCENE_LOGIN) SetCurrentState(...)`. Because no scene
ever sets `ESCENE_LOGIN` today, that condition is always true and the login scene tears itself down
and rebuilds on every disconnect. After the rename it becomes false in the login scene, and the
screen survives a failed connection with its fields intact.

That is a behaviour change hidden inside a rename, taken deliberately: it matches the guard's evident
intent, and `client-login`'s "Disconnection on the login screen does not rebuild the screen"
requirement now depends on it.

### Endpoint is a build-time macro, not a source constant

Define it next to `TM_CONNECTION_PORT` in `Basedef.h`:

```
#ifndef W2_SERVER_HOST
#define W2_SERVER_HOST "localhost"
#endif
```

so a build can retarget with `/D W2_SERVER_HOST="\"play.example.com\""` without editing tracked
source.

*Alternative rejected:* a plain `constexpr auto`. Same default, but every retarget becomes a source
edit and a dirty working tree in a submodule that is already awkward to commit to.

`NewApp::m_szServerIP` is deleted rather than filled from the macro. After the field-scene removal it
has exactly one remaining reader; passing the macro straight to `ConnectServer` removes a global.

### `getaddrinfo`, IPv4 only

`CPSock::ConnectServer:137` uses `inet_addr`, so only dotted quads work. Replace with `getaddrinfo`
hinted to `AF_INET` / `SOCK_STREAM`, take the first result, `freeaddrinfo`. `ws2_32` is already
linked; no new dependency.

*Alternatives rejected:* `gethostbyname` (deprecated, not thread-safe, no benefit here); dual-stack
IPv6 (the rest of `CPSock` is `sockaddr_in` throughout — supporting v6 means reworking bind, connect
and the retry ladder for a server that does not listen on v6).

`CPSock::SingleConnect` has the same `inet_addr` call and is never called from anywhere
(`CPSock.h:19`, `CPSock.cpp:199`, zero callers). Left alone — touching it is scope creep.

### `TID[52]` is deleted, not reserved

Its only consumer was the channel hop: the server minted it on the origin channel and the client
echoed it on the destination connection. With the hop gone it is 52 zero bytes on every request.

*Alternative rejected:* keep it as a reserved field for a future session token. Re-adding a field
costs nothing while no server parses the struct, and carrying dead bytes invites someone to
rediscover the hop protocol from them later.

### Delete the picker rather than hide it

The minimal change satisfying the user-visible requirements is roughly thirty lines: show the login
panel at scene init, fill the endpoint from a constant, relax validation, drop the capacity gate. It
would leave the three file loaders, the HTTP fetch and the whole picker intact but unreachable.

Deleting instead, because the proposal requires the data files to stop being read at all — and once
`g_pServerList` is gone, the field scene's channel panel does not compile, so its removal is forced
rather than optional.

### Struct sizes get `static_assert`

Add a `static_assert(sizeof(T) == N)` for each login-path struct — `MSG_STANDARD`,
`MSG_AccountLogin`, `MSG_CNFAccountLogin`, `STRUCT_SELCHAR`, `STRUCT_ITEM` — asserting the sizes the
specs state. Zero runtime cost, and it converts the research note's biggest unverified claim into a
build failure if wrong. The two padding runs in the accept response (offsets 28 and 1972) exist only
because `STRUCT_SELCHAR` ends in `long long Exp[4]` and is therefore 8-aligned; a Rust
reimplementation that concatenates fields naively will disagree, so the number is worth pinning here.

### Email validation is a shape check, not RFC 5322

One `@` with something before it, a `.` somewhere after it, total length 6..63. Anything stricter
belongs on the server, which is the only side that can actually decide whether an address exists.

Validation failures reuse the existing message-string indices 3, 4 and 5 (`TMSelectServerScene.cpp`
`:658`, `:668`, `:678`). `UI\strdef.bin` is not in the repository, so no new string can be added; the
existing three read as "too short", "too long" and "bad password", which covers the new cases well
enough.

### Field widths are overridden in code

After `LoadRC`, set `m_pEditID->m_nMaxStringLen = 63` and widen the control. The picker panel is
simply never made visible. No asset editing, and an install with the old `SelServerScene2.bin`
still works.

### Version 1759

An increment off 1758, chosen because nothing else in the client reads the field and a distinct value
is all a future server needs. Change it freely before implementation if a versioning scheme emerges.

## Risks / Trade-offs

- **Derived struct layouts could be wrong** → `static_assert` on every login-path struct; a mismatch
  fails the build rather than producing a silent wire bug.
- **The login panel may be positioned assuming a picker behind it** → its position is recomputed at
  runtime from screen dimensions (`TMSelectServerScene.cpp:159-160`), so it should centre correctly,
  but this needs a visual check against a real install before the pin bump.
- **A widened identity field may overflow the panel art** → the control's width is set in code; if
  the artwork cannot accommodate a 63-character field, fall back to a narrower control that scrolls
  its text rather than editing the asset.
- **`SListBoxServerItem` may have a consumer outside the two removed screens** → confirm by grep
  before deleting; if one exists, leave the class and remove only its two call sites.
- **No automated verification exists for the client** → the check is a `Release|x86` build plus a
  manual login against the local Rust server, which currently accepts the connection and answers
  nothing. That exercises connect, handshake and send, but not the accept response. The response
  layout rests on `static_assert` alone until the server implements login.
- **Retargeting the endpoint requires a rebuild and redistribution** → accepted; it is the direct
  consequence of the "IP lives with the compiled client" decision, and the `/D` override at least
  keeps it out of tracked source.
- **Passwords stay plaintext under a broken cipher** → out of scope, recorded as a non-goal in the
  proposal. It gets worse as a risk once accounts are email-keyed and passwords are reused, so it
  should become its own change before any public deployment.

## Migration Plan

No data migration: there is nothing deployed. Ordering only.

1. Land the whole change on a named branch in `w2-client`. It is one commit's worth of work; splitting
   it does not produce intermediate states that build, because deleting `g_pServerList` breaks the
   field scene in the same step.
2. Build `Release|x86` via `scripts/build-client.sh` and confirm the `static_assert`s pass.
3. Run against the local server and confirm the login screen appears first, accepts an email, and
   reaches the connect.
4. Only then bump the submodule pin here, as its own commit, per `CLAUDE.md`.

Rollback is reverting the client branch. The pin never moves until the client builds, so this repo
cannot end up pointing at a broken commit.

**Note:** `openspec/config.yaml` still says client edits "stay uncommitted for now" because the commit
convention is unsettled. `CLAUDE.md` has since settled it — `/w2-commit` owns the paired case and
fixes the ordering. The config should be refreshed; this change follows `CLAUDE.md`.

## Open Questions

- What hostname non-local builds should use. Deferred deliberately: it is a `/D` flag at build time
  and changing it touches no tracked source.
- Whether the login panel needs manual repositioning once the picker is gone. Answered by looking at
  the built client, not by more reading.
