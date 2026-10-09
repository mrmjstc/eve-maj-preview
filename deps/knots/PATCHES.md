# Local patches to knots

Vendored from [knots-ui/knots](https://github.com/knots-ui/knots) at commit `9cd60181892ef12d9cb3e0d87f5461e928140a92` (0.3.0). Every change is marked `EVE-Maj patch` in the source; re-apply these after updating the copy.

## `src/ui/component/ColorPicker.zig`

- `show_hex` (default `true`): off, the trigger is just the swatch, with no hex beside it.
- `show_alpha` (default `true`): off, the popup has no alpha strip, the hex has no alpha, and picked colours are opaque.
- The popup is shifted left, as far as the viewport allows, so a trigger near the window's right edge doesn't push it off screen.
- The swatch's corner radius comes from its style (`parts.swatch`, default 3). With `show_hex` off, the trigger's minimum height is just the swatch plus its padding, and the swatch has no outline of its own, so a swatch can fill its trigger.
- `is_unset` (default `false`): on, the swatch is struck through, showing its colour is only a fallback.
- `reset` (default `null`): set, the popup ends with a Reset button (styled by `parts.reset`/`parts.reset_label`, disabled while `is_unset`) whose click sets it true and closes the popup.
- Checkerboards round their corner cells to match the fill over them, the swatch skips its board for an opaque colour, and the preview rounds only its outer corners, so no checker pixels show at rounded corners.

## `src/ui/component/TextInput.zig`

- The root's overflow is `scroll_x_bare`, so long text still scrolls to keep the caret in view, but no scrollbar is drawn over the box.
- The text is drawn from a copy in the frame arena, so a caller that clears or refills the buffer later in the same frame (e.g. a search box's clear button) doesn't leave the drawn text pointing at bytes Zig has set to undefined.
- The caret, selection and mouse hit-testing are offset by the gap the root's centring leaves above the line, so they line up with the text in an input taller than one line.

## `src/layout/Element.zig`, `src/layout/Context.zig`, `src/ui/scrollbar.zig`

- `Overflow.scroll_x_bare`: scrolls horizontally like `scroll_x`, but `scrollbar.compute` gives it no bar, so none is drawn or hit-tested.

## `src/ui/UI.zig`

- `inert_depth` (default 0): while above 0, `openWith` makes every element it opens non-interactive and non-focusable, so a disabled group of controls takes no clicks and drops out of Tab order.

## `src/ui/Context.zig`

- A `scroll_x_bare` box clips its children at its left and right padding, so a text input's long line stops short of the border.
- Rectangles are drawn with their edges and border widths rounded to whole device pixels (`snapToPixel`), so a box laid out on a half pixel, e.g. centred in a row, doesn't smear its 1px border over two pixels.
