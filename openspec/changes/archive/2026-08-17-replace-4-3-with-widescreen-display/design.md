## Context

See `proposal.md` — Why. This section records only the facts about the current client that constrain
the approach. All paths are under `packages/apps/client/Projects/TMProject/`, read at pinned commit
`5018219b6fc623304403c09e10c44d19c788a8ad`. Supporting investigation is in
`docs/researchs/client-aspect-ratio-16-9-16-10.md`.

**The 3D renderer is already aspect-correct.** `RenderDevice.cpp:1837-1852` holds vertical FOV
constant and derives aspect from the live backbuffer; mouse picking inherits it from the projection
matrix at `RenderDevice.cpp:1872-1889`. Neither needs editing to work at 16:9.

**The stretch is in one constructor.** `SControl.cpp:31-36` multiplies every control's X and width by
`m_fWidthRatio` (`screenW/800`) and its Y and height by `m_fHeightRatio` (`screenH/600`), defined at
`RenderDevice.cpp:64-65`. Those factors are equal only at 4:3. The two symbols are then multiplied
into literal offsets at roughly 150 further call sites.

**UI layout is data, and the data format has no slack.** Layout comes from three binary files loaded
by `TMScene::ReadRCBin` (`TMScene.cpp:307-808`) as a bare sequence of `[int32 type tag][fixed-size
record]` pairs read until EOF — no header, no magic, no record count, no version field. Records are
declared in `UIBinary.h`; every field is `int`, so under MSVC 32-bit packing there is zero interior
and zero tail padding in all nine record types. An unrecognised type tag aborts the whole parse
(`TMScene.cpp:806-808`). There is no room to add a field and no way to detect a new format.

**Coordinates are parent-relative.** No branch of the record-to-control conversion adds a parent
origin (`TMScene.cpp:362-372` and the eight siblings); the absolute rect is never stored. Rendering
walks the tree accumulating a running parent offset (`SControlContainer.cpp:281-282`, unwound at
`:302-303`) and hit-testing translates the mouse down the same walk
(`SControlContainer.cpp:64,73-74,94-95`). Moving a parent moves its whole subtree, in both draw and
input.

**Top-level control counts, from parsing the shipped data**: 56 in `FieldScene2.bin` (of 1338
records), 10 in `SelCharScene2.bin`, 5 in `SelServerScene2.bin`. 54 of the 55 distinct top-level IDs
in `FieldScene2.bin` have named constants in `ResourceControl.h`; 12288 has none and appears nowhere
in the C++ sources. Five IDs are duplicated within `FieldScene2.bin`, three of them among the
top-level set — and `FindControl` returns only the first match for a given ID.

**Nothing writes `Config.bin`.** The client only reads it (`NewApp.cpp:130-140`); the external
`Change.exe` launcher owned the options UI and is absent from current installs. The struct carries a
version field (`NewApp.h:15`) written as 7000 in the missing-file default block (`NewApp.cpp:143`).

## Goals / Non-Goals

**Goals:**

- Change what the scaling constructor *means*, so downstream call sites become correct without being
  touched.
- Derive anchoring from data already present in the layout files, so the file format is untouched.
- Leave the resolution table read on every launch, so it cannot rot before the options scene lands.
- Delete every code path the new presentation model makes unreachable, rather than leaving it dormant.

**Non-Goals:**

- No change to the layout file format or the layout files themselves.
- No options UI in this change. The mode index is read, never written.
- No runtime resolution change. Presentation is decided once at startup.
- No re-tuning of art assets. Art may look soft on high-resolution screens; that is a quality
  question for the change that unpins the scale factor.
- No ultrawide validation. Nothing here forbids 21:9 and nothing verifies it.

## Decisions

### Fullscreen is a borderless window at the desktop resolution

Today `SetWindowedFullScreen` reads the desktop mode through GDI and drives `ChangeDisplaySettings`
on the whole desktop (`RenderDevice.cpp:462-472,483-496`), restoring it in the destructor
(`NewApp.cpp:56-59`, `RenderDevice.cpp:476-482`).

Rejected: **exclusive fullscreen with a new 16:9/16:10 mode table.** It keeps the desktop mode
switch — slow, flickering, disruptive to other windows, and unrecovered if the client crashes — and
it needs a resolution picker the client does not have, because `Change.exe` is absent.

Rejected: **enumerate adapter modes and filter by aspect.** `CheckResolution`
(`NewApp.cpp:1283-1296`) already walks `EnumDisplaySettings`, so this is cheap, but it still needs a
picker and still switches the desktop mode.

Borderless-at-desktop removes four problems at once: the mode table, the desktop mode switch, the
window-fit bug below, and the dependency on a binary that is not in either repository.

### Windowed size stays index-driven, and the resolution table stays

The table is not deleted. It moves to `TMGlobal.cpp` beside the new scale global — a function-local
in `NewApp::Initialize` (`NewApp.cpp:76`) cannot be reached by the future options scene — drops its
bit-depth field, and is read on every launch to size the window.

Rejected: **delete the table, derive the windowed size from the desktop work area.** Fewer moving
parts, but it leaves the options scene with no list to present and makes the windowed size
unpredictable across machines.

