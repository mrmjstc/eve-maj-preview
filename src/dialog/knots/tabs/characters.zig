//! The configuration window's Characters tab: a roster beside the selected character's details; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../config.zig");
const ranges = @import("../../../config/ranges.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const CharacterRef = session.Ref(config.CharacterConfig);

const Flag = struct { field: []const u8, label: []const u8 };

const FLAGS = [_]Flag{
    .{ .field = "excludeFromMinimize", .label = "Exclude from Auto-Minimize" },
    .{ .field = "excludeFromCloseAll", .label = "Exclude from Close All" },
    .{ .field = "excludeFromAutoMove", .label = "Exclude from Auto-Move" },
    .{ .field = "hideThumbnail", .label = "Hide Thumbnail" },
    .{ .field = "notificationsMuted", .label = "Mute Notifications" },
};

var g_selected_index: usize = 0;

pub fn show(context: *ui.Frame) !void {
    const section = try widgets.openSection(
        context,
        "Character List",
        "Customize each character's saved position, size, border color, display name, and jump-to hotkey. Characters are added automatically when detected.",
        .profile,
        &style.fill_section,
    );
    const master_detail = Rect{ .key = .src(@src()), .style = &.{
        .width = .grow(),
        .height = .grow(),
        .direction = .row,
        .gap = 8,
    } };
    _ = try master_detail.open(context);
    const characters = session.profile().ptr.characters.items;
    // The list can shrink while the window is open, e.g. on a profile switch.
    if (g_selected_index >= characters.len) g_selected_index = characters.len -| 1;
    try roster(context, characters);
    try detail(context, characters.len);
    try master_detail.close(context);
    try section.close(context);
}

fn roster(context: *ui.Frame, characters: []const config.CharacterConfig) !void {
    const list = Rect{ .key = .src(@src()), .style = &style.roster };
    _ = try list.open(context);
    if (characters.len == 0) {
        try context.e(Text{ .key = .src(@src()), .content = "No characters yet.", .style = &style.roster_empty });
    }
    const arena = context.arena();
    for (characters, 0..) |*character, index| {
        const is_selected = index == g_selected_index;
        const row = Button{
            .key = ui.Key.str("knots.roster.row").indexed(index),
            .style = if (is_selected) &style.roster_row_selected else &style.roster_row,
        };
        if ((try row.openResponse(context)).clicked and !is_selected) {
            g_selected_index = index;
            context.requestRedraw();
        }
        try context.e(Text{
            .key = ui.Key.str("knots.roster.index").indexed(index),
            .content = try std.fmt.allocPrint(arena, "{d:0>2}", .{index + 1}),
            .style = &style.index_chip,
        });
        try context.e(Text{
            .key = ui.Key.str("knots.roster.name").indexed(index),
            .content = if (character.name.len > 0) character.name else try std.fmt.allocPrint(arena, "Character {d}", .{index + 1}),
            .style = if (is_selected) &style.roster_name_selected else &style.roster_name,
        });
        try row.close(context);
    }
    try list.close(context);
}

fn detail(context: *ui.Frame, character_count: usize) !void {
    const stack = Rect{ .key = .src(@src()), .style = &style.detail_stack };
    _ = try stack.open(context);
    if (character_count == 0) {
        try widgets.hintText(context, .str("knots.characters.empty"), "Add a character below, or use \"Populate from Open Clients\" to detect one automatically.");
        try stack.close(context);
        return;
    }
    const character = session.profile().item("characters", g_selected_index);

    const header = Rect{ .key = .src(@src()), .style = &style.detail_header };
    _ = try header.open(context);
    try bind.text(context, character, "name", "Character Name", "Character Name");
    try header.close(context);

    try bind.text(context, character, "displayName", "Display Name", "Leave empty to use character name");
    try widgets.hintText(context, .str("knots.character.display.hint"), "Cosmetic only - shown on the thumbnail label and spoken by TTS if enabled. The Character Name above is still what's matched against your EVE login.");

    try opacity(context, character);
    try widgets.hintText(context, .str("knots.character.opacity.hint"), "Stays linked to the Thumbnails tab's Opacity setting unless you move this slider away from it.");

    const behavior_row = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .row, .gap = 8 } };
    _ = try behavior_row.open(context);
    try context.e(Text{ .key = .src(@src()), .content = "Behavior", .style = &style.label });
    const checks = Rect{ .key = .src(@src()), .style = &.{ .direction = .column, .gap = 6 } };
    _ = try checks.open(context);
    inline for (FLAGS) |flag| try bind.toggle(context, character, flag.field, flag.label);
    try checks.close(context);
    try behavior_row.close(context);

    try stack.close(context);
}

/// Unset follows the Thumbnails tab's opacity; moving the slider gives the character its own.
fn opacity(context: *ui.Frame, character: CharacterRef) !void {
    const inherited = session.profile().ptr.thumbnail.thumbnailOpacity;
    const row = try widgets.openBinding(context, .str("knots.character.opacity"), "Opacity (%)");
    var value: f32 = @floatFromInt(character.get("opacity") orelse inherited);
    if (try widgets.slider(context, ui.Key.str("knots.character.opacity.slider").indexed(character.index), &value, ranges.OPACITY[0], ranges.OPACITY[1], 1)) {
        character.set("opacity", @as(u8, @intFromFloat(@round(value))));
    }
    try widgets.valueText(context, .str("knots.character.opacity.value"), try std.fmt.allocPrint(context.arena(), "{d:.0}%", .{value / 255.0 * 100.0}));
    try row.close(context);
}
