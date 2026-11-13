//! The History Panel's look, shared by the panel and the config dialog's preview: its sizes, category chips and row text, in the client list's palette; no I/O.
const std = @import("std");
const notification = @import("../notifications/notification.zig");
const panels = @import("../config/panels.zig");
const notifications_mod = @import("../config/notifications.zig");
const glyphs = @import("glyphs.zig");
const list_look = @import("list_look.zig");
const palette = @import("palette.zig");
const box = @import("../util/box.zig");
const color = @import("../util/color.zig");

const Box = box.Box;
const HistoryPanelConfig = panels.HistoryPanelConfig;
const NotificationConfig = notifications_mod.NotificationConfig;
const NotificationCategory = notification.NotificationCategory;

pub const HEADER_TEXT = "Alerts";
/// Between a row's name and its message, and its message and timestamp.
pub const TEXT_GAP: i32 = 6;
/// The most of a row's text width a long name may take from its message.
pub const NAME_MAX_PERCENT = 50;
/// Fits mergedText's and clientsText's longest results.
pub const COUNT_TEXT_MAX = 24;
/// A row's sides.
pub const PADDING_X: i32 = palette.PADDING_X;
/// The square behind a row's category glyph.
pub const TILE_SIZE: i32 = 18;
pub const TILE_RADIUS: usize = palette.RADIUS;
/// The category glyph inside its tile.
pub const TILE_GLYPH_SIZE = 12;
/// Between a row's tile and its text.
pub const TILE_GAP: i32 = 9;
/// Above the first row.
pub const ROWS_PADDING_TOP: i32 = 4;
/// The divider between new rows and older ones.
pub const EARLIER_HEIGHT: i32 = 22;
pub const EARLIER_TEXT = "EARLIER";
/// Between the divider's text and its rule.
pub const EARLIER_RULE_GAP: i32 = 8;
/// Between the lines of an expanded row's names.
pub const NAME_LINE_GAP: i32 = 2;
/// Under an expanded row's names.
pub const NAMES_PADDING_BOTTOM: i32 = 4;
/// The most lines an expanded row's names take; the last is cut short.
pub const MAX_NAME_LINES = 4;
/// Inside a merged row's count.
pub const MERGED_PADDING_X: i32 = 4;
pub const MERGED_RADIUS: usize = palette.SMALL_RADIUS;
pub const CHIP_HEIGHT: i32 = 22;
pub const CHIP_RADIUS: usize = 11;
pub const CHIP_PADDING_X: i32 = 8;
pub const CHIP_DOT_RADIUS: i32 = 3;
/// Between a chip's dot, label and count.
pub const CHIP_TEXT_GAP: i32 = 5;
/// Between chips, across and down.
pub const CHIP_GAP: i32 = 4;
pub const CHIPS_PADDING_TOP: i32 = 8;
pub const CHIPS_PADDING_BOTTOM: i32 = 6;
pub const CHIPS_PADDING_X: i32 = 8;
const TILE_PERCENT = 14;
const CHIP_COUNT_PERCENT = 75;

/// The chips, left to right.
pub const CATEGORY_ORDER = [_]NotificationCategory{ .Fleet, .Mining, .Combat, .Navigation, .Chat, .General };
pub const CATEGORY_COUNT = CATEGORY_ORDER.len;

/// The panel's sizes for the current settings, in pixels; its width and height are the configured ones.
pub const Metrics = struct {
    row_height: i32,
};

/// Where the category chips sit.
pub const ChipLayout = struct {
    /// In CATEGORY_ORDER.
    boxes: [CATEGORY_COUNT]Box,
    /// Below the bar's divider, where the rows start.
    bottom: i32,

    pub fn categoryAt(self: *const ChipLayout, x: i32, y: i32) ?NotificationCategory {
        for (self.boxes, CATEGORY_ORDER) |chip, category| {
            if (chip.containsPoint(x, y)) return category;
        }
        return null;
    }
};

/// What follows a stacked row's system: the distance intel's wording puts in brackets after it, and the message.
pub const AfterSystem = struct {
    /// Borrows from the text split; empty for none.
    distance: []const u8,
    /// Borrows from the text split.
    message: []const u8,
};

/// Rows grow with the font as the client list's do.
pub fn metrics(history_settings: *const HistoryPanelConfig) Metrics {
    return .{ .row_height = list_look.rowHeight(history_settings.fontSize) };
}

/// A chip's width round its label and count, each `*_width` wide.
pub fn chipWidth(label_width: i32, count_width: i32) i32 {
    return 2 * CHIP_PADDING_X + 2 * CHIP_DOT_RADIUS + CHIP_TEXT_GAP + label_width + CHIP_TEXT_GAP + count_width;
}

/// `widths` are each chip's, in CATEGORY_ORDER; they wrap onto more lines as `panel_width` needs.
pub fn layOutChips(widths: [CATEGORY_COUNT]i32, panel_width: i32, top: i32) ChipLayout {
    var layout: ChipLayout = undefined;
    const right = panel_width - CHIPS_PADDING_X;
    var x = CHIPS_PADDING_X;
    var y = top + CHIPS_PADDING_TOP;
    for (widths, &layout.boxes) |width, *chip| {
        if (x > CHIPS_PADDING_X and x + width > right) {
            x = CHIPS_PADDING_X;
            y += CHIP_HEIGHT + CHIP_GAP;
        }
        chip.* = .{ .left = x, .top = y, .right = x + width, .bottom = y + CHIP_HEIGHT };
        x += width + CHIP_GAP;
    }
    layout.bottom = y + CHIP_HEIGHT + CHIPS_PADDING_BOTTOM + 1;
    return layout;
}

