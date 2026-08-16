# Research: the server list in the WYD / TMProject client

Date: 2026-08-15. Repo: `/home/nrechdan/projects/w2-server`. Submodule `packages/apps/client` read at pinned
commit `5852bb61397a458096d61f7879b936d89e71ba75` (`Fixed #include casing for case-sensitive filesystems`).

**Primary source only.** Every claim below carries a `path:line` citation into the client tree. Paths are
relative to the repo root; all client paths start `packages/apps/client/Projects/TMProject/`, abbreviated
below as `…/`.

**Licence note.** The client is GPL v3, this repo is Apache-2.0. Nothing here is copied from it. Struct
layouts are given as re-derived "offset / size / meaning" tables, not as source. Constant *tables* (the
512-byte cipher table, the 64-byte server-list key) are pointed at by line number and deliberately **not**
reproduced — read them from the client when you need them.

Everything marked **DERIVED** is my computation from the MSVC 32-bit ABI, not something I executed. Nothing
in this note was compiled or run; §9 lists what that leaves unverified.

> **Superseded in part.** The change `replace-server-select-with-email-login` removed the server picker
> from the client. §1, §2, §3, §5 and §7 describe machinery that no longer exists: the three `.bin` files
> and their loaders, the HTTP population feed, the group/channel picker, and the whole channel-hop
> protocol (`0x334` to `srv`, `0x52A`, and the second `0x10A` body). §4 still holds for the framing and
> the cipher, but the login structs have moved — see that change's
> `specs/account-login-protocol/spec.md` for the current shapes. §6 and §8 remain accurate as a record of
> what the pre-change client did, and §8.1, §8.2 and §8.4 describe traps that no longer apply because the
> code carrying them is gone.
>
> Read this note as history plus a transport reference, not as a description of the current client.

---

## Verdict up front

**The client never receives a server list over the network.** There is no server-list opcode, no
"request server list" packet, no login server that hands one out. The whole list is baked into three local
binary files that ship next to the executable, and the *only* live data the client pulls at runtime is a
per-group population feed fetched over **plain HTTP** with WinINet.

That single fact reshapes what a server implementation has to do:

| Concern | Reality |
| --- | --- |
| Who owns the list of servers | The client install, in `serverlist.bin` / `sn.bin` / `sn2.bin` |
| Who owns the population numbers | An **HTTP endpoint** whose URL is itself stored in `serverlist.bin` |
| First bytes the game server sees | A bare 4-byte init code, then `MSG_AccountLogin` (0x20D) |
| Address the client dials | A dotted-quad IPv4 **string** from `serverlist.bin`, port **8281**, hardcoded |
| Channel switch while in game | A **whisper packet** addressed to the literal name `srv` |

So: to stand up a server that this client can reach, you ship a `serverlist.bin`, you serve an HTTP page of
integers, and you answer 0x20D on TCP/8281. Nothing about the picker itself is your protocol surface.

---

## 1. Where the list lives in the client

Four globals hold everything. All are plain C arrays with fixed bounds — no dynamic allocation, no vector.

| Global | Shape | Bytes | Declared | Defined |
| --- | --- | --- | --- | --- |
| `g_pServerList` | `[10][11][64]` chars | 7040 | `…/Basedef.h:2848` | `…/Basedef.cpp:16` |
| `g_szServerNameList` | `[11][9]` chars | 99 | `…/TMGlobal.h:58` | `…/TMGlobal.cpp:27` |
| `g_nServerCountList` | `[11]` ints | 44 | `…/TMGlobal.h:57` | `…/TMGlobal.cpp:26` |
| `g_szServerName` | `[10][10][9]` chars | 900 | `…/TMGlobal.h:59` | `…/TMGlobal.cpp:28` |

The bounds come from `…/Basedef.h:11-13`:

