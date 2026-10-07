//! The configuration window's Hotkey Groups tab: a reorderable list of groups beside the selected group's keys, behaviour and members; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../config.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const hotkey = @import("../hotkey.zig");
const positions = @import("../positions.zig");
const suggest = @import("../suggest.zig");
const status = @import("../status.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const log = @import("../../../log.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const TextInput = ui.component.TextInput;
const ProfileRef = session.Ref(config.Config);
const GroupRef = session.Ref(config.HotkeyGroupConfig);
const slog = log.scoped("dialog_knots");

const GROUP_ROW_KEY: ui.Key = .str("knots.groups.row");
const MEMBER_ROW_KEY: ui.Key = .str("knots.groups.member");
const ADD_MEMBER_KEY: ui.Key = .str("knots.groups.add_member");

var g_allocator: std.mem.Allocator = undefined;
var g_selected_index: usize = 0;
/// The name typed into the add-member box. Owned; freed in reset.
var g_new_member: std.ArrayList(u8) = .empty;

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// Once the window has closed.
pub fn reset() void {
    g_new_member.deinit(g_allocator);
    g_new_member = .empty;
}

pub fn show(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Hotkey Groups", "Groups of characters you can cycle through with hotkeys. List members here, or assign them live.", &style.section);
    const profile = session.profile();
    try bind.toggle(context, profile.child("hotkeys"), "resetGroupIndexOnNonGroupFocus", "Reset Cycle Position When Leaving a Group");

    const count = profile.ptr.hotkeyGroups.items.len;
    if (g_selected_index >= count) g_selected_index = count -| 1;
    const master_detail = Rect{ .key = .src(@src()), .style = &style.master_detail };
    _ = try master_detail.open(context);
    try roster(context, profile);
    const stack = Rect{ .key = .src(@src()), .style = &style.detail_fit };
    _ = try stack.open(context);
    if (count == 0) {
        try widgets.paragraph(context, .src(@src()), "Add a hotkey group below to give a set of characters their own cycling keys.");
    } else {
        try detail(context, profile, g_selected_index);
    }
    try stack.close(context);
    try master_detail.close(context);
    try section.close(context);
}

fn groupName(arena: std.mem.Allocator, group: *const config.HotkeyGroupConfig, index: usize) ![]const u8 {
    return if (group.name.len > 0) group.name else try std.fmt.allocPrint(arena, "Hotkey Group {d}", .{index + 1});
}

fn roster(context: *ui.Frame, profile: ProfileRef) !void {
    const groups = profile.ptr.hotkeyGroups.items;
    const list = Rect{ .key = .src(@src()), .style = &style.roster_filters };
    _ = try list.open(context);
    if (groups.len == 0) {
        try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "No hotkey groups yet.", .style = &style.roster_empty });
    }
    const arena = context.arena();
    for (groups, 0..) |*group, index| {
        const is_selected = index == g_selected_index;
        const mark = try widgets.reorderRow(context, GROUP_ROW_KEY, index, groups.len);
        const row = Button{
            .key = GROUP_ROW_KEY.indexed(index),
            .style = switch (mark) {
                .above => &style.roster_row_drop_above,
                .below => &style.roster_row_drop_below,
                .none => if (is_selected) &style.roster_row_selected else &style.roster_row,
            },
        };
        if ((try row.openResponse(context)).clicked and !is_selected) {
            g_selected_index = index;
            context.requestRedraw();
        }
        try context.e(Text{
            .selectable = false,
            .key = ui.Key.str("knots.groups.name").indexed(index),
            .content = try groupName(arena, group, index),
            .style = if (is_selected) &style.roster_name_selected else &style.roster_name,
        });
        try row.close(context);
    }
    if ((try context.interact(Button{ .key = .src(@src()), .label = "+ Add Group", .style = &style.roster_add })).clicked) {
        profile.append("hotkeyGroups", .{});
        g_selected_index = profile.ptr.hotkeyGroups.items.len - 1;
    }
    try list.close(context);

    // The selection follows the group it was on, not the slot.
    if (widgets.reorderFinish(context, GROUP_ROW_KEY, groups.len)) |moved| {
        const from = moved.from;
        const was_selected = g_selected_index;
        profile.move("hotkeyGroups", from, moved.before);
        const to = if (moved.before > from) moved.before - 1 else moved.before;
        if (was_selected == from) {
            g_selected_index = to;
        } else if (from < was_selected and to >= was_selected) {
            g_selected_index -= 1;
        } else if (from > was_selected and to <= was_selected) {
            g_selected_index += 1;
        }
    }
}

