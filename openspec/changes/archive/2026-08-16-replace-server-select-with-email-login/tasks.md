All work happens in the `packages/apps/client` submodule working tree, on a named branch in
`w2-client`. Nothing in `packages/apps/server` or `packages/apps/web` changes. The submodule pin in
this repo moves only after task 8 passes.

## 1. Wire shape

- [x] 1.1 Widen `MSG_AccountLogin.AccountPass` and `.AccountName` to `char[64]` and delete `TID[52]`
      (`Basedef.h:897-907`)
- [x] 1.2 Widen `MSG_CNFAccountLogin.AccountName` to `char[64]` (`Basedef.h:779-789`)
- [x] 1.3 Add `static_assert` for `sizeof` of `MSG_STANDARD` (12), `STRUCT_ITEM` (8),
      `STRUCT_SELCHAR` (840), `MSG_AccountLogin` (164) and `MSG_CNFAccountLogin` (1976), plus
      `offsetof` assertions for the two padding runs in the accept response (28 and 1972)
- [x] 1.4 Change the version the client sends from 1758 to 1759 (`TMSelectServerScene.cpp:703`)

## 2. Endpoint resolution

- [x] 2.1 Add the `W2_SERVER_HOST` macro with a `localhost` default beside `TM_CONNECTION_PORT`
      (`Basedef.h:9`)
- [x] 2.2 Replace `inet_addr` in `CPSock::ConnectServer` with `getaddrinfo` hinted `AF_INET` /
      `SOCK_STREAM`, using the first result and calling `freeaddrinfo` on every exit path
      (`CPSock.cpp:137`)
- [x] 2.3 Make connection failure distinguish "could not resolve" from "could not connect" in the
      value returned to the caller, so the login screen can report it
- [x] 2.4 Delete `NewApp::m_szServerIP` (`NewApp.h:57`) and pass `W2_SERVER_HOST` directly to
      `ConnectServer`

## 3. Remove the in-game channel panel and hop protocol

- [x] 3.1 Delete the `B_SYS_SERVER` handler and channel-panel rebuild (`TMFieldScene.cpp:3801-3980`)
- [x] 3.2 Delete the row-pick handler and its 500-population gate (`TMFieldScene.cpp:4638-4653`)
- [x] 3.3 Delete the teleport countdown and the `srv` whisper it sends
      (`TMFieldScene.cpp:11901-11918`)
- [x] 3.4 Delete the `0x52A` and `0x10A` dispatch cases and their handlers
      (`TMFieldScene.cpp:6358-6361`, `:18656-18741`)
- [x] 3.5 Delete the panel bind, escape-close and remaining references
      (`TMFieldScene.cpp:418`, `:1978-1983`, `:14498-14500`, `:23216`)
- [x] 3.6 Delete the members `m_pServerPanel`, `m_pServerList`, `m_stRemoveServer`, `m_nServerMove`
      and the two handler declarations (`TMFieldScene.h:177-178`, `:715-721`)
- [x] 3.7 Delete `MSG_CNFRemoveServer` and `MSG_CNFRemoveServerLogin` (`Basedef.h:866-871`,
      `:1363-1382`)
- [x] 3.8 Delete the control constants `TMP_MOVE_SELSERVER`, `TML_MOVE_SELECT_SERVER`,
      `TMP_MOVE_SELSERVER_BACK`, `B_SYS_SERVER`, `TMB_SYS_SERVER` (`ResourceControl.h:1171`,
      `:1505-1506`, `:1846`, `:1879`)
- [x] 3.9 Replace the remaining reads of `m_nServerIndex` / `m_nServerGroupIndex` outside the login
      path with fixed values, and confirm the guild-mark filename at `TMFieldScene.cpp:22618` still
      resolves (`TMScene.cpp:1152-1155`, `TMFieldScene.cpp:7113-7114`)

## 4. Rewrite the login screen

- [x] 4.1 Make the login panel and its three buttons visible at scene init, and start the scene in
      the logged-out state rather than the picker state (`TMSelectServerScene.cpp:110-230`)
- [x] 4.2 Delete the picker panel lookup, group-list and channel-list construction from
      `InitializeUI` (`TMSelectServerScene.cpp:1341-1428`)
- [x] 4.3 Delete the `L_SELECT_SERVERG` and `B_SERVER_SEL_OK` handlers and the row-index computation
      that runs before the switch (`TMSelectServerScene.cpp:377-383`, `:386-618`)
- [x] 4.4 Delete the HTTP population fetch and its parse from scene init
      (`TMSelectServerScene.cpp:207-218`)
- [x] 4.5 Delete the picker/login fade state machine and its alpha helpers
      (`TMSelectServerScene.cpp:887-897`, `:1298`, and the `m_cLogin` value 2 path)
