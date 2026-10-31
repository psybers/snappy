# Snappy Implementation Plan

## Purpose and scope

This plan turns the requirements in [AGENTS.md](./AGENTS.md) into sequential, testable implementation milestones. It is a roadmap; implementation progress and verified milestone outcomes are recorded alongside the relevant milestones.

The central product constraint is reliable, unobtrusive measurement across applications and displays. The hardest parts are not drawing lines; they are obtaining trustworthy element boundaries from other apps, obtaining screen pixels only when permitted, coordinating global input without taking focus, and persisting a session without confusing it with the next fresh session.

## Requirement analysis and constraints

### Public macOS APIs and permissions

- **Accessibility hit testing:** Prototype `AXUIElementCreateSystemWide` and `AXUIElementCopyElementAtPosition`, then read supported position, size, role, and related attributes. Access to other applications' accessibility trees requires the user to grant Accessibility permission. Check trust state with `AXIsProcessTrustedWithOptions`; explain why permission is needed and provide a route to System Settings. Do not treat a successful hit test as proof that the returned element has a useful or visually exact boundary.
- **Screen capture:** Prefer ScreenCaptureKit. Its streaming APIs are available starting with macOS 12.3; `SCScreenshotManager.captureImage(in:)` is available starting with macOS 15.2 and is a simpler one-shot region path. Select the minimum OS target based on whether supporting pre-15.2 systems justifies implementing a stream for occasional captures. Check/request Screen Recording permission, capture only the display/region needed, and handle protected content, secure surfaces, and unavailable system UI. Do not make capture a prerequisite for accessibility-based measurements. `CGPreflightScreenCaptureAccess` and `CGRequestScreenCaptureAccess` are present in the inspected SDK; do not assume they are deprecated.
- **Global shortcut:** There is no modern high-level SwiftUI API for registering arbitrary system-wide shortcuts. The Carbon `RegisterEventHotKey` route compiled and successfully registered/unregistered a test shortcut in the feasibility probe. Production work must still verify event delivery through an application event handler, conflicts, re-registration, and cleanup. Keep it behind a small adapter so a future implementation can change without rewriting application behavior.
- **Global pointer and button input:** `NSEvent` global monitor registration and creation of a mouse-only listen-only `CGEvent` tap succeeded in the feasibility probe. Creation alone does not prove event delivery while another app is active, nor does the probe establish keyboard event permission behavior. `NSEvent` global monitors, local monitors, and event taps have different scope and permission behavior; they are not interchangeable. Validate real callbacks in a packaged app and select the narrowest reliable mechanism before building the interaction layer.
- **Overlay input and focus:** A screen overlay must remain visible over normal apps, avoid activating the Snappy app merely to measure, and still permit annotation hover/drag/click interactions. Prototype a non-activating AppKit panel/window and explicit hit-testing or event-routing behavior. Avoid assuming that a single window configuration can both pass all input through and receive annotation interactions.
- **System restrictions:** Do not promise measurements for secure/protected content, apps that expose no useful accessibility information, or visual objects whose semantics cannot be inferred from pixels. Communicate unavailable permissions and degraded detection instead of presenting confident-looking but unreliable dimensions.

### Detection strategy and quality boundary

Expose a common detection result for every strategy: candidate rectangle in display-local logical coordinates, source (`accessibility` or `vision`), confidence, and a reason when no usable result exists.

1. Try an accessibility hit test at the pointer; validate that the result has finite, non-empty bounds, contains the pointer (with a documented tolerance), and is not an unhelpful root/window-sized fallback when a more specific element can be found.
2. If AX is unavailable, incomplete, or implausible and capture is authorized, capture a bounded region around the pointer. Use image processing (for example Vision rectangle observations with conservative filtering and/or Core Image/Accelerate edge analysis) to propose candidates. Evaluate closed rectangular structure, containment of the pointer, scale, and confidence; do not treat every color or texture transition as a UI boundary.
3. Rank valid candidates by confidence and specificity. Return an explicit low-confidence/unknown result if neither method is adequate. In that case show a neutral fallback (such as no element measurement and a clear permission/help state), not a guessed screen-edge distance labelled as the element's dimensions.

