All client paths below are relative to `packages/apps/client/Projects/TMProject/`. Line numbers are
from pinned commit `5018219b6fc623304403c09e10c44d19c788a8ad` and will drift as edits land — treat
them as anchors, not addresses.

## 1. Foundation

- [x] 1.1 Create a named branch in the `packages/apps/client` submodule working tree. Never detached HEAD, never straight onto the pinned branch. Confirm `git -C packages/apps/client status` is clean first.
- [x] 1.2 Add the uniform UI scale global to `TMGlobal.cpp` / `TMGlobal.h`, initialised to `1.0f`. No `Config` slot, no plumbing.
- [x] 1.3 Move the resolution table out of the `NewApp::Initialize` local (`NewApp.cpp:76,87-119`) to file scope in `TMGlobal.cpp` beside the scale global, with an accessor the future options scene can reach.
- [x] 1.4 Replace the table's entries with the 11 supported resolutions, grouped 16:9 then 16:10, ascending within each group. Drop the bit-depth field from the entry type.

## 2. Presentation

- [x] 2.1 Fullscreen: create a borderless `WS_POPUP` window at the desktop resolution, replacing the mode-driven sizing at `NewApp.cpp:219-227`.
- [x] 2.2 Windowed: size the client area from the table entry the stored index names, and centre the window on the desktop instead of placing it at (0,0) (`NewApp.cpp:281-292`).
- [x] 2.3 Add the fit check: if the windowed client area plus the frame added by `AdjustWindowRect` (`NewApp.cpp:279`) exceeds the screen, launch borderless fullscreen instead.
- [x] 2.4 Replace the font-size `switch` on the width literal (`NewApp.cpp:228-246`) with sizing routed through the scale global.

## 3. Stored configuration

- [x] 3.1 Bump the version constant written into `SaveUpdatAndConfig` (`NewApp.h:15`, written as 7000 at `NewApp.cpp:143`).
- [x] 3.2 Reject a stored configuration whose version does not match, falling back to the defaults. This is what catches a stale index — bounds-checking cannot, since both the old and new tables hold 11 entries.
- [x] 3.3 Bounds-check the mode index against the table before using it (`NewApp.cpp:160,219`), falling back to the defaults on failure.
- [x] 3.4 Set the missing-file default block (`NewApp.cpp:142-156`) to mode index 1 with the fullscreen flag on.

## 4. Uniform scaling

- [x] 4.1 Assign the scale global to both `m_fWidthRatio` and `m_fHeightRatio` (`RenderDevice.cpp:64-65`), keeping both symbols so the ~150 downstream call sites need no edit.
- [x] 4.2 Change the `SControl` base constructor (`SControl.cpp:31-36`) to apply one factor to both axes.
- [x] 4.3 Mirror the same factor in `SProgressBar::FrameMove2` (`SControl.cpp:1796-1797`), which recomputes the ratios locally.
- [x] 4.4 Route `BASE_ScreenResize` (`Basedef.cpp:29-32`) through the scale global so minimap markers (`TMFieldScene.cpp:6517-6521`) stay glued to the minimap panel.
- [x] 4.5 Fix the three clip-rejection tests (`SControl.cpp:376-377`, `:856-857`, `:958-959`) to use the actual screen dimensions. Pinned at 1.0 they otherwise cull everything past x=800 / y=600.
- [x] 4.6 Verify the inventory cell and item icon sizing (`SGrid.cpp:5157-5180`, `:722-723`) is now square. These should fall out of 4.1 with no edit — confirm rather than change.

## 5. Deletions forced by uniform scaling

