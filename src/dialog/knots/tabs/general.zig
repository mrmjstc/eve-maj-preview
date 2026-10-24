//! The configuration window's General tab: app-wide preferences and startup, then, in Advanced Mode, logging, scanning, and the window filters that pick which applications are tracked; main thread only.
const std = @import("std");
const ui = @import("ui");
const win32 = @import("../../../platform/win32.zig");
const config = @import("../../../config.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const host = @import("../host.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const window_picker = @import("../window_picker.zig");
const status = @import("../status.zig");
const lang = @import("../../../lang/lang.zig");
const log = @import("../../../log.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const ProfileRef = session.Ref(config.Config);
const FilterRef = session.Ref(config.WindowFilterConfig);
const slog = log.Scoped("dialog_knots");

const NEW_FILTER_NAME = "New Filter";
const PROTOCOL_DOCS_URL = "https://github.com/mrmjstc/eve-maj-preview/blob/main/docs/CONFIGURATION.md#command-line-and-protocol";

var g_allocator: std.mem.Allocator = undefined;
/// The filter open in its editor, or null while every filter shows as a row.
var g_open_index: ?usize = null;
/// The Window Filters switch isn't saved; it starts on whenever the profile has filters.
var g_are_filters_enabled: ?bool = null;
/// The open "Pick Running Window" dropdown, under one filter.
var g_picker: ?window_picker.Picker = null;

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// Once the window has closed.
pub fn reset() void {
    window_picker.close(&g_picker);
    g_are_filters_enabled = null;
    g_open_index = null;
}

pub fn show(context: *ui.Frame) !void {
    try preferences(context);
    try startup(context);
    if (!session.global().get("advancedMode")) return;
    try logging(context);
    try scanning(context);
    try windowFilters(context);
}

fn preferences(context: *ui.Frame) !void {
    const section = try widgets.openSection(
        context,
        "Preferences",
        "Settings for the app itself, shared by every profile.",
        &style.section,
    );
    const global = session.global();
    try bind.choice(context, global, "language", "Language");
    try widgets.hintText(context, .src(@src()), "Also used for the app's on-screen messages.");
    try bind.toggle(context, global, "advancedMode", "Advanced Mode");
    try widgets.hintText(context, .src(@src()), "Shows extra, rarely changed settings and tabs.");
    const was_on_top = global.get("alwaysOnTop");
    try bind.toggle(context, global, "alwaysOnTop", "Always on Top");
    try widgets.hintText(context, .src(@src()), "Keeps this window above other windows.");
    if (global.get("alwaysOnTop") != was_on_top) host.setAlwaysOnTop(!was_on_top);
    try section.close(context);
}

fn startup(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Startup", "Starting with Windows, control from other apps, and update checks.", &style.section);
    const global = session.global();
    try bind.toggle(context, global, "runOnStartup", "Run on Startup");
    try widgets.hintText(context, .src(@src()), "Starts EVE-Maj Preview when you sign in to Windows.");
    try bind.toggle(context, global, "autoRegisterProtocol", "Auto-Register Protocol Handler");
    if (try widgets.hintWithLink(context, .src(@src()), "Lets links in other apps control EVE-Maj Preview.", "Learn more")) {
        if (!win32.shellOpenUrl(PROTOCOL_DOCS_URL)) slog.warn("Failed to open '{s}' in the browser", .{PROTOCOL_DOCS_URL});
    }
    try bind.invertedToggle(context, global, "disableUpdateChecks", "Check for Updates");
    try widgets.hintText(context, .src(@src()), "Looks online for a new version at startup.");
    try section.close(context);
}

fn logging(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Logging", "How much detail is written to the log file.", &style.section);
    try bind.choice(context, session.global(), "logLevel", "Log Level");
    try widgets.hintText(context, .src(@src()), "Use Debug when reporting a problem.");
    const file_row = try widgets.openBinding(context, .src(@src()), "Log File");
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = log.LOG_FILE_NAME, .style = &style.muted_text });
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Open Folder"), .style = &style.plain_button })).clicked) openLogFolder();
    try file_row.close(context);
    try section.close(context);
}

/// The working directory is the app's folder, so the relative log folder opens from there.
fn openLogFolder() void {
    if (win32.shellOpen(log.LOG_DIR, null)) return;
    slog.err("Failed to open the log folder '{s}'", .{log.LOG_DIR});
    status.show(.failure, "Failed to open the log folder", .{});
}

