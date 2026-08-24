# Changelog

## Unreleased

### Added
- Draggable layout preview for text overlay positioning, with independent per-element fonts and backgrounds (merged from `feat/layout-preview`).
- "Constrain aspect ratio" now defaults to on in the config dialog.
- Combat/Mining/Bounty overlay tabs are now hidden behind Advanced Mode, like the General tab.

### Changed
- Default build optimize mode is now `ReleaseFast` instead of `ReleaseSafe`.
- Layout preview: disabled chips now show a diagonal strike (matching the swatch cleared-color style) instead of fading via opacity.
- Merged the overlay tab's "Preview" and "Layout Preview" sections into one "Text Overlays and Layout" section with a combined hint and checkboxes.

### Fixed
- Deleting the last-used profile no longer crashes the app on next launch; it falls back to the default profile and heals `global.settings.json`.
- Disabling chatlog monitoring while System Name display is on no longer leaves a stale system name frozen on the thumbnail until restart.
- Layout preview: chips now sit flush against the stage edges and align with each other correctly, both while dragging and at rest (sub-pixel positioning, padding-vs-border-box, and stage/chip measurement consistency fixes).
- Layout preview: font size now visibly scales with each element's configured font size instead of staying fixed.
- Layout preview: the aspect-ratio size slider now refreshes the preview like manually editing width/height does.

### Removed
- Per-alert "Enable" checkboxes for Taking Damage, Laser Idle, and Mining Stopped alerts, along with the Taking Damage alert's separate Repeat Interval — these were redundant with the Notifications tab's own per-type enable/suppress/throttle controls, which now solely govern whether these alerts are shown.
