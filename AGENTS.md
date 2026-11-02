# Instructions for GitHub Copilot

These instructions describe the overall requirements and
architecture of this project.

IMPORTANT:
- Treat this document as the authoritative project specification.
- Do not attempt to implement the entire application in one task.
- Implement only the functionality requested in the current task.
- Preserve existing functionality when making changes.
- Build and test the application after each meaningful change.
- If a requirement is ambiguous, ask for clarification rather
  than making assumptions that significantly affect architecture.
- If a requirement cannot be implemented using public macOS APIs,
  explain the limitation before implementing an alternative.
- Update this document if architectural decisions change,
  but do not silently change functional requirements.

# Project: Native macOS Screen Measurement Application named "Snappy"

Create a native macOS application using Swift, SwiftUI, and AppKit, developed, built, and tested using Xcode.

The application is a lightweight screen measurement utility. It allows users to measure the dimensions and positions of visual elements on their screen, create persistent measurement annotations, and place alignment guidelines over other applications.

The application should behave like a screen ruler or design measurement tool, with an emphasis on being lightweight, unobtrusive, and easy to operate using keyboard shortcuts and mouse interactions.

# 1. Application Structure

- Build a native macOS application using Swift.
- Use Xcode as the development environment and build system.
- The application should be a menu bar application.
- It should not display an icon in the macOS Dock.
- It should not have a conventional main application window.
- A menu bar icon should provide the following options:
  - Preferences...
  - Restore Last Session
  - Clear Annotations
  - Quit
- Support multiple monitors, including monitors with different resolutions and scaling factors.
- Treat each monitor as an independent measurement and annotation surface.
- Each monitor should have its own coordinate space and annotation collection.
- Screen overlays should appear above other applications without unnecessarily stealing keyboard focus.
- Use transparent, borderless overlay windows for measurements, rectangles, and guidelines.

# 2. Measurement Mode

The user activates measurement mode using a configurable global keyboard shortcut.

- Default shortcut: Command+Shift+F.
- The shortcut must work regardless of which application currently has focus.

When measurement mode is activated:

1. Begin tracking the mouse position.
2. Identify the visual element underneath the mouse.
3. Determine its boundaries.
4. Draw red measurement indicators showing its horizontal and vertical dimensions.
5. Display the corresponding width and height as readable dimension labels.
6. Update the indicators continuously as the mouse moves.

The application should identify actual visual element boundaries rather than simply measuring the distance to the nearest screen edges.

### Edge detection strategy

Use a hybrid edge detection approach:

**Primary: macOS Accessibility API**

- Identify the UI element underneath the cursor using macOS Accessibility APIs.
- Retrieve its bounding rectangle and other available information.
- Prefer this information when it provides a reliable element boundary.
- Handle applications that expose incomplete or unavailable accessibility information.

**Fallback: Computer vision and screen capture**

- When Accessibility information is unavailable or insufficient, capture the relevant screen region.
- Analyze the captured image to identify visual boundaries.
- Use appropriate computer vision techniques to identify rectangular regions, edges, and visual elements.
- Prefer the smallest plausible visual element containing the mouse position.
- Avoid treating arbitrary changes in color or texture as definitive UI element boundaries.

The edge detection subsystem should expose a consistent interface regardless of which detection strategy is used.

If neither approach can confidently identify an element, provide a reasonable fallback rather than displaying misleading measurements.

# 3. Persistent Measurements

The user can turn the current measurement indicators into persistent annotations.

### Horizontal measurement

- Pressing H makes the current horizontal measurement persistent.
- The measurement remains at its current position and retains its dimensions.
- Hovering over the measurement allows the user to drag it.
- Dragging changes its position without changing its length or orientation.

### Vertical measurement

- Pressing V makes the current vertical measurement persistent.
- The measurement remains at its current position and retains its dimensions.
- Hovering over the measurement allows the user to drag it.
- Dragging changes its position without changing its length or orientation.

### Deleting measurements

- Hovering over the dimension label of a persistent measurement changes the label into an X delete indicator.
- Clicking the X removes the measurement.
- The measurement otherwise remains visible and unchanged.

Persistent measurements must remain visible after measurement mode is exited.

# 4. Guidelines

The user can create alignment guidelines while in measurement mode.

