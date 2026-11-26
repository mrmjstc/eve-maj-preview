//! The configuration window's Hotkey Groups tab: a reorderable list of groups beside the selected group's keys, behaviour and members; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../config.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const hotkey = @import("../hotkey.zig");
const positions = @import("../positions.zig");
const roster_mod = @import("../roster.zig");
const selection = @import("../selection.zig");
const suggest = @import("../suggest.zig");
const status = @import("../status.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const lang = @import("../../../lang/lang.zig");
const window_mod = @import("../window.zig");

const Rect = ui.component.Rect;
const Button = ui.component.Button;
const TextInput = ui.component.TextInput;
const ProfileRef = session.Ref(config.Config);
const GroupRef = session.Ref(config.HotkeyGroupConfig);
const Window = window_mod.Window;

const GROUP_ROW_KEY: ui.Key = .str("knots.groups.row");
const MEMBER_ROW_KEY: ui.Key = .str("knots.groups.member");
const MEMBERS_KEY: ui.Key = .str("knots.groups.members");
const ADD_MEMBER_KEY: ui.Key = .str("knots.groups.add_member");
/// An unnamed group's name wherever the dialog shows it; English, for lang.format with `.n` counting from 1.
pub const UNNAMED_GROUP_FORMAT = "Hotkey Group {n}";

/// One window's, reset as each opens.
pub const State = struct {
    /// The name typed into the add-member box; owned, freed in deinit.
    new_member: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.new_member.deinit(allocator);
    }
};

/// Kept from one opening of the window to the next.
pub const Kept = struct {
    selected: selection.Selection = .{},
};

pub fn show(window: *Window, context: *ui.Frame) !void {
    const section = try window.widgets.openSection(context, "Hotkey Groups", "Characters to cycle through with hotkeys. List them here or assign them live.", &style.fill_section);
    const profile = window.session.profile();
    const group_count = profile.ptr.hotkeyGroups.items.len;
    if (group_count == 0) {
        const state = try window.widgets.openEmptyState(context, .str("knots.groups.empty"), "No hotkey groups yet", "A group gives a set of characters their own cycle hotkeys.");
        if (try widgets.glyphButton(context, .str("knots.groups.empty.add"), .add, "Add Group", &style.add_button, false)) {
            if (profile.append("hotkeyGroups", .{})) |added| window.kept.hotkey_groups.selected.index = added.index;
        }
        try state.close(context);
        try section.close(context);
        return;
    }
    window.kept.hotkey_groups.selected.clamp(group_count);
    const master_detail = Rect{ .key = .src(@src()), .style = &style.master_detail_fill };
    _ = try master_detail.open(context);
    try roster(window, context, profile);
    // Pinned, so only the members scroll.
    const stack = Rect{ .key = .str("knots.groups.detail"), .style = &style.detail_fill };
    _ = try stack.open(context);
    try detail(window, context, profile, window.kept.hotkey_groups.selected.index);
    try stack.close(context);
    try master_detail.close(context);
    try section.close(context);

    // Its own card, so it doesn't read as a setting of the selected group.
    const all = try window.widgets.openSection(context, "All Groups", "", &style.section);
    try window.bind.toggle(context, profile.child("hotkeys"), "resetGroupIndexOnNonGroupFocus", "Reset Cycle Position When Leaving a Group");
    try window.widgets.hintText(context, .src(@src()), "Cycling a group again starts from its first character.");
    try all.close(context);
}

fn groupName(window: *Window, context: *ui.Frame, index: usize) ![]const u8 {
    const name = try window.bind.liveText(context, window.session.profile().item("hotkeyGroups", index), "name");
    return if (name.len > 0) name else try lang.format(context.arena(), UNNAMED_GROUP_FORMAT, .{ .n = index + 1 });
}

fn roster(window: *Window, context: *ui.Frame, profile: ProfileRef) !void {
    const groups = profile.ptr.hotkeyGroups.items;
    const list = try window.widgets.openRoster(context, .str("knots.groups.roster"), &style.roster, true);
    var order = widgets.ReorderList.begin(&window.widgets, context, GROUP_ROW_KEY, groups.len, 0);
    for (groups, 0..) |*group, index| {
        try window.widgets.reorderRow(context, GROUP_ROW_KEY, index);
        if (try order.next(context, index)) try groupRow(window, context, group, index, null);
    }
    if (try order.end(context)) |lifted| {
        try groupRow(window, context, &groups[lifted], lifted, try order.liftedStyle(context, list.rowsKey(), roster_mod.rowStyle(lifted == window.kept.hotkey_groups.selected.index)));
    }
    if (try list.close(context, .{ .add_label = "Add Group" }) == .add) {
        if (profile.append("hotkeyGroups", .{})) |added| window.kept.hotkey_groups.selected.index = added.index;
    }

    if (window.widgets.reorderFinish(context, GROUP_ROW_KEY, groups.len)) |moved| {
        profile.move("hotkeyGroups", moved.from, moved.before);
        window.kept.hotkey_groups.selected.afterMove(moved.from, moved.before);
    }
}

