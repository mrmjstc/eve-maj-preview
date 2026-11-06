//! What the History, Map and Intel panels share so they match: sizes, footer buttons, ages and when they show; no I/O.
const std = @import("std");
const panels = @import("../config/panels.zig");
const list_look = @import("list_look.zig");

const HistoryPanelConfig = panels.HistoryPanelConfig;

/// Between the footer's buttons, and round them inside it.
pub const BUTTON_GAP: i32 = 4;
pub const BUTTON_RADIUS: usize = 3;
/// A lit footer button's background.
pub const BUTTON_ON: u32 = 0xFF2E3036;
/// Fits relativeTime's longest result.
pub const TIME_TEXT_MAX = 24;

/// A footer button's left and right edges, from the panel's outer left edge.
pub const Span = struct { left: i32, right: i32 };

/// What a panel's auto-hide watches, read once a tick.
pub const Presence = struct {
    any_character_logged_in: bool,
    is_eve_focused: bool,
};

/// When a panel shows, given its auto-hide settings and the tray toggle's override.
pub const Visibility = struct {
    /// Set by force(): shows the panel with no character logged in, until the last one logs out.
    is_forced_visible: bool = false,
    /// Set by force(): shows the panel while EVE is unfocused, until EVE next has focus.
    is_focus_forced: bool = false,
    /// Last tick's any-character-logged-in, to catch the logout that clears is_forced_visible.
    had_characters: bool = false,
    /// When EVE lost focus, in ms since boot; null while it has it.
    focus_lost_ms: ?u64 = null,

    pub const Conditions = struct {
        hides_without_characters: bool,
        any_character_logged_in: bool,
        hides_without_focus: bool = false,
        hide_delay_ms: u32 = 0,
        now_ms: u64 = 0,
    };

    pub fn allows(self: Visibility, conditions: Conditions) bool {
        if (conditions.hides_without_characters and !conditions.any_character_logged_in and !self.is_forced_visible) return false;
        if (!conditions.hides_without_focus or self.is_focus_forced) return true;
        const lost_ms = self.focus_lost_ms orelse return true;
        return conditions.now_ms -| lost_ms < conditions.hide_delay_ms;
    }

    /// allows by a panel's settings section, which has hideWhenNoCharacters, hideWhenNoEveFocus and hideDebounceMs.
    pub fn allowsFor(self: Visibility, settings: anytype, any_character_logged_in: bool, now_ms: u64) bool {
        return self.allows(.{
            .hides_without_characters = settings.hideWhenNoCharacters,
            .any_character_logged_in = any_character_logged_in,
            .hides_without_focus = settings.hideWhenNoEveFocus,
            .hide_delay_ms = settings.hideDebounceMs,
            .now_ms = now_ms,
        });
    }

    /// The tray toggle or hotkey asked for the panel, past whatever would hide it.
    pub fn force(self: *Visibility) void {
        self.is_forced_visible = true;
        self.is_focus_forced = true;
    }

    pub fn release(self: *Visibility) void {
        self.is_forced_visible = false;
        self.is_focus_forced = false;
    }

    /// Per tick.
    pub fn note(self: *Visibility, presence: Presence, now_ms: u64) void {
        if (self.had_characters and !presence.any_character_logged_in) self.is_forced_visible = false;
        self.had_characters = presence.any_character_logged_in;
        if (presence.is_eve_focused) {
            self.focus_lost_ms = null;
            self.is_focus_forced = false;
        } else if (self.focus_lost_ms == null) {
            self.focus_lost_ms = now_ms;
        }
    }
};

/// Set by the History Panel's font, which every panel draws its header and buttons in.
pub fn headerHeight(history_settings: *const HistoryPanelConfig) i32 {
    return list_look.headerHeight(history_settings.fontSize);
}

/// A footer button is as tall as the header.
pub fn footerHeight(header_height: i32) i32 {
    return header_height + 2 * BUTTON_GAP;
}

/// Where the footer starts; a large font can leave no room below the header.
pub fn footerTop(panel_height: i32, header_height: i32, footer_height: i32) i32 {
    return @max(header_height, panel_height - footer_height);
}

