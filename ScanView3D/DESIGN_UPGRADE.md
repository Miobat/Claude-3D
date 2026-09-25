# Field design upgrade

Branch: `codex/design-system-upgrade`, based on the previous TestFlight release source
`e089dd3` (`codex/coordinate-export-consistency`). No automatic TestFlight upload.

## Visual direction

An understated field instrument: graphite viewport panels, mint primary controls,
adaptive neutral library surfaces, native system typography, rounded continuous
cards, and subtle vector contours. No remote fonts, image downloads, new service,
account, or image-generation dependency. Decorative contours are not scan data.

`Views/Shared/DesignSystem.swift` owns colors, cards, hero/empty states, thumbnails,
button feedback and field icons. AccentColor has separate light/dark variants.
Scanner and viewer controls remain high-contrast on opaque dark panels even when
the library uses light mode. System/Light/Dark preference lives in Settings.

## Screens and interaction changes

- Projects: searchable workspace, summary, larger thumbnails, clearer hierarchy,
  and explicit deletion confirmation for context-menu and swipe deletion.
- All Scans: responsive visual grid, persistent grid/list preference, search,
  shared cards and clear empty/search states.
- Project detail: project header, adaptive statistics and consistent scan rows;
  duplication also works when there is only one project. Import errors surface.
- Scanner: live camera remains the canvas. Compact capture-mode selection and
  Start/Finish controls; range/detail/color/north/photo settings move into a
  scrollable native sheet. Existing capture/finalization/recovery behavior stays.
- Viewer: separate camera/projection/layer controls; scrollable render modes;
  labelled Tools/Measure/Share actions; scale warnings retained; consistent
  loading/export UI and retry on model-load errors.
- Save/recovery/move/settings/diagnostics: native navigation and shared surfaces.
  Settings now shows the real bundle version/build instead of a hardcoded 1.0.0.

Dynamic Type is used for reading and controls, with simplified headers, a single
column of capture choices, and a horizontally scrollable action dock at
accessibility sizes. Landscape uses compact capture and viewer layouts.
Icon-only actions are labelled;
primary field hit areas are at least 44 points. Button motion respects Reduce
Motion. Selection uses a checkmark or selected accessibility trait as well as
color. Destructive actions and unverified-scale restrictions remain explicit.

## Validation

The normal 67 core tests, independent OpenUSD verification and unsigned device /
simulator builds remain the release gate. This branch also captures production
SwiftUI views on a real iOS simulator in light, dark and accessibility text sizes.
See `.github/scripts/design-screenshots.sh` and the `native-design-previews` CI
artifact. Visual fixtures are compiled **only in Debug simulator builds**, use a
new temporary library, and cannot modify a device user's library. Sample terrain
is synthetic and is not an accuracy demonstration.

Phone acceptance checklist: bright-light camera contrast; mode/settings changes;
Start/Pause/Finish/Keep for Later; save and reopen; Viewer Tools/Measure/Share;
search/list/grid; cancel delete; largest text; VoiceOver focus; iPad split-screen
and phone rotation. Simulator screenshots cannot certify camera capture, touch
feel, outdoor legibility, thermal behavior or real-device photogrammetry.