For rectangle selection, collect accessibility elements intersecting the selection when their bounds are usable; otherwise analyze the selected pixels as a region. Take the union of accepted element rectangles, or the bounds of accepted visual content. Do not independently snap four selection edges to nearby edges. The thresholding, filtering, and selection policy need representative tests and real-app validation; computer vision cannot reliably infer every application's semantic grouping.

### Multiple-display coordinate model

- Use **AppKit points** as the application and annotation model. A display owns an overlay and an annotation collection.
- Centralize conversion between global pointer coordinates, each `NSScreen.frame`, overlay-local coordinates, AX coordinates, and captured-image pixel coordinates in a `DisplayCoordinateMapper`. AX hit-test coordinates are documented as top-left-relative screen coordinates, while AppKit uses a different origin convention; do not scatter origin flips or backing-scale multiplication through drawing and interaction code.
- Treat `NSScreen.frame` origins as arbitrary, including negative origins; never assume the primary display starts at `(0, 0)`. Keep display-local positions separate from global desktop positions.
- Record display identity and characteristics (stable identifier where available, saved logical bounds, pixel dimensions, and backing scale). Match by identity first. When a saved display is disconnected, retain its annotations without rendering them on an unrelated display; expose an unavailable-display state and retry matching when the display configuration changes.
- On a matched display whose geometry has changed, apply one documented remapping policy based on saved/current display geometry and test it. The initial candidate is proportional remapping of display-local coordinates and extents using saved and current logical bounds; preserve original saved data so remapping is repeatable and reversible. This policy must be validated for Retina scale changes and resolution changes before release.
- Observe display connect/disconnect and geometry changes, rebuild/reposition per-display overlays, and ensure guidelines span only their associated display.

### Session persistence model

Keep the persistence format independent of SwiftUI/AppKit view objects. Use a versioned `Codable` model with:

- Session ID, creation time, last-modified time, and schema version.
- Per-display identity and saved display characteristics.
- Typed annotations: horizontal measurement, vertical measurement, rectangle, or guideline; display-local point geometry; relevant dimensions/orientation; stable annotation ID.
- No transient pointer measurement or in-progress rectangle selection.

Use native file storage under the app's Application Support directory, with atomic replacement (write a complete new file before replacing the prior valid file). Validate the schema on load, report failures, and preserve the last valid snapshot on interrupted writes or corrupt data. Keep two concepts separate:

1. **Active working session:** the in-memory session and its durable checkpoint, updated after annotation create/move/delete, on Escape, and on quit.
2. **Last-restorable snapshot:** the separately retained session offered by Restore Last Session.

Starting measurement mode creates an empty active session but must not overwrite the last-restorable snapshot just by starting. Restore explicitly loads the snapshot into the active session and displays it. Clear empties and saves the active session, but does not silently erase the separately retained snapshot. Define and test exactly when an edited/new active session becomes the next last-restorable snapshot; the initial candidate is to advance that snapshot only after a successful save of a non-empty active session, while Clear itself never advances or deletes it. This reconciles fresh-session behavior with explicit restoration and should be confirmed during the persistence milestone.

## Proposed modular architecture

Use a menu-bar-only SwiftUI application shell with AppKit-backed services and windows. Keep modules organized by responsibility (separate Swift files/targets only where useful; do not prematurely split the Xcode project):