/// The `index`th of `button_count` equal buttons across a panel `width` wide, with BUTTON_GAP around each.
pub fn buttonSpan(width: i32, button_count: usize, index: usize) Span {
    const signed_count: i32 = @intCast(button_count);
    const signed_index: i32 = @intCast(index);
    const room = @max(0, width - BUTTON_GAP * (signed_count + 1));
    const left = BUTTON_GAP * (signed_index + 1);
    return .{ .left = left + @divTrunc(room * signed_index, signed_count), .right = left + @divTrunc(room * (signed_index + 1), signed_count) };
}

/// The button under `x`; null in a gap between them.
pub fn buttonIndexAt(width: i32, button_count: usize, x: i32) ?usize {
    for (0..button_count) |index| {
        const span = buttonSpan(width, button_count, index);
        if (x >= span.left and x < span.right) return index;
    }
    return null;
}

/// The row under `y`; null over the header or past the last of `row_count`.
pub fn rowAt(y: i32, header_height: i32, row_height: i32, row_count: usize) ?usize {
    if (y < header_height or row_height <= 0) return null;
    const row_index: usize = @intCast(@divTrunc(y - header_height, row_height));
    return if (row_index < row_count) row_index else null;
}

/// How long ago, e.g. "just now", "5m ago" or "2h ago".
pub fn relativeTime(buffer: *[TIME_TEXT_MAX]u8, elapsed_ms: u64) []const u8 {
    const elapsed_seconds = elapsed_ms / std.time.ms_per_s;
    if (elapsed_seconds < std.time.s_per_min) return "just now";
    if (elapsed_seconds < std.time.s_per_hour) return std.mem.print(buffer, "{d}m ago", .{elapsed_seconds / std.time.s_per_min}) catch unreachable;
    return std.mem.print(buffer, "{d}h ago", .{elapsed_seconds / std.time.s_per_hour}) catch unreachable;
}

const testing = std.testing;

const FOCUS_HIDE: Visibility.Conditions = .{ .hides_without_characters = false, .any_character_logged_in = true, .hides_without_focus = true, .hide_delay_ms = 500 };

fn focusHideAt(now_ms: u64) Visibility.Conditions {
    var conditions = FOCUS_HIDE;
    conditions.now_ms = now_ms;
    return conditions;
}

test "buttonSpan fills the width between gaps without overlapping" {
    const width = 300;
    const button_count = 6;
    try testing.expectEqual(BUTTON_GAP, buttonSpan(width, button_count, 0).left);
    try testing.expectEqual(width - BUTTON_GAP, buttonSpan(width, button_count, button_count - 1).right);
    for (1..button_count) |index| {
        try testing.expectEqual(buttonSpan(width, button_count, index - 1).right + BUTTON_GAP, buttonSpan(width, button_count, index).left);
    }
}

test "buttonIndexAt finds the button under the cursor and misses the gaps" {
    try testing.expectEqual(@as(?usize, 0), buttonIndexAt(300, 6, BUTTON_GAP));
    try testing.expectEqual(@as(?usize, 5), buttonIndexAt(300, 6, 300 - BUTTON_GAP - 1));
    try testing.expectEqual(@as(?usize, null), buttonIndexAt(300, 6, 0));
}

test "rowAt finds the row under the cursor and none over the header or past the last" {
    try testing.expectEqual(@as(?usize, null), rowAt(19, 20, 10, 3));
    try testing.expectEqual(@as(?usize, 0), rowAt(20, 20, 10, 3));
    try testing.expectEqual(@as(?usize, 2), rowAt(49, 20, 10, 3));
    try testing.expectEqual(@as(?usize, null), rowAt(50, 20, 10, 3));
}

test "footerTop stays below the header when the font leaves no room" {
    try testing.expectEqual(@as(i32, 570), footerTop(600, 20, 30));
    try testing.expectEqual(@as(i32, 50), footerTop(60, 50, 30));
}

test "headerHeight follows the History Panel's font, so the panels match" {
    const small: HistoryPanelConfig = .{ .fontSize = 13 };
    const large: HistoryPanelConfig = .{ .fontSize = 24 };
    try testing.expect(headerHeight(&large) > headerHeight(&small));
}

