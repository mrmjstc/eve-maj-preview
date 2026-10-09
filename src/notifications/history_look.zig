//! The History Panel's look, shared by the panel and the config dialog's preview: its sizes, filter buttons and row text, in the client list's palette; no I/O.
const std = @import("std");
const notification = @import("notification.zig");
const display_mod = @import("../config/display.zig");
const notifications_mod = @import("../config/notifications.zig");
const list_look = @import("../thumbnail/list_look.zig");

const DisplayConfig = display_mod.DisplayConfig;
const NotificationConfig = notifications_mod.NotificationConfig;
const NotificationCategory = notification.NotificationCategory;

pub const HEADER_TEXT = "Notification History";
/// Between the filter buttons, and round them inside the footer.
pub const FILTER_GAP: i32 = 4;
pub const FILTER_RADIUS: usize = 3;
/// An enabled filter button's background.
pub const FILTER_ON: u32 = 0xFF2E3036;
/// Between a row's name and its message, and its message and timestamp.
pub const TEXT_GAP: i32 = 6;
/// The most of a row's text width a long name may take from its message.
pub const NAME_MAX_PERCENT = 50;
/// Fits relativeTime's longest result.
pub const TIME_TEXT_MAX = 24;
/// Fits countText's longest result.
pub const COUNT_TEXT_MAX = 24;

/// The footer's filter buttons, left to right.
pub const CATEGORY_ORDER = [_]NotificationCategory{ .Fleet, .Mining, .Combat, .Navigation, .General };

/// The panel's sizes for the current settings, in pixels; its width and height are the configured ones.
pub const Metrics = struct {
    header_height: i32,
    row_height: i32,
    /// Zero while the filter buttons are hidden.
    footer_height: i32,
};

/// A filter button's left and right edges, from the panel's outer left edge.
pub const Span = struct { left: i32, right: i32 };

/// Rows and the header grow with the font as the client list's do; a filter button is as tall as the header.
pub fn metrics(display: *const DisplayConfig) Metrics {
    const font_size = display.notifInfoPanelFontSize;
    const header_height = list_look.headerHeight(font_size);
    return .{
        .header_height = header_height,
        .row_height = list_look.rowHeight(font_size),
        .footer_height = if (display.notifInfoPanelShowCategoryFilters) header_height + 2 * FILTER_GAP else 0,
    };
}

/// How many rows fit between the header and footer, at most notifInfoPanelMaxRows.
pub fn rowCapacity(display: *const DisplayConfig, sizes: Metrics) usize {
    const room = display.notifInfoPanelHeight - sizes.header_height - sizes.footer_height - list_look.BOTTOM_PADDING;
    const fit_count = @max(0, @divTrunc(room, sizes.row_height));
    return @intCast(@min(fit_count, @max(1, display.notifInfoPanelMaxRows)));
}

pub fn categoryLabel(category: NotificationCategory) []const u8 {
    return switch (category) {
        .Fleet => "Fleet",
        .Mining => "Mining",
        .Combat => "Combat",
        .Navigation => "Nav",
        .General => "General",
    };
}

/// The `index`th filter button in CATEGORY_ORDER, in a panel `width` wide.
pub fn filterSpan(width: i32, index: usize) Span {
    const button_count: i32 = CATEGORY_ORDER.len;
    const i: i32 = @intCast(index);
    const room = @max(0, width - FILTER_GAP * (button_count + 1));
    const left = FILTER_GAP * (i + 1);
    return .{ .left = left + @divTrunc(room * i, button_count), .right = left + @divTrunc(room * (i + 1), button_count) };
}

/// The filter button under `x`; null in a gap between them.
pub fn filterAt(width: i32, x: i32) ?NotificationCategory {
    for (CATEGORY_ORDER, 0..) |category, index| {
        const span = filterSpan(width, index);
        if (x >= span.left and x < span.right) return category;
    }
    return null;
}

pub fn categoryEnabled(display: *const DisplayConfig, category: NotificationCategory) bool {
    return switch (category) {
        .Fleet => display.notifInfoPanelShowFleet,
        .Mining => display.notifInfoPanelShowMining,
        .Combat => display.notifInfoPanelShowCombat,
        .Navigation => display.notifInfoPanelShowNavigation,
        .General => display.notifInfoPanelShowGeneral,
    };
}