- [x] 5.1 Delete the login-scene logo placement branch on width (`TMLoginScene.cpp:140-162`) and the rating-splash scale `switch` (`:958-975`).
- [x] 5.2 Delete the button-label nudge branch on ratio equality in `SetButtonTextXY` (`TMFieldScene.cpp:16259-16279`).
- [x] 5.3 Delete the guild-mark blit offset branch (`RenderDevice.cpp:3179-3198`) and the two 640-width text baseline nudges (`:3278`, `:3297`).
- [x] 5.4 Delete the nameplate and HP-bar Y-offset branches (`TMHuman.cpp:7567-7580`, `:8012-8025`).
- [x] 5.5 Delete the 1.26 aspect test in `RenderForUI` (`TMMesh.cpp:286-287`), whose only purpose was separating 5:4 from 4:3.
- [x] 5.6 Delete the `g_UIVer` classic-UI path: `NewApp.cpp:183-193`, its only consumer in `SListBox::SetPickSize` (`SControl.cpp:2437-2438`), and the global at `TMGlobal.cpp:34`.
- [x] 5.7 Delete `SetCenterSize` (`SControl.cpp:187-191`) — zero call sites today.
- [x] 5.8 Delete `SetAutoSize` (`SControl.cpp:181-185`) and its call site on `P_MAIN_INFO2` (`TMFieldScene.cpp:1000-1002`).

## 6. Anchoring

- [x] 6.1 Add an `int margin = 0` parameter to `SetStickLeft` / `SetStickRight` / `SetStickTop` / `SetStickBottom` (`SControl.cpp:193-211`).
- [x] 6.2 Fold the existing manual nudges into that parameter: `TMSelectCharScene.cpp:208-209` (+30/-30) and `TMFieldScene.cpp:1878-1879` (+135).
- [x] 6.3 Implement the derived anchor rule: from a control's authored position and size in 800×600 space, pick left / right / horizontal-centre and top / bottom / vertical-centre independently, by which third of the axis its centre falls in.
- [x] 6.4 Apply the rule inside the `TMScene.cpp` record walk, to top-level records only — those whose parent ID is 0 (`TMScene.cpp:362,417,460,512,572,625,680,731,788`). Do not look controls up by ID: `FindControl` returns only the first match and three top-level IDs are duplicated in `FieldScene2.bin`.
- [x] 6.5 Add the override hook — a per-ID anchor override consulted before the rule — and leave it empty.
- [x] 6.6 Confirm panels authored at the full design width (`P_MAIN_INFO1` 65628 at `0,400,800,74`, and 65566 at `0,0,800,520`) keep their authored width and are not stretched.
- [x] 6.7 Delete `SetCenterPos` (`SControl.cpp:223-237`) and its nine call sites (`TMScene.cpp:356,406,454,506,566,619,674,725,782`), now that centring is a rule outcome. Leave `SMessageBox`'s own self-centring (`SControl.cpp:2628`) alone.

## 7. Deletions of unreachable display paths

- [x] 7.1 Delete `CheckResolution` (`NewApp.cpp:1283-1296`) and its call site.
- [x] 7.2 Delete `SetWindowedFullScreen` and the `ChangeDisplaySettings` pair (`RenderDevice.cpp:462-472`, `:483-496`) plus the call at `NewApp.cpp:378-383`.
- [x] 7.3 Delete the desktop-mode restore (`NewApp.cpp:56-59`, `RenderDevice.cpp:476-482`).
- [x] 7.4 Delete the exclusive-fullscreen device path (`FindBestFullscreenMode`, `D3DDevice.cpp:395`) and make device creation windowed-only in `ChooseInitialD3DSettings` (`D3DDevice.cpp:515`).
- [x] 7.5 Confirm `/w` (`NewApp.cpp:1325`) still parses as a bare flag with no size argument.

## 8. Build and verify

- [x] 8.1 Build `Release|x86` via `scripts/build-client.sh`. `Debug|x64` is known broken for unrelated reasons — do not use it.
- [x] 8.2 Back up `Config.bin` in the game install before the first run. The version bump resets it.
- [x] 8.3 Copy the built executable into the install under a name that does not overwrite the retail one.
- [x] 8.4 Verify against the spec scenarios: square icons, no clipping past x=800, panels at real screen edges, clicks landing on the panels they appear over, fullscreen leaving the desktop resolution untouched, and the oversized-index fallback.
- [x] 8.5 Populate the override list from 6.5 with any panel the derived rule misplaces.

## 9. Commit and pin

- [ ] 9.1 Commit in the submodule on the named branch from 1.1.
- [ ] 9.2 Push the submodule branch.
- [ ] 9.3 Bump the submodule pin here as its own commit, containing nothing else.
- [ ] 9.4 Run `git push --recurse-submodules=check`.
