//! The configuration window's Client Windows tab: how EVE windows animate, minimize, return to their saved positions and sit with the taskbar, then, in Advanced Mode, how often and which windows are tracked; main thread only.
const std = @import("std");
const ui = @import("ui");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const positions = @import("../positions.zig");
const status = @import("../status.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const window_filters = @import("window_filters.zig");
const lang = @import("../../../lang/lang.zig");
const window_mod = @import("../window.zig");
const log = @import("../../../log.zig");

const Button = ui.component.Button;
const Text = ui.component.Text;
const SelectInput = ui.component.SelectInput;
const Window = window_mod.Window;
const slog = log.Scoped("dialog_knots");

/// A list of names scanned from outside the settings, kept until the next scan.
const Scan = struct {
    arena: std.heap.ArenaAllocator,
    /// Owned by `arena`.
    names: []const []const u8,
    selected_index: u32 = 0,
};

/// One window's, reset as each opens.
pub const State = struct {
    /// Open clients for Copy to All, scanned when the tab first shows and on ↻.
    sources: ?Scan = null,
    /// Done before the next frame's dropdown, since a rescan frees the names this frame drew.
    is_sources_rescan_due: bool = false,

    pub fn deinit(self: *State) void {
        if (self.sources) |*sources| sources.arena.deinit();
    }
};

pub fn show(window: *Window, context: *ui.Frame) !void {
    try animation(window, context);
    try autoMinimize(window, context);
    try windowPosition(window, context);
    try taskbar(window, context);
    if (!window.session.global().get("advancedMode")) return;
    try scanning(window, context);
    try window_filters.show(window, context);
}

fn animation(window: *Window, context: *ui.Frame) !void {
    const section = try window.widgets.openSection(context, "Animation", "How clients minimize and restore as you switch between them.", &style.section);
    try window.bind.segmented(context, window.session.profile().child("interaction"), "animationStyle", "Animation Style", &.{ "None", "Original" });
    try window.widgets.hintText(context, .src(@src()), "Original plays Windows' own minimize and restore animation.");
    try section.close(context);
}

fn autoMinimize(window: *Window, context: *ui.Frame) !void {
    const ref = window.session.profile().child("autoMinimize");
    const section = try window.widgets.openSection(context, "Auto-Minimize", "Minimizes EVE clients that have been in the background for a while.", &style.section);
    try window.bind.toggle(context, ref, "enabled", "Enable Auto-Minimize");
    const options = try window.widgets.openGroup(context, .src(@src()), ref.get("enabled"));
    try window.bind.toggle(context, ref, "exemptLastActiveOnFocusLoss", "Keep Last-Active Client Visible");
    try window.widgets.hintText(context, .src(@src()), "Never minimizes the client you were just in, even after the delay.");
    try window.bind.number(context, ref, "delayMs", "Delay", .{ .shows_seconds = true, .unit = "s" });
    try window.widgets.hintText(context, .src(@src()), "How long a client waits in the background before it's minimized.");
    try options.close(context);
    try window.bind.toggle(context, ref, "startMinimized", "Start Clients Minimized");
    try window.widgets.hintText(context, .src(@src()), "Minimizes each client as it opens, even with Auto-Minimize off.");
    try section.close(context);
}

fn taskbar(window: *Window, context: *ui.Frame) !void {
    const section = try window.widgets.openSection(context, "Taskbar", "Whether the Windows taskbar stays over a client.", &style.section);
    try window.bind.toggle(context, window.session.profile().child("interaction"), "hideTaskbarOverClients", "Hide Taskbar Over Clients");
    try window.widgets.hintText(context, .src(@src()), "Puts the taskbar behind the active client, even one smaller than the screen.");
    try section.close(context);
}

fn scanning(window: *Window, context: *ui.Frame) !void {
    const section = try window.widgets.openSection(context, "Scanning", "How often to check for new EVE windows.", &style.section);
    try window.bind.number(context, window.session.profile().child("timer"), "scanIntervalMs", "Scan Interval", .{ .shows_seconds = true, .unit = "s" });
    try window.widgets.hintText(context, .src(@src()), "How often to look for opened or closed clients.");
    try section.close(context);
}

fn windowPosition(window: *Window, context: *ui.Frame) !void {
    const section = try window.widgets.openSection(context, "Window Position", "Saves each character's EVE window position and puts the window back there.", &style.section);
    const ref = window.session.profile().child("autoMovePosition");
    try window.bind.toggle(context, ref, "enabled", "Restore Saved Position on Login");
    try window.widgets.hintText(context, .src(@src()), "Uses each character's window position from the Characters tab.");
    try window.bind.toggle(context, ref, "moveOnStartup", "Restore Saved Position on App Startup");
    try window.widgets.hintText(context, .src(@src()), "Also moves clients already logged in when the app starts.");
    try window.bind.toggle(context, window.session.global(), "moveOnProfileSwitch", "Restore Saved Position on Profile Reload");
    try window.widgets.hintText(context, .src(@src()), "Moves clients to the new profile's saved positions when you switch profile; applies to every profile.");
    try window.bind.number(context, ref, "verifyCount", "Recheck Count", .{ .unit = "times", .singular_unit = "time" });
    try window.widgets.hintText(context, .src(@src()), "How many times to check again; 0 turns this off.");
    const rechecks = try window.widgets.openGroup(context, .src(@src()), ref.get("verifyCount") > 0);
    try window.bind.number(context, ref, "verifyIntervalMs", "Recheck Interval", .{ .shows_seconds = true, .unit = "s" });
    try window.widgets.hintText(context, .src(@src()), "EVE can shift its window while loading, so it's checked again this often.");
    try rechecks.close(context);

    if (window.client_windows.sources == null or window.client_windows.is_sources_rescan_due) scanSources(window);
    const set_all = try window.widgets.openBinding(context, .src(@src()), "Copy Position From");
    const source = try sourceSelect(window, context);
    if (try widgets.glyphButton(context, .src(@src()), .refresh, "", &style.icon_button, false)) {
        window.client_windows.is_sources_rescan_due = true;
        context.requestRedraw();
    }
    const paired_width = try pairedButtonWidth(context);
    const set_all_style = try widgets.withWidth(context, if (source == null) &style.paired_disabled_button else &style.paired_button, paired_width);
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Copy to All"), .disabled = source == null, .style = set_all_style })).clicked) setAll(window, source);
    try set_all.close(context);
    try window.widgets.hintText(context, .src(@src()), "Copies that window's position to every character.");
    const clear_all = try window.widgets.openBinding(context, .src(@src()), "Saved Positions");
    const clear_style = try widgets.withWidth(context, &style.paired_danger_button, paired_width);
    const confirm_style = try widgets.withWidth(context, &style.paired_confirm_button, paired_width);
    if (try window.widgets.confirmButton(context, .src(@src()), "Clear All", "Confirm", clear_style, confirm_style)) clearAll(window);
    try clear_all.close(context);
    try window.widgets.hintText(context, .src(@src()), "Clear All removes every character's saved window position.");
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

fn clearAll(window: *Window) void {
    positions.clearAll(window.session) catch |err| {
        slog.err("Failed to clear all character window positions: {}", .{err});
        window.status.show(.failure, "Failed to save: {err}", .{ .err = err });
        return;
    };
    window.status.show(.success, "Window positions cleared", .{});
}

/// The open client whose position Copy to All copies, or null when none is open.
fn sourceSelect(window: *Window, context: *ui.Frame) !?[]const u8 {
    const sources = if (window.client_windows.sources) |*scan| scan else return null;
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
    const source = sources.names[@min(sources.selected_index, sources.names.len - 1)];
    try window.widgets.nameSelect(context, key, source);
    return source;
}

/// Keeps the picked client selected when it's still open.
fn scanSources(window: *Window) void {
    window.client_windows.is_sources_rescan_due = false;
    const scanned = scanOpenClients(window) catch |err| {
        slog.err("Failed to refresh window position source options: {}", .{err});
        return;
    };
    if (window.client_windows.sources) |*sources| sources.arena.deinit();
    window.client_windows.sources = scanned;
}

fn scanOpenClients(window: *Window) !Scan {
    const previous: ?[]const u8 = if (window.client_windows.sources) |sources| if (sources.names.len > 0) sources.names[@min(sources.selected_index, sources.names.len - 1)] else null else null;
    var arena: std.heap.ArenaAllocator = .init(window.allocator);
    errdefer arena.deinit();
    const names = try positions.openClients(window.session, arena.allocator());
    var selected_index: u32 = 0;
    for (names, 0..) |name, index| {
        if (previous) |was| {
            if (std.mem.eql(u8, was, name)) selected_index = @intCast(index);
        }
    }
    return .{ .arena = arena, .names = names, .selected_index = selected_index };
}

fn setAll(window: *Window, source: ?[]const u8) void {
    const name = source orelse {
        window.status.show(.failure, "No open EVE clients found", .{});
        return;
    };
    positions.setAll(window.session, name) catch |err| {
        slog.err("Failed to set all character window positions: {}", .{err});
        window.status.show(.failure, "Failed to save: {err}", .{ .err = err });
        return;
    };
    window.status.show(.success, "Window position saved", .{});
}
