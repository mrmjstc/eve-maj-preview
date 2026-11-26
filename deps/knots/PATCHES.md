# Local patches to knots

Vendored from [knots-ui/knots](https://github.com/knots-ui/knots) at the commit in `patches/BASE`. Every change is marked `EVE-Maj patch` in the source and saved as one patch per file in `patches/`. After changing a vendored file, run `python tools/update_knots.py export`; to move to a newer upstream, `python tools/update_knots.py update <commit>` applies the patches to it. `tools/checks/knots_patches.py` (part of `run_all.py`) fails when the patches, the markers and this file disagree.

Each section's **Upstream** line says where it stood against upstream `80d6396` (0.7.0, checked 2026-11-26): *fixed upstream* (drop it on the next update), *still needed*, or *local* (a preference upstream wouldn't want).

## `src/ui/component/ColorPicker.zig`

**Upstream:** still needed; the file changed upstream, so it's ported by hand.

- `show_hex` (default `true`): off, the trigger is just the swatch, with no hex beside it.
- `show_alpha` (default `true`): off, the popup has no alpha strip, the hex has no alpha, and picked colours are opaque.
- The popup is shifted left, as far as the viewport allows, so a trigger near the window's right edge doesn't push it off screen.
- The swatch's corner radius comes from its style (`parts.swatch`, default 3). With `show_hex` off, the trigger's minimum height is just the swatch plus its padding, and the swatch has no outline of its own, so a swatch can fill its trigger.
- `is_unset` (default `false`): on, the swatch is struck through, showing its colour is only a fallback.
- `reset` (default `null`): set, the popup ends with a Reset button (styled by `parts.reset`/`parts.reset_label`, disabled while `is_unset`) whose click sets it true and closes the popup.
- Checkerboards round their corner cells to match the fill over them, the swatch skips its board for an opaque colour, and the preview rounds only its outer corners, so no checker pixels show at rounded corners.

## `src/ui/component/TextInput.zig`

**Upstream:** the frame-arena copy is fixed upstream; the other two are still needed, ported by hand into the IME rewrite (#28).

- The root's overflow is `scroll_x_bare`, so long text still scrolls to keep the caret in view, but no scrollbar is drawn over the box.
- The text is drawn from a copy in the frame arena, so a caller that clears or refills the buffer later in the same frame (e.g. a search box's clear button) doesn't leave the drawn text pointing at bytes Zig has set to undefined.
- The caret, selection and mouse hit-testing are offset by the gap the root's centring leaves above the line, so they line up with the text in an input taller than one line.

## `src/layout/Element.zig`, `src/layout/Context.zig`, `src/ui/scrollbar.zig`

**Upstream:** still needed; applies cleanly.

- `Overflow.scroll_x_bare`: scrolls horizontally like `scroll_x`, but `scrollbar.compute` gives it no bar, so none is drawn or hit-tested.

## `src/layout/Context.zig`, `src/layout/tests.zig`

**Upstream:** `distributeGrow` is still needed, and worth offering upstream with its tests; the `justify` gap is fixed upstream.

- `distributeGrow` works each pass's share out afresh from the children it clamps, then sizes every grow child from it. A grow child with a `min` starts at that min and was skipped, so it never grew past it; a child clamped in an earlier pass was subtracted from the free space again. Tested in `tests.zig`'s new `min/max` tests.

- `computeLayoutNode`'s free space for `justify` subtracts the gaps once: they were added back, so a centred row with a gap (e.g. a button with a glyph and a label) sat half a gap right, and `space_between`/`space_around` overran by the gaps. Tested in `tests.zig`'s gap `justify` tests.

## `src/ui/UI.zig`

**Upstream:** still needed; applies cleanly.

- `inert_depth` (default 0): while above 0, `openWith` makes every element it opens non-interactive and non-focusable, so a disabled group of controls takes no clicks and drops out of Tab order.
- `setAccessibilityName(id, name)`: renames a node drawn this frame and keeps its role and state, so a caller that draws a control's label itself (e.g. beside a text input) can still give the control that name. Does nothing for a node that isn't there, such as while accessibility is off.

## `src/ui/component/Tooltip.zig`

**Upstream:** still needed; applies cleanly.

- `align_start` (default false): a tooltip above or below its trigger starts at the trigger's left edge instead of centring on it, so a row label's tooltip sits over its words rather than the middle of a stretched label cell.

## `src/ui/State.zig`

**Upstream:** fixed upstream; the state bridge went with hot reload (#16).

- No widget state is copied into the state bridge (`bridged` is always false). The bridge only feeds knots' hot reload, which EVE-Maj doesn't use, and it never drops a widget's entry once its state is evicted, so browsing tabs for long enough filled its 1024 entries and stopped the window with `TooManyStateValues`.

## `src/ui/Context.zig`

**Upstream:** the drag threshold is local; the other two are still needed, ported by hand since the file was largely rewritten upstream.

- `press_drag_threshold_sq` is 64 (8px) instead of 9 (3px): a press that moves less than that before release is still a click, so clicking while the mouse is moving isn't dropped.
- A `scroll_x_bare` box clips its children at its left and right padding, so a text input's long line stops short of the border.
- Rectangles are drawn with their edges and border widths rounded to whole device pixels (`snapToPixel`), so a box laid out on a half pixel, e.g. centred in a row, doesn't smear its 1px border over two pixels.

## `src/App.zig`

**Upstream:** fixed upstream with the same guard; it would apply cleanly and duplicate it, so drop it.

- `renderFrame` skips a frame while the window's logical or framebuffer size is zero: a minimized window stays zero-sized after its resize event, and a frame built at that size fails.

## `build.zig.zon`, `lib/*/build.zig.zon`

**Upstream:** local; upstream needs 0.17.0, and `lib/wasmtime` and `lib/watch` are gone.

- `minimum_zig_version` is 0.17.1, matching the app.
