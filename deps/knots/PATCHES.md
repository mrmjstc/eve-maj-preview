# Local patches to knots

Vendored from [knots-ui/knots](https://github.com/knots-ui/knots) at commit `9cd60181892ef12d9cb3e0d87f5461e928140a92` (0.3.0). Every change is marked `EVE-Maj patch` in the source; re-apply these after updating the copy.

## `src/ui/component/ColorPicker.zig`

- `show_hex` (default `true`): off, the trigger is just the swatch, with no hex beside it.
- `show_alpha` (default `true`): off, the popup has no alpha strip, the hex has no alpha, and picked colours are opaque.
- The popup is shifted left, as far as the viewport allows, so a trigger near the window's right edge doesn't push it off screen.

## `src/ui/Context.zig`

- Rectangles are drawn with their edges and border widths rounded to whole device pixels (`snapToPixel`), so a box laid out on a half pixel, e.g. centred in a row, doesn't smear its 1px border over two pixels.
