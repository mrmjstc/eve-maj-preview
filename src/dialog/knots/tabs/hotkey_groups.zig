//! The configuration window's Hotkey Groups tab: a reorderable list of groups, each opening a page of its keys, members and behaviour; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../config.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const hotkey = @import("../hotkey.zig");
const images = @import("../images.zig");
const portraits = @import("../portraits.zig");
const positions = @import("../positions.zig");
const suggest = @import("../suggest.zig");
const status = @import("../status.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const lang = @import("../../../lang/lang.zig");
const log = @import("../../../log.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const TextInput = ui.component.TextInput;
const ProfileRef = session.Ref(config.Config);
const GroupRef = session.Ref(config.HotkeyGroupConfig);
const slog = log.Scoped("dialog_knots");

const GROUP_ROW_KEY: ui.Key = .str("knots.groups.row");
const GROUP_ROWS_KEY: ui.Key = .str("knots.groups.rows");
const MEMBER_ROW_KEY: ui.Key = .str("knots.groups.member");
const MEMBERS_KEY: ui.Key = .str("knots.groups.members");
const ADD_MEMBER_KEY: ui.Key = .str("knots.groups.add_member");
/// A group row shows this many members' portraits, then how many more there are.
const STACK_PORTRAITS = 3;
/// An unnamed group's name wherever the dialog shows it; English, for lang.format with `.n` counting from 1.
pub const UNNAMED_GROUP_FORMAT = "Hotkey Group {n}";

var g_allocator: std.mem.Allocator = undefined;
/// The group whose page is open, or null for the list.
var g_open_index: ?usize = null;
/// Set as a new group's page opens, so its first frame focuses the name box.
var g_should_focus_name: bool = false;
/// The name typed into the add-member box; owned, freed in reset.
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
    const profile = session.profile();
    // The list can shrink while a page is open, e.g. on a profile switch.
    if (g_open_index) |index| {
        if (index >= profile.ptr.hotkeyGroups.items.len) g_open_index = null;
    }
    if (g_open_index) |index| return showPage(context, profile, index);
    try showList(context, profile);
}

fn showList(context: *ui.Frame, profile: ProfileRef) !void {
    const toolbar = try widgets.openListToolbar(context, .src(@src()));
    const is_add_clicked = try widgets.glyphButton(context, .str("knots.groups.add"), .add, "Add Group", &style.add_button, false);
    try toolbar.close(context);
    if (is_add_clicked) addGroup(profile);

    const groups = profile.ptr.hotkeyGroups.items;
    if (groups.len == 0) {
        const state = try widgets.openEmptyState(context, .str("knots.groups.empty"), "No hotkey groups yet", "A group gives a set of characters their own cycle hotkeys.");
        try state.close(context);
    } else {
        const section = try widgets.openSection(context, "Hotkey Groups", "Characters to cycle through with hotkeys. List them here or assign them live.", &style.list_section);
        const ui_state = context.ui();
        _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, GROUP_ROWS_KEY.hash());
        const rows = Rect{ .key = GROUP_ROWS_KEY, .style = &style.list_rows };
        _ = try rows.open(context);
        var order = widgets.ReorderList.begin(context, GROUP_ROW_KEY, groups.len, 0);
        for (groups, 0..) |*group, index| {
            try widgets.reorderRow(context, GROUP_ROW_KEY, index);
            if (try order.next(context, index)) try groupRow(context, group, index, null);
        }
        if (try order.end(context)) |lifted| {
            try groupRow(context, &groups[lifted], lifted, try order.liftedStyle(context, GROUP_ROWS_KEY, &style.list_item));
        }
        try rows.close(context);
        try section.close(context);
        if (widgets.reorderFinish(context, GROUP_ROW_KEY, groups.len)) |moved| profile.move("hotkeyGroups", moved.from, moved.before);
    }

    // Its own card, so it doesn't read as a setting of one group.
    const all = try widgets.openSection(context, "All Groups", "", &style.section);
    try bind.toggle(context, profile.child("hotkeys"), "resetGroupIndexOnNonGroupFocus", "Reset Cycle Position When Leaving a Group");
    try widgets.hintText(context, .src(@src()), "Cycling a group again starts from its first character.");
    try all.close(context);
}

