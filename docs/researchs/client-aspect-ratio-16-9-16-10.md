# Research: moving the WYD / TMProject client to 16:9 + 16:10 and dropping 4:3

Date: 2026-08-16. Repo: `/home/nrechdan/projects/w2-server`. Submodule `packages/apps/client` read at pinned
commit `5018219b6fc623304403c09e10c44d19c788a8ad` (`Replaced the server picker with email and password login`).

**Primary source only.** Every claim carries a `path:line` citation into the client tree. All client paths
start `packages/apps/client/Projects/TMProject/`, abbreviated below as `…/`.

**Licence note.** The client is GPL v3, this repo is Apache-2.0. Nothing here is copied from it. Tables below
are re-derived descriptions with line pointers; the resolution table, the style-flag constants and the enum
bodies are pointed at, not reproduced. Read them from the client when you need the literal values.

Nothing in this note was compiled or run. §10 lists what that leaves unverified.

---

## Verdict up front

**Medium, and almost entirely client-side.** Nothing in this repo's server or web workspace, and nothing in
`openspec/`, knows the client's resolution (§7). The 3D renderer is already aspect-correct. The problem is
one line of UI scaling and the ~15 call sites that hardcode a specific 4:3 resolution around it.

| Layer | State today | Work |
| --- | --- | --- |
| 3D projection | **Already dynamic** — aspect from the real backbuffer, `…/RenderDevice.cpp:1841` | Decide Hor+ vs Vert+ (§9), otherwise none |
| Mouse picking / unprojection | **Already dynamic** — derived from `m_matProj`, `…/RenderDevice.cpp:1875-1876` | None |
| UI layout | **Non-uniform stretch of an 800×600 design**, `…/SControl.cpp:31-36` | This is the whole job |
| Mode list | Hardcoded 11-entry table, all 4:3 or 5:4, `…/NewApp.cpp:87-119` | Replace or enumerate |
| Windowed mode | Fixed-size caption window created at (0,0), `…/NewApp.cpp:267-292` | Breaks at native 16:9 (§4.1) |
| Fullscreen | Forces the desktop into the chosen mode via `ChangeDisplaySettings`, `…/RenderDevice.cpp:494` | Consider borderless instead (§9) |
| Assets | UI atlas + three layout `.bin` files, **none of them in this repo** | See §6 |

**The single hardest part is `…/SControl.cpp:31-36`.** Every `SControl` — every panel, button, text, grid,
progress bar — multiplies its authored X/width by `screenW/800` and its Y/height by `screenH/600` **in the
base constructor**. Those two factors are equal only at 4:3. At 16:9 they diverge by 33%, so everything the
UI draws is anisotropically stretched: square item icons become rectangles, round art becomes oval, and every
piece of per-resolution nudge code downstream (§3.2) was tuned against that stretch. You cannot fix this by
patching call sites; the fix has to change what the base constructor means, and then every site that
compensates for the old meaning has to be revisited.

---

## 1. How the client picks a resolution today

The chain, in order:

1. `NewApp::Initialize` builds a local 11-entry `stResList` of width/height/bpp — `…/NewApp.cpp:76`
   (declaration), `…/NewApp.cpp:87-119` (values). Entries 1–5 and 6–10 are the **same five modes twice**
   (640×480, 800×600, 1024×768, 1280×1024, 1600×1200); the 11th is 3200×2400. All are 4:3 except 1280×1024,
   which is 5:4. The duplication used to select the "classic" UI (§3.3) and is now dead.
2. `Config.bin` is read whole into a `SaveUpdatAndConfig` — `…/NewApp.cpp:130-140`, struct at
   `…/NewApp.h:13-17` (a version short plus 14 config shorts). If the file is missing, a hardcoded default
   block is used — `…/NewApp.cpp:142-156`.
3. `Config[0]` is the 1-based mode index — `…/NewApp.cpp:160`; `Config[8]` is the windowed flag —
   `…/NewApp.cpp:170-176`.
4. The chosen entry populates `m_dwScreenWidth` / `m_dwScreenHeight` / `m_dwColorBit` —
   `…/NewApp.cpp:219-221`. `CheckResolution` (`…/NewApp.cpp:1283-1296`) walks `EnumDisplaySettings` looking
   for an **exact** W/H/bpp match and, failing that, the code falls back to entry index 1 = 800×600 —
   `…/NewApp.cpp:222-227`.
