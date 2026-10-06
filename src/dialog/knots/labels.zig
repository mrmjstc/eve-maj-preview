//! Display labels the configuration window derives from setting names; no I/O.
const std = @import("std");

/// Where a tag spelled as words isn't clear enough, keyed by "<enum name>.<tag>".
const OVERRIDES = std.StaticStringMap([]const u8).initComptime(.{
    .{ "RegionFitOrder.Characters", "Character Order" },
    .{ "RegionFitOrder.HotkeyGroups", "Hotkey Group Order" },
    .{ "RegionFitDirection.RowFirst_LTR_TTB", "Rows: left to right, top to bottom" },
    .{ "RegionFitDirection.RowFirst_RTL_TTB", "Rows: right to left, top to bottom" },
    .{ "RegionFitDirection.RowFirst_LTR_BTT", "Rows: left to right, bottom to top" },
    .{ "RegionFitDirection.RowFirst_RTL_BTT", "Rows: right to left, bottom to top" },
    .{ "RegionFitDirection.ColumnFirst_TTB_LTR", "Columns: top to bottom, left to right" },
    .{ "RegionFitDirection.ColumnFirst_TTB_RTL", "Columns: top to bottom, right to left" },
    .{ "RegionFitDirection.ColumnFirst_BTT_LTR", "Columns: bottom to top, left to right" },
    .{ "RegionFitDirection.ColumnFirst_BTT_RTL", "Columns: bottom to top, right to left" },
    .{ "LayoutMode.RegionFit", "Region Fit (Auto)" },
    .{ "BorderStyle.DashDot", "Dash-Dot" },
    .{ "ViewMode.Thumbnails", "Thumbnails (live video preview)" },
    .{ "ViewMode.ClientList", "Client List (compact text panel)" },
    .{ "ViewMode.Nothing", "Nothing (no display, saves resources)" },
    .{ "ListViewOrder.Tracked", "Tracked Order" },
    .{ "ListViewOrder.ConfiguredCharacters", "Configured Character Order" },
    .{ "ClickTrigger.MouseDown", "Mouse Down (Instant)" },
    .{ "ClickTrigger.MouseUp", "Mouse Up (On Release)" },
    .{ "HoverCursor.Default", "Default (Arrow)" },
    .{ "TravelThresholdMode.percent", "Percentage of characters" },
    .{ "TravelThresholdMode.count", "Fixed number of characters" },
    .{ "IskRateUnit.minute", "Per Minute" },
    .{ "IskRateUnit.hour", "Per Hour" },
    .{ "LogLevel.warn", "Warning" },
    .{ "LogLevel.err", "Error" },
});

/// An enum's tags as words, in declaration order: "TopLeft" reads "Top Left", unless OVERRIDES has better.
pub fn enumLabels(comptime E: type) [std.enums.values(E).len][]const u8 {
    const values = std.enums.values(E);
    var labels: [values.len][]const u8 = undefined;
    for (values, &labels) |value, *label| label.* = comptime tagLabel(E, @tagName(value));
    return labels;
}

fn tagLabel(comptime E: type, comptime tag: []const u8) []const u8 {
    return OVERRIDES.get(shortTypeName(E) ++ "." ++ tag) orelse spellOut(tag);
}

fn shortTypeName(comptime E: type) []const u8 {
    const full = @typeName(E);
    const dot = std.mem.findScalarLast(u8, full, '.') orelse return full;
    return full[dot + 1 ..];
}

/// "TopLeft" -> "Top Left", "EVEFocus" -> "EVE Focus", "next_profile" -> "Next profile".
pub fn spellOut(comptime tag: []const u8) []const u8 {
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
    const IskRateUnit = enum { minute, hour };
    const labels = comptime enumLabels(IskRateUnit);
    try std.testing.expectEqualStrings("Per Minute", labels[0]);
    try std.testing.expectEqualStrings("Per Hour", labels[1]);
}

test "enumLabels follows the enum's declaration order" {
    const Position = enum { TopLeft, BottomRight };
    const labels = comptime enumLabels(Position);
    try std.testing.expectEqualStrings("Top Left", labels[0]);
    try std.testing.expectEqualStrings("Bottom Right", labels[1]);
}