/// `lifted_style` while it's being dragged, otherwise the list's own.
fn groupRow(context: *ui.Frame, group: *const config.HotkeyGroupConfig, index: usize, lifted_style: ?*const ui.Style) !void {
    const arena = context.arena();
    const row = Button{ .key = GROUP_ROW_KEY.indexed(index), .style = lifted_style orelse &style.list_item };
    if ((try widgets.openRosterRow(context, row)).clicked and !widgets.isDragMoving(GROUP_ROW_KEY)) openPage(context, index);
    const text_column = Rect{ .key = ui.Key.str("knots.groups.text").indexed(index), .style = &style.list_item_text };
    _ = try text_column.open(context);
    const name = if (group.name.len > 0) group.name else try lang.format(arena, UNNAMED_GROUP_FORMAT, .{ .n = index + 1 });
    try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.groups.name").indexed(index), .content = name, .style = &style.list_item_name });
    const detail = if (group.temporaryMembership)
        lang.text("Temporary: assigned while the app runs")
    else
        try lang.format(arena, if (group.characters.items.len == 1) "{n} character" else "{n} characters", .{ .n = group.characters.items.len });
    try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.groups.detail").indexed(index), .content = detail, .style = &style.list_item_detail });
    try text_column.close(context);
    if (!group.temporaryMembership) try memberStack(context, group, index);
    if (group.forwardKey.len > 0) {
        var keys: std.Io.Writer.Allocating = .init(arena);
        try hotkey.writeKeys(&keys.writer, group.forwardKey);
        try widgets.boxedText(context, ui.Key.str("knots.groups.key").indexed(index), keys.written(), &style.keycap, &style.keycap_text);
    }
    try widgets.listChevron(context, ui.Key.str("knots.groups.chevron").indexed(index));
    try row.close(context);
}

/// The first few members' portraits, overlapping, then a count of the rest.
fn memberStack(context: *ui.Frame, group: *const config.HotkeyGroupConfig, index: usize) !void {
    const names = group.characters.items;
    if (names.len == 0) return;
    const key = ui.Key.str("knots.groups.stack").indexed(index);
    const stack = Rect{ .key = key, .style = &style.portrait_stack };
    _ = try stack.open(context);
    for (names[0..@min(names.len, STACK_PORTRAITS)], 0..) |name, member_index| {
        const ring_key = key.indexed(1 + member_index * 2);
        const ring = Rect{ .key = ring_key, .style = &style.portrait_stack_ring };
        _ = try ring.open(context);
        try portrait(context, name, ring_key.indexed(1), &style.portrait_stack_image);
        try ring.close(context);
    }
    if (names.len > STACK_PORTRAITS) {
        const more = try std.fmt.allocPrint(context.arena(), "+{d}", .{names.len - STACK_PORTRAITS});
        try widgets.boxedText(context, key.indexed(100), more, &style.portrait_stack_more, &style.list_chip_text);
    }
    try stack.close(context);
}

/// `name`'s portrait, or the default one until it's loaded.
fn portrait(context: *ui.Frame, name: []const u8, key: ui.Key, image_style: *const ui.Style) !void {
    const image = portraits.image(context.arena(), key, name, image_style) orelse
        images.g_default_portrait.image(key.indexed(1), image_style);
    if (image) |shown| try context.e(shown);
}

fn openPage(context: *ui.Frame, index: usize) void {
    g_open_index = index;
    g_new_member.clearRetainingCapacity();
    widgets.scrollTabToTop(context);
}

fn addGroup(profile: ProfileRef) void {
    const added = profile.append("hotkeyGroups", .{}) orelse return;
    g_open_index = added.index;
    g_should_focus_name = true;
    g_new_member.clearRetainingCapacity();
}

