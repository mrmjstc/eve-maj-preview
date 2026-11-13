//! The configuration window's colours, sizes and fonts, for panels drawn in GDI to match it; mirrors dialog/knots/style.zig.
const std = @import("std");
const fonts = @import("../platform/fonts.zig");
const types = @import("../config/types.zig");

/// A button's or field's height.
pub const CONTROL_HEIGHT: i32 = 28;
/// A card's, control's or row's corners; one nested in a 2px inset takes 2 less.
pub const RADIUS: usize = 6;
/// A tag's or small mark's corners.
pub const SMALL_RADIUS: usize = 3;
/// A panel window's corners.
pub const WINDOW_RADIUS: usize = 8;
/// From a panel's sides to its rows' text, as the dialog's sections inset theirs.
pub const PADDING_X: i32 = 12;
/// A menu's width, and the room inside its border round its rows.
pub const MENU_WIDTH: i32 = 260;
pub const MENU_PADDING: i32 = 6;
/// The body text's size.
pub const FONT_SIZE: i32 = 12;
/// A label's or hint's size.
pub const SMALL_FONT_SIZE: i32 = 11;
pub const FACE = fonts.UI_FACE;
pub const SEMIBOLD_FACE = fonts.UI_SEMIBOLD_FACE;

// The colours below are 0xAARRGGBB, not premultiplied.
/// The window's header bar.
pub const CHROME: u32 = 0xFF0B0C0D;
/// Behind the cards.
pub const BG: u32 = 0xFF111214;
/// Cards, menus and popovers.
pub const PANEL: u32 = 0xFF1E1F22;
/// A control's fill.
pub const SURFACE: u32 = 0xFF2A2B2E;
/// A lit row on a card.
pub const ROW_HOVER: u32 = 0xFF242528;
pub const SURFACE_ALT: u32 = 0xFF2F3033;
/// A hovered segment, and the dividers on the map's cards.
pub const BORDER: u32 = 0xFF414245;
pub const CARD_BORDER: u32 = 0xFF343538;
/// Between rows on a card.
pub const DIVIDER: u32 = 0xFF2F3033;
/// A control's outline.
pub const BORDER_STRONG: u32 = 0xFF6B6E75;
pub const TEXT: u32 = 0xFFE8E6E1;
pub const TEXT_SECONDARY: u32 = 0xFFC4C0B6;
pub const MUTED: u32 = 0xFF96948F;
pub const HINT_TEXT: u32 = 0xFFAEACA7;
pub const ERROR: u32 = 0xFFE05A4E;
/// Data and warnings; yellower than the default accent's amber, so neither reads as a control.
pub const CAUTION: u32 = 0xFFE1C747;
/// Behind error text.
pub const ERROR_TINT: u32 = 0xFF2A1614;

comptime {
    // The panels' default font must be the bundled face their headers use.
    std.debug.assert(std.mem.eql(u8, types.DEFAULT_FONT, FACE));
    std.debug.assert(types.DEFAULT_FONT_SIZE == FONT_SIZE);
}
