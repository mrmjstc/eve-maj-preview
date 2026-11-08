//! The configuration window's colours, sizes and fonts, for panels drawn in GDI to match it; mirrors dialog/knots/style.zig.
const fonts = @import("../platform/fonts.zig");

/// A button's or field's height.
pub const CONTROL_HEIGHT: i32 = 28;
/// A card's or control's corners.
pub const RADIUS: usize = 6;
/// The body text's size.
pub const FONT_SIZE: i32 = 12;
/// A label's or hint's size.
pub const SMALL_FONT_SIZE: i32 = 11;
pub const FACE = fonts.UI_FACE;
pub const SEMIBOLD_FACE = fonts.UI_SEMIBOLD_FACE;

// The colours below are 0xAARRGGBB, not premultiplied.
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
