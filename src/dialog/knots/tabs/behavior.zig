//! The configuration window's Mouse & Windows tab: mouse interaction, auto-minimize, exclusion, saved window positions and Ultra Potato Mode; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../config.zig");
const ultra_potato = @import("../../tools/ultra_potato.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const positions = @import("../positions.zig");
const status = @import("../status.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const lang = @import("../../../lang/lang.zig");
const log = @import("../../../log.zig");

const Button = ui.component.Button;
const Text = ui.component.Text;
const SelectInput = ui.component.SelectInput;
const slog = log.Scoped("dialog_knots");

/// A list of names scanned from outside the settings, kept until the next scan.
const Scan = struct {
    arena: std.heap.ArenaAllocator,
    /// Owned by `arena`.
    names: []const []const u8,
    selected_index: u32 = 0,
};

const PotatoScan = union(enum) {
    not_scanned,
    failed,
    found: struct {
        arena: std.heap.ArenaAllocator,
        /// Owned by `arena`.
        profiles: []const ultra_potato.Profile,
        selected_index: u32 = 0,
    },
};

var g_allocator: std.mem.Allocator = undefined;
/// Open clients for Copy to All, scanned when the tab first shows and on ↻.
var g_sources: ?Scan = null;
var g_potato: PotatoScan = .not_scanned;
/// Done before the next frame's dropdown, since a rescan frees the names this frame drew.
var g_is_sources_rescan_due: bool = false;
/// Like g_is_sources_rescan_due, for the EVE settings profiles.
var g_is_potato_rescan_due: bool = false;

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// Once the window has closed.
pub fn reset() void {
    if (g_sources) |*sources| sources.arena.deinit();
    g_sources = null;
    switch (g_potato) {
        .found => |*found| found.arena.deinit(),
        .not_scanned, .failed => {},
    }
    g_potato = .not_scanned;
    g_is_sources_rescan_due = false;
    g_is_potato_rescan_due = false;
}

pub fn show(context: *ui.Frame) !void {
    try interaction(context);
    try autoMinimize(context);
    try exclusion(context);
    try windowPosition(context);
    if (session.global().get("advancedMode")) try ultraPotato(context);
}

fn interaction(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Interaction", "How thumbnails and the client list react to the mouse, and how clients animate.", &style.section);
    const ref = session.profile().child("interaction");
    try bind.segmented(context, ref, "animationStyle", "Animation Style", &.{ "None", "Original" });
    try widgets.hintText(context, .src(@src()), "Original plays Windows' own minimize and restore animation.");
    try bind.toggle(context, ref, "clickThrough", "Click Through");
    try widgets.hintText(context, .src(@src()), "Clicks go through thumbnails and the client list to what's behind.");
    const is_click_through = ref.get("clickThrough");

    const mouse_options = try widgets.openGroup(context, .src(@src()), !is_click_through);
    try bind.segmented(context, ref, "clickTrigger", "Click Trigger", &.{ "Mouse Down", "Mouse Up" });
    try widgets.hintText(context, .src(@src()), "Mouse Up waits until you let go, so sliding off first cancels the click.");
    try bind.choice(context, ref, "hoverCursor", "Hover Cursor");
    try widgets.hintText(context, .src(@src()), "The pointer shown over thumbnails and the client list.");
    try mouse_options.close(context);
    if (session.showsThumbnails()) try hoverZoom(context, ref, is_click_through);
    try section.close(context);
}

fn hoverZoom(context: *ui.Frame, ref: session.Ref(config.InteractionConfig), is_click_through: bool) !void {
    const zoom_options = try widgets.openGroup(context, .src(@src()), !is_click_through);
    try bind.toggle(context, ref, "hoverZoomEnabled", "Zoom on Hover");
    try widgets.hintText(context, .src(@src()), "Shows a bigger copy of a thumbnail while you hover over it.");
    const zoom = try widgets.openNestedGroup(context, .src(@src()), ref.get("hoverZoomEnabled"));
    try bind.number(context, ref, "hoverZoomPercent", "Zoom Size", .{ .unit = "%" });
    try widgets.hintText(context, .src(@src()), "Shrinks to fit if it would go off the monitor.");
    try bind.choice(context, ref, "hoverZoomAnchor", "Zoom Anchor");
    try widgets.hintText(context, .src(@src()), "The part of the thumbnail that stays put as it grows.");
    try zoom.close(context);
    try zoom_options.close(context);
}

fn autoMinimize(context: *ui.Frame) !void {
    const ref = session.profile().child("autoMinimize");
    const section = try widgets.openSection(context, "Auto-Minimize", "Minimizes EVE clients that have been in the background for a while.", &style.section);
    try bind.toggle(context, ref, "enabled", "Enable Auto-Minimize");
    const options = try widgets.openNestedGroup(context, .src(@src()), ref.get("enabled"));
    try bind.toggle(context, ref, "exemptLastActiveOnFocusLoss", "Keep Last-Active Client Visible");
    try widgets.hintText(context, .src(@src()), "Never minimizes the client you were just in, even after the delay.");
    try bind.number(context, ref, "delayMs", "Delay", .{ .shows_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "How long a client waits in the background before it's minimized.");
    try options.close(context);
    try bind.toggle(context, ref, "startMinimized", "Start Clients Minimized");
    try widgets.hintText(context, .src(@src()), "Minimizes each client as it opens, even with Auto-Minimize off.");
    try section.close(context);
}

fn exclusion(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Character Exclusion", "Controls Shift+Click exclusion of characters from hotkey cycling.", &style.section);
    const ref = session.profile().child("exclusion");
    // The Toggle Character Exclusion hotkey excludes too, so the settings below don't depend on Shift+Click.
    try bind.toggle(context, ref, "enableShiftClickExclude", "Enable Shift+Click to Exclude");
    try widgets.hintText(context, .src(@src()), "Shift+click a thumbnail to skip its character when cycling.");
    try bind.toggle(context, ref, "autoMinimizeExcluded", "Auto-Minimize Excluded Characters");
    try widgets.hintText(context, .src(@src()), "Minimizes them straight away, without the delay.");
    try bind.toggle(context, ref, "logoutClearsExclusion", "Logging Out Clears Exclusion");
    try widgets.hintText(context, .src(@src()), "A character stops being excluded once you log it out.");
    if (session.showsThumbnails()) try exclusionOverlay(context);
    try section.close(context);
}

/// Drawn over an excluded thumbnail; the client list dims the row instead.
fn exclusionOverlay(context: *ui.Frame) !void {
    const thumbnail = session.profile().child("thumbnail");
    try bind.choice(context, thumbnail, "exclusionOverlayStyle", "Overlay Style");
    try widgets.hintText(context, .src(@src()), "How excluded thumbnails are marked.");
    try bind.rgb(context, thumbnail, "exclusionOverlayColor", "Overlay Color");
    try widgets.hintText(context, .src(@src()), "The tint laid over excluded thumbnails.");
    try bind.alphaSlider(context, thumbnail, "exclusionOverlayColor", "Overlay Opacity");
    try widgets.hintText(context, .src(@src()), "How strongly excluded thumbnails are tinted.");
}

fn windowPosition(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Window Position", "Saves each character's EVE window position and puts the window back there.", &style.section);
    const ref = session.profile().child("autoMovePosition");
    try bind.toggle(context, ref, "enabled", "Restore Saved Position on Login");
    try widgets.hintText(context, .src(@src()), "Uses each character's window position from the Characters tab.");
    try bind.toggle(context, ref, "moveOnStartup", "Restore Saved Position on App Startup");
    try widgets.hintText(context, .src(@src()), "Also moves clients already logged in when the app starts.");
    try bind.number(context, ref, "verifyCount", "Recheck Count", .{ .unit = "times", .singular_unit = "time" });
    try widgets.hintText(context, .src(@src()), "How many times to check again; 0 turns this off.");
    const rechecks = try widgets.openNestedGroup(context, .src(@src()), ref.get("verifyCount") > 0);
    try bind.number(context, ref, "verifyIntervalMs", "Recheck Interval", .{ .shows_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "EVE can shift its window while loading, so it's checked again this often.");
    try rechecks.close(context);

    if (g_sources == null or g_is_sources_rescan_due) scanSources();
    const set_all = try widgets.openBinding(context, .src(@src()), "Copy Position From");
    const source = try sourceSelect(context);
    if (try widgets.glyphButton(context, .src(@src()), .refresh, "", &style.icon_button, false)) {
        g_is_sources_rescan_due = true;
        context.requestRedraw();
    }
    const paired_width = try pairedButtonWidth(context);
    const set_all_style = try widgets.withWidth(context, if (source == null) &style.paired_disabled_button else &style.paired_button, paired_width);
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Copy to All"), .disabled = source == null, .style = set_all_style })).clicked) setAll(source);
    try set_all.close(context);
    try widgets.hintText(context, .src(@src()), "Copies that window's position to every character.");
    const clear_all = try widgets.openBinding(context, .src(@src()), "Saved Positions");
    const clear_style = try widgets.withWidth(context, &style.paired_danger_button, paired_width);
    const confirm_style = try widgets.withWidth(context, &style.paired_confirm_button, paired_width);
    if (try widgets.confirmButton(context, .src(@src()), "Clear All", "Confirm", clear_style, confirm_style)) clearAll();
    try clear_all.close(context);
    try widgets.hintText(context, .src(@src()), "Clear All removes every character's saved window position.");
    try section.close(context);
}

/// Copy to All, Clear All and Confirm share the widest label's width, at least style.PAIRED_BUTTON_WIDTH.
fn pairedButtonWidth(context: *ui.Frame) !f32 {
    const padding = comptime style.plain_button.padding.?;
    const border_width = comptime style.plain_button.border_width.?.max();
    var widest: f32 = 0;
    for ([_][]const u8{ "Copy to All", "Clear All", "Confirm" }) |label| {
        widest = @max(widest, try widgets.textWidth(context, lang.text(label), &style.button_text));
    }
    return @max(style.PAIRED_BUTTON_WIDTH, @ceil(padding.left() + widest + padding.right() + 2 * border_width));
}

fn clearAll() void {
    positions.clearAll() catch |err| {
        slog.err("Failed to clear all character window positions: {}", .{err});
        status.show(.failure, "Failed to save: {err}", .{ .err = err });
        return;
    };
    status.show(.success, "Window positions cleared", .{});
}

/// The open client whose position Copy to All copies, or null when none is open.
fn sourceSelect(context: *ui.Frame) !?[]const u8 {
    const sources = if (g_sources) |*scan| scan else return null;
    const key: ui.Key = .str("knots.positions.source");
    if (sources.names.len == 0) {
        try context.e(Text{ .selectable = false, .key = key, .content = lang.text("No open EVE clients"), .style = &style.muted_text });
        return null;
    }
    const values = try context.arena().alloc(u32, sources.names.len);
    for (values, 0..) |*value, index| value.* = @intCast(index);
    const response = try context.interact(SelectInput(u32){
        .key = key,
        .labels = sources.names,
        .values = values,
        .initial_selected = sources.selected_index,
        .style = try widgets.fittedSelect(context, sources.names),
        .parts = .{ .popup = &style.select_popup },
    });
    if (response.selected) |selected| sources.selected_index = selected.value;
    return sources.names[@min(sources.selected_index, sources.names.len - 1)];
}

/// Keeps the picked client selected when it's still open.
fn scanSources() void {
    g_is_sources_rescan_due = false;
    const scanned = scanOpenClients() catch |err| {
        slog.err("Failed to refresh window position source options: {}", .{err});
        return;
    };
    if (g_sources) |*sources| sources.arena.deinit();
    g_sources = scanned;
}

fn scanOpenClients() !Scan {
    const previous: ?[]const u8 = if (g_sources) |sources| if (sources.names.len > 0) sources.names[@min(sources.selected_index, sources.names.len - 1)] else null else null;
    var arena = std.heap.ArenaAllocator.init(g_allocator);
    errdefer arena.deinit();
    const names = try positions.openClients(arena.allocator());
    var selected_index: u32 = 0;
    for (names, 0..) |name, index| {
        if (previous) |was| {
            if (std.mem.eql(u8, was, name)) selected_index = @intCast(index);
        }
    }
    return .{ .arena = arena, .names = names, .selected_index = selected_index };
}

fn setAll(source: ?[]const u8) void {
    const name = source orelse {
        status.show(.failure, "No open EVE clients found", .{});
        return;
    };
    positions.setAll(name) catch |err| {
        slog.err("Failed to set all character window positions: {}", .{err});
        status.show(.failure, "Failed to save: {err}", .{ .err = err });
        return;
    };
    status.show(.success, "Window position saved", .{});
}

fn ultraPotato(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Ultra Potato Mode", "Sets EVE's heaviest graphics options to their lowest quality.", &style.section);
    if (g_potato == .not_scanned or g_is_potato_rescan_due) scanPotato();
    const row = try widgets.openBinding(context, .src(@src()), "EVE Settings Profile");
    const paths = try potatoSelect(context);
    if (try widgets.glyphButton(context, .src(@src()), .refresh, "", &style.icon_button, false)) {
        g_is_potato_rescan_due = true;
        context.requestRedraw();
    }
    try row.close(context);
    try widgets.hintText(context, .src(@src()), "The EVE settings to change. Close EVE first.");
    const apply = try widgets.openBinding(context, .src(@src()), "Lowest Graphics Settings");
    const has_selection = paths != null;
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Apply Ultra Potato Mode"), .disabled = !has_selection, .style = if (has_selection) &style.plain_button else &style.disabled_button })).clicked) {
        if (paths) |chosen| applyPotato(chosen);
    }
    try apply.close(context);
    try widgets.hintText(context, .src(@src()), "Each file is backed up before its first change.");
    try section.close(context);
}

/// The paths the selection covers: one profile, or every one for All Profiles.
fn potatoSelect(context: *ui.Frame) !?[]const []const u8 {
    const key: ui.Key = .str("knots.potato.profile");
    const found = switch (g_potato) {
        .found => |*found| found,
        .not_scanned, .failed => {
            const message = if (g_potato == .failed) "Failed to scan for EVE settings profiles" else "Scanning for EVE settings profiles...";
            try context.e(Text{ .selectable = false, .key = key, .content = lang.text(message), .style = &style.muted_text });
            return null;
        },
    };
    if (found.profiles.len == 0) {
        try context.e(Text{ .selectable = false, .key = key, .content = lang.text("No EVE settings profiles found"), .style = &style.muted_text });
        return null;
    }
    const arena = context.arena();
    const has_all = found.profiles.len > 1;
    const option_count = found.profiles.len + @intFromBool(has_all);
    const labels = try arena.alloc([]const u8, option_count);
    const values = try arena.alloc(u32, option_count);
    if (has_all) labels[0] = lang.text("All Profiles");
    for (found.profiles, @intFromBool(has_all)..) |profile, index| labels[index] = profile.label;
    for (values, 0..) |*value, index| value.* = @intCast(index);
    const response = try context.interact(SelectInput(u32){ .key = key, .labels = labels, .values = values, .initial_selected = found.selected_index, .style = try widgets.fittedSelect(context, labels), .parts = .{ .popup = &style.select_popup } });
    if (response.selected) |selected| found.selected_index = selected.value;

    const all_paths = try arena.alloc([]const u8, found.profiles.len);
    for (found.profiles, all_paths) |profile, *path| path.* = profile.path;
    if (has_all and found.selected_index == 0) return all_paths;
    const index = found.selected_index - @intFromBool(has_all);
    return all_paths[index .. index + 1];
}

fn scanPotato() void {
    g_is_potato_rescan_due = false;
    switch (g_potato) {
        .found => |*found| found.arena.deinit(),
        .not_scanned, .failed => {},
    }
    const environ_map = config.environMap() orelse {
        slog.err("Failed to scan EVE settings profiles: the environment isn't loaded yet", .{});
        g_potato = .failed;
        return;
    };
    var arena = std.heap.ArenaAllocator.init(g_allocator);
    const profiles = ultra_potato.scanProfiles(arena.allocator(), session.runningApp().io, environ_map) catch |err| {
        arena.deinit();
        slog.err("Failed to scan EVE settings profiles: {}", .{err});
        g_potato = .failed;
        return;
    };
    g_potato = .{ .found = .{ .arena = arena, .profiles = profiles } };
}

fn applyPotato(paths: []const []const u8) void {
    var arena = std.heap.ArenaAllocator.init(g_allocator);
    defer arena.deinit();
    const results = ultra_potato.applyToFiles(arena.allocator(), session.runningApp().io, paths) catch |err| {
        slog.err("Failed to apply Ultra Potato Mode: {}", .{err});
        status.show(.failure, "Failed: {err}", .{ .err = err });
        return;
    };
    var changed_count: usize = 0;
    var already_set_count: usize = 0;
    var first_failure: ?ultra_potato.ApplyResult = null;
    for (results) |result| {
        if (!result.succeeded) {
            slog.warn("Failed to apply Ultra Potato Mode to '{s}': {s}", .{ result.path, result.error_message orelse "unknown error" });
            if (first_failure == null) first_failure = result;
        } else if (result.changed) changed_count += 1 else already_set_count += 1;
    }
    if (first_failure) |failure| {
        status.show(.failure, "Applied to {done}/{total}. Failed: {path} ({err})", .{ .done = changed_count + already_set_count, .total = results.len, .path = failure.path, .err = lang.text(failure.error_message orelse "unknown error") });
    } else if (changed_count > 0 and already_set_count > 0) {
        status.show(.success, "Applied to {changed}, already set on {already} profile(s).", .{ .changed = changed_count, .already = already_set_count });
    } else if (changed_count > 0) {
        status.show(.success, "Applied to {n} profile(s).", .{ .n = changed_count });
    } else {
        status.show(.success, "Already applied to {n} profile(s).", .{ .n = already_set_count });
    }
}
