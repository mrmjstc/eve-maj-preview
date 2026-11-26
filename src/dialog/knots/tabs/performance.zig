//! The configuration window's Performance tab: Client Speed, which sets each client's CPU priority and efficiency mode, and Ultra Potato Mode; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../config.zig");
const ultra_potato = @import("../../tools/ultra_potato.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const lang = @import("../../../lang/lang.zig");
const window_mod = @import("../window.zig");
const log = @import("../../../log.zig");

const Text = ui.component.Text;
const Button = ui.component.Button;
const SelectInput = ui.component.SelectInput;
const Window = window_mod.Window;
const slog = log.Scoped("dialog_knots");

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

/// One window's, reset as each opens.
pub const State = struct {
    potato: PotatoScan = .not_scanned,
    /// Done before the next frame's dropdown, since a rescan frees the names this frame drew.
    is_potato_rescan_due: bool = false,

    pub fn deinit(self: *State) void {
        switch (self.potato) {
            .found => |*found| found.arena.deinit(),
            .not_scanned, .failed => {},
        }
    }
};

pub fn show(window: *Window, context: *ui.Frame) !void {
    try clientSpeed(window, context);
    try ultraPotato(window, context);
}

fn clientSpeed(window: *Window, context: *ui.Frame) !void {
    const section = try window.widgets.openSharedSection(context, "Client Speed", "How much of the PC each EVE client gets. Undone when EVE-Maj Preview exits.", &style.section);
    const speed = window.session.global().child("clientSpeed");
    try window.bind.toggle(context, speed, "raiseFocusedClient", "Raise the Focused Client's Priority");
    try window.widgets.hintText(context, .src(@src()), "Above Normal CPU priority for the client you're in.");
    try window.bind.toggle(context, speed, "lowerBackgroundClients", "Lower Background Clients' Priority");
    try window.widgets.hintText(context, .src(@src()), "Below Normal CPU priority for the others, once you stop switching.");
    try window.bind.toggle(context, speed, "backgroundEfficiencyMode", "Efficiency Mode for Background Clients");
    try window.widgets.hintText(context, .src(@src()), "Less power and heat; their thumbnails may update less smoothly.");
    try window.widgets.hintText(context, .src(@src()), "Characters set to Keep at Full Speed are never slowed down.");
    try section.close(context);
}

fn ultraPotato(window: *Window, context: *ui.Frame) !void {
    const section = try window.widgets.openSection(context, "Ultra Potato Mode", "Sets EVE's heaviest graphics options to their lowest quality.", &style.section);
    if (window.performance.potato == .not_scanned or window.performance.is_potato_rescan_due) scanPotato(window);
    const row = try window.widgets.openBinding(context, .src(@src()), "EVE Settings Profile");
    const paths = try potatoSelect(window, context);
    if (try widgets.glyphButton(context, .src(@src()), .refresh, "", &style.icon_button, false)) {
        window.performance.is_potato_rescan_due = true;
        context.requestRedraw();
    }
    try row.close(context);
    try window.widgets.hintText(context, .src(@src()), "The EVE settings to change. Close EVE first.");
    const apply = try window.widgets.openBinding(context, .src(@src()), "Lowest Graphics Settings");
    const has_selection = paths != null;
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Apply Ultra Potato Mode"), .disabled = !has_selection, .style = if (has_selection) &style.plain_button else &style.disabled_button })).clicked) {
        if (paths) |chosen| applyPotato(window, chosen);
    }
    try apply.close(context);
    try window.widgets.hintText(context, .src(@src()), "Each file is backed up before its first change.");
    try section.close(context);
}

/// The paths the selection covers: one profile, or every one for All Profiles.
fn potatoSelect(window: *Window, context: *ui.Frame) !?[]const []const u8 {
    const key: ui.Key = .str("knots.potato.profile");
    const found = switch (window.performance.potato) {
        .found => |*found| found,
        .not_scanned, .failed => {
            const message = if (window.performance.potato == .failed) "Failed to scan for EVE settings profiles" else "Scanning for EVE settings profiles...";
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
    try window.widgets.nameSelect(context, key, labels[@min(found.selected_index, labels.len - 1)]);

    const all_paths = try arena.alloc([]const u8, found.profiles.len);
    for (found.profiles, all_paths) |profile, *path| path.* = profile.path;
    if (has_all and found.selected_index == 0) return all_paths;
    const index = found.selected_index - @intFromBool(has_all);
    return all_paths[index .. index + 1];
}

fn scanPotato(window: *Window) void {
    window.performance.is_potato_rescan_due = false;
    switch (window.performance.potato) {
        .found => |*found| found.arena.deinit(),
        .not_scanned, .failed => {},
    }
    const environ_map = config.environMap() orelse {
        slog.err("Failed to scan EVE settings profiles: the environment isn't loaded yet", .{});
        window.performance.potato = .failed;
        return;
    };
    var arena: std.heap.ArenaAllocator = .init(window.allocator);
    const profiles = ultra_potato.scanProfiles(arena.allocator(), window.session.appContext().io, environ_map) catch |err| {
        arena.deinit();
        slog.err("Failed to scan EVE settings profiles: {}", .{err});
        window.performance.potato = .failed;
        return;
    };
    window.performance.potato = .{ .found = .{ .arena = arena, .profiles = profiles } };
}

fn applyPotato(window: *Window, paths: []const []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(window.allocator);
    defer arena.deinit();
    const results = ultra_potato.applyToFiles(arena.allocator(), window.session.appContext().io, paths) catch |err| {
        slog.err("Failed to apply Ultra Potato Mode: {}", .{err});
        window.status.show(.failure, "Failed: {err}", .{ .err = err });
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
        window.status.show(.failure, "Applied to {done}/{total}. Failed: {path} ({err})", .{
            .done = changed_count + already_set_count,
            .total = results.len,
            .path = failure.path,
            .err = lang.text(failure.error_message orelse "unknown error"),
        });
    } else if (changed_count > 0 and already_set_count > 0) {
        window.status.show(.success, "Applied to {changed}, already set on {already} profile(s).", .{ .changed = changed_count, .already = already_set_count });
    } else if (changed_count > 0) {
        window.status.show(.success, "Applied to {n} profile(s).", .{ .n = changed_count });
    } else {
        window.status.show(.success, "Already applied to {n} profile(s).", .{ .n = already_set_count });
    }
}