fn detail(window: *Window, context: *ui.Frame, profile: ProfileRef, index: usize) !void {
    const group = profile.item("hotkeyGroups", index);
    const previous_rows = window.widgets.useDetailRows();
    defer window.widgets.restoreRows(previous_rows);

    const header = try window.widgets.openDetailHeader(context, .src(@src()), "Group Name");
    const name_before = try context.arena().dupe(u8, group.get("name"));
    try window.bind.textBox(context, group, "name", try lang.format(context.arena(), UNNAMED_GROUP_FORMAT, .{ .n = index + 1 }));
    const removed = try window.widgets.removeButton(context, ui.Key.str("knots.groups.remove").indexed(index));
    try header.close(context);
    carryToSpaces(profile, name_before, group.get("name"));

    const keys = try window.widgets.openFieldGroup(context, .str("knots.groups.keys"), "Hotkeys");
    inline for (.{
        .{ "backwardKey", "Cycle Backward", "Switches to the previous character in this group." },
        .{ "forwardKey", "Cycle Forward", "Switches to the next character in this group." },
        .{ "assignKey", "Assign Group", "Hover a thumbnail and press this to add or remove it." },
        .{ "minimizeKey", "Minimize Group", "Minimizes every open client in this group." },
        .{ "closeKey", "Close Group", "Closes every open client in this group." },
    }) |key| {
        const row = try window.widgets.openWrappingBinding(context, .str("knots.groups.key:" ++ key[0]), key[1]);
        try window.hotkey.field(context, group, key[0]);
        try row.close(context);
        try window.widgets.hintText(context, .str("knots.groups.key.hint:" ++ key[0]), key[2]);
    }
    try keys.close(context);
    try window.widgets.separator(context, .str("knots.groups.separator.keys"));

    const behavior = try window.widgets.openFieldGroup(context, .str("knots.groups.behavior"), "Behavior");
    try window.bind.toggle(context, group, "includeNotLoggedIn", "Include Logged-Out Clients");
    try window.widgets.hintText(context, .src(@src()), "Clients at the login screen come after the group's characters.");
    try window.bind.toggle(context, group, "stopAtEnds", "Stop at First/Last Character");
    try window.widgets.hintText(context, .src(@src()), "Pressing again at the end goes back to that character if you've switched away.");
    try window.bind.toggle(context, group, "temporaryMembership", "Temporary Membership");
    try window.widgets.hintText(context, .src(@src()), "Changes made with Assign Group are undone on restart.");
    try window.bind.toggle(context, group, "showBadge", "Show Group Badge on Thumbnails");
    try window.widgets.hintText(context, .src(@src()), "Shows the group's name on its characters' thumbnails.");
    try behavior.close(context);
    try window.widgets.separator(context, .str("knots.groups.separator.behavior"));

    const characters = try window.widgets.openFillFieldGroup(context, .str("knots.groups.characters"), "Characters");
    // Temporary members are assigned while the app runs, so there's no list to edit.
    const has_member_list = !group.get("temporaryMembership");
    if (has_member_list) {
        try members(window, context, group);
    } else {
        try window.widgets.paragraph(context, .src(@src()), "Members are assigned while the app runs: hover a thumbnail and press the Assign Group key to toggle it in or out.");
    }
    try characters.close(context);
    if (has_member_list) try addMemberRow(window, context, group);

    if (removed) {
        const name = try context.arena().dupe(u8, group.get("name"));
        profile.remove("hotkeyGroups", index);
        carryToSpaces(profile, name, null);
        window.kept.hotkey_groups.selected.afterRemove(index, profile.ptr.hotkeyGroups.items.len);
    }
}

/// `lifted_style` while it's being dragged, otherwise the roster's own.
fn groupRow(window: *Window, context: *ui.Frame, group: *const config.HotkeyGroupConfig, index: usize, lifted_style: ?*const ui.Style) !void {
    const row = try roster_mod.Row.open(&window.widgets, context, GROUP_ROW_KEY.indexed(index), index == window.kept.hotkey_groups.selected.index, lifted_style);
    if (row.is_picked) window.kept.hotkey_groups.selected.index = index;
    const badge = if (group.temporaryMembership) lang.text("Temporary") else try context.arena().print("{d}", .{group.characters.items.len});
    try row.close(context, try groupName(window, context, index), 0, .{ .text = badge });
}

/// Carries a group's rename to spaces holding it, or drops it (`new_name` null), unless another group shares the name.
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

