# Snappy

Snappy is a native macOS menu-bar screen measurement utility, built with SwiftUI and AppKit. It measures on-screen elements and regions, pins measurements, and places alignment guidelines above other apps.

This was vibe coded with GitHub Copilot. I don't know Swift and had never made a macOS app, so it may be buggy. I want to keep it basic; the current feature set is probably the most I will add. Bug-fix PRs are welcome.

## Installing

The easiest way to install is via Homebrew:

```sh
brew trust --cask psybers/homebrew-tap/snappy
xattr -d com.apple.quarantine /Applications/Snappy.app
```

Note that if you don't remove the quarantine, the app won't run.  You can do
that with the above command, or by going into Settings and allowing the program
to run.

## Build and setup

1. Open `Snappy.xcodeproj` in Xcode and build/run the **Snappy** scheme (macOS 26.0+, required for ScreenCaptureKit one-shot region capture).
2. Run tests: `xcodebuild -project Snappy.xcodeproj -scheme Snappy -destination 'platform=macOS' test` (70 tests).
3. Grant permissions on first use (below).

The target is ad-hoc signed, so every rebuild changes its identity. After a rebuild macOS may report the permissions as unavailable: quit Snappy, remove and re-enable its entries in Privacy & Security, and relaunch.

## Permissions

| Permission | Why | Without it |
|---|---|---|
| Accessibility | Identify the UI element under the pointer; receive H/V/Shift+H/Shift+V/Escape while measuring | Detection falls back to screen capture; pin/guideline keys do not work |
| Screen Recording | Capture a small region around the pointer / selection for the visual fallback (processed in memory, never stored) | Only Accessibility detection is available; a guidance label is shown |

Preferences explains both permissions, can request them, and opens the matching System Settings pane. The global hotkey itself needs neither.

## Usage and shortcuts

| Input | Action |
|---|---|
| Cmd+Shift+F (configurable) | Start measurement mode; press again to exit and keep annotations visible |
| Arrow keys / Shift+Arrow keys | Move the cursor 1 / 10 physical display pixels and update the measurement or Shift crosshair |
| Move the mouse | Horizontal and vertical measurement lines with T caps and W/H labels |
| `H` / `V` | Pin the current horizontal / vertical measurement |
| `Shift+H` / `Shift+V` | Add a horizontal / vertical guideline at the pointer (spans that display) |
| Drag | Select a region (the app underneath does not receive the drag); on release it becomes a persistent rectangle snapped to the content found |
| Hover a pinned item | Drag measurements, guidelines, and rectangles to move them; rectangles have a faint fill and can be dragged from their outline or interior |
| Click a measurement or rectangle label (shows ✕) | Delete it |
| Right-click a guideline | Delete it |
| `Escape` | Exit measurement mode, save, and clear all annotations |

Menu: Preferences..., Restore Last Session, Clear Annotations (no confirmation), Quit. Preferences covers the shortcut, measurement and guideline colours, and label font size.

## Session behaviour

- Sessions live in `~/Library/Application Support/Snappy/`: `active-session.json` (saved shortly after every change, on Escape, and on quit) and `last-session.json` (last non-empty snapshot). Writes are atomic; corrupt files are moved to `*.corrupt.json`; newer schema versions are rejected without deleting them.
- The hotkey starts an empty session only if the active one has no annotations; existing (e.g. restored) annotations are kept so you can keep measuring.
- Escape saves the snapshot and then clears annotations. **Clear Annotations** clears the active session but never the snapshot.
- Pressing the global shortcut while measuring saves and exits measurement mode while keeping annotations visible.
- **Restore Last Session** loads the snapshot and remaps annotations to connected displays (by ID, then pixel size and scale; geometry is scaled if resolution changed). Annotations for disconnected displays are retained and reappear on reconnect.

## Architecture

All coordinates are AppKit points; annotations are stored display-local (origin at the display's bottom-left). `DisplayCoordinateMapper` converts to/from global, Accessibility (top-left origin) and capture-pixel spaces.

- `DomainModels`, `DisplayCoordinateMapper`: geometry, annotations, sessions.
- `DisplayManager`: one transparent, borderless, click-through panel per display; draws temporary indicators, annotations and the selection rectangle.
- `GlobalShortcutService`, `GlobalInputMonitor`, `MeasurementCoordinator`: Carbon hotkeys, global mouse/key events, mode state machine.
- `AccessibilityDetection`: AX hit-testing with validation. `ScreenCaptureDetection`: ScreenCaptureKit capture (rate-limited to one per 120 ms, Snappy windows excluded), Vision rectangles and `PixelExtentDetector`; `ElementDetectionService` orchestrates AX-first with capture fallback.
- `RectangleSelection`: drag analysis (AX sampled on a 5x5 grid, then content bounds, then the raw selection).
- `AnnotationInteraction`: layout, hit-testing, hover, drag, delete.
- `SessionPersistence`: store, display remapper, controller. `AppPreferences`/`PreferencesStore`/`PreferencesView`: settings.

Detection is event-driven (no polling timers); pointer updates are coalesced, one detection at a time, and stale results are discarded.

## Known limitations

- Public Screen Recording APIs report access as a Boolean; they do not expose whether Snappy is absent from System Settings or listed but disabled. On the first shortcut permission request of each app run, Snappy lets macOS present its dialog and shows no additional alert. If a later attempt still fails, Snappy offers to open System Settings. An already-disabled entry therefore requires a second attempt for that guidance. If you remove the permission entry while Snappy is running, relaunch Snappy before requesting access again.

- Live cursor measurements scan a cached full-monitor image so large areas are not clipped to a cursor crop. Thin and softened borders are confirmed along the edge, with an 8-level per-channel contrast threshold across transitions up to two points wide; subtle gradients and textured content can still produce imperfect measurements.
- Vision and pixel-extent results are heuristics, not semantic UI element boundaries; ambiguous areas report "unavailable" rather than guessed bounds.
- While measuring, Snappy's overlays capture all mouse events (nothing reaches the app underneath) and show a crosshair cursor; guidelines show resize cursors. Cursor changes from a background app use a private CoreGraphics connection property; if a cursor does not change on your macOS version, that is the cause.
- A selection is analysed on a single display; the visual fallback only looks inside the dragged area.
- Non-US keyboard layouts are not guaranteed for the shortcut key mapping.
- Protected/DRM content may not be capturable. Display IDs come from `CGDirectDisplayID` and are matched by characteristics when they change across restarts.
- Live permissions, multi-display scaling and real-app behaviour are verified manually, not by automated tests.

## Manual verification matrix

- [ ] Fresh grant of Accessibility and Screen Recording; revoke each and confirm guidance/degraded behaviour.
- [ ] Hover over native app, browser page, and canvas/inaccessible app: lines appear, no crash.
- [ ] H, V, Shift+H, Shift+V pin; drag and delete each; hover suppresses the temporary crosshair.
- [ ] Drag selection over UI elements and over plain imagery; delete by outline and by label.
- [ ] Escape clears; hotkey after Restore keeps restored items; relaunch then Restore Last Session.
- [ ] Two displays with different scale/position (including one left of primary): annotations stay on their display.
- [ ] Unplug and replug a display with annotations; change resolution and restore.
- [ ] Idle CPU near zero while not measuring; modest while moving the pointer.
