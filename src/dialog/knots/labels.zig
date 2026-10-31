//! Display labels the configuration window derives from setting names; no I/O.
const std = @import("std");

/// Where a tag spelled as words isn't clear enough, keyed by "<enum name>.<tag>".
const OVERRIDES = std.StaticStringMap([]const u8).initComptime(.{
    // The fill direction as arrows: the way along a row (or column), then the way to the next.
    .{ "RegionFitDirection.RowFirst_LTR_TTB", "Rows \u{2192} \u{2193}" },
    .{ "RegionFitDirection.RowFirst_RTL_TTB", "Rows \u{2190} \u{2193}" },
    .{ "RegionFitDirection.RowFirst_LTR_BTT", "Rows \u{2192} \u{2191}" },
    .{ "RegionFitDirection.RowFirst_RTL_BTT", "Rows \u{2190} \u{2191}" },
    .{ "RegionFitDirection.ColumnFirst_TTB_LTR", "Columns \u{2193} \u{2192}" },
    .{ "RegionFitDirection.ColumnFirst_TTB_RTL", "Columns \u{2193} \u{2190}" },
    .{ "RegionFitDirection.ColumnFirst_BTT_LTR", "Columns \u{2191} \u{2192}" },
    .{ "RegionFitDirection.ColumnFirst_BTT_RTL", "Columns \u{2191} \u{2190}" },
    .{ "BorderStyle.DashDot", "Dash-Dot" },
    .{ "ExclusionOverlayStyle.X", "Cross" },
    .{ "HoverCursor.Default", "Default (Arrow)" },
    .{ "LogLevel.warn", "Warning" },
    .{ "LogLevel.err", "Error" },
    // Each language in its own words, so it can be found whatever the window is showing.
    .{ "Language.en", "English" },
    .{ "Language.de", "Deutsch" },
    .{ "Language.es", "Español" },
    .{ "Language.fr", "Français" },
    .{ "Language.pl", "Polski" },
    .{ "Language.pt", "Português" },
    .{ "Language.ru", "Русский" },
});

/// The Hotkeys tab's row label for each fixed binding, keyed by setting name; a back/forward pair's halves share their row's.
const HOTKEY_LABELS = std.StaticStringMap(HotkeyLabel).initComptime(.{
    .{ "hotkeyCloseAll", HotkeyLabel{ .text = "Close All Clients" } },
    .{ "hotkeyCloseActive", HotkeyLabel{ .text = "Close Focused Client" } },
    .{ "hotkeyMinimizeAll", HotkeyLabel{ .text = "Minimize All Clients" } },
    .{ "hotkeyToggleVisibility", HotkeyLabel{ .text = "Toggle Thumbnail Visibility" } },
    .{ "hotkeyToggleAutoMinimize", HotkeyLabel{ .text = "Toggle Auto-Minimize" } },
    .{ "hotkeyMoveToSavedPositions", HotkeyLabel{ .text = "Move Windows to Saved Positions" } },
    .{ "hotkeyToggleDragging", HotkeyLabel{ .text = "Toggle Thumbnail Dragging" } },
    .{ "hotkeyToggleTravelMode", HotkeyLabel{ .text = "Toggle Travel Mode" } },
    .{ "hotkeyToggleNotificationHistory", HotkeyLabel{ .text = "Toggle Notification History" } },
    .{ "hotkeyToggleMapPanel", HotkeyLabel{ .text = "Toggle Map Panel" } },
    .{ "hotkeyToggleIntelPanel", HotkeyLabel{ .text = "Toggle Intel Panel" } },
    .{ "hotkeyClearNotificationHistory", HotkeyLabel{ .text = "Clear Notification History" } },
    .{ "hotkeyPreviousExcluded", HotkeyLabel{ .text = "Excluded Characters", .half = .back } },
    .{ "hotkeyNextExcluded", HotkeyLabel{ .text = "Excluded Characters", .half = .forward } },
    .{ "hotkeyPreviousNotified", HotkeyLabel{ .text = "Notified Characters", .half = .back } },
    .{ "hotkeyCycleNotified", HotkeyLabel{ .text = "Notified Characters", .half = .forward } },
    .{ "hotkeyToggleExclusion", HotkeyLabel{ .text = "Toggle Character Exclusion" } },
    .{ "hotkeySuspend", HotkeyLabel{ .text = "Toggle Suspend Hotkeys" } },
    .{ "hotkeyToggleAlertMute", HotkeyLabel{ .text = "Mute Audio Alerts" } },
    .{ "hotkeyExitApp", HotkeyLabel{ .text = "Exit App" } },
    .{ "hotkeyCycleAllClientsBackward", HotkeyLabel{ .text = "Logged-In Clients", .half = .back } },
    .{ "hotkeyCycleAllClientsForward", HotkeyLabel{ .text = "Logged-In Clients", .half = .forward } },
    .{ "hotkeyCycleNotLoggedInBackward", HotkeyLabel{ .text = "Logged-Out Clients", .half = .back } },
    .{ "hotkeyCycleNotLoggedInForward", HotkeyLabel{ .text = "Logged-Out Clients", .half = .forward } },
    .{ "hotkeyPreviousProfile", HotkeyLabel{ .text = "Profile", .half = .back } },
    .{ "hotkeyNextProfile", HotkeyLabel{ .text = "Profile", .half = .forward } },
    .{ "hotkeyReturnToLastApp", HotkeyLabel{ .text = "Return to Last App" } },
    .{ "hotkeyCycleAppsBackward", HotkeyLabel{ .text = "Cycle Apps", .half = .back } },
    .{ "hotkeyCycleAppsForward", HotkeyLabel{ .text = "Cycle Apps", .half = .forward } },
});

