## Why

The client's login flow is built around a server-group and channel picker that this project will
never feed. The picker's entire data source is three obfuscated binary files shipped next to the
executable (`serverlist.bin`, `sn.bin`, `sn2.bin`) plus a plain-HTTP population feed whose URL is
itself stored in one of those files. None of it travels over the game protocol, and none of it is
something the Rust server will produce.

At the same time the account model is moving to email and password. The current wire shape cannot
carry an email: `MSG_AccountLogin.AccountName` is `char[16]`, and the login screen rejects anything
longer than 12 characters before it reaches the socket.

Since the server has no login handling yet, the wire shape is client-authored right now. Widening it
later, against a running server, is far more expensive than widening it today.

## What Changes

**Login screen**

- The login panel is visible on entering the scene. The server-group list, the channel list and the
  "select server" panel are removed, along with the fade transition between picker and login.
- The identity field accepts an email address instead of a 4..12 character account name.
- The connection target is a compile-time hostname, defaulting to `localhost`. Port stays 8281.

**Wire protocol** — **BREAKING**

- `MSG_AccountLogin.AccountName` widens `[16]` → `[64]`; `AccountPass` widens `[16]` → `[64]`.
- `MSG_AccountLogin.TID[52]` is deleted. Its only purpose was carrying the channel-hop handoff token,
  and the hop is going away; on a first login it was always 52 zero bytes. `sizeof` goes 120 → 164.
- `MSG_CNFAccountLogin.AccountName` widens `[16]` → `[64]`.
- `MSG_AccountLogin.Version` is bumped off 1758 so a future server can reject binaries built before
  this change on that field alone.
- `CPSock::ConnectServer` resolves its host with `getaddrinfo` instead of `inet_addr`, so a hostname
  works where previously only a dotted quad did.

**Removals**

- `serverlist.bin`, `sn.bin` and `sn2.bin` are no longer read. Their loaders, path constants and the
  four globals they populate are deleted.
- The HTTP population feed is removed: no population numbers, no busy bar, no `FULL` label, and no
  capacity gate. The client no longer refuses a login on a user count — capacity becomes the
  server's concern.
- The in-game channel-switch panel is removed together with the whole hop protocol: the `0x334`
  whisper addressed to `srv`, the `0x52A` reply, and the second `0x10A` body
  (`MSG_CNFRemoveServerLogin`) that only the field scene understood. `0x10A` regains a single
  meaning.
- Dead credential-mangling buffers `ObjectManager::m_szAccountName` / `m_szAccountPass` and the
  `NewApp::m_szServerIP` global are deleted along with their last writers.

**Renames**

- `TMSelectServerScene` → `TMLoginScene` (class, both files, and the two MSBuild project files).
- `TM_SELECTSERVER_STATE` → `TM_LOGIN_STATE`, keeping the numeric value 7; the orphan
  `TM_LOGIN_STATE = 3` is deleted.
- `ESCENE_SELECT_SERVER` → `ESCENE_LOGIN`, keeping the numeric value `0x7534`; the orphan
  `ESCENE_LOGIN = 0x7532` is deleted.
- **BREAKING (behaviour)** the rename makes the previously-unreachable guard at `TMScene.cpp:863,878`
  live: a disconnect while the login scene is current no longer tears the scene down and rebuilds
  it. This is deliberate.

## Capabilities

### New Capabilities

- `client-login`: what the player sees and does to get from launching the client to an authenticated
  session — the login screen's fields, its validation, where it connects, and what it no longer
  offers.
- `account-login-protocol`: the wire contract for authentication — the connect handshake, the
  `MSG_AccountLogin` request shape, and the accept/reject responses. This is the capability the Rust
  server will implement against.

### Modified Capabilities

None. This is the first change in the repo; `openspec/specs/` is empty.

## Impact

**Scope: `packages/apps/client` only.** No Rust or TypeScript changes. The server currently accepts
TCP on 8281 and does nothing with the bytes (`packages/apps/server/src/main.rs`), so no server code
targets the old shape and nothing breaks on that side.

Client files touched:

- `Basedef.h` / `Basedef.cpp` — packet structs, `BASE_InitializeServerList`, `BASE_GetHttpRequest`,
  `g_pServerList`
- `TMSelectServerScene.{h,cpp}` → `TMLoginScene.{h,cpp}` — the bulk of the change
- `TMFieldScene.{h,cpp}` — channel panel, hop protocol, `0x10A`/`0x52A` dispatch
- `NewApp.{h,cpp}` — `InitServerName`, `InitServerName2`, `m_szServerIP`
- `TMGlobal.{h,cpp}` — `g_szServerNameList`, `g_nServerCountList`, `g_szServerName`
- `CPSock.cpp` — hostname resolution
- `SControl.{h,cpp}` — `SListBoxServerItem`
- `ObjectManager.{h,cpp}`, `TMScene.cpp`, `TMPaths.h`, `ResourceControl.h` — enums, dead members,
  path and control constants
- `EventTranslator.cpp`, `TMSkillMeteorStorm.cpp`, `TMGround.cpp`, `TMHuman.cpp` — rename only
- `TMProject.vcxproj`, `TMProject.vcxproj.filters` — renamed files

Operational impact:

- Existing installs stop needing `serverlist.bin`, `sn.bin` and `sn2.bin`. Leftover copies are
  ignored, not an error.
- The server hostname is fixed at build time. Changing it means a new client build and
  redistribution.
- The UI resource (`UI\SelServerScene2.bin`) is not in the repo and is **not** edited by this
  change. The identity field's character limit and pixel width are overridden in code after
  `LoadRC`, and the picker panel is simply never made visible.

Non-goals:

- Password handling on the wire stays as it is today — plaintext inside the existing table cipher.
  Moving to email accounts raises the stakes on that, but fixing it needs a server side to negotiate
  with and is out of scope here.
- Account registration is unchanged: the "create ID" button still opens an external URL.
- Distinguishing the `0x11C` and `0x11D` rejection reasons is left alone; both still show one
  message.