fn detail(context: *ui.Frame, profile: ProfileRef, index: usize) !void {
    const group = profile.item("hotkeyGroups", index);

    const header = Rect{ .key = .src(@src()), .style = &style.detail_header };
    _ = try header.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "Group Name", .style = &style.inline_label });
    const name_before = try context.arena().dupe(u8, group.get("name"));
    try bind.textBox(context, group, "name", try std.fmt.allocPrint(context.arena(), "Hotkey Group {d}", .{index + 1}));
    const removed = try widgets.confirmButton(context, ui.Key.str("knots.groups.remove").indexed(index), "Remove", "Confirm", &style.plain_button, &style.confirm_button);
    try header.close(context);
    carryToSpaces(profile, name_before, group.get("name"));

    const keys = try widgets.openBinding(context, .src(@src()), "Cycle Keys");
    const halves = Rect{ .key = .src(@src()), .style = &style.pair_column };
    _ = try halves.open(context);
    inline for (.{ .{ "backwardKey", "\u{2190}" }, .{ "forwardKey", "\u{2192}" } }) |half| {
        const line = Rect{ .key = .str("knots.groups.half:" ++ half[0]), .style = &style.inline_row };
        _ = try line.open(context);
        try context.e(Text{ .selectable = false, .key = .str("knots.groups.arrow:" ++ half[0]), .content = half[1], .style = &style.binding_arrow });
        try hotkey.field(context, group, half[0]);
        try line.close(context);
    }
    try halves.close(context);
    try keys.close(context);

    const assign = try widgets.openBinding(context, .src(@src()), "Assign Key");
    try hotkey.field(context, group, "assignKey");
    try assign.close(context);
    try widgets.hintText(context, .src(@src()), "Hover a thumbnail and press this to toggle that character in or out of this group's Characters list.");

    try widgets.subheading(context, .src(@src()), "Behavior");
    try bind.toggle(context, group, "includeNotLoggedIn", "Include Not Logged In Clients");
    try bind.toggle(context, group, "stopAtEnds", "Stop at First/Last Character (Don't Loop)");
    try bind.toggle(context, group, "temporaryMembership", "Temporary Membership (Resets on Restart)");
    try bind.toggle(context, group, "showBadge", "Show Group Badge on Thumbnails");

    // Temporary members are assigned while the app runs, so there's no list to edit.
    if (group.get("temporaryMembership")) {
        try widgets.paragraph(context, .src(@src()), "Members are assigned while the app runs: hover a thumbnail and press the assign key to toggle it in or out.");
    } else {
        try members(context, group);
    }

    if (removed) {
        const name = try context.arena().dupe(u8, group.get("name"));
        profile.remove("hotkeyGroups", index);
        carryToSpaces(profile, name, null);
        g_selected_index = @min(index, profile.ptr.hotkeyGroups.items.len -| 1);
    }
}

/// Spaces hold hotkey groups by name, so they follow a group's rename, or drop it once it's removed (`new_name` null); a name another group still has stays.
fn carryToSpaces(profile: ProfileRef, old_name: []const u8, new_name: ?[]const u8) void {
    if (old_name.len == 0 or profile.ptr.hasHotkeyGroupNamed(old_name)) return;
    // An emptied name box is mid-edit, not a removal.
    if (new_name) |name| if (name.len == 0) return;
    for (0..profile.ptr.thumbnailSpaces.items.len) |space_index| {
        const space = profile.item("thumbnailSpaces", space_index);
        const at = space.ptr.groupIndex(old_name) orelse continue;
        const renamed = new_name orelse {
            space.remove("groups", at);
            continue;
        };
        if (space.ptr.groupIndex(renamed) != null) {
            space.remove("groups", at);
        } else {
            space.setStringAt("groups", at, renamed);
        }
    }
}