test "a hidden panel shows while a character is logged in or the tray forces it" {
    var visibility: Visibility = .{};
    try testing.expect(visibility.allows(.{ .hides_without_characters = false, .any_character_logged_in = false }));
    try testing.expect(!visibility.allows(.{ .hides_without_characters = true, .any_character_logged_in = false }));
    try testing.expect(visibility.allows(.{ .hides_without_characters = true, .any_character_logged_in = true }));
    visibility.is_forced_visible = true;
    try testing.expect(visibility.allows(.{ .hides_without_characters = true, .any_character_logged_in = false }));
}

test "the last character logging out ends the tray's override" {
    var visibility: Visibility = .{ .is_forced_visible = true };
    visibility.note(.{ .any_character_logged_in = false, .is_eve_focused = true }, 0);
    try testing.expect(visibility.is_forced_visible);
    visibility.note(.{ .any_character_logged_in = true, .is_eve_focused = true }, 0);
    visibility.note(.{ .any_character_logged_in = false, .is_eve_focused = true }, 0);
    try testing.expect(!visibility.is_forced_visible);
}

test "losing focus hides a panel once the delay has passed, and regaining it shows it" {
    var visibility: Visibility = .{};
    const lost: Presence = .{ .any_character_logged_in = true, .is_eve_focused = false };
    visibility.note(lost, 1000);
    visibility.note(lost, 1400);
    try testing.expect(visibility.allows(focusHideAt(1400)));
    try testing.expect(!visibility.allows(focusHideAt(1500)));
    visibility.note(.{ .any_character_logged_in = true, .is_eve_focused = true }, 1600);
    try testing.expect(visibility.allows(focusHideAt(1600)));
}

test "a quick switch restarts the delay" {
    var visibility: Visibility = .{};
    visibility.note(.{ .any_character_logged_in = true, .is_eve_focused = false }, 1000);
    visibility.note(.{ .any_character_logged_in = true, .is_eve_focused = true }, 1200);
    visibility.note(.{ .any_character_logged_in = true, .is_eve_focused = false }, 1400);
    try testing.expect(visibility.allows(focusHideAt(1600)));
}

test "focus doesn't hide a panel with the setting off" {
    var visibility: Visibility = .{};
    visibility.note(.{ .any_character_logged_in = true, .is_eve_focused = false }, 1000);
    try testing.expect(visibility.allows(.{ .hides_without_characters = false, .any_character_logged_in = true, .now_ms = 9000 }));
}

test "forcing a panel keeps it up until EVE next has focus, then auto-hide resumes" {
    var visibility: Visibility = .{};
    const lost: Presence = .{ .any_character_logged_in = true, .is_eve_focused = false };
    visibility.note(lost, 1000);
    visibility.force();
    visibility.note(lost, 9000);
    try testing.expect(visibility.allows(focusHideAt(9000)));
    visibility.note(.{ .any_character_logged_in = true, .is_eve_focused = true }, 9100);
    visibility.note(lost, 9200);
    try testing.expect(!visibility.allows(focusHideAt(9800)));
}

test "allowsFor reads the auto-hide settings of a panel's section" {
    var visibility: Visibility = .{};
    const settings: HistoryPanelConfig = .{ .hideWhenNoCharacters = true, .hideWhenNoEveFocus = true, .hideDebounceMs = 500 };
    try testing.expect(!visibility.allowsFor(&settings, false, 0));
    visibility.note(.{ .any_character_logged_in = true, .is_eve_focused = false }, 1000);
    try testing.expect(visibility.allowsFor(&settings, true, 1400));
    try testing.expect(!visibility.allowsFor(&settings, true, 1500));
}

test "relativeTime rounds down to minutes, then hours" {
    var buffer: [TIME_TEXT_MAX]u8 = undefined;
    try testing.expectEqualStrings("just now", relativeTime(&buffer, 59_999));
    try testing.expectEqualStrings("5m ago", relativeTime(&buffer, 5 * 60_000 + 30_000));
    try testing.expectEqualStrings("2h ago", relativeTime(&buffer, 2 * 3_600_000 + 59 * 60_000));
}