- [x] 4.6 Delete the picker-only members from the header: `m_pNServerSelect`,
      `m_pNServerGroupList`, `m_pNServerList`, `m_pGroupPanel`, `m_nMaxGroup`, `m_nAdmitGroup`,
      `m_bAdmit`, `m_nDay` (`TMSelectServerScene.h:53-59`, `:74-77`)
- [x] 4.7 Replace the 4..12 account-name validation with the email shape check from design.md,
      reusing message-string indices 3, 4 and 5 (`TMSelectServerScene.cpp:656-679`)
- [x] 4.8 Extend the password check to reject over 63 characters, keeping the minimum of 4
- [x] 4.9 Override `m_nMaxStringLen` and the control width for the identity and password fields
      after `LoadRC` (`TMSelectServerScene.cpp:182-183`)
- [x] 4.10 Delete the `CheckPKNonePK` call, the Portuguese debug `printf`, and the credential
      mangling block (`TMSelectServerScene.cpp:605`, `:615`, `:740-758`)
- [x] 4.11 Delete `ObjectManager::m_szAccountName` and `m_szAccountPass` (`ObjectManager.h:98-99`)

## 5. Remove the data files and their globals

- [x] 5.1 Delete `BASE_InitializeServerList` and its call, and `g_pServerList`
      (`Basedef.cpp:16`, `:354`, `:1332-1353`; `Basedef.h:2848`, `:2870`)
- [x] 5.2 Delete `BASE_GetHttpRequest` and its declaration, after confirming the two removed screens
      were its only callers (`Basedef.cpp:397-422`, `Basedef.h:2871`)
- [x] 5.3 Delete `NewApp::InitServerName`, `InitServerName2` and their calls
      (`NewApp.cpp:63-73`, `:262-263`, `:497-512`; `NewApp.h:27`, `:79`)
- [x] 5.4 Delete `g_szServerNameList`, `g_nServerCountList` and `g_szServerName`
      (`TMGlobal.cpp:26-28`, `TMGlobal.h:57-59`)
- [x] 5.5 Delete `ServerName_Path`, `ServerName2_Path` and `ServerList_Path` (`TMPaths.h:10-12`)
- [x] 5.6 Delete `SListBoxServerItem` after confirming no consumer outside the two removed screens
      (`SControl.h:495-512`, `SControl.cpp:2209-2270`)
- [x] 5.7 Delete `g_nServerGroupNum`, `g_pPKServerNum` and `CheckPKNonePK` if nothing else reads them
      (`Basedef.cpp:15`, `TMGlobal.cpp:115`, `TMScene.cpp:2663-2672`)

## 6. Renames

- [x] 6.1 Rename `TMSelectServerScene.{h,cpp}` to `TMLoginScene.{h,cpp}` and the class with them,
      updating the four entries in `TMProject.vcxproj` and `TMProject.vcxproj.filters`
- [x] 6.2 Rename `TM_SELECTSERVER_STATE` to `TM_LOGIN_STATE` keeping the value 7, delete the orphan
      `TM_LOGIN_STATE = 3`, and update all eight call sites (`ObjectManager.h:18-32`)
- [x] 6.3 Rename `ESCENE_SELECT_SERVER` to `ESCENE_LOGIN` keeping the value `0x7534`, and delete the
      orphan `ESCENE_LOGIN = 0x7532` (`TMScene.h:7-17`)
- [x] 6.4 Update the five unrelated readers of the scene type (`EventTranslator.cpp:269`,
      `TMSkillMeteorStorm.cpp:531`, `TMFieldScene.cpp:545`, `TMGround.cpp:2768`, `TMHuman.cpp:3043`)
- [x] 6.5 Confirm the guard at `TMScene.cpp:863,878` now evaluates false in the login scene, and that
      a failed connect leaves the screen standing

## 7. Documentation

- [x] 7.1 Add a note to `docs/researchs/client-server-list.md` marking §1-§3, §5 and §7 as describing
      the pre-change client, with a pointer to this change
- [x] 7.2 Update `openspec/config.yaml` so its client-commit guidance matches `CLAUDE.md`

## 8. Verify

- [x] 8.1 Build `Release|x86` with `scripts/build-client.sh` and confirm every `static_assert` passes
- [x] 8.2 Grep the client for `serverlist`, `sn.bin`, `sn2.bin`, `g_pServerList` and `SelectServer`
      and confirm no hits remain outside comments
- [x] 8.3 Run the client against `yarn dev:app:server` on `localhost:8281`: confirm the login screen
      is first, accepts a 63-character email, rejects a malformed one without connecting, and reaches
      the connect with a 164-byte `0x20D` on the wire
- [x] 8.4 Confirm the client starts normally with the three `.bin` files deleted, and again with them
      present but stale
- [x] 8.5 Commit on the `w2-client` branch, then bump the submodule pin here as its own commit via
      `/w2-commit`