fn members(window: *Window, context: *ui.Frame, group: GroupRef) !void {
    const list = try window.widgets.openScrollPane(context, MEMBERS_KEY, style.members_scroll);
    const names = group.ptr.characters.items;
    if (names.len == 0) {
        try window.widgets.paragraph(context, .src(@src()), "No characters in this group yet. Add one below, or every open client with the refresh button.");
    }
    var order = widgets.ReorderList.begin(&window.widgets, context, MEMBER_ROW_KEY, names.len, 0);
    var removed_index: ?usize = null;
    for (0..names.len) |member_index| {
        try window.widgets.reorderRowByHandle(context, MEMBER_ROW_KEY, member_index, memberHandleKey(member_index));
        if (!try order.next(context, member_index)) continue;
        if (try memberRow(window, context, group, member_index, &style.member_row)) removed_index = member_index;
    }
    if (try order.end(context)) |lifted| {
        _ = try memberRow(window, context, group, lifted, try order.liftedStyle(context, MEMBERS_KEY.indexed(1), &style.member_row_lift));
    }
    try list.close(context);
    if (removed_index) |member_index| group.remove("characters", member_index);
    if (window.widgets.reorderFinish(context, MEMBER_ROW_KEY, names.len)) |moved| group.move("characters", moved.from, moved.before);
}

/// Under the Characters group rather than in it, so the name box has the pane's full width.
fn addMemberRow(window: *Window, context: *ui.Frame, group: GroupRef) !void {
    const add_row = Rect{ .key = .src(@src()), .style = &style.member_add_row };
    _ = try add_row.open(context);
    const is_focused = context.ui().focused(ADD_MEMBER_KEY.hash());
    try context.e(TextInput{ .key = ADD_MEMBER_KEY, .buf = &window.hotkey_groups.new_member, .allocator = window.allocator, .style = &style.text_input, .placeholder = lang.text("Add character name\u{2026}") });
    const is_add_clicked = try widgets.glyphButton(context, .str("knots.groups.member.add"), .add, "Add", &style.add_button, false);
    if (is_add_clicked or (is_focused and context.ui().input.containsKey(.enter))) addMember(window, group);
    if (try window.widgets.addOpenClientsButton(context, .src(@src()), &style.plain_button)) fillFromClients(window, context, group);
    try add_row.close(context);
    if (try window.suggest.openClients(window.session, context, ADD_MEMBER_KEY, window.hotkey_groups.new_member.items, group.ptr.characters.items)) |picked| {
        window.hotkey_groups.new_member.clearRetainingCapacity();
        try window.hotkey_groups.new_member.appendSlice(window.allocator, picked);
    }
}

fn addMember(window: *Window, group: GroupRef) void {
    const name = std.mem.trim(u8, window.hotkey_groups.new_member.items, " ");
    if (name.len == 0) return;
    group.appendString("characters", name);
    window.hotkey_groups.new_member.clearRetainingCapacity();
}

/// Returns whether remove was clicked.
fn memberRow(window: *Window, context: *ui.Frame, group: GroupRef, member_index: usize, row_style: *const ui.Style) !bool {
    const row = Rect{ .key = MEMBER_ROW_KEY.indexed(member_index), .style = row_style };
    _ = try row.open(context);
    try widgets.dragHandle(context, memberHandleKey(member_index));
    const name_key = ui.Key.str("knots.groups.member.name").indexed(member_index);
    if (try window.bind.stringBox(context, name_key, group.ptr.characters.items[member_index], "Character Name", &style.text_input)) |typed| {
        group.setStringAt("characters", member_index, typed);
    }
    const is_removed = (try context.interact(Button{ .key = ui.Key.str("knots.groups.member.remove").indexed(member_index), .label = "\u{00D7}", .style = &style.icon_button_danger_text })).clicked;
    try row.close(context);
    if (try window.suggest.openClients(window.session, context, name_key, window.bind.typedText(name_key), group.ptr.characters.items)) |picked| group.setStringAt("characters", member_index, picked);
    return is_removed;
}

fn memberHandleKey(member_index: usize) ui.Key {
    return ui.Key.str("knots.groups.member.handle").indexed(member_index);
}

/// Adds every logged-in client the group doesn't list yet.
fn fillFromClients(window: *Window, context: *ui.Frame, group: GroupRef) void {
    const names = positions.clientsNotIn(window.session, &window.status, context.arena(), group.ptr.characters.items) orelse return;
    for (names) |name| group.appendString("characters", name);
    if (names.len > 0) {
        window.status.show(.success, "Added {n} character(s) to hotkey group", .{ .n = names.len });
    } else {
        window.status.show(.info, "All open EVE clients are already in this group", .{});
    }
}