| Component | Responsibility |
|---|---|
| `AppLifecycle` / `MenuBarController` | Own app lifecycle and menu-bar commands: Preferences, Restore Last Session, Clear Annotations, Quit. Coordinate shutdown saves and app activation policy so no Dock icon or conventional main window is shown. |
| `PreferencesStore` / `PreferencesView` | Persist and present shortcut, measurement color, guideline color, and label font size. Keep settings independent of annotation/session models. |
| `GlobalShortcutService` | Register/unregister the configured shortcut through a replaceable adapter; report registration conflicts and permission/API failures. |
| `InputTrackingService` | Observe pointer/button/keyboard input without stealing focus; normalize events and route them to the interaction state machine. |
| `MeasurementCoordinator` | Own measurement-mode states (`inactive`, `tracking`, `selecting`, `analyzing`), Escape behavior, hotkey fresh-session behavior, and temporary state cleanup. |
| `DisplayManager` / `DisplayCoordinateMapper` | Track `NSScreen` and display changes; create display descriptors; convert among global, display-local, overlay, AX, and capture coordinates. |
| `AccessibilityElementDetector` | Perform AX hit tests, read/validate supported attributes, handle unavailable trust and unsupported app trees, and produce normalized candidates. |
| `ScreenCaptureService` | Check permission, capture only requested display regions with ScreenCaptureKit, and return image plus explicit coordinate metadata. |
| `VisualBoundaryDetector` | Analyze captured/selected images and produce ranked visual-boundary candidates and confidence. |
| `ElementDetectionService` | Apply AX-first/fallback detection policy and return a shared result type regardless of source. |
| `MeasurementGeometry` | Pure calculations for dimensions, candidate validation, selection unions, display mapping, and hit-test geometry; designed for unit testing. |
| `AnnotationStore` | Own annotation collections grouped by display, stable IDs, create/move/delete/clear operations, and change notifications. |
| `SessionRepository` | Encode/decode versioned session data, atomically save/load active and last-restorable snapshots, migrate schema versions, and surface I/O errors. |
| `OverlayWindowController` / `OverlayView` | Manage a transparent, borderless, non-activating overlay per display and render temporary indicators and persistent annotations. |
| `AnnotationInteractionController` | Resolve hover, drag, label-delete, rectangle-delete, guideline-right-click, and selection gestures; issue changes to `AnnotationStore`. |

Prefer protocols around OS boundaries (input, capture, AX detection, persistence, and display enumeration) so geometry and state transitions can be tested without granting TCC permissions. Keep rendering read-only with respect to session persistence.

## Sequential development milestones

Every milestone should build in Xcode, add focused tests, preserve the previous milestone's behavior, and update the README when its user-facing behavior or permission requirements change.

### 0. Confirm platform and API feasibility

- Decide the minimum supported macOS version and target architecture. ScreenCaptureKit streams are available from macOS 12.3; the one-shot `SCScreenshotManager.captureImage(in:)` API is available from macOS 15.2.
- Create tiny throwaway prototypes (not product implementation) for AX hit testing, ScreenCaptureKit permission/capture, Carbon global shortcut registration, global pointer/button observation, and non-activating overlay input.
- Record permission prompts, event-monitor limitations, secure-content behavior, coordinate conventions, and any API availability constraints.
- Choose whether vision is built with Vision, Core Image/Accelerate, or both only after the prototype validates the required rectangle signals.
- **Exit criteria:** documented API decisions and a working spike for each critical system boundary, or an explicit alternative/limitation. Separate compile/API availability checks from runtime permission and interaction tests. No claim that unsupported interactions are solved.

#### Feasibility probe results (2026-10-30)

Environment: macOS 26.7, Xcode 27.1, Swift 6.4 compiler in Swift 5 language mode, macOS 27 SDK, arm64. A disposable Swift command-line probe was compiled and run outside the workspace; it was not application code. No deployment-target compatibility build was performed.

