//! The History Panel's look, shared by the panel and the config dialog's preview: its sizes, filter buttons and row text, in the client list's palette; no I/O.
const std = @import("std");
const notification = @import("../notifications/notification.zig");
const display_mod = @import("../config/display.zig");
const notifications_mod = @import("../config/notifications.zig");
const list_look = @import("list_look.zig");
const panel_look = @import("panel_look.zig");

const DisplayConfig = display_mod.DisplayConfig;
const NotificationConfig = notifications_mod.NotificationConfig;
const NotificationCategory = notification.NotificationCategory;

pub const HEADER_TEXT = "Notification History";
/// Between a row's name and its message, and its message and timestamp.
pub const TEXT_GAP: i32 = 6;
/// The most of a row's text width a long name may take from its message.
pub const NAME_MAX_PERCENT = 50;
/// Fits countText's longest result.
pub const COUNT_TEXT_MAX = 24;

/// The footer's filter buttons, left to right.
pub const CATEGORY_ORDER = [_]NotificationCategory{ .Fleet, .Mining, .Combat, .Navigation, .Chat, .General };

/// The panel's sizes for the current settings, in pixels; its width and height are the configured ones.
pub const Metrics = struct {
    header_height: i32,
    row_height: i32,
    /// Zero while the filter buttons are hidden.
    footer_height: i32,
};

/// Rows and the header grow with the font as the client list's do.
pub fn metrics(display: *const DisplayConfig) Metrics {
    const header_height = panel_look.headerHeight(display);
    return .{
        .header_height = header_height,
        .row_height = list_look.rowHeight(display.notifInfoPanelFontSize),
        .footer_height = if (display.notifInfoPanelShowCategoryFilters) panel_look.footerHeight(header_height) else 0,
    };
}

/// How many rows fit between the header and footer, at most notifInfoPanelMaxRows.
pub fn rowCapacity(display: *const DisplayConfig, sizes: Metrics) usize {
    return rowsThatFit(display.notifInfoPanelHeight, sizes, @max(1, display.notifInfoPanelMaxRows));
}

/// How many rows a panel `panel_height` tall holds, at most `limit`.
pub fn rowsThatFit(panel_height: i32, sizes: Metrics, limit: i32) usize {
    const room = panel_height - sizes.header_height - sizes.footer_height - list_look.BOTTOM_PADDING;
    const fit_count = @max(0, @divTrunc(room, sizes.row_height));
    return @intCast(@min(fit_count, limit));
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

/// The filter button under `x`; null in a gap between them.
pub fn filterAt(width: i32, x: i32) ?NotificationCategory {
    const index = panel_look.buttonIndexAt(width, CATEGORY_ORDER.len, x) orelse return null;
    return CATEGORY_ORDER[index];
}

pub fn isCategoryEnabled(display: *const DisplayConfig, category: NotificationCategory) bool {
    return switch (category) {
        .Fleet => display.notifInfoPanelShowFleet,
        .Mining => display.notifInfoPanelShowMining,
        .Combat => display.notifInfoPanelShowCombat,
        .Navigation => display.notifInfoPanelShowNavigation,
        .Chat => display.notifInfoPanelShowChat,
        .General => display.notifInfoPanelShowGeneral,
    };
}

/// With the filter buttons hidden every category shows, so none is dropped by a filter the user can't see or change.
pub fn showsCategory(display: *const DisplayConfig, category: NotificationCategory) bool {
    if (!display.notifInfoPanelShowCategoryFilters) return true;
    return isCategoryEnabled(display, category);
}

/// The type's own text colour, else the notifications' default.
pub fn messageColor(notifications: *const NotificationConfig, notification_type: notification.NotificationType) u32 {
    return notifications.getTypeConfig(notification_type).text_color orelse notifications.color;
}

/// A merged row's count, shown in place of the name.
pub fn countText(buffer: *[COUNT_TEXT_MAX]u8, count: usize) []const u8 {
    return std.mem.print(buffer, "+{d}", .{count}) catch unreachable;
}

const testing = std.testing;

test "filterAt finds the button under the cursor and misses the gaps" {
    try testing.expectEqual(@as(?NotificationCategory, .Fleet), filterAt(300, panel_look.BUTTON_GAP));
    try testing.expectEqual(@as(?NotificationCategory, .General), filterAt(300, 300 - panel_look.BUTTON_GAP - 1));
    try testing.expectEqual(@as(?NotificationCategory, null), filterAt(300, 0));
}

test "rowCapacity is capped by the max rows setting and by the room there is" {
    var display: DisplayConfig = .{ .notifInfoPanelHeight = 1000, .notifInfoPanelMaxRows = 5 };
    try testing.expectEqual(@as(usize, 5), rowCapacity(&display, metrics(&display)));
    display.notifInfoPanelHeight = 60;
    display.notifInfoPanelMaxRows = 30;
    try testing.expectEqual(@as(usize, 0), rowCapacity(&display, metrics(&display)));
}

test "metrics drops the footer while the filter buttons are hidden" {
    var display: DisplayConfig = .{};
    try testing.expect(metrics(&display).footer_height > 0);
    display.notifInfoPanelShowCategoryFilters = false;
    try testing.expectEqual(@as(i32, 0), metrics(&display).footer_height);
}

test "showsCategory ignores the filters while their buttons are hidden" {
    var display: DisplayConfig = .{ .notifInfoPanelShowMining = false };
    try testing.expect(!showsCategory(&display, .Mining));
    display.notifInfoPanelShowCategoryFilters = false;
    try testing.expect(showsCategory(&display, .Mining));
}
