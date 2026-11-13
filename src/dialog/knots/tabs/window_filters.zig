//! The configuration window's Window Filters section: which other applications' windows are tracked as clients; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../config.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const window_picker = @import("../window_picker.zig");
const roster = @import("../roster.zig");
const selection = @import("../selection.zig");
const lang = @import("../../../lang/lang.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const ProfileRef = session.Ref(config.Config);
const FilterRef = session.Ref(config.WindowFilterConfig);

const NEW_FILTER_NAME = "New Filter";

var g_allocator: std.mem.Allocator = undefined;
var g_selected: selection.Selection = .{};
/// The Window Filters switch isn't saved; it starts on whenever the profile has filters.
var g_are_filters_enabled: ?bool = null;
var g_picker: ?window_picker.Picker = null;

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// Once the window has closed.
pub fn reset() void {
    window_picker.close(&g_picker);
    g_are_filters_enabled = null;
    g_selected = .{};
}

pub fn show(context: *ui.Frame) !void {
    const profile = session.profile();
    var is_enabled = g_are_filters_enabled orelse (profile.ptr.windowFilters.items.len > 0);
    const section = try widgets.openSection(context, "Window Filters", "Tracks other apps by window class or executable. Off shows only EVE.", &style.section);
    if (try widgets.checkbox(context, .src(@src()), "Enable Window Filters", &is_enabled)) g_are_filters_enabled = is_enabled;

    const options = try widgets.openGroup(context, .src(@src()), is_enabled);
    try filterList(context, profile);
    try options.close(context);
    try section.close(context);
}

/// The built-in EVE filter is the profile default and isn't editable here, so it's left out of the roster.
fn isBuiltIn(filter: *const config.WindowFilterConfig) bool {
    return std.mem.eql(u8, filter.name, config.WindowFilterConfig.DEFAULT.name);
}

fn filterList(context: *ui.Frame, profile: ProfileRef) !void {
    const filters = profile.ptr.windowFilters.items;
    var first_editable: ?usize = null;
    var is_selected_editable = false;
    for (filters, 0..) |*filter, index| {
        if (isBuiltIn(filter)) continue;
        if (first_editable == null) first_editable = index;
        if (index == g_selected.index) is_selected_editable = true;
    }
    const first = first_editable orelse {
        if (try widgets.emptyListRow(context, .src(@src()), "No window filters yet. Add one to show another app's windows as thumbnails.", "Add Window Filter")) addFilter(profile);
        return;
    };
    if (!is_selected_editable) g_selected.index = first;
    const master_detail = Rect{ .key = .src(@src()), .style = &style.master_detail };
    _ = try master_detail.open(context);
    // A fixed height, like System Colors', so Add sits at the bottom as on every other list.
    const list = try widgets.openRoster(context, .str("knots.filter.roster"), &style.roster_fixed, true);

    const arena = context.arena();
    for (filters, 0..) |*filter, index| {
        if (isBuiltIn(filter)) continue;
        const row = try roster.Row.open(context, ui.Key.str("knots.filter.row").indexed(index), index == g_selected.index, null);
        if (row.is_picked) g_selected.index = index;
        const name = if (filter.name.len > 0) filter.name else try lang.format(arena, "New Filter {n}", .{ .n = index + 1 });
        try row.close(context, name, 0, .{ .text = if (filter.enabled) "" else lang.text("Disabled") });
    }
    if (try list.close(context, .{ .add_label = "Add Window Filter" }) == .add) addFilter(profile);
    try filterDetail(context, profile, g_selected.index);
    try master_detail.close(context);
}

fn addFilter(profile: ProfileRef) void {
    if (profile.append("windowFilters", .{ .name = lang.text(NEW_FILTER_NAME), .enabled = true })) |added| g_selected.index = added.index;
}

fn filterDetail(context: *ui.Frame, profile: ProfileRef, index: usize) !void {
    const filter = profile.item("windowFilters", index);
    const stack = Rect{ .key = .src(@src()), .style = &style.detail_fit };
    _ = try stack.open(context);

    const header = try widgets.openDetailHeader(context, .src(@src()), null);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("Filter Name"), .style = &style.inline_label });
    const name_before = try context.arena().dupe(u8, filter.get("name"));
    try bind.textBox(context, filter, "name", "e.g., EVE Online");
    const name_after = filter.get("name");
    const removed = try widgets.removeButton(context, ui.Key.str("knots.filter.remove").indexed(index));
    try header.close(context);
    if (!std.mem.eql(u8, name_before, name_after)) carryRename(profile, std.mem.trim(u8, name_before, " "), std.mem.trim(u8, name_after, " "));

    var is_enabled: bool = filter.get("enabled");
    if (try widgets.switchRow(context, ui.Key.str("knots.filter.enabled").indexed(index), "Enabled", &is_enabled)) filter.set("enabled", is_enabled);
    try widgets.hintText(context, ui.Key.str("knots.filter.enabled.hint").indexed(index), "When off, this filter matches nothing.");
    const classes = try widgets.openBinding(context, ui.Key.str("knots.filter.classes").indexed(index), "Window Classes");
    try bind.csvBox(context, filter, "class_names", "e.g., trinityWindow");
    try classes.close(context);
    try widgets.hintText(context, ui.Key.str("knots.filter.classes.hint").indexed(index), "Optional. Leave blank to match by Executable Names only.");
    const executables = try widgets.openBinding(context, ui.Key.str("knots.filter.exes").indexed(index), "Executable Names");
    try bind.csvBox(context, filter, "executable_names", "e.g., exefile.exe");
    try executables.close(context);
    try widgets.hintText(context, ui.Key.str("knots.filter.exes.hint").indexed(index), "Separate names with commas.");
    const detect = try widgets.openBinding(context, ui.Key.str("knots.filter.detect").indexed(index), "Detect");
    if (try widgets.glyphButton(context, ui.Key.str("knots.filter.pick").indexed(index), .refresh, "Pick Running Window", &style.add_button, false)) window_picker.open(g_allocator, &g_picker, index);
    try detect.close(context);
    try widgets.hintText(context, ui.Key.str("knots.filter.detect.hint").indexed(index), "Pick an open window to fill in this filter.");
    try picker(context, profile, filter);
    try stack.close(context);

    if (removed) removeFilter(profile, index);
}