| Area | Observed result | What this establishes / does not establish |
|---|---|---|
| Accessibility | `AXIsProcessTrusted()` returned false; a system-wide hit test returned AX error `-25211` (API disabled). SDK headers document `AXUIElementCopyElementAtPosition` as using top-left-relative screen coordinates. | The API imports and executes, but no external-app element geometry could be tested without Accessibility permission. No prompt was requested. |
| Screen capture | `CGPreflightScreenCaptureAccess()` returned false. ScreenCaptureKit and `SCScreenshotManager.captureImage(in:)` compiled against the installed SDK. | The capture path is available at compile time, but no capture was attempted without Screen Recording permission. The API compile check does not validate capture output, permission UX, or protected-content behavior. |
| Global shortcut | Carbon registered and unregistered a temporary Command+Shift+F20 hotkey successfully (`noErr`). | OS registration is feasible without a Snappy app target. Delivery through the app event loop, shortcut collision UX, and preference-driven replacement remain untested. |
| Pointer/button monitoring | `NSEvent` global monitor registration succeeded. Creation of a mouse-only listen-only `CGEvent` tap succeeded. | API construction is feasible. The probe did not run a callback loop or verify delivery while another application was active. Keyboard monitoring and its permission behavior remain untested. |
| Overlay | A borderless, non-activating `NSPanel` instantiated; `ignoresMouseEvents` was set successfully. | Basic window construction is feasible. The panel was not shown; z-order, focus behavior, Spaces/full-screen behavior, click-through, and annotation interaction were not validated. A fully click-through panel cannot itself receive annotation input, so selective hit testing or separate overlay/input surfaces must be prototyped. |
| Displays | One display was visible to the probe: AppKit frame `(0, 0, 2056, 1329)` points and backing scale `2.0`. | Single-display enumeration works. Negative origins, mixed scaling, and hot-plug behavior were not available to test in this environment. |
| Persistence primitive | A temporary `Codable` session was atomically written with Foundation `Data.write(options: .atomic)`, read back, and compared successfully. | The chosen native file primitive supports the basic round trip. Crash/power-loss guarantees, replacement failures, schema migration, and separate active/last-restorable semantics still need targeted tests. |

**Milestone 0 status: partial; feasibility is documented, but runtime acceptance is blocked on environment access and multi-display hardware.** The compile and safe local registration checks passed. Do not mark the milestone fully verified until an app-target probe can exercise actual shortcut/input delivery and overlay behavior; Accessibility and screen capture can be tested after the user grants their respective permissions; coordinate/display behavior needs additional displays or a dedicated geometry test harness.

### 1. Xcode app shell and lifecycle

- Scaffold the native Swift/SwiftUI macOS app in Xcode as an accessory/menu-bar utility, with no Dock icon or conventional main window.
- Add the status-item menu and placeholder Preferences/Restore/Clear/Quit actions with clear disabled/empty states where functionality is not yet available.
- Establish app identifiers, entitlements/usage descriptions as appropriate, deployment target, and build/test schemes.
- **Tests/exit criteria:** app builds and launches; status item appears; no Dock icon/main window; Quit terminates cleanly.

**Status: complete (2026-10-30).** Added a shared Xcode scheme, a SwiftUI `MenuBarExtra` app shell, an informational Preferences scene, and disabled Restore/Clear actions with explanatory help. The app target sets `LSUIElement = YES`; it contains no conventional `WindowGroup`. The initial deployment target is macOS 15.2, chosen to make `SCScreenshotManager.captureImage(in:)` available without a pre-15.2 streaming fallback. This is a deliberate initial platform choice and can be revisited if broader OS support is required.

**Verification:** `xcodebuild build` succeeded; `xcodebuild test` succeeded with 2 tests and 0 failures; the built app launched and remained running (PID 63374 at verification). The built `Info.plist` reports `LSUIElement = true`. Xcode emitted non-blocking local toolchain/CoreSimulator plugin warnings; they did not prevent the build or tests. The visual appearance of the menu-bar item was not independently inspected through UI automation.

### 2. Domain models, coordinate primitives, and preferences