pub fn categoryLabel(category: NotificationCategory) []const u8 {
    return switch (category) {
        .Fleet => "Fleet",
        .Mining => "Mining",
        .Combat => "Combat",
        .Navigation => "Nav",
        .Chat => "Chat",
        .General => "General",
    };
}

/// A chip's dot and a row's glyph; hues kept clear of style.ACCENT_PRESETS, so no category reads as the accent.
pub fn categoryColor(category: NotificationCategory) u32 {
    return switch (category) {
        .Fleet => 0xFF8B91E4,
        .Mining => 0xFFC7CE64,
        .Combat => 0xFFE0676F,
        .Navigation => 0xFFD590D4,
        .Chat => 0xFF80C775,
        .General => palette.TEXT_SECONDARY,
    };
}

pub fn categoryGlyph(category: NotificationCategory) glyphs.Glyph {
    return switch (category) {
        .Fleet => .group,
        .Mining => .ore,
        .Combat => .crosshair,
        .Navigation => .arrow_right,
        .Chat => .speech,
        .General => .bell,
    };
}

/// Behind a row's glyph.
pub fn tileColor(category: NotificationCategory) u32 {
    return color.mix(categoryColor(category), list_look.PANEL, TILE_PERCENT);
}

/// A chip's count, a little fainter than its label in `label_color` on `background`.
pub fn chipCountColor(label_color: u32, background: u32) u32 {
    return color.mix(label_color, background, CHIP_COUNT_PERCENT);
}

pub fn isCategoryEnabled(history_settings: *const HistoryPanelConfig, category: NotificationCategory) bool {
    return switch (category) {
        .Fleet => history_settings.showFleet,
        .Mining => history_settings.showMining,
        .Combat => history_settings.showCombat,
        .Navigation => history_settings.showNavigation,
        .Chat => history_settings.showChat,
        .General => history_settings.showGeneral,
    };
}

/// With the chips hidden every category shows, so none is dropped by a filter the user can't see or change.
pub fn showsCategory(history_settings: *const HistoryPanelConfig, category: NotificationCategory) bool {
    if (!history_settings.showCategoryFilters) return true;
    return isCategoryEnabled(history_settings, category);
}

/// The type's own text colour, else the notifications' default.
pub fn messageColor(notifications: *const NotificationConfig, notification_type: notification.NotificationType) u32 {
    return notifications.getTypeConfig(notification_type).text_color orelse notifications.color;
}

/// A merged row's count; UTF-8, so drawn with the wide text calls.
pub fn mergedText(buffer: *[COUNT_TEXT_MAX]u8, count: usize) []const u8 {
    return std.mem.print(buffer, "\u{00D7}{d}", .{count}) catch unreachable;
}

/// A merged row's name, when more than one character shares it.
pub fn clientsText(buffer: *[COUNT_TEXT_MAX]u8, count: usize) []const u8 {
    return std.mem.print(buffer, "{d} clients", .{count}) catch unreachable;
}

/// `text` is what follows the system's name, as in "(3 jumps): 5 hostiles".
pub fn splitAfterSystem(text: []const u8) AfterSystem {
    var rest = std.mem.trimStart(u8, text, " ");
    var distance: []const u8 = "";
    if (std.mem.startsWith(u8, rest, "(")) {
        if (std.mem.findScalar(u8, rest, ')')) |close| {
            distance = rest[1..close];
            rest = rest[close + 1 ..];
        }
    }
    return .{ .distance = distance, .message = std.mem.trimStart(u8, rest, ": ") };
}

const testing = std.testing;

test "layOutChips keeps chips on one line while they fit, then wraps" {
    const widths: [CATEGORY_COUNT]i32 = @splat(60);
    const wide = layOutChips(widths, 1000, 34);
    try testing.expectEqual(wide.boxes[0].top, wide.boxes[CATEGORY_COUNT - 1].top);
    const narrow = layOutChips(widths, 200, 34);
    try testing.expect(narrow.boxes[CATEGORY_COUNT - 1].top > narrow.boxes[0].top);
    try testing.expect(narrow.bottom > wide.bottom);
    for (narrow.boxes) |chip| try testing.expect(chip.right <= 200);
}

test "categoryAt finds the chip under the cursor and misses the gaps" {
    const widths: [CATEGORY_COUNT]i32 = @splat(60);
    const layout = layOutChips(widths, 1000, 34);
    const first = layout.boxes[0];
    try testing.expectEqual(@as(?NotificationCategory, .Fleet), layout.categoryAt(first.left, first.top));
    try testing.expectEqual(@as(?NotificationCategory, null), layout.categoryAt(first.right, first.top));
}

test "showsCategory ignores the filters while their chips are hidden" {
    var history_settings: HistoryPanelConfig = .{ .showMining = false };
    try testing.expect(!showsCategory(&history_settings, .Mining));
    history_settings.showCategoryFilters = false;
    try testing.expect(showsCategory(&history_settings, .Mining));
}

test "mergedText marks the count with a multiplication sign" {
    var buffer: [COUNT_TEXT_MAX]u8 = undefined;
    try testing.expectEqualStrings("\u{00D7}10", mergedText(&buffer, 10));
}

test "splitAfterSystem takes the bracketed distance out of the message" {
    const split = splitAfterSystem("(3 jumps): 5 hostiles on gate");
    try testing.expectEqualStrings("3 jumps", split.distance);
    try testing.expectEqualStrings("5 hostiles on gate", split.message);
}

test "splitAfterSystem leaves a bare report with no message, and a nearby one with no distance" {
    const bare = splitAfterSystem("(1 jump)");
    try testing.expectEqualStrings("1 jump", bare.distance);
    try testing.expectEqualStrings("", bare.message);
    const here = splitAfterSystem(": neut in local");
    try testing.expectEqualStrings("", here.distance);
    try testing.expectEqualStrings("neut in local", here.message);
}