Rejected: **keep the table but let nothing read it.** An unreferenced table is dead code the next
reader deletes. Making it load-bearing now is the cheaper of the two, because it *replaces* the
work-area arithmetic rather than sitting beside it.

The `/w` switch (`NewApp.cpp:1325`) stays a bare flag. Size selection is the index's job.

### The window-fit failure falls back to fullscreen

`AdjustWindowRect` (`NewApp.cpp:279`) grows the requested client rect by the caption and border, so
even an exactly-matching entry overflows the desktop. Combined with a stale index that can name
3840×2160 on a 1080p panel, the client can open a window whose title bar is unreachable.

Rejected: **fall back to the smallest table entry.** Stays windowed, but silently substitutes a size
the user did not choose.

Rejected: **allow the oversized window.** Leaves the user unable to move or close it.

One screen-size comparison, and the failure mode is a presentation the user can always escape.

### Migration resets one slot, not the whole file

The new table has 11 entries; so did the old one. Every stale index therefore remains *in range*, so
bounds-checking cannot distinguish a pre-change configuration from a valid one — it would silently
select a different resolution. The version field exists for exactly this: read it, and reset the
index when it does not match.

Bounds-checking is retained regardless, because `Config.bin` is a file on disk and an out-of-range
index must not reach the table.

On a mismatch only `Config[0]` is reset. It is the sole slot whose meaning this change alters;
sound, music, brightness, cursor, camera, key type and the windowed flag all still mean what they
meant before, so discarding them would throw away settings for no reason — and would silently
override a user's windowed preference with the fullscreen default.

The version constant sits **outside the retail 76xx sequence**. `wyd_updates/` contains packages
named for consecutive version transitions (`76047605.zip` through `76217622.zip`), so that range is
live and climbing: a value inside it would eventually be written by a real update and accepted here
with a different meaning. This also corrects an assumption in the research note — something *does*
write `Config.bin`, which is why the follow-up options scene must persist literal width and height
rather than an index.

Recorded for the options scene, not implemented here: **it should persist literal width and height,
not an index.** An index into a mutable table is what created this migration problem; a resolution
pair cannot desync when the list changes.

### One uniform scale factor, assigned to both existing symbols

`m_fWidthRatio` and `m_fHeightRatio` (`RenderDevice.cpp:64-65`) are kept as symbols and both set to
the new global. That is what makes the ~150 downstream call sites correct without being edited, and
it is the reason not to introduce a third symbol.

The global is pinned at `1.0f` for this change and lives in `TMGlobal.cpp`. Deciding the eventual
factor — height-derived, or `min(screenW/800, screenH/600)` — is deferred to the change that unpins
it, alongside the art-quality questions that come with upscaling.

Two consequences are forced by the pin and are part of this change, not follow-ups:

- The clip-rejection tests at `SControl.cpp:376-377`, `:856-857` and `:958-959` compute
  `800.0f * m_fWidthRatio`, which today evaluates to the real screen width. Pinned to 1.0 it
  evaluates to 800, culling everything past x=800. They must read the actual screen dimensions.
- The seven per-resolution nudge branches test specific widths or ratios by float equality
  (`TMLoginScene.cpp:140-162` and `:958-975`, `TMFieldScene.cpp:16259-16279`,
  `RenderDevice.cpp:3179-3198` and `:3278`/`:3297`, `TMHuman.cpp:7567-7580` and `:8012-8025`,
  `TMMesh.cpp:286-287`). Several test `ratio == 1.0`, so pinning makes them fire unconditionally.
  They go in this change.

Two bugs retire as a side effect: `SetCenterPos`'s off-by-`(1-ratio)·w/2` error, caused by comparing
unscaled record values against already-scaled fields, evaluates to zero at 1.0; and `SetAutoSize`'s
double-scaling becomes a no-op.

### Anchoring is derived during the record walk, not looked up by ID

Each top-level control's authored centre in the 800×600 design space picks its anchor — left third,
right third, or centred, independently per axis — applied inside the `TMScene.cpp` record walk where
every record is visited exactly once with its parent ID in hand.

Rejected: **an ID-keyed anchor table applied after load.** Structurally impossible for the three
duplicated top-level IDs: 65686 names both a 13×13 button at (3,500) and a 227×421 dialog at (280,0),
which want opposite anchors, and `FindControl` returns only the first. It would also need a constant
invented for 12288.

Rejected: **add an anchor field to the layout format.** No padding to occupy, no version field to
detect the new format by, and an unknown type tag aborts the parse. It also means re-authoring three
shipped data files with no authoring tool in existence.

Parent-relative coordinates are what make this cheap: anchoring a top-level panel moves its whole
subtree, in both rendering and hit-testing, at no extra cost. The existing
`SetStickLeft/Right/Top/Bottom` (`SControl.cpp:193-211`) already write screen coordinates and are
already only used on top-level controls — they gain an `int margin = 0` parameter, which folds in the
manual nudges at `TMSelectCharScene.cpp:208-209` and `TMFieldScene.cpp:1878-1879`.

An override list exists for panels the rule misplaces. It starts empty.

