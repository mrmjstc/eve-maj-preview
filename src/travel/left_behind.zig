//! The travel check that alerts characters left behind in another system when the group moves on.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const painter_mod = @import("../painter.zig");
const exclusions = @import("../hotkeys/exclusions.zig");

const Painter = painter_mod.Painter;
const ThumbnailWindow = painter_mod.ThumbnailWindow;

/// Per-thumbnail travel state; Painter records jumps, check() reads it and flags alerts.
pub const LeftBehindState = struct {
    /// Zero = hasn't jumped this session.
    last_jump_ms: win32.Ticks = .{},
    /// Guards the left-behind alert to one per episode; cleared on jump.
    alert_fired: bool = false,

    pub fn recordJump(self: *LeftBehindState) void {
        self.last_jump_ms = win32.Ticks.now();
        self.alert_fired = false;
    }
};

/// Flags characters behind the group's current system by more than config.travel.window_seconds.
pub fn check(painter: *Painter, now: win32.Ticks) void {
    const cfg = painter.config.travel;
    if (!cfg.enabled) return;

    var eligible_count: usize = 0;
    for (painter.thumbnails.items) |*thumb| {
        if (!isTracked(thumb)) continue;
        eligible_count += 1;
    }
    if (eligible_count < 2) return;

    var group_system: []const u8 = "";
    var group_count: usize = 0;
    var group_arrival_ms: win32.Ticks = .{};

    for (painter.thumbnails.items) |*candidate| {
        if (!isTracked(candidate)) continue;

        var count: usize = 0;
        var arrival_ms: win32.Ticks = .{};
        for (painter.thumbnails.items) |*other| {
            if (!isTracked(other)) continue;
            if (!std.mem.eql(u8, other.system_name, candidate.system_name)) continue;
            count += 1;
            if (other.travel.last_jump_ms.ms > arrival_ms.ms) arrival_ms = other.travel.last_jump_ms;
        }

        if (count > group_count) {
            group_count = count;
            group_system = candidate.system_name;
            group_arrival_ms = arrival_ms;
        }
    }
    if (group_count == 0) return;

    const required: usize = switch (cfg.threshold_mode) {
        .percent => @intFromFloat(@ceil(cfg.threshold_percent / 100.0 * @as(f32, @floatFromInt(eligible_count)))),
        .count => cfg.threshold_count,
    };
    if (group_count < required) return;

    const window_ms: u64 = @as(u64, cfg.window_seconds) * 1000;
    if (now.elapsedSince(group_arrival_ms) < window_ms) return;

    for (painter.thumbnails.items) |*thumb| {
        if (!isTracked(thumb)) continue;
        if (std.mem.eql(u8, thumb.system_name, group_system)) continue;
        if (thumb.travel.alert_fired) continue;

        thumb.travel.alert_fired = true;
        painter.notify(thumb.source_hwnd, .{ .ntype = .TravelLeftBehind, .source = thumb.system_name, .target = group_system });
    }
}

/// Only characters that have jumped this session and aren't excluded from cycling count toward, or get, the alert.
fn isTracked(thumbnail: *const ThumbnailWindow) bool {
    return !thumbnail.travel.last_jump_ms.isZero() and !exclusions.isExcluded(thumbnail.character_name);
}