- Define display descriptors, typed annotations, detection results, and versioned session DTOs.
- Implement pure geometry and coordinate conversion helpers for negative origins, differing display bounds, backing scales, and captured pixel regions.
- Add Preferences storage and UI for shortcut, colors, and label font size, including validation and defaults.
- **Tests/exit criteria:** unit tests cover conversion round trips and edge cases, dimensions, bounding unions, serialization shape, and preference defaults/validation; app builds.

**Status: complete (2026-10-30).** Added codable display/session/annotation/detection models; reusable point, size, rectangle, union/intersection, and display/capture/AX coordinate primitives; and a `UserDefaults`-backed preference store with validated shortcut, sRGB colors, and font-size range. The Preferences scene now exposes those settings and reports invalid values or corrupt saved preferences. The selected key is constrained to one ASCII letter/digit with at least one modifier; global shortcut registration remains for milestone 4.

**Verification:** targeted Xcode build and test succeeded with 15 tests and 0 failures, including negative display origins, round-trip point/rectangle transforms, AX vertical-axis conversion, logical-to-capture-pixel scaling/axis flip, invalid bounds/confidence, Codable session round trip, preference defaults/validation, persistence, and corrupt preference reporting. These are unit-level coordinate conventions; runtime behavior still needs validation with actual AX/ScreenCaptureKit data and multiple displays.

### 3. Display lifecycle and overlay-window prototype

- Enumerate displays and create one transparent, borderless AppKit overlay per display.
- Verify window level, Spaces/full-screen behavior, click-through vs. annotation hit-testing, z-order, and focus behavior.
- Handle display changes and retain annotations for disconnected displays without moving them to the primary display.
- **Tests/exit criteria:** manual matrix with displays left/right/above/below, including Retina/non-Retina if available; overlays align to display bounds and do not activate Snappy during passive measurement.

**Status: implemented with hardware validation pending (2026-10-30).** Snappy now creates a clear, click-through non-activating `NSPanel` per enumerated `NSScreen`, sets its bounds to that screen, and reconciles windows on `didChangeScreenParametersNotification`. Windows use the screen-saver level with all-Spaces/full-screen auxiliary behavior so future overlay content can remain above normal applications. A display annotation registry retains groups keyed by display ID while disconnected and exposes which groups are unavailable instead of assigning them to another attached display.

**Verification:** targeted tests pass for transparent/click-through/non-activating window properties, display identity independent of enumeration order, and retaining/restoring annotation groups through disconnect/reconnect. Launch/relaunch and display enumeration work on the available single Retina display. Physical multi-display arrangements, Spaces/full-screen behavior, and whether `.screenSaver` level is appropriate with actual overlay drawing remain to be checked before release. Current `CGDirectDisplayID` keys are runtime identifiers, not guaranteed durable device IDs across restarts/reconfiguration; persistent matching needs a later stable-identity strategy.

### 4. Global shortcut and input state machine

- Implement the shortcut adapter and configurable Command+Shift+F default; add conflict/error reporting.
- Validate pointer tracking, key commands, mouse-down/drag/up selection, Escape, and annotation interaction while another app has focus.
- Implement mode transitions and ensure starting via hotkey always creates a fresh active session while leaving saved restore data intact.
- **Tests/exit criteria:** unit tests for state transitions and hotkey lifecycle; manual tests across foreground apps; no stuck tracking, accidental focus steal, or lost persistent data on Escape.
- **Progress (2026-10-30):** Carbon hotkey registration now has an explicit lifecycle, shortcut changes attempt registration before replacing the current hotkey, stale hotkey IDs are ignored, and registration errors are shown in Preferences. Global mouse/key monitors and the coordinator implement pointer tracking, normalized drag-selection command emission, exact H/V modifier chords, Escape, and fresh-session initialization. Automated Xcode build and unit tests pass (25 tests, 0 failures). The new coordinator tests cover fresh sessions, display filtering, pointer/selection transitions, empty selection, command chords, and stop behavior. Foreground-app event delivery, Accessibility permission behavior, shortcut conflicts/re-registration in a real running app, and interaction/focus behavior remain manual verification items; downstream annotation/detection behavior is not implemented in this milestone.

