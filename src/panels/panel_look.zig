//! What the History, Map and Intel panels share so they match: ages and when they show; no I/O.
const std = @import("std");
const panels = @import("../config/panels.zig");

const HistoryPanelConfig = panels.HistoryPanelConfig;

/// Fits relativeTime's longest result.
pub const TIME_TEXT_MAX = 24;

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