5. Font size is picked by a `switch` on the **width literal** — `…/NewApp.cpp:228-246`. Unlisted widths fall
   to a default of 24.
6. The window is created — `…/NewApp.cpp:251-292`. Style is `WS_POPUP` when fullscreen, else
   caption+sysmenu+minimize (no `WS_THICKFRAME`, no `WS_MAXIMIZEBOX` — **the window is not resizable**),
   OR'd with `WS_VISIBLE` — `…/NewApp.cpp:267-274`. `AdjustWindowRect` grows the requested client rect by
   the non-client frame (`…/NewApp.cpp:279`) and `CreateWindowEx` places it at **(0,0)**, not centred —
   `…/NewApp.cpp:281-292`.
7. `NewApp::InitDevice` constructs the `RenderDevice` and, when fullscreen, calls `SetWindowedFullScreen` —
   `…/NewApp.cpp:378-383`. That reads the current desktop mode via GDI and then `ChangeDisplaySettings` the
   whole desktop into the chosen mode — `…/RenderDevice.cpp:462-472` and `…/RenderDevice.cpp:483-496`. The
   destructor restores it — `…/NewApp.cpp:56-59`, `…/RenderDevice.cpp:476-482`.
8. `D3DDevice::Initialize` seeds its client rect from those dimensions (`…/D3DDevice.cpp:76-79`), then
   `ChooseInitialD3DSettings` (`…/D3DDevice.cpp:515`) picks a device combo through
   `FindBestFullscreenMode` / `FindBestWindowedMode` (`…/D3DDevice.cpp:395`, `…/D3DDevice.cpp:323`) over
   the modes enumerated by `EnumAdapterModes` (`…/D3DEnumeration.cpp:337`). Present params take the
   backbuffer size from the window client rect when windowed (`…/D3DDevice.cpp:280-281`) and from the D3D
   display mode when fullscreen (`…/D3DDevice.cpp:290-291`).

One command-line switch exists: `/w` forces windowed — `…/NewApp.cpp:1325`. No resolution switch.

### Where the setting is authored

**Not in the client.** The client only ever *reads* `Config.bin` (`…/TMPaths.h:10`); there is no writer
anywhere in the source tree. The client shells out to `Change.exe` at startup (`…/TMPaths.h:9`, launched at
`…/NewApp.cpp:41`, deleted at `…/NewApp.cpp:324`) — that external launcher owns the options UI. **Changing
the mode list therefore means changing a binary this repo does not contain** unless the client grows its
own picker. See §9.

---

## 2. What is already aspect-correct — leave it alone

- **Perspective projection.** `SetProjectionMatrix` passes a constant vertical FOV (`m_fFOVY`, 0.25 →
  45°, `…/RenderDevice.cpp:29`) and computes aspect as width/height from the live device dimensions —
  `…/RenderDevice.cpp:1837-1852`. It is re-run every time the viewport is set (`…/RenderDevice.cpp:355`),
  and the viewport is set from the real screen size once per frame (`…/NewApp.cpp:640`) and on device
  restore (`…/RenderDevice.cpp:548`).
- **UI-space 3D projection** (character preview, 3D item icons) uses the backbuffer aspect times a
  0.94 fudge — `…/RenderDevice.cpp:1857`.
- **Mouse picking.** `GetPickRayVector` divides by `m_matProj.m[0][0]` / `m[1][1]`, so it inherits whatever
  aspect the projection used — `…/RenderDevice.cpp:1872-1889`.
- **UI hit-testing.** `PtInControl` tests the control's own scaled rect — `…/SControl.cpp:213-216` — so it
  always agrees with layout, whatever the scaling rule is.
- **Object visibility.** `TMObject::IsInView` rejects by distance against `m_fFogEnd` (156.0f,
  `…/RenderDevice.cpp:57`) first, then by a screen-rect test against the live viewport —
  `…/TMObject.cpp:459-473` and `…/TMObject.cpp:555-586`. Same shape in `BASE_IsInView`
  (`…/TMUtil.cpp:91-139`). Draw distance is distance-based; the screen test just follows the frustum.
- **`m_nWidthShift` / `m_nHeightShift`** are a dead knob. Initialised to 0 (`…/RenderDevice.cpp:52-53`)
  and every other write in the tree assigns 0 (e.g. `…/TMFieldScene.cpp:527`, `…/TMLoginScene.cpp:202`).
  They are subtracted from the screen size in ~30 places. Harmless; not worth touching in this change.