fn members(context: *ui.Frame, group: GroupRef) !void {
    try widgets.subheading(context, .src(@src()), "Characters");
    const list = Rect{ .key = .src(@src()), .style = &style.members_list };
    _ = try list.open(context);
    const names = group.ptr.characters.items;
    if (names.len == 0) {
        try widgets.paragraph(context, .src(@src()), "No characters in this group yet - add one below, or fill the group from the open clients.");
    }
    const arena = context.arena();
    var removed: ?usize = null;
    for (names, 0..) |name, member_index| {
        const mark = try widgets.reorderRow(context, MEMBER_ROW_KEY, member_index, names.len);
        const row = Rect{ .key = MEMBER_ROW_KEY.indexed(member_index), .style = switch (mark) {
            .above => &style.member_row_drop_above,
            .below => &style.member_row_drop_below,
            .none => &style.member_row,
        } };
        _ = try row.open(context);
        try context.e(Text{
            .selectable = false,
            .key = ui.Key.str("knots.groups.member.index").indexed(member_index),
            .content = try std.fmt.allocPrint(arena, "{d:0>2}", .{member_index + 1}),
            .style = &style.index_chip,
        });
        if (try bind.stringBox(context, ui.Key.str("knots.groups.member.name").indexed(member_index), name, "Character Name", &style.text_input)) |typed| {
            group.setStringAt("characters", member_index, typed);
        }
        if ((try context.interact(Button{ .key = ui.Key.str("knots.groups.member.remove").indexed(member_index), .label = "\u{00D7}", .style = &style.icon_button_danger_text })).clicked) removed = member_index;
        try row.close(context);
        const member_box = ui.Key.str("knots.groups.member.name").indexed(member_index);
        if (try suggest.openClients(context, member_box, bind.typedText(member_box))) |picked| group.setStringAt("characters", member_index, picked);
    }
    try list.close(context);
    if (removed) |member_index| group.remove("characters", member_index);
    if (widgets.reorderFinish(context, MEMBER_ROW_KEY, names.len)) |moved| group.move("characters", moved.from, moved.before);

    const add_row = Rect{ .key = .src(@src()), .style = &style.inline_row };
    _ = try add_row.open(context);
    const is_focused = context.ui().focused(ADD_MEMBER_KEY.hash());
    try context.e(TextInput{ .key = ADD_MEMBER_KEY, .buf = &g_new_member, .style = &style.text_input, .placeholder = "Add character name\u{2026}" });
    const add_clicked = (try context.interact(Button{ .key = .src(@src()), .label = "+ Add", .style = &style.plain_button })).clicked;
    if (add_clicked or (is_focused and context.ui().input.containsKey(.enter))) addMember(group);
    if (try widgets.glyphButton(context, .src(@src()), .refresh, "Fill from Open Clients", &style.plain_button, false)) fillFromClients(context, group);
    try add_row.close(context);
    if (try suggest.openClients(context, ADD_MEMBER_KEY, g_new_member.items)) |picked| {
        g_new_member.clearRetainingCapacity();
        try g_new_member.appendSlice(g_allocator, picked);
    }
}

fn addMember(group: GroupRef) void {
    const name = std.mem.trim(u8, g_new_member.items, " ");
    if (name.len == 0) return;
    group.appendString("characters", name);
    g_new_member.clearRetainingCapacity();
}

/// Adds every logged-in client the group doesn't list yet.
fn fillFromClients(context: *ui.Frame, group: GroupRef) void {
    const names = positions.openClients(context.arena()) catch |err| {
        slog.err("Failed to fill hotkey group from open clients: {}", .{err});
        status.show(.failure, "Failed to scan clients: {}", .{err});
        return;
    };
    if (names.len == 0) {
        status.show(.failure, "No open EVE clients found", .{});
        return;
    }
    var added: usize = 0;
    for (names) |name| {
        const exists = for (group.ptr.characters.items) |member| {
            if (std.ascii.eqlIgnoreCase(member, name)) break true;
        } else false;
        if (exists) continue;
        group.appendString("characters", name);
        added += 1;
    }
    if (added > 0) {
        status.show(.success, "Added {d} character(s) to hotkey group", .{added});
    } else {
        status.show(.info, "All open EVE clients are already in this group", .{});
    }
}