/// Which half of a back/forward row a hotkey is, or `none` for a row of its own.
pub const Half = enum { none, back, forward };

pub const HotkeyLabel = struct {
    /// English, translated where shown.
    text: []const u8,
    half: Half = .none,
};

/// A compile error for a fixed hotkey setting with no label, so a new one can't be left out.
pub fn hotkeyLabel(comptime field: []const u8) HotkeyLabel {
    return comptime HOTKEY_LABELS.get(field) orelse @compileError("no label for hotkey setting " ++ field);
}

/// An enum's tags as words, in declaration order: "TopLeft" reads "Top Left", unless OVERRIDES has better.
pub fn enumLabels(comptime E: type) [std.enums.values(E).len][]const u8 {
    const values = std.enums.values(E);
    var labels: [values.len][]const u8 = undefined;
    for (values, &labels) |value, *label| label.* = comptime tagLabel(E, @tagName(value));
    return labels;
}

/// "TopLeft" -> "Top Left", "EVEFocus" -> "EVE Focus", "next_profile" -> "Next profile".
fn spellOut(comptime tag: []const u8) []const u8 {
    comptime {
        var out: []const u8 = &.{std.ascii.toUpper(tag[0])};
        for (tag[1..], 1..) |c, i| {
            const previous = tag[i - 1];
            const starts_word = std.ascii.isLower(previous) or
                (std.ascii.isUpper(previous) and i + 1 < tag.len and std.ascii.isLower(tag[i + 1]));
            if (c == '_') {
                out = out ++ " ";
            } else if (std.ascii.isUpper(c) and starts_word) {
                out = out ++ " " ++ &[_]u8{c};
            } else {
                out = out ++ &[_]u8{c};
            }
        }
        return out;
    }
}

fn tagLabel(comptime E: type, comptime tag: []const u8) []const u8 {
    return OVERRIDES.get(shortTypeName(E) ++ "." ++ tag) orelse spellOut(tag);
}

fn shortTypeName(comptime E: type) []const u8 {
    const full = @typeName(E);
    const dot = std.mem.findScalarLast(u8, full, '.') orelse return full;
    return full[dot + 1 ..];
}

test "spellOut splits camel case and snake case into words" {
    try std.testing.expectEqualStrings("Top Left", comptime spellOut("TopLeft"));
    try std.testing.expectEqualStrings("Bold Italic", comptime spellOut("BoldItalic"));
    try std.testing.expectEqualStrings("Next profile", comptime spellOut("next_profile"));
    try std.testing.expectEqualStrings("X", comptime spellOut("X"));
}

test "spellOut keeps a run of capitals together" {
    try std.testing.expectEqualStrings("EVE Focus", comptime spellOut("EVEFocus"));
}

test "enumLabels takes an override by the enum's own name" {
    const HoverCursor = enum { Default, Hand };
    const labels = comptime enumLabels(HoverCursor);
    try std.testing.expectEqualStrings("Default (Arrow)", labels[0]);
    try std.testing.expectEqualStrings("Hand", labels[1]);
}

test "enumLabels follows the enum's declaration order" {
    const Position = enum { TopLeft, BottomRight };
    const labels = comptime enumLabels(Position);
    try std.testing.expectEqualStrings("Top Left", labels[0]);
    try std.testing.expectEqualStrings("Bottom Right", labels[1]);
}