- **The `800.0f * m_fWidthRatio` clip-rejection tests** at `…/SControl.cpp:376-377`, `…/SControl.cpp:856-857`
  and `…/SControl.cpp:958-959` read as 4:3 constants but algebraically evaluate to the real screen size.
  No change needed — but they will *look* like bugs to the next reader, so they are worth simplifying while
  you are in the file.

---

## 3. Everything that assumes 4:3

### 3.1 The root: non-uniform UI scaling

| Site | What it does |
| --- | --- |
| `…/RenderDevice.cpp:64-65` | Defines `m_fWidthRatio = screenW/800`, `m_fHeightRatio = screenH/600` |
| `…/SControl.cpp:31-36` | **Base `SControl` ctor** applies both factors to every control's pos and size |
| `…/SControl.cpp:1796-1797` | `SProgressBar::FrameMove2` recomputes the same two factors locally |
| `…/Basedef.cpp:29-32` | `BASE_ScreenResize(n)` — a *width-only* `screenW * n/800` helper |
| `…/SControl.cpp:181-185` | `SetAutoSize` — the same non-uniform stretch, applied again |
| `…/SControl.cpp:187-191` | `SetCenterSize` — centres an 800×600 box in the screen |

`m_fWidthRatio` / `m_fHeightRatio` are then multiplied into literal offsets at roughly 150 further call
sites across `…/TMFieldScene.cpp`, `…/TMHuman.cpp`, `…/SGrid.cpp`, `…/TMFont3.cpp`,
`…/TMSelectCharScene.cpp`, `…/TMScene.cpp` and others. Two that matter visibly:

- `…/SGrid.cpp:5157-5160` and `…/SGrid.cpp:5177-5180` size inventory cells as `23 × ratio` / `35 × ratio`
  per axis — square cells become rectangles the moment the two ratios diverge.
- `…/SGrid.cpp:722-723` does the same for the 24×24 item icon.

There **are** anchoring primitives already: `SetStickLeft/Right/Top/Bottom` at `…/SControl.cpp:193-211` and
the ID-whitelisted horizontal centring in `SetCenterPos` at `…/SControl.cpp:223-237` (note it only ever
touches X, and only for five hardcoded control IDs). They are barely used — nine call sites total, all in
`…/TMFieldScene.cpp:962-963,1000-1002,1878-1879` and `…/TMSelectCharScene.cpp:208-209`. **These are the
hook for the fix**: the target design is uniform scale + edge anchoring, and half the vocabulary exists.

### 3.2 Hardcoded per-resolution branches — these are deletions

Each of these tests a specific 4:3/5:4 resolution or its derived ratio with **float equality**, so any
16:9 or 16:10 mode silently falls through to an untuned default:

| Site | Test |
| --- | --- |
| `…/TMLoginScene.cpp:140-162` | Logo panel placement branches on width == 1600 / 1024 / 12180 (that last is a typo for 1280 and is dead) |
| `…/TMLoginScene.cpp:958-975` | Rating-splash panel scale factor chosen by a `switch` on width |
| `…/TMFieldScene.cpp:16259-16279` | `SetButtonTextXY` nudges button label offsets on ratio == 0.8 / 1.28 / 1.6 / 2.0 |
| `…/RenderDevice.cpp:3179-3198` | Guild-mark blit offsets on ratio == 0.8 / 1.0 / 1.6 / 2.0 |
| `…/RenderDevice.cpp:3278`, `:3297` | Text baseline nudge when width == 640 |
| `…/TMHuman.cpp:7567-7580`, `:8012-8025` | Nameplate/HP-bar Y offsets on `m_fHeightRatio` == 1.0 or >= 1.7 |
| `…/TMMesh.cpp:286-287` | `RenderForUI` swaps a magic width divisor when viewport aspect < 1.26 — i.e. it exists purely to tell 5:4 (1.25) apart from 4:3 (1.333) |

Note `…/TMMesh.cpp:286-287` is the only place in the tree that branches on *aspect* rather than on a
resolution. Every 16:9 (1.778) and 16:10 (1.6) mode takes its non-5:4 arm already.

### 3.3 The dead "classic UI" path