/// With the filter buttons hidden every category shows, so none is dropped by a filter the user can't see or change.
pub fn showsCategory(display: *const DisplayConfig, category: NotificationCategory) bool {
    if (!display.notifInfoPanelShowCategoryFilters) return true;
    return categoryEnabled(display, category);
}

/// The type's own text colour, else the notifications' default.
pub fn messageColor(notifications: *const NotificationConfig, notification_type: notification.NotificationType) u32 {
    return notifications.getTypeConfig(notification_type).text_color orelse notifications.color;
}

/// How long ago, e.g. "just now", "5m ago" or "2h ago".
pub fn relativeTime(buffer: *[TIME_TEXT_MAX]u8, elapsed_ms: u64) []const u8 {
    const elapsed_seconds = elapsed_ms / 1000;
    if (elapsed_seconds < 60) return "just now";
    if (elapsed_seconds < 3600) return std.fmt.bufPrint(buffer, "{d}m ago", .{elapsed_seconds / 60}) catch unreachable;
    return std.fmt.bufPrint(buffer, "{d}h ago", .{elapsed_seconds / 3600}) catch unreachable;
}

/// A merged row's count, shown in place of the name.
pub fn countText(buffer: *[COUNT_TEXT_MAX]u8, count: usize) []const u8 {
    return std.fmt.bufPrint(buffer, "+{d}", .{count}) catch unreachable;
}

test "filterSpan fills the width between gaps without overlapping" {
    const width = 300;
    try std.testing.expectEqual(FILTER_GAP, filterSpan(width, 0).left);
    try std.testing.expectEqual(width - FILTER_GAP, filterSpan(width, CATEGORY_ORDER.len - 1).right);
    for (1..CATEGORY_ORDER.len) |index| {
        try std.testing.expectEqual(filterSpan(width, index - 1).right + FILTER_GAP, filterSpan(width, index).left);
    }
}

test "filterAt finds the button under the cursor and misses the gaps" {
    try std.testing.expectEqual(@as(?NotificationCategory, .Fleet), filterAt(300, FILTER_GAP));
    try std.testing.expectEqual(@as(?NotificationCategory, .General), filterAt(300, 300 - FILTER_GAP - 1));
    try std.testing.expectEqual(@as(?NotificationCategory, null), filterAt(300, 0));
}

test "rowCapacity is capped by the max rows setting and by the room there is" {
    var display: DisplayConfig = .{ .notifInfoPanelHeight = 1000, .notifInfoPanelMaxRows = 5 };
    try std.testing.expectEqual(@as(usize, 5), rowCapacity(&display, metrics(&display)));
    display.notifInfoPanelHeight = 60;
    display.notifInfoPanelMaxRows = 30;
    try std.testing.expectEqual(@as(usize, 0), rowCapacity(&display, metrics(&display)));
}

test "metrics drops the footer while the filter buttons are hidden" {
    var display: DisplayConfig = .{};
    try std.testing.expect(metrics(&display).footer_height > 0);
    display.notifInfoPanelShowCategoryFilters = false;
    try std.testing.expectEqual(@as(i32, 0), metrics(&display).footer_height);
}

test "showsCategory ignores the filters while their buttons are hidden" {
    var display: DisplayConfig = .{ .notifInfoPanelShowMining = false };
    try std.testing.expect(!showsCategory(&display, .Mining));
    display.notifInfoPanelShowCategoryFilters = false;
    try std.testing.expect(showsCategory(&display, .Mining));
}

test "relativeTime rounds down to minutes, then hours" {
    var buffer: [TIME_TEXT_MAX]u8 = undefined;
    try std.testing.expectEqualStrings("just now", relativeTime(&buffer, 59_999));
    try std.testing.expectEqualStrings("5m ago", relativeTime(&buffer, 5 * 60_000 + 30_000));
    try std.testing.expectEqualStrings("2h ago", relativeTime(&buffer, 2 * 3_600_000 + 59 * 60_000));
}
