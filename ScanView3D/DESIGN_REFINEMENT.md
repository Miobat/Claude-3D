# TinyScanner design refinement

Branch: `codex/design-refinement`, based on verified reliability work `4879d21`.
The graphite, titanium and ice-cyan TinyCorp identity stays in place. This pass
focuses on information hierarchy and usable model/camera space, with no changes
to capture algorithms, coordinates, stored formats or measurement maths.

## Changes

- **Live scanning:** a compact overlay selector, range and capture summary replace
  the large always-visible dashboard. Detailed counts, legends, capacity and
  checkpoint information move into a scrollable Capture details sheet. Recovery,
  tracking and photo warnings remain accessible on the live view. Large text
  uses a labelled-for-accessibility info button instead of cramming two long
  controls into one row. The full-size capture actions remain available.
- **Viewer:** quieter grouped action controls reserve cyan for the active tool.
  Large text uses a two-column action layout and a menu showing the selected
  rendering style. Manual/Object selection remains visible above the scrolling
  measurement controls. A failed measurement has an explicit Retry Save action.
- **Object dimensions:** clearer value/evidence hierarchy, restrained Save/Saved
  states, stacked dimensions at accessibility sizes, and a narrow-width fallback
  for selection controls. The default panel remains bounded so it does not grow
  over the model as content changes.
- **Projects/library:** compact summaries replace repeated large hero panels;
  consistent rows/cards show capture type, size and scale status where relevant.
  Search results put matching captures first. Large text uses readable list
  presentation without changing the saved grid preference. Project sorting is
  visible alongside the capture list.
- **Settings:** compact branding, one Preferences group, consistent row symbols,
  neutral labels and values, and less repeated product information.
- **Import progress:** a focused, readable progress card over a dimmed workspace,
  with a scrolling fallback for limited height and modal accessibility semantics.
  It shows indeterminate progress honestly; no invented percentage is displayed.

All existing capture/recovery, save/retry, import/export, scale restrictions,
destructive confirmations and library protections remain in place. The preview
fixtures are Debug-simulator-only and operate on temporary libraries.

## Verification

Local source/project/workflow checks and the normal Swift/native regression suite
are required. The design branch expands the simulator tour to include library,
project, empty, importing, capture-details, combined-warning and measurement-retry
states, plus large-text and landscape variants. Preview scan settings are reset
only inside explicit design fixtures, so one screenshot cannot inherit another
fixture's capture mode. Final CI and visual-review results are recorded here
after verification.

Physical-device acceptance still includes live camera visibility outdoors,
rotation, largest text, VoiceOver, scrolling to every action, and the feel of
joystick/measurement gestures. Screenshots cannot prove these interactions.
See `COMMERCIAL_READINESS.md` for the separate data-safety and paid-release gates.