`g_UIVer` defaults to 2 (`…/TMGlobal.cpp:34`), is read from `Config[9]` (`…/NewApp.cpp:183`), forced to 1
for the 640×480 entries (`…/NewApp.cpp:184-185`) — and then **unconditionally reassigned to 2 five lines
later** at `…/NewApp.cpp:193`. Its only consumer is `SListBox::SetPickSize` at `…/SControl.cpp:2437-2438`,
which uses 1.0 instead of the ratios when `g_UIVer == 2`. So: the classic UI is unreachable, the duplicate
half of the mode table exists only to select it, and both can go.

### 3.4 UI layout is data, not code

Layout comes from three binary resource files, one per scene, loaded through `TMScene::LoadRC` —
`…/TMScene.cpp:290-303` (it rewrites the `.txt` name it is given into `.bin`) and `TMScene::ReadRCBin` —
`…/TMScene.cpp:307` onward. The three files are named at `…/TMLoginScene.cpp:106`,
`…/TMSelectCharScene.cpp:71` and `…/TMFieldScene.cpp:602` (`UI\SelServerScene2`, `UI\SelCharScene2`,
`UI\FieldScene2`). Each record carries **absolute integer** `nStartX` / `nStartY` / `nWidth` / `nHeight`
plus a parent ID, authored against 800×600, fed straight into the control constructors that then apply the
§3.1 stretch (`…/TMScene.cpp:341-352` for panels; grids, buttons, texts, edits, progress bars, checkboxes
and listboxes follow the same shape through `…/TMScene.cpp:800`).

**Consequence: no amount of C++ editing gives you a good 16:9 HUD on its own.** Absolute coordinates in a
data file cannot express "anchor to the right edge". You either add an anchor field to the `.bin` format
(and to whatever authoring tool produces it) or you keep overriding positions in C++ after `LoadRC`, the
way `…/TMFieldScene.cpp:962-1002` already does. The second is the lazy path and is what the code is already
doing; the first is the correct one.

---

## 4. Work breakdown, in order

### 4.1 Display init (small, do first)

1. Replace `stResList` (`…/NewApp.cpp:76,87-119`) with 16:9 + 16:10 entries only. This is the literal
   "drop 4:3" edit. Drop the duplicated second block and the 3200×2400 entry with it (§3.3).
   `Config[0]` is a 1-based index into this table (`…/NewApp.cpp:160,219`), so **renumbering it silently
   re-points every existing user's saved setting** — see §9.
2. Fix the fallback at `…/NewApp.cpp:222-227`: it currently falls back to index 1 = 800×600.
3. Replace the width `switch` for font size at `…/NewApp.cpp:228-246` with a formula on height.
4. **Windowed mode breaks at native 16:9.** The window is non-resizable, positioned at (0,0), and
   `AdjustWindowRect` (`…/NewApp.cpp:279`) adds the caption and border *outside* the requested client area.
   Ask for a 1920×1080 client area on a 1920×1080 desktop and the window is ~30px taller than the screen.
   Either centre-and-clamp, or use `WS_POPUP` at desktop size for the top mode (borderless fullscreen).
5. Optional but cheap: `CheckResolution` (`…/NewApp.cpp:1283-1296`) already enumerates the adapter's modes.
   Filtering that enumeration by aspect ratio gives a real mode list for free and makes the hardcoded table
   redundant.

### 4.2 UI scaling (the bulk)

6. Change `…/SControl.cpp:31-36` to a **uniform** scale — one factor, derived from height (`screenH/600`)
   so the design's vertical rhythm is preserved and the extra horizontal space becomes margin rather than
   stretch. Mirror the change in `…/SControl.cpp:1796-1797` and `…/SControl.cpp:181-185`.
7. Keep `m_fWidthRatio` and `m_fHeightRatio` as symbols but make them both equal to that uniform factor.
   That single move makes ~150 downstream call sites correct without touching them, and is the reason to
   prefer it over introducing a new symbol.
8. Re-anchor the HUD. Every panel currently placed at `ratio * <literal>` in `…/TMFieldScene.cpp` (the
   inventory at `:1062`, skills at `:1305`, shop/cargo/trade at `:1233-1261`, the minimap block at
   `:12746-12778`, the chat block at `:967-1012`) needs to become an anchor to a screen edge instead. The
   `SetStick*` helpers at `…/SControl.cpp:193-211` already do this; extend them with a margin parameter
   rather than writing new code.
9. Delete the branches in §3.2 and replace each with the ratio-driven expression it was approximating.
10. `…/SGrid.cpp:5157-5180` and `:722-723` fall out of step 6 automatically once the two ratios are equal —
    verify rather than edit.

