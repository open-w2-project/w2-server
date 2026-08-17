## Purpose

Defines how the client presents itself on screen: which aspect ratios and resolutions it supports,
how it chooses between fullscreen and windowed presentation, how that choice is persisted and
validated, and how the interface scales and anchors to the resulting screen.

## Requirements

### Requirement: Supported aspect ratios

The client SHALL support 16:9 and 16:10 aspect ratios only. It SHALL NOT offer any 4:3 or 5:4 mode.

The supported resolution list SHALL be exactly:

| Ratio | Resolutions |
| --- | --- |
| 16:9 | 1280×720, 1366×768, 1600×900, 1920×1080, 2560×1440, 3840×2160 |
| 16:10 | 1280×800, 1440×900, 1680×1050, 1920×1200, 2560×1600 |

The list SHALL be ordered by ratio group, ascending within each group, so that the first entry is
1280×720. 1366×768 is included as a supported 16:9 entry despite its 1.779 aspect, because it is a
common panel size.

Entries SHALL NOT carry a colour depth. The client SHALL use the desktop's colour depth.

#### Scenario: No 4:3 mode is offered

- **WHEN** the supported resolution list is read
- **THEN** it contains no entry whose width divided by height is 4/3 or 5/4

#### Scenario: List order is stable

- **WHEN** the supported resolution list is read
- **THEN** entry 1 is 1280×720
- **AND** all 16:9 entries precede all 16:10 entries
- **AND** entries within each group ascend by resolution

### Requirement: Fullscreen uses the desktop resolution

In fullscreen the client SHALL present a borderless window covering the whole screen at the
desktop's current resolution. It SHALL NOT change the desktop display mode, and SHALL NOT require
the desktop resolution to appear in the supported resolution list.

#### Scenario: Fullscreen launch leaves the desktop alone

- **WHEN** the client is launched in fullscreen
- **THEN** it fills the screen with no window border or caption
- **AND** the desktop resolution is the same after launch as before
- **AND** other windows are not resized or rearranged

#### Scenario: Fullscreen on an unlisted desktop resolution

- **WHEN** the desktop resolution is not in the supported resolution list
- **AND** the client is launched in fullscreen
- **THEN** the client fills the screen at the desktop resolution

#### Scenario: Exit restores nothing

- **WHEN** a fullscreen client exits, by normal quit or by crash
- **THEN** the desktop resolution is unchanged, because it was never changed

### Requirement: Windowed size comes from the stored mode index

The stored configuration SHALL hold a 1-based index into the supported resolution list. That index
SHALL determine the windowed client area size. It SHALL NOT affect fullscreen presentation.

The window SHALL be positioned centred on the desktop.

#### Scenario: Indexed size is honoured

- **WHEN** the stored index names 1600×900
- **AND** the client is launched windowed
- **THEN** the client area measures 1600×900
- **AND** the window is centred on the desktop

#### Scenario: Index does not affect fullscreen

- **WHEN** the stored index names 1280×720
- **AND** the client is launched in fullscreen on a 2560×1440 desktop
- **THEN** the client fills the screen at 2560×1440

### Requirement: A window that does not fit falls back to fullscreen

If the windowed size named by the stored index, together with the window's caption and border, would
not fit within the desktop, the client SHALL launch borderless fullscreen instead. It SHALL NOT open
a window extending beyond the screen.

#### Scenario: Oversized index falls back

- **WHEN** the stored index names 3840×2160
- **AND** the desktop is 1920×1080
- **AND** the client is launched windowed
- **THEN** the client launches borderless fullscreen at 1920×1080

#### Scenario: Exact-fit index accounts for the frame

- **WHEN** the stored index names 1920×1080
- **AND** the desktop is 1920×1080
- **AND** the client is launched windowed
- **THEN** the client launches borderless fullscreen, because the caption and border would not fit

### Requirement: Stored configuration is validated before use

The client SHALL treat the stored configuration as untrusted input.

- The client SHALL reject a mode index outside the bounds of the supported resolution list.
- The stored configuration carries a version. When that version does not match this client's, the
  client SHALL reset the stored mode index to 1 and SHALL preserve every other stored setting. The
  mode index is the only value whose meaning changed with the new resolution list, and a stale index
  cannot be distinguished from a valid one by bounds alone.