### Full-width panels keep their authored width

Two top-level records span the whole design width: `P_MAIN_INFO1` (65628, authored `0,400,800,74`)
and 65566 (`0,0,800,520`). At scale 1.0 they stay 800 pixels wide on any screen.

Rejected: **stretch their width to the screen width.** Their background art goes through
`RENDER_IMAGE_STRETCH` (`Enums.h:10`, `RenderDevice.cpp:2860`), so 800-pixel art smears across 1920.
Worse, this is the one place parent-relative positioning stops helping: children sit at fixed offsets
from the parent origin, so stretching the parent leaves them bunched at the left end. Redistributing
them is per-child repositioning — the large job this design exists to avoid.

Revisit when the scale global comes off 1.0; that is the change where full-width bars become the
right question.

### The 3D projection is left alone (Hor+)

`RenderDevice.cpp:1837-1852` is untouched, so widescreen players see ~33% more horizontal world than
a 4:3 player did and the same vertical extent.

Rejected: **Vert+** — scale `m_fFOVY` down as aspect widens so horizontal FOV is constant. Fair
across aspects, but it pays for that by cropping vertical view on the aspect ratios everyone actually
uses, which is the worse trade under this camera. With 4:3 dropped from the supported list, the
remaining spread between 16:9 and 16:10 is about 11%, not 33%.

This is a behaviour commitment, not an implementation detail, which is why it appears in the spec.

### Unreachable paths are deleted, not gated

`CheckResolution`, `SetWindowedFullScreen` with its `ChangeDisplaySettings` pair and restore, the
exclusive-fullscreen device path (`FindBestFullscreenMode`, `D3DDevice.cpp:395`), the `g_UIVer`
classic-UI path (`NewApp.cpp:183-193`, `SControl.cpp:2437-2438`, `TMGlobal.cpp:34` — already
unreachable today, forced to 2 five lines after being read), `SetCenterPos` with its nine call sites,
`SetCenterSize` (zero call sites today) and `SetAutoSize` all go.

Rejected: **keep exclusive fullscreen behind a switch.** It preserves the flicker and the desktop
mode switch this change exists to remove, and leaves a second presentation path nobody exercises. If
exclusive fullscreen is ever wanted back, a fresh implementation beats a resurrected one.

Device creation becomes windowed-only, which simplifies device-loss handling rather than
complicating it.

## Risks / Trade-offs

- **Existing `Config.bin` files reset on first run.** → Intended, and the only way to catch a stale
  index given both tables have 11 entries. Back up the file before testing; the user-visible effect
  is one wrong window size, and under the fit check an oversized stale index lands in fullscreen.
- **The HUD is physically small at scale 1.0 on a high-resolution screen.** → Accepted and explicit:
  the pinned factor is the user's deferral, and the anchoring work means the HUD is at the screen
  edges where it belongs rather than clustered in a corner. Unpinning is a follow-up change.
- **Unexplained constants were tuned against the old stretch.** The 0.94 fudge at
  `RenderDevice.cpp:1857` and the magic divisors at `TMMesh.cpp:286-290` have no derivation in the
  decompiled source. → They need re-checking by eye once scaling is uniform; they are cosmetic, not
  correctness.
- **Some art may have been authored pre-squashed** to compensate for the anisotropic stretch. → Only
  running the client reveals it. If it turns up, it is an asset question, not a code one.
- **The derived anchor rule will misplace some of the 56 top-level panels.** → The override list is
  the escape hatch, and the client plus its data are both available locally, so finding out is one
  run rather than an analysis exercise.
- **Launching the WSL2-built binary is unproven.** `docs/researchs/wsl2-client-build-watcher.md:958`
  states the produced executable was never run. → Not a regression this change introduces. The
  shipped data sits on a Windows drive next to a retail executable, so running from Windows is the
  verification path.
- **Panel 12288 has no named constant** and appears only in the data. → The derived rule needs no
  constant, so this costs nothing unless 12288 ever needs an override entry.

## Migration Plan

1. Author the change in the `packages/apps/client` submodule working tree on a named branch — never
   detached HEAD, never straight onto the pinned branch.
2. Build `Release|x86` via `scripts/build-client.sh`. `Debug|x64` is known broken for unrelated
   reasons.
3. Back up `Config.bin` in the game install. Copy the built executable in under a name that does not
   overwrite the retail one, and run it against that install.
4. Commit in the submodule, push, then bump the pin here as its own commit containing nothing else,
   followed by `git push --recurse-submodules=check`.

No server or web change, so no paired commit and no `/w2-commit`.

**Rollback**: revert the pin bump. The client change is confined to one repository and touches no
persisted data other than resetting the mode index, which the previous binary re-reads harmlessly —
its own version check does not exist, so it simply reads whatever index is present.

## Open Questions

- **Which panels, if any, need an override entry?** Answerable only by running the client, and it
  changes neither the specs, the approach, nor the task breakdown — the override list is a data
  addition to a mechanism this change builds either way.
- **Does 1360×768 belong in the table** alongside 1366×768 as the pedantically-16:9 sibling?
  Currently excluded as clutter. Adding it is one row and affects nothing else.