- `MAX_SERVER = 10` — "max number of game servers that can connect to DB server" (the client's own comment)
- `MAX_SERVERGROUP = 10` — "max number of servers that can exist"
- `MAX_SERVERNUMBER = MAX_SERVER + 1 = 11` — "DB + TMSrvs + BISrv" (the client's own comment)

### 1.1 `g_pServerList` — the two-role array

The second index is **not** uniform. Slot 0 of each group and slots 1..10 of each group hold different kinds
of string:

| Index | Contents | Consumed as | Evidence |
| --- | --- | --- | --- |
| `[group][0]` | an **HTTP URL** | passed to `InternetOpenUrl` | `…/TMSelectServerScene.cpp:409,422`; `…/Basedef.cpp:403` |
| `[group][1..10]` | an **IPv4 dotted-quad string** | passed to `inet_addr` | `…/TMSelectServerScene.cpp:604`; `…/CPSock.cpp:137` |

Each slot is a 64-byte NUL-padded C string. Emptiness is tested by "first byte is zero" everywhere
(`…/TMSelectServerScene.cpp:466,1364,1381,1408`), so **`\0` in byte 0 is the sentinel for "slot unused"**, and
group 0 being empty means "no groups at all".

`g_pServerList[group][0][0] != 0` is the "does this group exist" test; `g_pServerList[group][n][0] != 0` for
n ≥ 1 is the "does this channel exist" test.

### 1.2 The three name/count arrays

- `g_szServerNameList[group]` — an 8-char group display name (9 bytes with terminator). Used as the group row
  label (`…/TMSelectServerScene.cpp:1418-1419`) and as the left half of the channel label
  (`…/TMSelectServerScene.cpp:495,520`).
- `g_szServerName[group][channel]` — an 8-char per-channel display name, optional. When present it replaces
  the numeric suffix (`…/TMSelectServerScene.cpp:519-520`).
- `g_nServerCountList[i]` — an int per row, but **not a count of anything**. It is used exclusively as an
  indirection table: `nIndexN = g_nServerCountList[nMaxGroupN - idwEvent - 1] - 1` maps a clicked list row to
  a group index (`…/TMSelectServerScene.cpp:383`). Its values are 1-based group ids; 0 means "row absent"
  (`…/TMSelectServerScene.cpp:377`). It also drives `m_nAdmitGroup` and `m_nMaxGroup`
  (`…/TMSelectServerScene.cpp:1397-1409`).

### 1.3 Scene-side storage

`TMSelectServerScene` holds no copy of the list. It keeps only derived state
(`…/TMSelectServerScene.h:53-59, 74-77`): `m_nMaxGroup`, `m_nAdmitGroup`, `m_bAdmit`, `m_nDay[10]`, the two
list-box pointers `m_pNServerGroupList` / `m_pNServerList`, and the panel `m_pNServerSelect`. The selected
result is written to two `ObjectManager` fields, `m_nServerGroupIndex` and `m_nServerIndex`
(`…/TMSelectServerScene.cpp:601-602`), and to `g_pApp->m_szServerIP`, a `char[128]`
(`…/NewApp.h:57`, written at `…/TMSelectServerScene.cpp:604`).

---

## 2. How the client obtains it — files, not packets

I grepped the whole client for a network-delivered list and there is none. See §9.1 for exactly what I
searched.

### 2.1 `serverlist.bin` — the addresses

Loaded by `BASE_InitializeServerList` (`…/Basedef.cpp:1332-1353`), called first thing from
`BASE_InitializeBaseDef` (`…/Basedef.cpp:354`). The path is hardcoded as `./serverlist.bin` at the call site
(`…/Basedef.cpp:1335`) even though `ServerList_Path` exists in `…/TMPaths.h:12` — see §8.

Layout, re-derived:

| Offset | Size | Meaning |
| --- | --- | --- |
| 0 | 7040 | the whole `[10][11][64]` array, flat, obfuscated |

The read is expressed as 64 records of 110 bytes (`…/Basedef.cpp:1342`). 110 × 64 = 7040 = 10 × 11 × 64, so
it is a flat blob and the record shape is cosmetic. **A file shorter than 7040 bytes is read short and the
remainder stays zeroed** (the array is `memset` first, `…/Basedef.cpp:1341`); the function still returns 1 as
long as the file opened.

**Obfuscation.** After reading, every 64-byte slot is de-obfuscated in place by subtracting a fixed 64-byte
key **in reverse order**: byte *i* of each slot has key byte *(63 − i)* subtracted from it, as `char`
arithmetic (`…/Basedef.cpp:1345-1348`). To produce a file, add the same key bytes. The key itself is the
string literal at `…/Basedef.cpp:1339` — read it from there, I am not reproducing it. What you need to know
about it without reading it:

- It is exactly **64 code points**, all in U+00A1..U+00D9, so exactly 64 bytes once narrowed — the `char[65]`
  it initialises is fully used plus the terminator.
- The source file is UTF-8 **with BOM** and the project sets no `/utf-8` and no `/execution-charset`
  (`…/TMProject.vcxproj` has `<CharacterSet>MultiByte</CharacterSet>` only, lines 33/41/54). MSVC therefore
  narrows the literal using the **build machine's ANSI code page**. On CP1252 you get the Latin-1 bytes; on
  a CJK code page those same code points narrow to multi-byte sequences and the literal no longer fits. See
  §8.1 — this is a real portability trap for anyone generating the file from a script.
- It contains only 30 distinct byte values across the 64 positions, so it is not a strong key and repeats.

### 2.2 `sn.bin` — group names and the row→group map

Loaded by `NewApp::InitServerName` (`…/NewApp.cpp:497-512`), called from `NewApp::Initialize`
(`…/NewApp.cpp:263`). Path constant `ServerName_Path = "sn.bin"` (`…/TMPaths.h:10`). Two sequential reads,
no header, no obfuscation:

| Offset | Size | Meaning |
| --- | --- | --- |
| 0 | 99 | `g_szServerNameList` — 11 × 9 bytes, each an 8-char NUL-terminated group name |
| 99 | 44 | `g_nServerCountList` — 11 × `int32` little-endian, the row→group indirection |

Total 143 bytes. Both arrays are `memset` to zero first (`…/NewApp.cpp:500-501`), so a missing or short file
degrades to "all zero" rather than failing.

### 2.3 `sn2.bin` — per-channel names

Loaded by `InitServerName2` (`…/NewApp.cpp:63-73`), called at `…/NewApp.cpp:262`, path
`ServerName2_Path = "sn2.bin"` (`…/TMPaths.h:11`).

| Offset | Size | Meaning |
| --- | --- | --- |
| 0 | 900 | `g_szServerName` — 10 groups × 10 channels × 9 bytes, each an 8-char NUL-terminated name |

Note the shape mismatch with `g_pServerList`: this array is `[10][10]`, indexed by channel 0..9, while the
address array is `[..][11]` indexed by channel 1..10. The client indexes it inconsistently — see §8.4.

### 2.4 The population feed — plain HTTP

`BASE_GetHttpRequest` (`…/Basedef.cpp:397-422`) is a thin WinINet wrapper: `InternetOpen` with the user-agent
string `"MS"`, `InternetOpenUrl` with flags `0x4000000` (`INTERNET_FLAG_RELOAD`), a single `InternetReadFile`
of at most `MaxBuffer` bytes, then NUL-terminate. Every caller passes a 1024-byte buffer, and the function
additionally clamps to 1023 bytes (`…/Basedef.cpp:415-416`).

- **No POST, no headers, no auth.** GET of the URL stored in `g_pServerList[group][0]`.
- One read only — a response that arrives in more than one TCP segment may be **truncated**. The server side
  should keep the body small and send it in one go.
- Called at three sites: scene init (`…/TMSelectServerScene.cpp:214`, which passes the address of the whole
  array, i.e. group 0's URL), and twice when a group row is clicked (`…/TMSelectServerScene.cpp:409,422`).
  The in-game channel panel calls it too (`…/TMFieldScene.cpp:3859,3872`).

**Response body format.** The parse is `sscanf_s` with a format of repeated `%d` separated by what the source
writes as `\\n` (`…/TMSelectServerScene.cpp:216,411,423`; `…/TMFieldScene.cpp:3861,3873`). In C++ `"\\n"` is
**backslash followed by the letter n**, two literal characters — not a newline. `sscanf` requires those to
match the input byte for byte. So as the code stands the body must be:

```
<int>\n<int>\n<int>\n…
```

with a literal backslash and a literal `n` between numbers. If the body uses real newlines (0x0A), the first
`%d` converts and the literal `\` then fails to match, so **only index 0 is ever filled** and the rest keep
their initialiser. I judge this a decompilation artefact (an escaped string copied out of a disassembler
without un-escaping) rather than the original behaviour — see §8.2 — but it is what the pinned client does,
and a server generating this feed has to pick one.

Counts consumed per call site: 11 values at `…/TMSelectServerScene.cpp:216` and `:411`; **12** at `:423`,
where the last two are not populations but `nAspGetweek` and `nAspGetday` (`…/TMSelectServerScene.cpp:425`);
11 at `…/TMFieldScene.cpp:3861`; 10 at `…/TMFieldScene.cpp:3873`. The population array is indexed 1..10 to
match channel numbers, so **index 0 of the feed is read into a slot the UI never displays**.

`nAspGetweek` / `nAspGetday` are trailing fields that only the select-server group-click path reads. They
override the castle-week calculation (`…/TMSelectServerScene.cpp:469-472`) and default to −1 / today's day of
month when absent (`…/TMSelectServerScene.cpp:395-396, 430-431`).

---

## 3. What the client does with it

### 3.1 Scene and UI

`TMSelectServerScene` (`…/TMSelectServerScene.h:12`, implementation `…/TMSelectServerScene.cpp`) is created
by `ObjectManager::SetCurrentState` for `TM_SELECTSERVER_STATE = 7`
(`…/ObjectManager.h:29`, `…/ObjectManager.cpp:721-723`). Its layout comes from a text resource loaded at
`…/TMSelectServerScene.cpp:110`, `UI\SelServerScene2.txt` — **that file is not in the repo** (§9.2).

Controls, from `…/ResourceControl.h`:

| Constant | Value | Role |
| --- | --- | --- |
| `P_SERVER_SEL` | 65537 | the picker panel (`:1554`) |
| `B_SERVER_SEL_OK` | 65538 | confirm (`:1555`) |
| `B_SERVER_SEL_EXIT` | 65539 | quit (`:1556`) |
| `L_SELECT_SERVERG` | 65542 | **group** list box (`:1559`) |
| `L_SELECT_SERVER` | 65543 | **channel** list box (`:1560`) |
| `TMT_SEL_SERVER_TEXT` | 5635 | "server" caption (`:25`) |
| `TMT_SEL_CHANNEL_TEXT` | 5636 | "channel" caption (`:26`) |

`InitializeUI` (`…/TMSelectServerScene.cpp:1341-1428`) finds them, hides the channel list until a group is
picked (`:1350-1351`), and fills the group list by walking groups **downwards** from `m_nMaxGroup` to 0
(`:1411-1426`), so the on-screen order is reverse of the array order — which is why every later lookup
subtracts the clicked index from a count.

### 3.2 Clicking a group

`OnControlEvent` case `L_SELECT_SERVERG` (`…/TMSelectServerScene.cpp:386-576`):

1. Shows a "please wait" message (`:398-399`).
2. Fetches the population feed for that group (`:409` or `:422`) and parses it (§2.4).
3. Recomputes `m_nDay[group]` = number of non-empty channel slots in the group, then folds today's day of
   month into it: `day % count`, with 0 mapped to `count` (`:433-448`). This picks a "server of the day"
   that gets highlighted.
4. Empties the channel list and rebuilds it, one row per non-empty `g_pServerList[group][1..10]`
   (`:456-574`).

Row label construction (`:494-541`):

- `"<groupname>-<channelname>"` when a per-channel name exists in `sn2.bin`.
- `"<groupname>-<n>"` otherwise, n being the 1-based channel number.
- Falls back to a printf template from the message string table, index 68, when the group has no name
  (`:541`).
- If the population for that channel exceeds **600**, the label is truncated at byte 14 and the ASCII string
  `"FULL"` is appended (`:502-514`, `:525-537`). The "pad with spaces" loop above it is a no-op — its bounds
  are `for (n1 = len; n1 < len; …)` (`:508`, `:531`).

Row widget: `SListBoxServerItem` (`…/SControl.h:495-512`, ctor `…/SControl.cpp:2209-2251`), constructed at
`…/TMSelectServerScene.cpp:555`. Its per-row state:

| Field | Meaning |
| --- | --- |
| `m_nCurrent` | population, clamped to ≥ 0 at `…/TMSelectServerScene.cpp:543-545` |
| `m_cCastle` | draws a crown sprite (texture 151) when 1 (`…/SControl.cpp:2234-2235`) |
| `m_cGoldBug` | draws a second sprite (texture 316) when 1 (`…/SControl.cpp:2236-2237`) |
| `m_cConnected` | set to 0 when the population came back negative — **but never read anywhere** (§8.3) |
| `m_pBusyProgress` | a progress bar of `m_nCurrent` out of a **hardcoded 600** (`…/SControl.cpp:2250`) |

The bar's colours are chosen by the `nTextureSet` argument: ≤ −1 gives red-on-dark, ≤ −2 gives green-on-dark
(`…/SControl.cpp:2239-2248`). −2 is used to highlight the day's server (`…/TMSelectServerScene.cpp:548-552`).
Texture set 6 marks a placeholder row labelled from message string 70 (`:562-572`).

`g_nChannelWidth = 133` fixes the row width (`…/TMSelectServerScene.cpp:133`, global at `…/Basedef.h:2845`).

### 3.3 Clicking OK — the only thing that reaches the network

`OnControlEvent` case `B_SERVER_SEL_OK` (`…/TMSelectServerScene.cpp:581-618`):

1. Resolves group and channel: `nServerGroupIndex` from `g_nServerCountList` indirection, `nServerIndex` =
   selected row + 1, i.e. **1-based** (`:583-584`).
2. Rejects the click if no row is selected or the indices are out of range (message string 24, `:587-592`).
3. **Rejects if `m_nCurrent >= 600`** (message string 25, `:594-599`). Note the asymmetry with the label,
   which says FULL at `> 600`: population exactly 600 shows no FULL label but cannot be entered.
4. Stores the two indices on `ObjectManager` (`:601-602`).
5. Copies `g_pServerList[group][channel]` into `g_pApp->m_szServerIP` (`:604`) and prints it to the console
   (`:605` — a debug `printf` in Portuguese, see §8.5).
6. Swaps the picker for the login box and starts the fade (`:607-614`).
7. Calls `CheckPKNonePK(nServerIndex)` (`:615`), which is inert — see §6.3.

**No packet is sent here.** The address is only dialled when the user then presses Login.

`B_LOGIN_OK` (`…/TMSelectServerScene.cpp:646-762`):

1. Rate-limits to one attempt per 1500 ms (`:648-650`).
2. Client-side validation: account name **4..12 chars**, password **≥ 4 chars** (`:656-679`). Rejections use
   message strings 3, 4, 5.
3. `g_pSocketManager->ConnectServer(g_pApp->m_szServerIP, TM_CONNECTION_PORT, 0, 1124)` (`:688`).
   `TM_CONNECTION_PORT = 8281`, a compile-time constant (`…/Basedef.h:9`). **The port is never read from any
   file or packet.** The `1124` is `WM_USER + 100`, the window message the socket signals on
   (`…/NewApp.cpp:1156`).
4. Builds and sends `MSG_AccountLogin` (`:699-760`). Details in §4.

---

## 4. The protocol that follows a selection

### 4.1 Transport framing

`CPSock` (`…/CPSock.h`, `…/CPSock.cpp`). Buffers are 131072 bytes each way (`…/CPSock.h:3-4`).

**Connect handshake.** `ConnectServer` (`…/CPSock.cpp:122-197`):

- `inet_addr(HostAddr)` — **no `gethostbyname`, no `getaddrinfo`**. Only dotted-quad IPv4 works. A hostname
  in `serverlist.bin` yields `INADDR_NONE` and the connect fails.
- Immediately after `connect` succeeds, the client sends a bare 4-byte `INIT_CODE` = 521270033 =
  `0x1F11F311`, on the wire little-endian as `11 F3 11 1F` (`…/CPSock.h:8`, `…/CPSock.cpp:169-171`).
- It then sets `Init = 1` (`…/CPSock.cpp:171`), so **the client does not expect an init code back**. The
  inbound-init branch in `ReadMessage` (`…/CPSock.cpp:297-312`) is unreachable on the normal path. A server
  that echoes the init code would have those 4 bytes parsed as the start of a message header and produce
  `ErrorCode = 2`.
- Local bind is attempted three times, unbound then on ports `ConnectPort + 5000` with `ConnectPort`
  advancing by 10 each retry (`…/CPSock.cpp:152-158`). `ConnectPort` is a file-scope global at
  `…/CPSock.cpp:8`.

**Message header** — `MSG_STANDARD` (`…/Basedef.h:27-35`). No `#pragma pack` exists anywhere in the client
(grepped, zero hits), so MSVC default alignment applies. Re-derived, **DERIVED**:

| Offset | Size | Type | Field | Notes |
| --- | --- | --- | --- | --- |
| 0 | 2 | u16 LE | Size | total message length including header |
| 2 | 1 | u8 | KeyWord | index into the cipher table |
| 3 | 1 | u8 | CheckSum | |
| 4 | 2 | u16 LE | Type | the opcode |
| 6 | 2 | u16 LE | ID | client/char id |
| 8 | 4 | u32 LE | Tick | server time |

Size 12, alignment 4, no padding. Everything is little-endian x86; the client does no byte swapping
anywhere (`ntohs`/`htons` appear only on port numbers, `…/CPSock.cpp:90,139`).

**Validation the client applies to every inbound message** (`…/CPSock.cpp:314-409`) — a server that violates
any of these drops the stream:

- Fewer than 12 buffered bytes → wait for more (`:314-315`).
- `Size >= 131072` or `Size < 12` → `ErrorCode = 2`, receive buffer reset (`:357-364`).
- `Size` greater than what is buffered → wait (`:366-369`).
- Checksum: bytes 4..Size−1 are decrypted in place; `(Sum2 − Sum1) & 0xFF` must equal the header's
  `CheckSum`, where Sum2 sums the ciphertext and Sum1 the plaintext (`:379-407`). A mismatch sets
  `ErrorCode = 1`, which breaks the read loop at `…/NewApp.cpp:1179`.
- Non-zero `ErrorCode` ends the drain loop; the socket is not closed by the loop itself.

**Obfuscation.** Bytes 0..3 travel in clear; bytes 4..Size−1 are transformed. The stream position starts at
`pKeyWord[KeyWord * 2]` and advances one per byte; the per-byte modifier is `pKeyWord[(pos % 256) * 2 + 1]`.
The operation depends on `i & 3` — for the *send* direction: `+2·T`, `−(T >> 3)`, `+4·T`, `−(T >> 5)` for
i mod 4 = 0,1,2,3; the receive direction is the exact inverse (`…/CPSock.cpp:379-401` receive,
`…/CPSock.cpp:494-516` send). `pKeyWord` is a 512-byte constant table at `…/CPSock.cpp:10-27` — read it
there; I have not reproduced it.

**Keyword selection.** The header's `KeyWord` byte is chosen by `AddMessage`
(`…/CPSock.cpp:426-464, 477-479`):

- Before login, `SendQueue[0]` is zero, so `FixedKeyWord` is 0 and the byte is `rand() % 256`.
- After a successful login the 16 `SecretCode` bytes seed `SendQueue`
  (`…/TMSelectServerScene.cpp:844-846`), and the next 16 outbound messages use
  `SendQueue[SendCount++] ^ 0xFF` (`…/CPSock.cpp:459`).
- From the 17th message on, the intended rolling formula is dead — see §8.6 — and the byte reverts to
  random.

**The server must therefore treat the inbound keyword byte as arbitrary** and derive the cipher stream from
it rather than validating it.

### 4.2 `MSG_AccountLogin` — opcode 0x20D

Declared at `…/Basedef.h:897-907`, built at `…/TMSelectServerScene.cpp:699-760`. Re-derived layout,
**DERIVED**:

| Offset | Size | Type | Field | What the client puts there |
| --- | --- | --- | --- | --- |
| 0 | 12 | — | Header | `Type` = 0x20D, `ID` = 0 (`:700-701`), `Size`/`KeyWord`/`CheckSum`/`Tick` filled by `AddMessage` |
| 12 | 16 | char[16] | AccountPass | the password, **plaintext**, `sprintf_s` from the edit box (`:739`) |
| 28 | 16 | char[16] | AccountName | the account name, plaintext, as typed (`:738`) |
| 44 | 52 | char[52] | TID | **all zero** on first login; carries a token on a channel hop (§5) |
| 96 | 4 | i32 LE | Version | **1758**, hardcoded (`:703`) |
| 100 | 4 | i32 LE | Force | **1**, hardcoded (`:702`) |
| 104 | 16 | u32[4] LE | Mac | first adapter's GUID, digits only, parsed as 4 hex words (`:706-736`) |

`sizeof` = **120**, no padding. That is the value that lands in the header's `Size`, because the send is
`SendOneMessage(&stAccountLogin, sizeof MSG_AccountLogin)` (`:760`).

Notes a server has to honour:

- The struct is zero-initialised (`:699`), so `TID` is 52 NUL bytes and any short name/password is
  NUL-padded, not garbage.
- `AccountName` and `AccountPass` are **not** transformed. The uppercasing and per-index byte shifting a few
  lines below (`:748-758`) operate on separate `ObjectManager` copies that are never transmitted — §8.7.
- `Mac` is derived from the NIC's adapter *name* (a GUID string with `{`, `}` and `-` stripped, regrouped
  into 8-char chunks and `sscanf`'d as `%x`), not from a MAC address (`:715-733`). If `GetAdaptersInfo`
  reports nothing the field stays zero.
- `Version` 1758 is the protocol/build gate. It is the single client-version signal in the whole login path.

### 4.3 Login responses

Dispatch happens in `TMSelectServerScene::OnPacketEvent` (`…/TMSelectServerScene.cpp:813-873`).

| Opcode | Meaning | Handling |
| --- | --- | --- |
| `0x10A` | login accepted | `MSG_CNFAccountLogin`, `…/TMSelectServerScene.cpp:832-852` |
| `0x11C`, `0x11D` | login rejected | shows message string 12, re-enables the button (`:853-863`) |
| `0x101` | (only re-shows the login panel) | `:821-822`, `:855-856` |
| `0x194` | billing block | handled by the base scene, `…/TMScene.cpp:885-891` |
| `0xADA` | play-time counter | reads a `u32` at **offset 12** (`:866-867`) |

On 0x10A the client: sets its clock from the header's `Tick` (`:835`), copies `SelChar` and the 128-slot
cargo (`:838-839`), takes `Coin` (`:841`), seeds the send keyword queue from `SecretCode` and resets both
counters (`:844-848`), and transitions to `TM_SELECTCHAR_STATE` (`:850`).

`MSG_CNFAccountLogin` (`…/Basedef.h:779-789`) — re-derived, **DERIVED**. The interior structs:
`STRUCT_ITEM` = 8 bytes (`…/Basedef.h:97-101` over the 2-byte union at `:87-95`), `STRUCT_SCORE` = 48 bytes
with internal padding after `Level` and after `AttackRun` (`…/Basedef.h:69-85`), `STRUCT_SELCHAR` = **840**
bytes with 8-byte alignment because of its trailing `long long Exp[4]` (`…/Basedef.h:103-113`).

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 12 | Header (`Type` = 0x10A) |
| 12 | 16 | SecretCode |
| 28 | 4 | **padding** — inserted to 8-align `SelChar` |
| 32 | 840 | SelChar |
| 872 | 1024 | Cargo — 128 × `STRUCT_ITEM` |
| 1896 | 4 | Coin |
| 1900 | 16 | AccountName |
| 1916 | 4 | SSN1 |
| 1920 | 4 | SSN2 |
| 1924 | 4 | **tail padding** — struct alignment 8 |

`sizeof` = **1928**. Those two padding runs are the highest-risk part of the whole note for a Rust
reimplementation: they exist only because `long long` is 8-aligned under MSVC's default `/Zp8`, and they do
**not** appear if you naively concatenate the fields. Confirm before shipping (§9.3).

---

## 5. In-game channel switching — a completely different path

Once in the field, the same list is re-rendered by `TMFieldScene`, but the switch is not a reconnect the
client initiates from the picker.

**Opening the panel** (`…/TMFieldScene.cpp:3801-3980`, control `B_SYS_SERVER`): if the panel does not exist
yet the client instead sends `MSG_STANDARDPARM` with `Type = MSG_SysQuit_Opcode = 0x3AE`
(`…/Basedef.h:39`, sent at `…/TMFieldScene.cpp:3806-3809`). Otherwise it rebuilds the channel rows exactly
as §3.2 does, into controls `TMP_MOVE_SELSERVER` = 12288 and `TML_MOVE_SELECT_SERVER` = 12289
(`…/ResourceControl.h:1505-1508`, bound at `…/TMFieldScene.cpp:1978-1979`).

**Picking a row** (`…/TMFieldScene.cpp:4638-4653`): the threshold here is **500**, not 600 — a row with
`m_nCurrent >= 500` is refused with message string 25. It sets `m_nServerMove = row + 1` and starts a 5
second teleport countdown.

**Requesting the move** (`…/TMFieldScene.cpp:11901-11918`): after the countdown the client sends a
`MSG_MessageWhisper` (opcode `MSG_MessageWhisper_Opcode` = 0x334, `…/Basedef.h:909-917`) whose recipient
name is the literal 3-byte string **`srv`** and whose body is the target channel number rendered as decimal
ASCII. That is the entire "move me to channel N" request. Re-derived layout, **DERIVED**:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 12 | Header (`Type` = 0x334, `ID` = char id) |
| 12 | 16 | MobName — `"srv"` + NUL padding |
| 28 | 128 | String — the channel number in decimal ASCII, NUL padded |
| 156 | 2 | Color — zero here |
| 158 | 2 | **tail padding** |

`sizeof` = **160**, and that is what goes on the wire (`…/TMFieldScene.cpp:11916`).

**The reply: `MSG_CNFRemoveServer`, opcode 0x52A** (dispatched at `…/TMFieldScene.cpp:6359`, struct at
`…/Basedef.h:866-871`, handler at `…/TMFieldScene.cpp:18656-18726`). Re-derived, **DERIVED**:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 12 | Header (`Type` = 0x52A, `ID` must equal the client's char id) |
| 12 | 16 | AccountName |
| 28 | 52 | TID — a handoff token, **and** the channel number |

`sizeof` = **80**.

The `TID` field does double duty. The client parses it with the format `*%d` — a literal asterisk followed by
a decimal integer — to recover the destination channel (`…/TMFieldScene.cpp:18674`). So **the token must
begin with `*` immediately followed by the 1-based channel number**, and whatever else the server wants to
carry follows. The client then:

1. Sets `m_nServerIndex` from that number (`:18675`).
2. Looks up `g_pServerList[currentGroup][thatNumber]` for the address (`:18677`) — **the group never
   changes on a hop**, and the address still comes from the local file, not from the packet.
3. Connects to that address on port 8281 again (`:18679`).
4. Sends a fresh `MSG_AccountLogin` (0x20D) with `Version` 1758 and `Force` 1, `AccountName` and `TID` copied
   straight from the 0x52A packet, and **an empty password** (`:18714-18717`).

So the TID is the client's only credential on the second connection. A server implementation must mint it on
the origin channel and accept it on the destination.

**And then the destination answers 0x10A with a *different* layout.** `TMFieldScene` maps opcode 0x10A to
`MSG_CNFRemoveServerLogin` (`…/TMFieldScene.cpp:6361`, struct `…/Basedef.h:1363-1382`, handler `:18728-18741`),
whose field order starts `SelChar, AccountName, Cargo, Coin, SecretCode, …` — `SecretCode` is *after* the
cargo here, not before `SelChar` as in `MSG_CNFAccountLogin`. Same opcode, two incompatible bodies,
disambiguated purely by which scene is active. See §8.8.

---

## 6. Groups, channels, worlds, and the status flags

### 6.1 The vocabulary

The client has exactly **two** levels, not three:

- **Server group** — the outer index, up to 10. Rendered in the left list box. Owns one HTTP population URL.
  Named from `sn.bin`.
- **Server / channel** — the inner index, 1..10. Rendered in the right list box. Owns one IPv4 address.
  Optionally named from `sn2.bin`. The code calls these "server" in `TMSelectServerScene` and "channel" in
  the caption constant `TMT_SEL_CHANNEL_TEXT` and in `g_nChannelWidth`; they are the same thing.

There is **no "world" concept** anywhere. I searched for it (§9.1).

Slot `[group][0]` is not a channel — it is the group's HTTP URL. That is why every channel loop starts at 1
(`…/TMSelectServerScene.cpp:458`, `…/TMFieldScene.cpp:3884`).

### 6.2 Per-entry status

There is no status byte, no flags word, no maintenance field, no lock field. Everything the UI shows is
inferred:

| Displayed state | How it is derived |
| --- | --- |
| exists | `g_pServerList[g][n][0] != 0` (`…/TMSelectServerScene.cpp:466`) |
| population | the n-th integer of the HTTP body (`…/TMSelectServerScene.cpp:543`) |
| busy bar | population out of a hardcoded 600 (`…/SControl.cpp:2250`) |
| "FULL" text | population **> 600** (`…/TMSelectServerScene.cpp:502,525`); the in-game panel uses **> 500** at `…/TMFieldScene.cpp:3908` and 600 at `:3931` |
| blocked from entering | population **≥ 600** in the picker (`…/TMSelectServerScene.cpp:594`); **≥ 500** in game (`…/TMFieldScene.cpp:4641`) |
| unreachable | population **< 0** sets `m_cConnected = 0`, which nothing reads (§8.3) |
| "day server" highlight | `m_nDay[group] == n`, giving a green bar (`…/TMSelectServerScene.cpp:548-549`) |
| crown icon | `IsCastle(n − 1)` or the `nAspGetweek`/`nAspGetday` override (`…/TMSelectServerScene.cpp:468-472`) |
| placeholder row | message string 70, texture set 6 (`…/TMSelectServerScene.cpp:562-572`) |

**A negative integer in the HTTP feed is the closest thing to a "down" marker**, and −1 is what the client
pre-fills when the fetch fails (`…/TMSelectServerScene.cpp:211-212, 393-394`). Its only visible effect is
that the bar renders at 0.

### 6.3 PK servers — inert

`g_pPKServerNum[2] = { 5, 10 }` (`…/TMGlobal.cpp:115`) names two channel numbers as PK servers, and
`CheckPKNonePK` (`…/TMScene.cpp:2663-2672`) is called on both the picker path and the hop path. But the
function unconditionally assigns `g_NonePKServer = 0` on its last line (`:2671`), discarding the loop's
result. **Every channel is a PK channel** regardless of the table.

### 6.4 Versioning and auth alongside

- `Version` = 1758 in `MSG_AccountLogin` — the only version number on the wire.
- `Mac[4]` — a machine fingerprint, not a MAC address.
- `SecretCode[16]` from 0x10A — seeds the outbound keyword stream.
- `TID[52]` — the channel-hop handoff token.
- `SSN1` / `SSN2` in the login confirmation are read into nothing in the picker path; in the hop path they
  are likewise ignored (`…/TMFieldScene.cpp:18730-18733`).
- `g_bTestServer` is set when `WYDLauncher.exe` is **absent**, which also selects the `T`-prefixed launcher
  filenames (`…/TMSelectServerScene.cpp:26-31`). It gates nothing else in this path.

---

## 7. What a server implementation here has to match

A checklist distilled from the above, each item traceable to a line cited earlier.

**Files you must ship with the client, not send:**

1. `serverlist.bin`, exactly 7040 bytes, 110 slots of 64 bytes laid out as `[10][11][64]`, every byte
   obfuscated by adding the reversed 64-byte key from `…/Basedef.cpp:1339`.
2. `sn.bin`, 143 bytes: 11 × 9-byte group names, then 11 × `int32` LE row→group indices (1-based, 0 = absent).
3. `sn2.bin`, 900 bytes: 10 × 10 × 9-byte channel names, all-zero where unnamed.

**HTTP endpoint**, one per group, URL stored in `[group][0]`:

4. Plain GET, no auth, body ≤ 1023 bytes, delivered in **one** read.
5. Integers separated per §2.4. Index 0 is ignored; indices 1..10 are the channels. The select-server path
   can read a 12th and 13th value as week/day overrides.

**TCP listener:**

6. Port **8281**, IPv4 only, address must be reachable as a dotted quad.
7. Expect exactly 4 bytes `11 F3 11 1F` from the client on connect. Send **nothing** in reply — no init code.
8. Frame everything as 12-byte header + body, little-endian, `Size` inclusive, `12 ≤ Size < 131072`.
9. Encrypt bytes 4..Size−1 with the table at `…/CPSock.cpp:10-27` keyed off the header's `KeyWord`, and set
   `CheckSum` = (Σ ciphertext − Σ plaintext) over that same range, truncated to 8 bits.
10. Accept an arbitrary inbound `KeyWord` byte; do not validate it against a rolling sequence.

**Login:**

11. Read 0x20D at 120 bytes: password at 12, name at 28, TID at 44, Version at 96 (expect 1758), Force at
    100, fingerprint at 104.
12. Reply 0x10A at **1928** bytes with the padding at offsets 28 and 1924 — or reject with 0x11C / 0x11D.
13. `SecretCode` must be 16 bytes the client can XOR with 0xFF as its next 16 send keywords.

**Channel hop:**

14. Recognise a 0x334 whisper to `"srv"` whose body is a decimal channel number.
15. Reply 0x52A at 80 bytes with `TID` beginning `*<channel>`.
16. On the destination connection, expect 0x20D with an **empty password** and that same TID, and reply 0x10A
    in the `MSG_CNFRemoveServerLogin` shape, not the `MSG_CNFAccountLogin` shape.

**Client-side rejections to stay clear of:**

17. Account name outside 4..12 characters and password under 4 characters never leave the client.
18. Population ≥ 600 blocks the picker; ≥ 500 blocks the in-game hop.
19. A `Size` outside `[12, 131072)` or a bad checksum halts the receive drain.

---

## 8. Gotchas

### 8.1 The obfuscation key depends on the build machine's code page

`…/Basedef.cpp:1339` is a narrow literal of 64 non-ASCII code points in a UTF-8-with-BOM file, and the
project passes neither `/utf-8` nor `/execution-charset` (`…/TMProject.vcxproj:33,41,47,54` set only
`CharacterSet`). The emitted key bytes are whatever the compiling machine's ANSI code page produces. On a
Western code page that is the 64 Latin-1 bytes; on a CJK one the literal expands and overruns the `char[65]`
it initialises. **Any tool that generates `serverlist.bin` must use the same bytes the client binary was
compiled with**, which means reading them out of the built executable or pinning the compiler's code page.
The visible mojibake in that literal also suggests it was originally a CP949 Korean string that was decoded
as Latin-1 at some point in the decompilation.

### 8.2 The HTTP feed separator is almost certainly wrong

`"%d\\n%d\\n…"` (five occurrences, `…/TMSelectServerScene.cpp:216,411,423` and `…/TMFieldScene.cpp:3861,3873`)
means literal backslash-n at runtime, not a newline. Reading the whole set together, they look like strings
lifted from a disassembler listing without un-escaping. Consequence if a server emits real newlines: `sscanf`
stops after the first conversion, all channels show population 0 with `m_cConnected = 0`, and — because the
picker's block is `>= 600` on a value of 0 — everything is still selectable. So it fails **soft**, which is
probably why it survived. Flagging it rather than assuming: this is a place where the client may need a fix
before the server can present real numbers.

### 8.3 `m_cConnected` is write-only

Declared at `…/SControl.h:509`, set to 1 in the constructor (`…/SControl.cpp:2225`), set to 0 at four call
sites (`…/TMSelectServerScene.cpp:558,569`; `…/TMFieldScene.cpp:3964,3974`), and **read nowhere**.
`SListBoxServerItem::FrameMove2` (`…/SControl.cpp:2260-2270`) does not consult it. There is no "this channel
is down" rendering, only the implicit zero-length bar.

### 8.4 Off-by-ones and out-of-bounds reads in the picker

Several, all live:

- `…/TMSelectServerScene.cpp:1362-1370` and `…/TMFieldScene.cpp:3819-3826` loop the **group** index to 11
  (`MAX_SERVERNUMBER`) over an array whose group dimension is 10 — `g_pServerList[10]` reads past the array.
- `…/TMSelectServerScene.cpp:1366` sets `m_nMaxGroup = i - 1`, so an empty group 0 yields −1.
- `…/TMSelectServerScene.cpp:1418-1419` tests `g_szServerNameList[i][0]` but prints `g_szServerNameList[i+1]`
  — every group row is labelled with the *next* group's name, and at `i = 10` it reads index 11 of an
  11-element array.
- `…/TMSelectServerScene.cpp:383` computes `nIndexN = g_nServerCountList[nMaxGroupN - idwEvent - 1] - 1`
  **unconditionally, before the switch**, so it executes for every control event in the scene including the
  login button, with an index that can go negative.
- `…/TMSelectServerScene.cpp:494` tests `g_szServerName[g][m_nDay[g]]` but prints
  `g_szServerName[g][m_nDay[g] - 1]`; `:519-520` tests and prints index `num` (1-based) into an array whose
  channel dimension is 0-based and 10 long, while `…/TMFieldScene.cpp:3925-3926` uses `num - 1` for the same
  lookup. The two screens disagree about the indexing of `sn2.bin`.

### 8.5 Debug leftovers

- `…/TMSelectServerScene.cpp:605` — a `printf` of the chosen IP, in Portuguese, to a console the client
  opens explicitly at `…/NewApp.cpp:52`.
- `g_hPacketDump` writes every received packet to a file when non-null (`…/NewApp.cpp:1130-1135, 1188-1193`).
- `…/TMSelectServerScene.cpp:175` compares the screen width against `12180`, which is not a resolution —
  almost certainly a typo for 1280, leaving that branch dead.
- `…/TMSelectServerScene.cpp:207-218` computes `nUserCount`, `nAspGetweek` and `nAspGetday` in
  `InitializeScene` and then never reads them.

### 8.6 The keyword rolling formula never runs

`EncodeByte` is a global `char[4]` (`…/Basedef.cpp:13`) that is **never written**. Both branches that guard on
it test the array itself — `if (EncodeByte)` at `…/CPSock.cpp:433` and `if (EncodeByte != 0)` at
`…/CPSock.cpp:331` — which decays to an address and is always true. On send that leads to an empty body
(the decompiler left a comment there, `…/CPSock.cpp:435`) so `Keyword` stays 0 and `AddMessage` falls back to
`rand()`. The `SendQueue`-based formulas at `…/CPSock.cpp:439-442` and `:451-454` are therefore unreachable.

Likewise `RecvQueue` is only ever `memset` to zero (`…/CPSock.cpp:44`) and never seeded, so the inbound
keyword validation block at `…/CPSock.cpp:324-355` never executes. **The server can put anything in the
`KeyWord` byte.**

### 8.7 The account credential mangling is dead

`…/TMSelectServerScene.cpp:740-758` copies the account name into `ObjectManager`, replaces all but the first
two characters of the password with random digits, uppercases both, and adds each byte's index to it. Those
two buffers (`…/ObjectManager.h:98-99`) are then **never read anywhere** in the client. It looks like the
remains of an on-wire obfuscation scheme that was moved or removed. Note also `nLen2` is computed at `:752`
and unused, and the second shifting loop at `:757-758` iterates over `nLen1` — the *name's* length — while
indexing the password.

### 8.8 One opcode, two bodies

Opcode `0x10A` is `MSG_CNFAccountLogin` in `TMSelectServerScene` (`…/TMSelectServerScene.cpp:832-837`) and
`MSG_CNFRemoveServerLogin` in `TMFieldScene` (`…/TMFieldScene.cpp:6360-6361`). The field orders differ from
byte 12 onward. The server has to know which of the two flows the client is in — which it can, because the
distinguishing input is whether the preceding 0x20D carried a TID.

### 8.9 A second socket that is never connected

`g_LoginSocket` is allocated at `…/NewApp.cpp:467` and drained on `WM_USER + 1` (`…/NewApp.cpp:1097-1154`),
but `ConnectServer` / `SingleConnect` are never called on it (grepped: the only references are the
allocation and the message pump). There is no login server in this build. `ESCENE_LOGIN` likewise exists as
an enum value (`…/TMScene.h:12`) with no scene class behind it — it is only ever compared against
(`…/TMScene.cpp:863,878`; `…/TMFieldScene.cpp:18723`).

### 8.10 Version drift signals

Things that read like they changed between client versions and were partially updated:

- The full/blocked thresholds disagree between the two screens (600 vs 500, §6.2) and between label and
  block on the same screen.
- `RefreshSendBuffer` (`…/CPSock.cpp:652-663`) copies from `pRecvBuffer` into `pSendBuffer` — a
  copy-paste bug against `RefreshRecvBuffer` just above it. It runs whenever a partial send happened
  (`…/CPSock.cpp:542-543`).
- `IsCastle` (`…/TMSelectServerScene.cpp:48-52`) uses `& 2` where the parity test wants `& 1`, and its input
  `BASE_GetWeekNumber` (`…/Basedef.cpp:424-431`) divides by 86400 — days, not weeks — despite the name. The
  `nAspGetweek`/`nAspGetday` override path (`…/TMSelectServerScene.cpp:469-472`) reads like a later
  replacement for it.
- `ServerList_Path` exists in `…/TMPaths.h:12` but `BASE_InitializeServerList` hardcodes `./serverlist.bin`
  at `…/Basedef.cpp:1335` — the constant was extracted and the call site not updated.
- `…/TMSelectServerScene.cpp:571` and `:554` carry the decompiler's own `TODO : review code` and `-1??`
  markers on the placeholder-row and texture-set logic.
- `STRUCT_SELCHAR_OLD` / `STRUCT_SCORE_OLD` survive at `…/Basedef.h:611-618` beside the current ones.

---

## 9. What I looked for and did **not** find

### 9.1 Searched for and confirmed absent

Greps across `packages/apps/client/Projects/` (all `.cpp` and `.h`):

- `ServerList` / `SERVERLIST` / `SERVER_LIST` as an **opcode or packet name** — the only matches are
  `BASE_InitializeServerList`, `g_pServerList` and `ServerList_Path`. No packet carries the list.
- `SelectServer` / `ServerSelect` — matches only the scene class and the UI control constants.
- `World` — no hits in any server/channel context.
- `Channel` — only `g_nChannelWidth` (a pixel width) and the caption constant `TMT_SEL_CHANNEL_TEXT`. There
  is no channel data structure distinct from the server array.
- `m_pServer` — matches only `m_pServerPanel` / `m_pServerList`, both UI pointers in `TMFieldScene`.
- `#pragma pack` — **zero hits in the entire client**. Default MSVC alignment applies everywhere, which is
  why §4.3 has padding.
- Hardcoded IP literals — a regex for dotted quads, `127.0.0.1`, `localhost` and `http://` over all sources
  returns exactly one hit, a documentation URL in `…/dsutil.h:7`. No addresses are compiled in.
- Opcode constants containing `Server` — `…/Basedef.h` has none; 0x52A is a bare literal at
  `…/TMFieldScene.cpp:6359` with no named constant.

### 9.2 Data files not present in the repo

`packages/apps/client` ships source only. None of the files this note describes exist in the tree — I
verified by searching for every `*.bin`, `*.ini` and `*.txt` outside `Dependencies/`, which returns a single
file, `Infos/Files Name.txt` (a 110-line index of source files, not data). So:

- `serverlist.bin`, `sn.bin`, `sn2.bin` — **absent**. Their layouts above are derived from the load code
  alone. I could not confirm them against a real file, and in particular I could not confirm the
  `sn2.bin` indexing ambiguity of §8.4 empirically.
- `UI\SelServerScene2.txt` — **absent**. The picker's geometry, which control IDs actually exist, and the
  list boxes' `m_nVisibleCount` all come from that file. I know the IDs the code looks up
  (`…/ResourceControl.h:1554-1560`) but not which of them the shipped resource defines. If `L_SELECT_SERVERG`
  is missing from it, `InitializeUI` skips the whole group-list build (`…/TMSelectServerScene.cpp:1360`).
- `UI\strdef.bin` — **absent**. The message string table is 2000 × 128 bytes, XOR-obfuscated with 0x5A and
  checksummed (`…/Basedef.cpp:298-322`). Every user-facing string in the picker is an index into it
  (3, 4, 5, 7, 8, 11, 12, 22, 23, 24, 25, 66, 68, 70, 132, 263). I can say which index is shown when, not
  what it says. Indices 66 and 68 are `printf` **templates** with `%d` conversions
  (`…/TMSelectServerScene.cpp:541, 1421`), so their contents constrain the label format.

### 9.3 Derived, not measured

Every `sizeof` and offset in §4 and §5 is my computation under MSVC 32-bit default alignment. I did not
compile the client and I did not run it. The three that would hurt most if wrong:

- `sizeof(MSG_CNFAccountLogin)` = 1928 with padding at offsets 28 and 1924, which hangs entirely on
  `long long` being 8-aligned inside `STRUCT_SELCHAR`.
- `sizeof(MSG_MessageWhisper)` = 160 with 2 tail padding bytes.
- `sizeof(STRUCT_SELCHAR)` = 840.

The cheap way to settle all three is a `static_assert` on each size, added **in the `w2-client` repo** (per
`CLAUDE.md`, the client is not edited from here), and a `Release|x86` build.

### 9.4 Open questions

1. **Is the `\\n` separator a decompilation artefact or the real format?** Deciding this needs either the
   original binary or a live server's population page. It changes what our HTTP endpoint must emit (§8.2).
2. **What exactly goes in `TID` beyond the leading `*<channel>`?** The client only parses the prefix
   (`…/TMFieldScene.cpp:18674`) and echoes the whole 52 bytes back (`:18715`). The remaining bytes are
   opaque to the client, so the server owns that format entirely — but if there is an existing convention,
   nothing in the client reveals it.
3. **What is the intended keyword rolling scheme past message 16?** The formulas at `…/CPSock.cpp:439-442`
   exist but are unreachable (§8.6). Whether a real server validated them is not visible from the client.
4. **Are `SSN1` / `SSN2` meaningful?** They are received and discarded on both 0x10A paths.
5. **What do opcodes 0x101, 0x11C and 0x11D mean individually?** The client treats 0x11C and 0x11D
   identically (one message string) and 0x101 only re-shows the login panel. Their distinct meanings are not
   recoverable from this side.
6. **Does anything ever set `g_szServerName` entries such that the `num` vs `num - 1` disagreement (§8.4)
   becomes visible?** Without `sn2.bin` I cannot tell whether real installs populate it at all.