fn showPage(context: *ui.Frame, profile: ProfileRef, index: usize) !void {
    const arena = context.arena();
    const group = profile.item("hotkeyGroups", index);
    if (try widgets.backLink(context, .src(@src()), "Hotkey Groups")) {
        g_open_index = null;
        return;
    }

    const header = try widgets.openPageHeader(context, .src(@src()));
    try widgets.pageTitle(context, .src(@src()), try groupName(context, index));
    const removed = try widgets.confirmButton(context, ui.Key.str("knots.groups.remove").indexed(index), "Remove", "Confirm", &style.plain_button, &style.confirm_button);
    try header.close(context);
    if (removed) {
        const name = try arena.dupe(u8, group.get("name"));
        profile.remove("hotkeyGroups", index);
        carryToSpaces(profile, name, null);
        g_open_index = null;
        return;
    }

    const settings = try widgets.openSection(context, "Group", "", &style.section);
    const name_box = bind.boxKey(group, "name");
    if (g_should_focus_name) {
        try widgets.focusTextInput(context, name_box, 0);
        g_should_focus_name = false;
    }
    const name_before = try arena.dupe(u8, group.get("name"));
    try bind.text(context, group, "name", "Group Name", try lang.format(arena, UNNAMED_GROUP_FORMAT, .{ .n = index + 1 }));
    carryToSpaces(profile, name_before, group.get("name"));
    try bind.toggle(context, group, "showBadge", "Show Group Badge on Thumbnails");
    try widgets.hintText(context, .src(@src()), "Shows the group's name on its characters' thumbnails.");
    try settings.close(context);

    const member_section = try widgets.openSection(context, "Members", "", &style.section);
    const membership = try widgets.openBinding(context, .src(@src()), "Membership");
    if (try widgets.segmented(context, .src(@src()), &.{ "Fixed List", "Temporary" }, @intFromBool(group.get("temporaryMembership")))) |picked| {
        group.set("temporaryMembership", picked == 1);
    }
    try membership.close(context);
    try widgets.hintText(context, .src(@src()), "Members are assigned with the Assign Group key instead of listed, and are forgotten on restart.");
    // Temporary members are assigned while the app runs, so there's no list to edit.
    if (group.get("temporaryMembership")) {
        try widgets.paragraph(context, .src(@src()), "Members are assigned while the app runs: hover a thumbnail and press the Assign Group key to toggle it in or out.");
    } else {
        try widgets.paragraph(context, .src(@src()), "Cycled in this order; drag to reorder.");
        try members(context, group);
        try addMemberRow(context, group);
    }
    try member_section.close(context);

    const keys = try widgets.openSection(context, "Group Hotkeys", "", &style.section);
    inline for (.{
        .{ "forwardKey", "Cycle Forward", "Switches to the next character in this group." },
        .{ "backwardKey", "Cycle Backward", "Switches to the previous character in this group." },
        .{ "assignKey", "Assign Group", "Hover a thumbnail and press this to add or remove it." },
        .{ "minimizeKey", "Minimize Group", "Minimizes every open client in this group." },
        .{ "closeKey", "Close Group", "Closes every open client in this group." },
    }) |key| {
        const row = try widgets.openWrappingBinding(context, .str("knots.groups.key:" ++ key[0]), key[1]);
        try hotkey.field(context, group, key[0]);
        try row.close(context);
        try widgets.hintText(context, .str("knots.groups.key.hint:" ++ key[0]), key[2]);
    }
    try keys.close(context);

    const cycling = try widgets.openSection(context, "Cycling", "", &style.section);
    try bind.toggle(context, group, "includeNotLoggedIn", "Include Logged-Out Clients");
    try widgets.hintText(context, .src(@src()), "Clients at the login screen come after the group's characters.");
    try bind.toggle(context, group, "stopAtEnds", "Stop at First/Last Character");
    try widgets.hintText(context, .src(@src()), "Pressing again at the end goes back to that character if you've switched away.");
    try cycling.close(context);
}