- Pressing Shift+H creates a horizontal guideline at the current mouse position.
- Pressing Shift+V creates a vertical guideline at the current mouse position.
- Guidelines should be blue to distinguish them from red measurement indicators.
- Guidelines should span the entire relevant monitor.
- Guidelines remain visible after measurement mode is exited.
- Hovering over a guideline allows the user to drag it to a new position.
- Holding Command while dragging a guideline temporarily disables edge snapping and snap haptic feedback; releasing Command allows snapping again.
- During dragging, guidelines snap to sustained visual edges near the grabbed point. Higher-contrast edges have a larger attraction and release distance. Use the selected visual edge tolerance, and reuse the frozen screen image or capture once per drag without overlays. Capture failure leaves dragging available without snapping.
- Request trackpad haptic feedback when acquiring a snap, with an additional brief pulse for stronger edges. Public macOS APIs do not expose haptic intensity; feedback depends on trackpad support and system preferences. Do not repeatedly pulse while staying snapped to one edge.
- Right-clicking a guideline removes it.

Guidelines should be independent of persistent measurements.

# 5. Rectangle Measurement

The user can measure rectangular regions by dragging the mouse.

### Selection

1. When the user presses and holds the mouse button, begin drawing a selection rectangle.
2. As the mouse moves, update the selection rectangle.
3. When the mouse button is released, analyze the selected region.
4. Identify the visual elements contained within or intersecting the selection.
5. Calculate the smallest bounding rectangle that completely encloses the identified elements.
6. Replace the original selection rectangle with the resulting bounding rectangle.
7. Display its width and height.
8. Make the resulting rectangle a persistent annotation.

### Element identification

Use the hybrid detection approach:

- Prefer Accessibility API information to identify individual UI elements.
- Fall back to computer vision when accessibility information is unavailable or incomplete.
- When multiple elements are identified, calculate the smallest rectangle that encloses all identified elements.

If individual elements cannot be reliably identified, use computer vision to identify visual content and calculate the smallest bounding rectangle enclosing that content.

Do not simply snap each edge independently to the nearest visual edge.

### Persistent rectangles

- Display the rectangle outline and its dimensions.
- Give persistent rectangles a faint transparent red fill.
- Dragging the outline or filled interior of a persistent rectangle moves it without changing its dimensions.
- Hovering the dimension label shows an X; clicking the X deletes the rectangle.
- Rectangles remain visible after measurement mode is exited.
- Rectangles should be independent of horizontal and vertical measurement annotations.

# 6. Exiting Measurement Mode

Pressing the configured global shortcut while measurement mode is active also exits measurement mode and keeps persistent annotations visible.

Pressing Escape exits measurement mode.

When measurement mode exits:

- Remove temporary measurement indicators.
- Remove any temporary rectangle selection.
- Preserve persistent measurements.
- Preserve persistent rectangles.
- Preserve persistent guidelines.
- Return control to the underlying application.

The user should be able to activate measurement mode again without losing existing annotations, subject to the session behavior described below.

# 7. Session Management and Persistence

Session management is an important feature of the application.

The application must distinguish between an active session and a previously saved session.

### Starting a new session

Whenever the user activates measurement mode using the global hotkey:

- Start a new, empty measurement session.
- Do not automatically restore annotations from the previous session.
- Initialize empty collections for horizontal measurements, vertical measurements, rectangles, and guidelines.
- Do not destroy the previously saved session when starting a new one.

This behavior is intentional: activating the hotkey always starts a fresh session.

### Saving sessions

- Automatically save the active session as annotations are created, moved, or deleted.
- Save the active session when measurement mode exits.
- Save the active session when the application quits.
- Persist measurements, rectangles, guidelines, their dimensions, positions, orientations, and associated monitor information.
- Use a reliable native macOS persistence mechanism.
- Ensure incomplete or interrupted writes do not corrupt the last successfully saved session.

### Restore Last Session

Provide a Restore Last Session menu item.

When selected:

- Load the most recently saved session.
- Restore all persistent measurements, rectangles, and guidelines.
- Restore their original positions and dimensions.
- Restore their associations with their original monitors.
- Make the restored annotations immediately visible.
- Do not start with an empty session.

Restoring a session should be an explicit user action.

### Clear Annotations

Provide a Clear Annotations menu item.

When selected:

- Remove all persistent horizontal measurements.
- Remove all persistent vertical measurements.
- Remove all persistent rectangles.
- Remove all persistent guidelines.
- Clear the annotations from the active session.
- Do not silently delete the separately retained previous-session snapshot.

