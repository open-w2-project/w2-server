## Why

The client only offers 4:3 and 5:4 display modes, and its UI scales an 800×600 design by
`screenWidth/800` horizontally and `screenHeight/600` vertically — two factors that are equal only
at 4:3. On any widescreen panel the entire HUD is anisotropically stretched: square item icons
become rectangles and round art becomes oval. Every modern display is 16:9 or 16:10, so the
supported mode list no longer intersects the hardware players actually own.

The mode picker that used to select a resolution (`Change.exe`) is absent from current installs, so
the resolution is in practice frozen at whatever index was last written to `Config.bin`. There is
nothing to preserve compatibility with.

## What Changes

- **BREAKING**: the 4:3 and 5:4 display modes are removed. The mode table is replaced with 16:9 and
  16:10 entries only, and its bit-depth field is dropped.
- **BREAKING**: `Config.bin`'s stored mode index is reinterpreted. The struct's version field is
  bumped and a stale version resets the index to the default, because the old and new tables have
  the same entry count and a stale index would otherwise select a wrong size silently.
- Fullscreen becomes a borderless window at the desktop's own resolution. The client no longer
  changes the desktop display mode.
- Windowed size comes from the stored mode index. When the resulting window does not fit the
  desktop, the client falls back to borderless fullscreen rather than opening a window that cannot
  be moved or closed.
- UI scaling becomes a single uniform factor, introduced as a global pinned at `1.0` for this
  change. Controls are drawn at their authored size and are no longer stretched.
- HUD placement becomes anchor-derived: each top-level control is anchored to a screen edge or
  centred based on where it was authored in the 800×600 design space, so panels sit against real
  screen edges instead of at scaled absolute offsets.
- Removals: the resolution-mode enumeration and matching, the desktop mode-switch path, the
  exclusive-fullscreen device path, seven per-resolution nudge branches that test specific widths
  or aspect ratios by float equality, the unreachable "classic UI" version path, and three dead or
  redundant control-placement helpers.
- The 3D perspective projection is deliberately left unchanged. It already derives aspect from the
  live backbuffer, so widescreen players see more of the world horizontally (Hor+).

Not in this change, but agreed as the shape of the follow-up: an in-client options scene to replace
the absent `Change.exe`. It will persist literal width and height rather than a table index, and
will re-expose the UI scale global.

## Capabilities

### New Capabilities

- `client-display`: how the client chooses its window and fullscreen presentation, which aspect
  ratios and resolutions it supports, how it persists and validates that choice, and how the UI
  scales and anchors to the resulting screen.

### Modified Capabilities

None. `account-login-protocol` and `client-login` describe wire and login behaviour; nothing in
this change touches either.

## Impact

**Client only** (`packages/apps/client`, the `w2-client` submodule). No wire-protocol change, so no
server or web change and no paired commit: a named branch in the submodule, then a pin bump here as
its own commit.

Affected client source, all under `Projects/TMProject/`:

- `NewApp.cpp` / `NewApp.h` — mode table, config read and validation, window creation, font sizing.
- `TMGlobal.cpp` — new home for the mode table and the UI scale global.
- `RenderDevice.cpp` — removal of the desktop mode-switch path and two per-resolution branches.
- `D3DDevice.cpp` — exclusive-fullscreen device path removed; device creation becomes
  windowed-only.
- `SControl.cpp` — the scaling constructor, the anchoring helpers, clip-rejection tests, and the
  placement helpers being deleted.
- `TMScene.cpp` — the record walk that turns layout data into controls, where anchors are applied.
- `TMFieldScene.cpp`, `TMLoginScene.cpp`, `TMSelectCharScene.cpp`, `TMHuman.cpp`, `TMMesh.cpp`,
  `Basedef.cpp` — per-resolution branch removals and scale routing.

**Not changed**: the binary UI layout files (`UI/FieldScene2.bin`, `UI/SelCharScene2.bin`,
`UI/SelServerScene2.bin`) and their on-disk format. Anchoring is derived from the coordinates
already in them, so no data re-authoring and no format break.

**User-visible migration**: existing `Config.bin` files are reset to the default mode on first run
after the version bump.