fn scanning(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Scanning", "How often to check for new EVE windows.", &style.section);
    try bind.number(context, session.profile().child("timer"), "scanIntervalMs", "Scan Interval", .{ .shows_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "How often to look for opened or closed clients.");
    try section.close(context);
}

fn windowFilters(context: *ui.Frame) !void {
    const profile = session.profile();
    var is_enabled = g_are_filters_enabled orelse (profile.ptr.windowFilters.items.len > 0);
    const section = try widgets.openSection(context, "Window Filters", "Tracks other apps by window class or executable. Off shows only EVE.", &style.section);
    if (try widgets.checkbox(context, .src(@src()), "Enable Window Filters", &is_enabled)) g_are_filters_enabled = is_enabled;

    const options = try widgets.openGroup(context, .src(@src()), is_enabled);
    try filterList(context, profile);
    try options.close(context);
    try section.close(context);
}

/// The built-in EVE filter is the profile default and isn't editable here, so it's left out of the list.
fn isBuiltIn(filter: *const config.WindowFilterConfig) bool {
    return std.mem.eql(u8, filter.name, config.WindowFilterConfig.DEFAULT.name);
}

/// A row per filter, the open one shown as its editor in its place, then Add.
fn filterList(context: *ui.Frame, profile: ProfileRef) !void {
    const arena = context.arena();
    var has_editable = false;
    for (profile.ptr.windowFilters.items, 0..) |*filter, index| {
        if (isBuiltIn(filter)) continue;
        has_editable = true;
        if (g_open_index == index) {
            if (try filterEditor(context, profile, index)) return;
            continue;
        }
        const row = Button{ .key = ui.Key.str("knots.filter.row").indexed(index), .style = &style.list_item };
        if ((try widgets.openRosterRow(context, row)).clicked) {
            g_open_index = index;
            window_picker.close(&g_picker);
            context.requestRedraw();
        }
        const text_column = Rect{ .key = ui.Key.str("knots.filter.text").indexed(index), .style = &style.list_item_text };
        _ = try text_column.open(context);
        const name = if (filter.name.len > 0) filter.name else try lang.format(arena, "New Filter {n}", .{ .n = index + 1 });
        try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.filter.name").indexed(index), .content = name, .style = &style.list_item_name });
        const detail = if (!filter.enabled) lang.text("Disabled") else try std.mem.join(arena, ", ", filter.executable_names.items);
        if (detail.len > 0) try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.filter.detail").indexed(index), .content = detail, .style = &style.list_item_detail });
        try text_column.close(context);
        try widgets.listChevron(context, ui.Key.str("knots.filter.chevron").indexed(index));
        try row.close(context);
    }
    if (!has_editable) try widgets.paragraph(context, .src(@src()), "No window filters yet. Add one to show another app's windows as thumbnails.");
    if (try widgets.glyphButton(context, .src(@src()), .add, "Add Window Filter", &style.add_button, false)) addFilter(profile);
}

fn addFilter(profile: ProfileRef) void {
    if (profile.append("windowFilters", .{ .name = lang.text(NEW_FILTER_NAME), .enabled = true })) |added| g_open_index = added.index;
    window_picker.close(&g_picker);
}

/// Returns whether the filter was removed, which ends the list for this frame.
fn filterEditor(context: *ui.Frame, profile: ProfileRef, index: usize) !bool {
    const filter = profile.item("windowFilters", index);
    const editor = Rect{ .key = ui.Key.str("knots.filter.editor").indexed(index), .style = &style.inline_editor };
    _ = try editor.open(context);

    const header = Rect{ .key = ui.Key.str("knots.filter.header").indexed(index), .style = &style.inline_editor_header };
    _ = try header.open(context);
    const name_before = try context.arena().dupe(u8, filter.get("name"));
    try bind.textBox(context, filter, "name", "e.g., EVE Online");
    const name_after = filter.get("name");
    const removed = try widgets.confirmButton(context, ui.Key.str("knots.filter.remove").indexed(index), "Remove", "Confirm", &style.plain_button, &style.confirm_button);
    if ((try context.interact(Button{ .key = ui.Key.str("knots.filter.done").indexed(index), .label = lang.text("Done"), .style = &style.primary_button })).clicked) {
        g_open_index = null;
        window_picker.close(&g_picker);
        context.requestRedraw();
    }
    try header.close(context);
    if (!std.mem.eql(u8, name_before, name_after)) carryRename(profile, std.mem.trim(u8, name_before, " "), std.mem.trim(u8, name_after, " "));

    var is_enabled: bool = filter.get("enabled");
    if (try widgets.switchRow(context, ui.Key.str("knots.filter.enabled").indexed(index), "Enabled", &is_enabled)) filter.set("enabled", is_enabled);
    try widgets.hintText(context, ui.Key.str("knots.filter.enabled.hint").indexed(index), "When off, this filter matches nothing.");
    const executables = try widgets.openStackedBinding(context, ui.Key.str("knots.filter.exes").indexed(index), "Executable Names");
    try bind.csvBox(context, filter, "executable_names", "e.g., exefile.exe");
    try executables.close(context);
    try widgets.hintText(context, ui.Key.str("knots.filter.exes.hint").indexed(index), "Separate names with commas.");
    const classes = try widgets.openStackedBinding(context, ui.Key.str("knots.filter.classes").indexed(index), "Window Classes");
    try bind.csvBox(context, filter, "class_names", "e.g., trinityWindow");
    try classes.close(context);
    try widgets.hintText(context, ui.Key.str("knots.filter.classes.hint").indexed(index), "Optional. Leave blank to match by Executable Names only.");
    const detect = try widgets.openBinding(context, ui.Key.str("knots.filter.detect").indexed(index), "Detect");
    if (try widgets.glyphButton(context, ui.Key.str("knots.filter.pick").indexed(index), .refresh, "Pick Running Window", &style.add_button, false)) window_picker.open(g_allocator, &g_picker, index);
    try detect.close(context);
    try widgets.hintText(context, ui.Key.str("knots.filter.detect.hint").indexed(index), "Pick an open window to fill in this filter.");
    try picker(context, profile, filter);
    try editor.close(context);

    if (!removed) return false;
    removeFilter(profile, index);
    return true;
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
    g_open_index = null;
    window_picker.close(&g_picker);
}