### 5. Accessibility detection and permissions UX

- Implement the AX permission check/onboarding explanation and AX hit-test adapter.
- Retrieve element role and bounds where available; reject invalid, implausible, or low-specificity results; distinguish denied permission from an app that exposes no useful element.
- Add permission settings guidance and meaningful degraded-mode UX.
- **Tests/exit criteria:** mock-based tests for missing attributes, denied permission, invalid geometry, and accepted boundaries; manual tests against representative native and third-party apps.
- **Status (2026-10-30): implementation complete; live permission/app validation pending.** Added a mockable AX query interface and system-wide hit-test client, reading role/position/size and converting AX top-left screen geometry to AppKit coordinates. The detector validates permission, display ownership, finite/non-empty geometry, pointer containment, role specificity, and oversized/window-sized fallbacks; valid candidates are returned in display-local points through the shared result model. Preferences now explain Accessibility use, can trigger the system permission prompt, and open the Accessibility privacy pane. The existing global key-monitor permission check now uses the same permission manager. Xcode build and tests pass (33 tests, 0 failures), including denied trust, missing data, invalid/outside bounds, accepted native-element geometry, generic and oversized result rejection, coordinate conversion, and secondary-display ownership. Runtime AX queries and permission grant/revocation against representative apps remain unverified in this environment. No screen-capture fallback was added; that remains Milestone 6.

### 6. Screen capture and visual fallback

- Implement ScreenCaptureKit authorization, bounded capture, display/pixel-to-point conversion, and explicit error reporting.
- Add a conservative visual-boundary detector with candidate confidence and a shared `ElementDetectionService` result contract.
- Avoid continuous full-screen capture; trigger only for the current relevant region and apply throttling/cancellation to pointer movement.
- **Tests/exit criteria:** deterministic image fixtures test candidate containment, ranking, no-boundary/low-confidence outcomes, and rectangle detection; manual checks include permission denied, permission granted, multiple scaling factors, and protected content limitations.
- **Status (2026-10-30): implementation complete; screen/capture hardware validation pending.** Added a Screen Recording permission manager with preflight/request operations and Preferences guidance. `ScreenCaptureKitRegionCapturer` selects the matching display, excludes Snappy's own windows, captures a clipped 320x240-point (maximum) region around the pointer with the cursor hidden, and returns the image with its display-local point bounds. `VisualBoundaryDetector` uses `VNDetectRectanglesRequest`, applies confidence/size/pointer-containment/display-area gates, maps normalized image rectangles to display-local AppKit geometry, and ranks by smallest area then confidence. `ElementDetectionService` tries AX first, falls back only when needed and capture permission is granted, throttles capture requests, supports task cancellation, and reports capture/vision failures explicitly. Unit suite passes (40 tests, 0 failures), including deterministic rectangle and blank fixtures, candidate ranking, AX priority, bounded edge clipping, permission denial, and throttle behavior. Actual ScreenCaptureKit capture with TCC enabled/denied, different Retina scales, protected content, and external displays remains a manual verification task. Detection results are not connected to the overlay or pointer stream until Milestone 7.

### 7. Temporary measurement indicators