### 4.3 3D projection (a decision, not a code change)

11. `…/RenderDevice.cpp:1837-1852` needs **no edit** to work at 16:9. It needs a decision about whether it
    *should* — see §9.

### 4.4 Config and launcher

12. Nothing to do in the client; `Config.bin` is written by `Change.exe`, which is not in this repo (§1).
    The mode list has to be changed in both places or the launcher will write indices the client
    misinterprets.

---

## 5. What "drop 4:3" concretely means

**Deletions:**

- The 4:3 and 5:4 rows of `stResList` — `…/NewApp.cpp:87-119`. Pure deletion.
- The duplicated second half of that table plus the 3200×2400 row (§3.3).
- The `g_UIVer` classic-UI path: `…/NewApp.cpp:183-193`, `…/SControl.cpp:2437-2438`, `…/TMGlobal.cpp:34`.
- Every branch in the §3.2 table — all seven sites. All are per-resolution hacks with no meaning once
  scaling is uniform.
- `…/TMMesh.cpp:286-287`'s 1.26 aspect test, whose only purpose was separating 5:4 from 4:3.

**Behaviour changes (no deletion):**

- `…/SControl.cpp:31-36` — the meaning of the constructor's scaling changes; the code stays.
- `…/NewApp.cpp:228-246` — font sizing moves from a width table to a height formula.
- `…/NewApp.cpp:267-292` — window creation gains a fit/centre step.
- HUD placement in `…/TMFieldScene.cpp` — same calls, different arguments (anchors instead of ratios).

**Untouched:** the wire protocol. `…/CPSock.cpp` has no screen, resolution, width or height reference;
`…/Basedef.h` and `…/Enums.h` carry nothing display-related except `RENDERCTRLTYPE` (`…/Enums.h:3-12`),
which is a draw-mode enum, not a layout one.

---

## 6. Asset impact

The client repo contains **only source and the vendored DirectX headers** — no `UI/`, no `.wys`, no `.bin`
data (`packages/apps/client` has `Dependencies/`, `Infos/`, `Projects/`, `Release/` and nothing else; the
game data ships separately). So this section is what the *code* says the assets are, not an inspection of
them.

| Asset | Loaded by | Impact of dropping 4:3 |
| --- | --- | --- |
| `UI\FieldScene2.bin`, `UI\SelCharScene2.bin`, `UI\SelServerScene2.bin` | `…/TMScene.cpp:290-303` | **Re-authoring, not re-art.** Absolute 800×600 coordinates. Either re-author against a new base or keep patching positions in C++ (§3.4) |
| `UI\UITextureSetList.txt` + `UI\UITextureListN.bin` | `…/TextureManager.cpp:426-455`, paths at `…/TMPaths.h:34-35` | Atlas of source rects. `RENDER_IMAGE_STRETCH` (`…/Enums.h:10`) stretches the source rect to the control rect (`…/RenderDevice.cpp:2860`), so nothing breaks — but 800×600-era art upscaled to 1920 will be soft. Re-art is a quality call, not a correctness one |
| `UI\minimap.wyt` + `minimap.dat` | `…/TMPaths.h:36`; the `.dat` marker table is parsed at `…/TMFieldScene.cpp:562-597` | Marker coords go through `BASE_ScreenResize` at `…/TMFieldScene.cpp:6517-6521`, so they follow whatever scaling rule you pick. No re-art |
| `WYD.avi` intro | `…/NewApp.cpp:305-313` via `TMVideoWnd` | **Not determined** — `TMVideoWnd.cpp` has no screen-size or letterbox reference. Whether DirectShow letterboxes or stretches a 4:3 clip into a 16:9 window is a runtime question |
| Login/character-select backgrounds | Panels declared in the scene `.bin` files, e.g. `…/TMSelectCharScene.cpp:218-224` | Any full-bleed background authored at 4:3 will stretch. These are the assets most likely to need actual re-art |

Net: **one re-authoring job (the three layout files), one optional re-art job (backgrounds and the atlas).**

---

## 7. Server and web: nothing

- `packages/apps/server/src` is 251 lines across six files (`main.rs`, `server.rs`, `connection.rs`,
  `client.rs`, `channel.rs`, `utils/`). No resolution, screen, window or aspect reference.
- `packages/apps/web/src` — same, nothing.
- `openspec/specs/` holds only `account-login-protocol` and `client-login`; `openspec/changes/archive/`
  holds only `2026-08-16-replace-server-select-with-email-login`. Neither touches display.