fn picker(context: *ui.Frame, profile: ProfileRef, filter: FilterRef) !void {
    const chosen = try window_picker.select(context, &g_picker, .str("knots.filter.picker"), filter.index) orelse return;
    filter.setStrings("class_names", &.{chosen.class});
    filter.setStrings("executable_names", &.{chosen.executable});
    const friendly = if (std.ascii.endsWithIgnoreCase(chosen.executable, ".exe")) chosen.executable[0 .. chosen.executable.len - ".exe".len] else chosen.executable;
    filter.set("name", friendly);
    addCharacterIfMissing(profile, friendly);
    window_picker.close(&g_picker);
}

/// A filter's windows show up as a character named after it, so one is added when a window is picked.
fn addCharacterIfMissing(profile: ProfileRef, name: []const u8) void {
    if (characterIndex(profile, name) != null) return;
    if (profile.append("characters", .{})) |added| added.set("name", name);
}

fn characterIndex(profile: ProfileRef, name: []const u8) ?usize {
    for (profile.ptr.characters.items, 0..) |character, index| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, character.name, " "), name)) return index;
    }
    return null;
}

/// A filter's windows are named after it, so its character entry and hotkey group places follow a rename.
fn carryRename(profile: ProfileRef, old_name: []const u8, new_name: []const u8) void {
    if (old_name.len == 0 or new_name.len == 0 or std.mem.eql(u8, old_name, new_name)) return;
    if (characterIndex(profile, old_name)) |entry| {
        const clash = characterIndex(profile, new_name);
        if (clash == null or clash == entry) profile.item("characters", entry).set("name", new_name);
    }
    for (0..profile.ptr.hotkeyGroups.items.len) |group_index| {
        const group = profile.item("hotkeyGroups", group_index);
        const members = group.ptr.characters.items;
        const old_index = for (members, 0..) |member, at| {
            if (std.mem.eql(u8, member, old_name)) break at;
        } else continue;
        const is_already_member = for (members) |member| {
            if (std.mem.eql(u8, member, new_name)) break true;
        } else false;
        if (is_already_member) group.remove("characters", old_index) else group.setStringAt("characters", old_index, new_name);
    }
}

fn removeFilter(profile: ProfileRef, index: usize) void {
    const name = std.mem.trim(u8, profile.ptr.windowFilters.items[index].name, " ");
    if (name.len > 0) {
        if (characterIndex(profile, name)) |entry| profile.remove("characters", entry);
    }
    profile.remove("windowFilters", index);
    if (g_selected.index >= index) g_selected.index -|= 1;
    window_picker.close(&g_picker);
}
