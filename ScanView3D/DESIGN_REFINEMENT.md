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
  controls into one row. Measured, capped scroll viewports keep long warnings
  and prescan controls inside their allotted space. The full-size capture
  actions remain available; Finish uses a deeper red with clear white text.
- **Viewer:** quieter grouped action controls reserve cyan for the active tool.
  Large text uses a two-column action layout and a menu showing the selected
  rendering style. Manual/Object selection remains visible above the scrolling
  measurement controls. A failed measurement puts Retry Save ahead of its error
  explanation; large-text point-placement actions also precede longer guidance.
- **Object dimensions:** clearer value/evidence hierarchy, restrained Save/Saved
  states, stacked dimensions at accessibility sizes, and a narrow-width fallback
  for selection controls. The default panel remains bounded so it does not grow
  over the model as content changes.
- **Projects/library:** compact summaries replace repeated large hero panels;
  consistent rows/cards show capture type, size and scale status where relevant.
  Search results put matching captures first. Large text uses readable list
  presentation without changing the saved grid preference. Project sorting is
  visible alongside the capture list with a 44-point minimum tap area. Compact
  accessibility summaries bring first-project actions and scan rows higher.
- **Settings:** compact branding, one Preferences group, consistent row symbols,
  neutral labels and values, and less repeated product information. At
  accessibility sizes, preferences appear first and product details move to
  About; multiline row labels stay aligned to the leading edge.
- **Import progress:** a focused, readable progress card over a dimmed workspace,
  with a scrolling fallback for limited height and modal accessibility semantics.
  It shows indeterminate progress honestly; no invented percentage is displayed.

All existing capture/recovery, save/retry, import/export, scale restrictions,
destructive confirmations and library protections remain in place. The preview
fixtures are Debug-simulator-only and operate on temporary libraries.

## Verification

Code `2ace457` passed [run 42315326643](https://github.com/Miobat/Claude-3D/actions/runs/42315326643)
on 2026-11-07:

- 275 Swift regression tests and 290 native checks, with zero failures.
- Unsigned iPhone and simulator builds, plus independent OpenUSD verification.
- 93 simulator screenshots, including library, project, empty, importing,
  capture-details, combined-warning and measurement-retry states, and large-text
  and landscape variants. Preview scan settings reset only inside explicit
  design fixtures, so one screenshot cannot inherit another fixture's mode.
- Local Swift-source, Xcode-project and workflow checks, and `git diff --check`.

Visual review inspected 33 distinct final screenshots across scanner, warnings,
capture details, viewer, measurements, projects/library, Settings and import
progress. No blocking layout issue remained in that reviewed set. The review
confirmed the screenshot-driven corrections: capped warning/prescan content,
readable Combined labels, visible Retry Save and point-placement actions, and
shorter large-text project/Settings headers. Longer warning and measurement
details deliberately remain in bounded scroll areas; not every detail fits in
one viewport at accessibility text sizes.

TestFlight upload was skipped. This branch is validated development work, not
a published phone build.

Physical-device acceptance still includes live camera visibility outdoors,
rotation, largest text, VoiceOver, scrolling to every action, and the feel of
joystick/measurement gestures. Screenshots cannot prove these interactions.
See `COMMERCIAL_READINESS.md` for the separate data-safety and paid-release gates.