- `docs/researchs/` has no prior note on rendering or windowing (`client-server-list.md` is protocol,
  `wsl2-client-build-watcher.md` is toolchain).

---

## 8. Cross-repo process

**This is client-only.** Nothing here changes the wire protocol (§5), so nothing here needs a server change,
a pin bump paired with a server commit, or `/w2-commit`. Per CLAUDE.md the work is: a named branch in
`packages/apps/client`, commits there, push, then a pin bump in this repo as its own commit with nothing
else in it.

Two caveats:

- If the mode list ends up spec'd rather than just changed, it is product behaviour and wants an OpenSpec
  proposal first (`/opsx:propose`) — unlike the build-script work, which CLAUDE.md explicitly exempts.
- `Change.exe` (§1, §4.4) is in neither repo. If the options UI has to move into the client, that is a new
  scene and materially larger than the rest of this note.

---

## 9. Risks and open questions

1. **Hor+ vs Vert+ — needs a decision, and it is a fairness question.** `…/RenderDevice.cpp:1839-1843` holds
   vertical FOV constant and derives aspect from the backbuffer. Going from 4:3 (1.333) to 16:9 (1.778) with
   that code unchanged widens the horizontal FOV by ~33% — a 16:9 player sees more of the world to the sides
   than a 4:3 player did, at the same distance. This is a PvP game. Options: leave it (Hor+, simplest, the
   advantage is real), or scale `m_fFOVY` down so horizontal FOV is constant across aspects (Vert+, fair,
   16:9 players get letterboxed-feeling vertical crop). **Nothing in the source picks for you.**
   Server-side entity streaming range is not implemented yet, so there is no server-side cap to lean on.
2. **`Config[0]` renumbering.** Existing `Config.bin` files hold a 1-based index into the old table
   (`…/NewApp.cpp:160,219`). Change the table and every installed client reads a different mode. Either
   bump `SaveUpdatAndConfig::Version` (`…/NewApp.h:15`, currently written as 7000 in the default block at
   `…/NewApp.cpp:143`) and migrate, or accept a one-time reset.
3. **`Change.exe` desync.** The launcher writes the index the client reads. Changing one without the other
   is a silent wrong-resolution bug, not a crash.
4. **Fullscreen mode-setting.** `…/RenderDevice.cpp:483-496` drives `ChangeDisplaySettings` on the whole
   desktop. On a modern flat panel this is slow, flickers, and disturbs other windows. Borderless windowed
   at desktop resolution would sidestep it *and* the mode-list problem *and* the §4.1 window-fit problem in
   one move. Worth proposing as the actual shape of this change.
5. **Uniform-scale factor choice** (height-derived vs width-derived) changes how much of the HUD's authored
   design survives. Height-derived is the conventional answer; it has not been validated against this
   client's art.
6. **Ultrawide.** 16:9 and 16:10 only, per the question. Nothing in the proposed approach forbids 21:9, but
   nothing validates it either.

---

## 10. Not determined from source

- **Whether the game data files (`UI\*.bin`, the atlas, backgrounds) can be re-authored at all.** They are
  not in this repo, and no authoring tool is referenced in the client source. The `.bin` layout format is
  readable from `…/TMScene.cpp:307-800`, but that only proves a reader exists.
- **The `.bin` layout record layouts themselves** (`BinPanel`, `BinGrid`, …). They are read with a single
  `fread` of the whole struct — declared in `…/ResourceControl.h` — so the on-disk format is the MSVC
  32-bit struct layout. I did not derive the offsets; you would need to read `…/ResourceControl.h` to size
  an anchor-field addition.
- **Intro video behaviour at 16:9.** `TMVideoWnd` / `…/DirShow.cpp` carry no screen-size or aspect logic;
  whether DirectShow letterboxes or stretches is a runtime observation, not a source fact.
- **What the 0.94 fudge in `…/RenderDevice.cpp:1857` and the 6.3/6.26/4.96/2.48 magic numbers in
  `…/TMMesh.cpp:286-290` were tuned against.** They are unexplained constants in decompiled code. They will
  need re-tuning by eye once scaling is uniform.
- **Whether anything visibly depends on the anisotropic stretch** — some art may have been authored
  pre-squashed to compensate. Only running the client at two aspect ratios answers that.
- Nothing was built or run. `git -C packages/apps/client status` was clean before and after.