- Connect tracking to detection and render current horizontal/vertical dimensions and labels on the relevant display only.
- Add stable fallback behavior when detection is unavailable; show source/degraded state if needed to avoid false certainty.
- **Tests/exit criteria:** geometry and state tests plus manual pointer movement in multiple apps/displays; no misleading measurement when AX and vision cannot confidently identify an element.
- **Status (2026-10-30): implementation complete; live permissions and multi-display validation pending.** Added a tracking presentation controller that coalesces pointer updates, runs one detection at a time with a 120 ms minimum interval, and rejects stale async results before presentation. It routes validated candidates to only the matching display overlay, where a transparent AppKit drawing surface renders the red boundary, horizontal/vertical dimension lines, and preference-driven width/height labels. Unavailable detection displays a concise degraded-state or permission hint and never renders guessed dimensions; temporary presentation clears on selection, Escape, and controller shutdown. The full Xcode suite passes (42 tests, 0 failures), including display ownership, candidate validation, dimension-label formatting, stale detection rejection, and clearing on exit. Manual pointer movement across native apps, protected content, Retina scaling, permission states, and physical multiple displays remains pending.
- **Revision (2026-10-31):** live testing showed rectangle outlines and element-only detection were wrong for hover mode. Hover now shows only a horizontal and a vertical red line through the pointer, each ending in a T-shaped cap, with W/H labels. Extents come from `PixelExtentDetector`, which captures a bounded region (up to 1000x700 pt) and scans outward from the pointer until a sharp colour change, so it works on any visual area rather than only AX/Vision elements. The service no longer uses AX in this path (`accessibilityFirst: false`). Rectangle outlines are reserved for Milestone 9. 43 tests pass.

### 8. Persistent measurements and guidelines

- Implement H/V pinning, Shift+H/Shift+V guidelines, hover states, dragging without changing measurement length/orientation, label-X deletion, and guideline right-click removal.
- Keep each annotation type independent and associated with its originating display.
- **Tests/exit criteria:** interaction tests for create/move/delete and display ownership; manual verification after exiting/re-entering measurement mode.
- **Milestone 8 status (done):** `H`/`V` pin the current hover extent as a persistent measurement; `Shift+H`/`Shift+V` add display-wide guidelines. Annotations are stored display-local on the pointer's display. Hovering a line/guideline lets you drag it (length and orientation preserved, clamped to the display); hovering a measurement label turns it into an X that deletes on click; right-click deletes a guideline. Overlay panels toggle click-through only while hovering an annotation, so interaction continues after Escape. Logic lives in `AnnotationInteraction.swift`. 49 tests pass. H/V/Shift keys need Accessibility permission (global key monitor).

### 9. Durable sessions, restore, clear, and display remapping

- Implement atomic active-session and last-restorable storage, schema validation/migration, and save triggers on mutation, Escape, and quit.
- Implement Restore Last Session and Clear Annotations exactly as specified; preserve the prior restorable snapshot when a new hotkey session starts or annotations are cleared.
- Implement identity-first display matching, tested geometry remapping, and unavailable-display retention/reconnection.
- **Tests/exit criteria:** persistence tests for interrupted/failed writes, corrupt/older schema, restore, fresh start, clear, quit/relaunch, display disconnect/reconnect, and changed display geometry. Manual checks confirm annotations reappear at expected positions.

**Status: complete.** `SessionPersistence.swift` adds `SessionStore` (versioned JSON, atomic writes, validation, corrupt files quarantined as `*.corrupt.json`, newer schemas rejected and kept), `SessionRemapper` (identity match, then pixel size/scale match, geometry scaling, retention of unavailable displays for reconnection) and `SessionPersistenceController` (debounced save on mutation, save on mode exit and quit). Snapshot rule: `last-session.json` advances only after a successful save of a non-empty active session; fresh starts and Clear never touch it. Clear asks for confirmation. 60 tests pass.

### 10. Rectangle selection and persistent rectangles

- Implement drag selection, temporary selection rendering, release-time analysis, union of accepted elements/content, and creation of a persistent rectangle with dimensions.
- Implement click-to-delete without confusing rectangle interaction with other annotation types.
- **Tests/exit criteria:** pure geometry tests for intersecting/contained elements and bounding unions, fixture tests for visual fallback, and manual tests on native controls and inaccessible canvas-like content.