Consider providing a confirmation dialog or an undo mechanism to prevent accidental deletion.

### Session data model

Keep session persistence independent of the annotation rendering system.

A session should contain:
- A unique session identifier.
- Creation and last-modified timestamps.
- Annotations grouped by monitor.
- Each annotation's type, position, dimensions, and relevant interaction properties.
- Monitor identification and display characteristics needed to restore annotations.

When restoring a session:

- Match annotations to their original monitors whenever possible.
- Handle disconnected monitors gracefully.
- Handle changes in monitor resolution and scaling.
- Avoid displaying annotations at incorrect positions when the original monitor is unavailable.

Maintain the last saved session separately from the currently active session so starting a new session does not destroy the ability to restore previous work.

# 8. Multiple Monitor Support

Treat each monitor as an independent measurement surface.

- Create appropriate transparent overlay windows for each monitor.
- Track the mouse on the monitor where it is currently located.
- Draw temporary indicators only on the relevant monitor.
- Associate persistent annotations with the monitor on which they were created.
- Ensure guidelines span their associated monitor rather than the entire virtual desktop.
- Support monitors positioned above, below, left, or right of the primary monitor.
- Correctly handle different display resolutions and Retina scaling factors.
- Handle monitors being connected or disconnected while the application is running.

Do not assume that the primary monitor begins at coordinate (0, 0).

# 9. Visual Design

Use a clean, minimal visual design.

Suggested visual conventions:

- Red: Temporary and persistent measurement indicators.
- Blue: Alignment guidelines.
- High-contrast dimension labels.
- Clear hover states for interactive annotations.
- An X indicator when hovering over a measurement's dimension label.

The application should remain usable against both light and dark backgrounds.

Avoid unnecessary animations, visual clutter, and opaque backgrounds.

# 10. Preferences

Measurement mode supports four edge tolerance levels: Zero (fixed at 0), Low (default 4), Medium (default 8 and initially selected), and High (default 16). Low, Medium, and High values and the selected level persist in preferences. Values are per-channel RGB contrast thresholds; higher levels ignore larger color differences. T cycles levels with wraparound; - decreases and = increases without wraparound. A change immediately refreshes the measurement and displays a brief toast centered near the bottom of the pointer's monitor. Accessibility element bounds are unaffected.

Provide a Preferences window accessible from the menu bar.

At a minimum, preferences should support:

- Changing the global keyboard shortcut.
- Configuring measurement indicator colors.
- Configuring guideline colors.
- Configuring dimension label font size.

Structure the preferences system so additional options can be added easily.

# 11. Technical Requirements

- Use native macOS APIs wherever practical.
- Use SwiftUI for conventional interface elements.
- Use AppKit and Core Graphics where appropriate for transparent overlays, window management, event handling, and precise drawing.
- Investigate appropriate macOS APIs for global keyboard shortcuts and mouse tracking.
- Use macOS Accessibility APIs for UI element identification.
- Use screen capture and computer vision as the fallback detection strategy.
- Handle Screen Recording and Accessibility permissions appropriately.
- Clearly explain permissions to the user.
- Avoid unnecessary polling and excessive screen capture operations.
- Keep the following concerns separate:
  - Screen capture.
  - Accessibility-based element detection.
  - Computer vision and edge detection.
  - Measurement calculations.
  - Overlay rendering.
  - Mouse and keyboard interaction.
  - Annotation management.
  - Session persistence.
  - Preferences.

The implementation should be modular, maintainable, and testable.

# 12. Development Expectations

Before implementing the application:

1. Examine the technical requirements.
2. Identify macOS API limitations and permission requirements.
3. Propose an application architecture.
4. Explain the hybrid edge detection strategy.
5. Explain the multiple-monitor coordinate system.
6. Describe the session persistence model.
7. Identify features that may be difficult or impossible to implement reliably using public macOS APIs.

Implement the application incrementally.

Each implementation stage should:
- Build successfully in Xcode.
- Include appropriate tests.
- Have working functionality rather than placeholders.
- Avoid introducing regressions in previously implemented features.

Do not claim a feature is complete if it is only partially implemented.

If a feature cannot be implemented reliably, document the limitation and propose alternatives.

Include a README documenting:

- Application architecture.
- Build and setup instructions.
- Required macOS permissions.
- Keyboard shortcuts.
- Session management behavior.
- Known limitations.
