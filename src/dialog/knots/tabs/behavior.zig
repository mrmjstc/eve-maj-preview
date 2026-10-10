//! The configuration window's Behavior tab: startup, mouse interaction, auto-minimize, exclusion, saved window positions and Ultra Potato Mode; main thread only.
const std = @import("std");
const ui = @import("ui");
const win32 = @import("../../../platform/win32.zig");
const config = @import("../../../config.zig");
const files = @import("../../../config/files.zig");
const ultra_potato = @import("../../tools/ultra_potato.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const positions = @import("../positions.zig");
const status = @import("../status.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const log = @import("../../../log.zig");

const Button = ui.component.Button;
const SelectInput = ui.component.SelectInput;
const slog = log.scoped("dialog_knots");

const PROTOCOL_DOCS_URL = "https://github.com/mrmjstc/eve-maj-preview/blob/main/docs/CONFIGURATION.md#protocol-handler";

/// A list of names scanned from outside the settings, kept until the next scan.
const Scan = struct {
    arena: std.heap.ArenaAllocator,
    names: []const []const u8,
    selected: u32 = 0,
};

const PotatoScan = union(enum) {
    not_scanned,
    failed,
    found: struct {
        arena: std.heap.ArenaAllocator,
        profiles: []const ultra_potato.Profile,
        selected: u32 = 0,
    },
};

var g_allocator: std.mem.Allocator = undefined;
/// Open clients for Set All, scanned when the tab first shows and on ↻.
var g_sources: ?Scan = null;
var g_potato: PotatoScan = .not_scanned;
/// Set by a ↻ click and done before the next frame draws its dropdown, since a rescan frees the names this frame's dropdown drew.
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
    try startup(context);
    try interaction(context);
    try autoMinimize(context);
    try exclusion(context);
    try windowPosition(context);
    if (session.global().get("advancedMode")) try ultraPotato(context);
}

fn startup(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Startup", "Launch on Windows login, and register the evemajpreview:// URL protocol for external control (Stream Deck, scripts, etc.).", &style.section);
    const global = session.global();
    try bind.toggle(context, global, "runOnStartup", "Run on Startup");
    try bind.toggle(context, global, "autoRegisterProtocol", "Auto-Register Protocol Handler");
    if (try widgets.hintWithLink(context, .src(@src()), "Needed once for links like evemajpreview://cycle-next to work from other apps.", "Learn more")) {
        if (!win32.shellOpenUrl(PROTOCOL_DOCS_URL)) slog.warn("Failed to open '{s}' in the browser", .{PROTOCOL_DOCS_URL});
    }
    try bind.toggle(context, global, "disableUpdateChecks", "Disable Update Checks");
    try section.close(context);
}

fn interaction(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Interaction", "Mouse behavior for thumbnails and client list rows, including when to activate the EVE client window on left-click, and whether client windows animate when restored or minimized.", &style.section);
    const ref = session.profile().child("interaction");
    try bind.toggle(context, ref, "clickThrough", "Click Through");
    try widgets.hintText(context, .src(@src()), "Thumbnails and the client list ignore all mouse input and let clicks/drags pass through to whatever is behind them; disables click-to-focus, exclusion toggling, and dragging.");
    const click_through = ref.get("clickThrough");

    const mouse_options = try widgets.openGroup(context, .src(@src()), !click_through);
    try bind.choice(context, ref, "clickTrigger", "Click Trigger");
    try widgets.hintText(context, .src(@src()), "Mouse Up avoids accidental drags from a quick click.");
    try bind.choice(context, ref, "hoverCursor", "Hover Cursor");
    try widgets.hintText(context, .src(@src()), "Mouse cursor shown while hovering a thumbnail or a client list row.");
    try mouse_options.close(context);

    try bind.choice(context, ref, "animationStyle", "Animation Style");
    try widgets.hintText(context, .src(@src()), "No Animation restores and minimizes clients instantly; Original Animation keeps Windows' native effect.");

    if (session.showsThumbnails()) try hoverZoom(context, ref, click_through);
    try section.close(context);
}

fn hoverZoom(context: *ui.Frame, ref: session.Ref(config.InteractionConfig), click_through: bool) !void {
    const zoom_options = try widgets.openGroup(context, .src(@src()), !click_through);
    try bind.toggle(context, ref, "hoverZoomEnabled", "Zoom on Hover");
    try widgets.hintText(context, .src(@src()), "Shows an enlarged copy of a thumbnail, with its overlay text, while the cursor rests on it.");
    const zoom = try widgets.openGroup(context, .src(@src()), ref.get("hoverZoomEnabled"));
    try bind.number(context, ref, "hoverZoomPercent", "Zoom Size", .{ .unit = "%" });
    try widgets.hintText(context, .src(@src()), "Size of the zoom relative to the thumbnail, shrunk if needed to fit its monitor.");
    try bind.choice(context, ref, "hoverZoomAnchor", "Zoom Anchor");
    try widgets.hintText(context, .src(@src()), "The point of the thumbnail that stays in place as the zoom grows.");
    try zoom.close(context);
    try zoom_options.close(context);
}

fn autoMinimize(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Auto-Minimize", "Minimizes an EVE client window after it's been unfocused for the configured delay.", &style.section);
    const ref = session.profile().child("autoMinimize");
    try bind.toggle(context, ref, "enabled", "Enable Auto-Minimize");
    const options = try widgets.openGroup(context, .src(@src()), ref.get("enabled"));
    try bind.toggle(context, ref, "exemptLastActiveOnFocusLoss", "Keep Last-Active Client Visible");
    try widgets.hintText(context, .src(@src()), "Exempts whichever client you focused most recently, even past the delay.");
    try bind.number(context, ref, "delayMs", "Delay", .{ .ms_as_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "How long a client can sit unfocused before it's minimized.");
    try options.close(context);
    try bind.toggle(context, ref, "startMinimized", "Start Clients Minimized");
    try widgets.hintText(context, .src(@src()), "Minimizes each EVE client as soon as it launches, even with Auto-Minimize off.");
    try section.close(context);
}

fn exclusion(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Character Exclusion", "Controls Shift+Click exclusion of characters from hotkey cycling.", &style.section);
    const ref = session.profile().child("exclusion");
    // The Toggle Character Exclusion hotkey excludes too, so the settings below don't depend on Shift+Click.
    try bind.toggle(context, ref, "enableShiftClickExclude", "Enable Shift+Click to Exclude");
    try bind.toggle(context, ref, "autoMinimizeExcluded", "Auto-Minimize Excluded Characters");
    try widgets.hintText(context, .src(@src()), "Minimizes immediately on exclusion, not on the Auto-Minimize delay above.");
    try bind.toggle(context, ref, "logoutClearsExclusion", "Logging Out Clears Exclusion");
    try widgets.hintText(context, .src(@src()), "Includes a character again once its client returns to the login screen.");
    if (session.showsThumbnails()) try exclusionOverlay(context);
    try section.close(context);
}

/// Drawn over an excluded thumbnail; the client list dims the row instead.
fn exclusionOverlay(context: *ui.Frame) !void {
    const thumbnail = session.profile().child("thumbnail");
    try bind.choice(context, thumbnail, "exclusionOverlayStyle", "Overlay Style");
    try bind.rgb(context, thumbnail, "exclusionOverlayColor", "Overlay Color");
    try bind.alphaSlider(context, thumbnail, "exclusionOverlayColor", "Overlay Opacity");
}

fn windowPosition(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Window Position", "Saves each character's real EVE client window position, restored via the Move to Saved Positions hotkey or automatically on login. Set All copies the selected window's current position to every character; Clear All removes every saved position.", &style.section);
    const ref = session.profile().child("autoMovePosition");
    try bind.toggle(context, ref, "enabled", "Restore Saved Position on Login");
    try widgets.hintText(context, .src(@src()), "Moves a client to its saved position when its character logs in.");
    try bind.toggle(context, ref, "moveOnStartup", "Restore Saved Position on App Startup");
    try widgets.hintText(context, .src(@src()), "Moves clients already logged in when the app launches.");
    try bind.number(context, ref, "verifyIntervalMs", "Re-check Interval", .{ .ms_as_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "How often a moved client's position is re-checked; EVE can shift its own window while loading.");
    try bind.number(context, ref, "verifyCount", "Re-check Count", .{});
    try widgets.hintText(context, .src(@src()), "How many times to re-check and re-apply the position after a move. 0 disables re-checking.");

    if (g_sources == null or g_is_sources_rescan_due) scanSources();
    const set_all = try widgets.openBinding(context, .src(@src()), "Copy to All From");
    const source = try sourceSelect(context);
    if (try widgets.glyphButton(context, .src(@src()), .refresh, "", &style.icon_button, false)) {
        g_is_sources_rescan_due = true;
        context.requestRedraw();
    }
    if ((try context.interact(Button{ .key = .src(@src()), .label = "Set All", .style = &style.plain_button })).clicked) setAll(source);
    try set_all.close(context);
    const clear_all = try widgets.openBinding(context, .src(@src()), "Saved Positions");
    if (try widgets.confirmButton(context, .src(@src()), "Clear All", "Confirm", &style.danger_button, &style.confirm_button)) clearAll();
    try clear_all.close(context);
    try section.close(context);
}

fn clearAll() void {
    positions.clearAll() catch |err| {
        slog.err("Failed to clear all character window positions: {}", .{err});
        status.show(.failure, "Failed to save: {}", .{err});
        return;
    };
    status.show(.success, "Window positions cleared", .{});
}

/// The open client Set All copies from, or null when none is open.
fn sourceSelect(context: *ui.Frame) !?[]const u8 {
    const sources = &(g_sources orelse return null);
    const key: ui.Key = .str("knots.positions.source");
    if (sources.names.len == 0) {
        const labels: []const []const u8 = &.{"No open EVE clients found"};
        _ = try context.interact(SelectInput(u32){ .key = key, .labels = labels, .values = &.{0}, .initial_selected = 0, .style = try widgets.fittedSelect(context, labels), .parts = .{ .popup = &style.select_popup } });
        return null;
    }
    const values = try context.arena().alloc(u32, sources.names.len);
    for (values, 0..) |*value, index| value.* = @intCast(index);
    const response = try context.interact(SelectInput(u32){
        .key = key,
        .labels = sources.names,
        .values = values,
        .initial_selected = sources.selected,
        .style = try widgets.fittedSelect(context, sources.names),
        .parts = .{ .popup = &style.select_popup },
    });
    if (response.selected) |selected| sources.selected = selected.value;
    return sources.names[@min(sources.selected, sources.names.len - 1)];
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
    const previous: ?[]const u8 = if (g_sources) |sources| if (sources.names.len > 0) sources.names[@min(sources.selected, sources.names.len - 1)] else null else null;
    var arena = std.heap.ArenaAllocator.init(g_allocator);
    errdefer arena.deinit();
    // The scout's names only live for this frame, so they're copied into the scan's own arena.
    const names = try positions.openClients(arena.allocator());
    const copies = try arena.allocator().alloc([]const u8, names.len);
    var selected: u32 = 0;
    for (names, copies, 0..) |name, *copy, index| {
        copy.* = try arena.allocator().dupe(u8, name);
        if (previous) |was| {
            if (std.mem.eql(u8, was, name)) selected = @intCast(index);
        }
    }
    return .{ .arena = arena, .names = copies, .selected = selected };
}

fn setAll(source: ?[]const u8) void {
    const name = source orelse {
        status.show(.failure, "No open EVE clients found", .{});
        return;
    };
    positions.setAll(name) catch |err| {
        slog.err("Failed to set all character window positions: {}", .{err});
        status.show(.failure, "Failed to save: {}", .{err});
        return;
    };
    status.show(.success, "Window position saved", .{});
}

fn ultraPotato(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Ultra Potato Mode", "Forces EVE Online's heaviest graphics settings (shaders, shadows, textures, reflections, post-processing, cloth, ambient occlusion, volumetrics) to their lowest quality. Close all EVE clients first - the client overwrites these files on exit. A .bak backup of each file is made before its first edit.", &style.section);
    if (g_potato == .not_scanned or g_is_potato_rescan_due) scanPotato();
    const row = try widgets.openBinding(context, .src(@src()), "EVE Settings Profile");
    const paths = try potatoSelect(context);
    if (try widgets.glyphButton(context, .src(@src()), .refresh, "", &style.icon_button, false)) {
        g_is_potato_rescan_due = true;
        context.requestRedraw();
    }
    try row.close(context);
    const apply = try widgets.openBinding(context, .src(@src()), "Lowest Graphics Settings");
    const can_apply = paths != null;
    if ((try context.interact(Button{ .key = .src(@src()), .label = "Apply Ultra Potato Mode", .disabled = !can_apply, .style = if (can_apply) &style.plain_button else &style.disabled_button })).clicked) {
        if (paths) |chosen| applyPotato(chosen);
    }
    try apply.close(context);
    try section.close(context);
}

/// The paths the selection covers: one profile, or every one for All Profiles.
fn potatoSelect(context: *ui.Frame) !?[]const []const u8 {
    const key: ui.Key = .str("knots.potato.profile");
    const found = switch (g_potato) {
        .found => |*found| found,
        .not_scanned, .failed => {
            const message: []const u8 = if (g_potato == .failed) "Failed to scan for EVE settings profiles." else "Scanning for EVE settings profiles...";
            const labels: []const []const u8 = &.{message};
            _ = try context.interact(SelectInput(u32){ .key = key, .labels = labels, .values = &.{0}, .initial_selected = 0, .style = try widgets.fittedSelect(context, labels), .parts = .{ .popup = &style.select_popup } });
            return null;
        },
    };
    if (found.profiles.len == 0) {
        const labels: []const []const u8 = &.{"No EVE settings profiles found."};
        _ = try context.interact(SelectInput(u32){ .key = key, .labels = labels, .values = &.{0}, .initial_selected = 0, .style = try widgets.fittedSelect(context, labels), .parts = .{ .popup = &style.select_popup } });
        return null;
    }
    const arena = context.arena();
    const has_all = found.profiles.len > 1;
    const count = found.profiles.len + @intFromBool(has_all);
    const labels = try arena.alloc([]const u8, count);
    const values = try arena.alloc(u32, count);
    if (has_all) labels[0] = "All Profiles";
    for (found.profiles, @intFromBool(has_all)..) |profile, index| labels[index] = profile.label;
    for (values, 0..) |*value, index| value.* = @intCast(index);
    const response = try context.interact(SelectInput(u32){ .key = key, .labels = labels, .values = values, .initial_selected = found.selected, .style = try widgets.fittedSelect(context, labels), .parts = .{ .popup = &style.select_popup } });
    if (response.selected) |selected| found.selected = selected.value;

    const all_paths = try arena.alloc([]const u8, found.profiles.len);
    for (found.profiles, all_paths) |profile, *path| path.* = profile.path;
    if (has_all and found.selected == 0) return all_paths;
    const index = found.selected - @intFromBool(has_all);
    return all_paths[index .. index + 1];
}

fn scanPotato() void {
    g_is_potato_rescan_due = false;
    switch (g_potato) {
        .found => |*found| found.arena.deinit(),
        .not_scanned, .failed => {},
    }
    var arena = std.heap.ArenaAllocator.init(g_allocator);
    const profiles = ultra_potato.scanProfiles(arena.allocator(), files.g_io, config.environMap()) catch |err| {
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
    const results = ultra_potato.applyToFiles(arena.allocator(), files.g_io, paths) catch |err| {
        slog.err("Failed to apply Ultra Potato Mode: {}", .{err});
        status.show(.failure, "Failed: {}", .{err});
        return;
    };
    var changed: usize = 0;
    var already_set: usize = 0;
    var first_failure: ?ultra_potato.ApplyResult = null;
    for (results) |result| {
        if (!result.success) {
            if (first_failure == null) first_failure = result;
        } else if (result.changed) changed += 1 else already_set += 1;
    }
    if (first_failure) |failure| {
        status.show(.failure, "Applied to {d}/{d}. Failed: {s} ({s})", .{ changed + already_set, results.len, failure.path, failure.error_message orelse "unknown error" });
    } else if (changed > 0 and already_set > 0) {
        status.show(.success, "Applied to {d}, already set on {d} profile(s).", .{ changed, already_set });
    } else if (changed > 0) {
        status.show(.success, "Applied to {d} profile(s).", .{changed});
    } else {
        status.show(.success, "Already applied to {d} profile(s).", .{already_set});
    }
}