**M10 status: implemented (68 tests passing).** `RectangleSelection.swift` adds pure selection geometry, `ContentBoundsDetector` (visual fallback), `RectangleSelectionService` (AX sampled on a 5x5 grid, then content bounds, then the raw selection) and `RectangleSelectionController`. Dragging draws a dashed temporary rectangle; release replaces it with a persistent rectangle with a W x H label. Clicking its outline or label deletes it. Behaviour changes since M9: Escape clears annotations after saving, and the hotkey keeps existing annotations.

### 11. Hardening, documentation, and release verification

- Add end-to-end acceptance coverage across permissions, foreground apps, displays, annotation lifecycle, restore/clear semantics, and app quit/relaunch.
- Check CPU/battery behavior and capture throttling; audit accessibility and screen-capture failure paths.
- Complete README build/setup, permissions, shortcuts, session semantics, architecture, and limitations; keep it consistent with observed behavior.
- **Exit criteria:** clean Xcode build and test run; documented manual matrix passes; unresolved reliability limitations are stated rather than represented as completed functionality.

**M11 status: automated work complete (70 tests passing, zero build warnings).** Added `AcceptanceLifecycleTests` (all annotation kinds across two displays through quit/relaunch/restore, hotkey keeps annotations, delete/clear keep snapshot, detector failure paths fall back to the raw selection). Audit: no polling timers; capture is rate-limited and cancellable; permission failures surface as unavailable states. README rewritten to match observed behaviour and now contains the manual verification matrix, which still needs a human pass on live permissions, multiple displays, and real apps.

## Key risks and acceptance boundaries

| Risk | Why it matters | Planned mitigation / boundary |
|---|---|---|
| AX bounds are absent, coarse, or semantically wrong | Web views, canvas apps, custom controls, and inaccessible apps may expose only a window or no useful child element. | Validate candidates; use vision fallback only with confidence; report no reliable element rather than inventing bounds. |
| Visual boundaries are ambiguous | Borders, shadows, text, textures, and overlapping controls create many plausible rectangles. | Conservative candidate ranking and fixed fixtures; real-app validation; no claim of universal semantic element detection. |
| TCC permissions are denied or revoked | AX and screen capture are distinct capabilities and can fail independently. | Check each capability at point of use; explain purpose, provide Settings guidance, support degraded mode, surface errors. |
| Global input or overlay routing is restricted | Global event monitoring, mouse interception, focus, and click-through requirements may conflict. | Resolve with milestone 0 prototypes before committing to the event architecture; minimize permissions and avoid suppressing underlying-app events. |
| Coordinate-system mismatches | AppKit, Quartz, AX, and image pixels can differ in origin and scale; monitors can have negative origins. | One tested mapper, explicit coordinate metadata, per-display-local geometry, cross-display manual matrix. |
| Restoring onto changed/disconnected displays | Blind fallback to the primary display can place annotations over unrelated content. | Identity-first matching, geometry remapping only on a match, preserve unmatched annotations without rendering elsewhere. |
| Session snapshot semantics are subtle | A fresh session and Clear must not erase the separately retained restore snapshot. | Separate active and restorable state/files; test new-session, mutation, clear, restore, failure, and relaunch cases before UI polish. |

## Decisions to settle before the relevant milestone

1. Minimum supported macOS version and distribution method, which determine API availability and permission onboarding.
2. Exact global input implementation after prototypes; decide whether any additional Input Monitoring permission is acceptable.
3. Whether a low-confidence detection should show no indicator or a clearly marked approximate fallback. The safe initial choice is no inferred element dimensions.
4. Confirm the last-restorable snapshot advancement rule: initial proposal is to update after a successful save of a non-empty active session, but never merely on hotkey activation or Clear.
5. Confirm the user-facing confirmation/undo behavior for Clear Annotations.
6. Confirm the display-change remapping policy, especially whether annotation dimensions should scale proportionally when logical display dimensions change.