- When the configuration file is missing or too short to read, the client SHALL use its defaults:
  mode index 1 and fullscreen presentation.

#### Scenario: Out-of-range index

- **WHEN** the stored mode index is 0, negative, or greater than the number of supported resolutions
- **THEN** the client uses mode index 1 and fullscreen presentation
- **AND** the client starts successfully

#### Scenario: Configuration from an earlier client version

- **WHEN** the stored configuration's version predates this client
- **AND** its mode index is within bounds of the current list
- **THEN** the client ignores the stored index rather than applying it
- **AND** uses mode index 1

#### Scenario: A version mismatch preserves the other settings

- **WHEN** the stored configuration's version predates this client
- **AND** it requests windowed presentation
- **THEN** the client presents windowed
- **AND** the stored sound, music, brightness, cursor and camera settings are still applied

#### Scenario: No configuration file

- **WHEN** no stored configuration exists
- **THEN** the client uses mode index 1 and fullscreen presentation
- **AND** the client starts successfully

### Requirement: Interface scaling is uniform

The interface SHALL be scaled by a single factor applied equally to horizontal and vertical extents.
It SHALL NOT scale the two axes independently.

For this change the factor SHALL be fixed at 1.0, so controls are drawn at their authored pixel
size. Interface elements SHALL NOT be clipped by any bound narrower than the actual screen.

#### Scenario: Square elements stay square

- **WHEN** the client runs at any supported resolution
- **THEN** an interface element authored square is drawn square
- **AND** circular interface art is drawn circular

#### Scenario: Proportions match across resolutions

- **WHEN** the same interface element is compared at 1920×1080 and at 1680×1050
- **THEN** its width-to-height ratio is identical at both

#### Scenario: Nothing is clipped at the old design width

- **WHEN** the client runs at a resolution wider than 800 pixels
- **THEN** interface elements positioned beyond 800 pixels from the left edge are drawn
- **AND** interface elements positioned beyond 600 pixels from the top edge are drawn

### Requirement: Interface panels anchor to screen edges

Each top-level interface panel SHALL be anchored horizontally and vertically according to where it
was authored within the interface design space: a panel authored near an edge SHALL be anchored to
that edge, and a panel authored near the middle SHALL be centred on that axis.

Child elements SHALL move with their parent panel, in both rendering and mouse interaction, so that
a click lands on the element drawn under the cursor.

Panels authored at the full design width SHALL retain their authored width rather than stretching to
the screen width.

#### Scenario: Edge-authored panels reach the edge

- **WHEN** the client runs at 1920×1080
- **THEN** a panel authored against the right edge of the design space is drawn against the right
  edge of the screen
- **AND** a panel authored against the bottom edge is drawn against the bottom edge of the screen

#### Scenario: Centre-authored panels stay centred

- **WHEN** the client runs at any supported resolution
- **THEN** a dialog authored near the middle of the design space is drawn centred on screen

#### Scenario: Clicks follow the drawn position

- **WHEN** a panel has been anchored to a screen edge
- **AND** the user clicks a button inside that panel
- **THEN** that button receives the click

#### Scenario: Two panels sharing an identifier anchor independently

- **WHEN** the interface layout contains two distinct panels that share the same identifier
- **AND** they were authored in different regions of the design space
- **THEN** each is anchored according to its own authored position

### Requirement: Horizontal field of view widens with aspect ratio

The 3D scene SHALL hold its vertical field of view constant and derive its horizontal field of view
from the screen's aspect ratio. A player on a wider screen therefore sees more of the world
horizontally and the same amount vertically.

This is deliberate. The client SHALL NOT crop or compensate to equalise horizontal field of view
across aspect ratios.

#### Scenario: Wider screen sees more horizontally

- **WHEN** the same scene is viewed from the same position at 1920×1080 and at 1920×1200
- **THEN** the 16:9 view shows more of the world to the left and right
- **AND** both views show the same vertical extent of the world

### Requirement: A single interface version

The client SHALL provide one interface layout. It SHALL NOT offer an alternative or legacy interface
version, and SHALL NOT read any stored setting selecting one.

#### Scenario: No interface version selection

- **WHEN** the stored configuration contains a value in the slot that formerly selected an interface
  version
- **THEN** the client ignores it
- **AND** renders the single interface layout
