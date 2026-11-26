# Local patches to knots

Vendored from [knots-ui/knots](https://github.com/knots-ui/knots) at the commit in `patches/BASE`. Every change is marked `EVE-Maj patch` in the source and saved as one patch per file in `patches/`. After changing a vendored file, run `python tools/update_knots.py export`; to move to a newer upstream, `python tools/update_knots.py update <commit>` applies the patches to it. `tools/checks/knots_patches.py` (part of `run_all.py`) fails when the patches, the markers and this file disagree.

Each section's **Upstream** line says whether it's worth offering upstream or is a local preference. Moving from 0.3.0 to 0.7.0 (`80d6396`) dropped five patches upstream had fixed: the `justify` gap, the state bridge's leak, the minimized-window guard, the text input's frame-arena copy and the colour picker's popup placement.

## `src/ui/component/ColorPicker.zig`

**Upstream:** worth offering; additive options.

- `show_hex` (default `true`): off, the trigger is just the swatch, with no hex beside it.
- `show_alpha` (default `true`): off, the popup has no alpha strip, the hex has no alpha, and picked colours are opaque.
- The swatch's corner radius comes from its style (`parts.swatch`, default 3). With `show_hex` off, the trigger's minimum height is just the swatch plus its padding, and the swatch has no outline of its own, so a swatch can fill its trigger.
- `is_unset` (default `false`): on, the swatch is struck through, showing its colour is only a fallback.
- `reset` (default `null`): set, the popup ends with a Reset button (styled by `parts.reset`/`parts.reset_label`, whose `base` styles are empty, and disabled while `is_unset`) whose click sets it true and closes the popup.
- Checkerboards round their corner cells to match the fill over them, the swatch skips its board for an opaque colour, and the preview rounds only its outer corners, so no checker pixels show at rounded corners.

## `src/ui/component/TextInput.zig`

**Upstream:** worth offering; the caret offset is a bug fix.

- The root's overflow is `scroll_x_bare`, so long text still scrolls to keep the caret in view, but no scrollbar is drawn over the box.
- The caret, selection, mouse hit-testing and IME position are offset by the gap the root's centring leaves above the line, so they line up with the text in an input taller than one line.

## `src/layout/Element.zig`, `src/layout/Context.zig`, `src/ui/scrollbar.zig`

**Upstream:** worth offering with the text input's use of it.

- `Overflow.scroll_x_bare`: scrolls horizontally like `scroll_x`, but `scrollbar.compute` gives it no bar, so none is drawn or hit-tested.

## `src/layout/Context.zig`, `src/layout/tests.zig`

**Upstream:** worth offering first; a bug fix with tests.

- `distributeGrow` works each pass's share out afresh from the children it clamps, then sizes every grow child from it. A grow child with a `min` starts at that min and was skipped, so it never grew past it; a child clamped in an earlier pass was subtracted from the free space again. Tested in `tests.zig`'s new `min/max` tests, and the gap `justify` tests guard upstream's own fix.

## `src/ui/UI.zig`

**Upstream:** worth offering; additive.

- `inert_depth` (default 0): while above 0, `openWith` makes every element it opens non-interactive and non-focusable, so a disabled group of controls takes no clicks and drops out of Tab order.
- `setAccessibilityName(id, name)`: renames a node drawn this frame and keeps its role and state, so a caller that draws a control's label itself (e.g. beside a text input) can still give the control that name. Does nothing for a node that isn't there, such as while accessibility is off.

## `src/ui/component/Tooltip.zig`

**Upstream:** worth offering; additive.

- `align_start` (default false): a tooltip above or below its trigger starts at the trigger's left edge instead of centring on it, so a row label's tooltip sits over its words rather than the middle of a stretched label cell.

## `src/ui/Context.zig`

**Upstream:** `snapToPixel` is worth offering as a bug fix; the drag threshold is local.

- `press_drag_threshold_sq` is 64 (8px) instead of 9 (3px): a press that moves less than that before release is still a click, so clicking while the mouse is moving isn't dropped.
- A `scroll_x_bare` box clips its children at its left and right padding, so a text input's long line stops short of the border.
- Rectangles, images, canvases and range knobs are drawn with their edges and border widths rounded to whole device pixels (`snapToPixel`), so a box laid out on a half pixel, e.g. centred in a row, doesn't smear its 1px border over two pixels.

## `build.zig.zon`, `lib/*/build.zig.zon`

**Upstream:** local.

- `minimum_zig_version` is 0.17.1, matching the app.