fn groupName(context: *ui.Frame, index: usize) ![]const u8 {
    const name = try bind.liveText(context, session.profile().item("hotkeyGroups", index), "name");
    return if (name.len > 0) name else try lang.format(context.arena(), UNNAMED_GROUP_FORMAT, .{ .n = index + 1 });
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

fn members(context: *ui.Frame, group: GroupRef) !void {
    const list = try widgets.openScrollPane(context, MEMBERS_KEY, style.members_fit);
    const names = group.ptr.characters.items;
    if (names.len == 0) {
        try widgets.paragraph(context, .src(@src()), "No characters in this group yet. Add one below, or every open client with the refresh button.");
    }
    var order = widgets.ReorderList.begin(context, MEMBER_ROW_KEY, names.len, 0);
    var removed_index: ?usize = null;
    for (0..names.len) |member_index| {
        try widgets.reorderRowByHandle(context, MEMBER_ROW_KEY, member_index, memberHandleKey(member_index));
        if (!try order.next(context, member_index)) continue;
        if (try memberRow(context, group, member_index, &style.member_row)) removed_index = member_index;
    }
    if (try order.end(context)) |lifted| {
        _ = try memberRow(context, group, lifted, try order.liftedStyle(context, MEMBERS_KEY.indexed(1), &style.member_row_lift));
    }
    try list.close(context);
    if (removed_index) |member_index| group.remove("characters", member_index);
    if (widgets.reorderFinish(context, MEMBER_ROW_KEY, names.len)) |moved| group.move("characters", moved.from, moved.before);
}

fn addMemberRow(context: *ui.Frame, group: GroupRef) !void {
    const add_row = Rect{ .key = .src(@src()), .style = &style.member_add_row };
    _ = try add_row.open(context);
    const is_focused = context.ui().focused(ADD_MEMBER_KEY.hash());
    try context.e(TextInput{ .key = ADD_MEMBER_KEY, .buf = &g_new_member, .style = &style.text_input, .placeholder = lang.text("Add character name\u{2026}") });
    const is_add_clicked = try widgets.glyphButton(context, .str("knots.groups.member.add"), .add, "Add", &style.add_button, false);
    if (is_add_clicked or (is_focused and context.ui().input.containsKey(.enter))) addMember(group);
    if (try widgets.addOpenClientsButton(context, .src(@src()), &style.plain_button)) fillFromClients(context, group);
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

/// Returns whether remove was clicked.
fn memberRow(context: *ui.Frame, group: GroupRef, member_index: usize, row_style: *const ui.Style) !bool {
    const row = Rect{ .key = MEMBER_ROW_KEY.indexed(member_index), .style = row_style };
    _ = try row.open(context);
    try widgets.dragHandle(context, memberHandleKey(member_index));
    try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.groups.member.number").indexed(member_index), .content = try std.fmt.allocPrint(context.arena(), "{d}", .{member_index + 1}), .style = &style.member_number });
    try portrait(context, group.ptr.characters.items[member_index], ui.Key.str("knots.groups.member.portrait").indexed(member_index), &style.member_portrait);
    const name_key = ui.Key.str("knots.groups.member.name").indexed(member_index);
    if (try bind.stringBox(context, name_key, group.ptr.characters.items[member_index], "Character Name", &style.text_input)) |typed| {
        group.setStringAt("characters", member_index, typed);
    }
    const is_removed = (try context.interact(Button{ .key = ui.Key.str("knots.groups.member.remove").indexed(member_index), .label = "\u{00D7}", .style = &style.icon_button_danger_text })).clicked;
    try row.close(context);
    if (try suggest.openClients(context, name_key, bind.typedText(name_key))) |picked| group.setStringAt("characters", member_index, picked);
    return is_removed;
}

fn memberHandleKey(member_index: usize) ui.Key {
    return ui.Key.str("knots.groups.member.handle").indexed(member_index);
}

/// Adds every logged-in client the group doesn't list yet.
fn fillFromClients(context: *ui.Frame, group: GroupRef) void {
    const names = positions.openClients(context.arena()) catch |err| {
        slog.err("Failed to fill hotkey group from open clients: {}", .{err});
        status.show(.failure, "Failed to scan clients: {err}", .{ .err = err });
        return;
    };
    if (names.len == 0) {
        status.show(.failure, "No open EVE clients found", .{});
        return;
    }
    var added_count: usize = 0;
    for (names) |name| {
        const exists = for (group.ptr.characters.items) |member| {
            if (std.ascii.eqlIgnoreCase(member, name)) break true;
        } else false;
        if (exists) continue;
        group.appendString("characters", name);
        added_count += 1;
    }
    if (added_count > 0) {
        status.show(.success, "Added {n} character(s) to hotkey group", .{ .n = added_count });
    } else {
        status.show(.info, "All open EVE clients are already in this group", .{});
    }
}
