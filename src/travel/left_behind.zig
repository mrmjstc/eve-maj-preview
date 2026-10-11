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
    last_jump: win32.Ticks = .{},
    /// Guards the left-behind alert to one per episode; cleared on jump.
    alert_fired: bool = false,

    pub fn recordJump(self: *LeftBehindState) void {
        self.last_jump = win32.Ticks.now();
        self.alert_fired = false;
    }
};

/// Flags characters behind the group's current system by more than config.travel.window_seconds.
pub fn check(painter: *Painter, now: win32.Ticks) void {
    const travel = painter.config.travel;
    if (!travel.enabled) return;

    var eligible_count: usize = 0;
    for (painter.thumbnails.items) |*thumbnail| {
        if (!isTracked(thumbnail)) continue;
        eligible_count += 1;
    }
    if (eligible_count < 2) return;

    var group_system: []const u8 = "";
    var group_count: usize = 0;
    var group_arrival: win32.Ticks = .{};

    for (painter.thumbnails.items) |*candidate| {
        if (!isTracked(candidate)) continue;

        var same_system_count: usize = 0;
        var arrival: win32.Ticks = .{};
        for (painter.thumbnails.items) |*other| {
            if (!isTracked(other)) continue;
            if (!std.mem.eql(u8, other.system_name, candidate.system_name)) continue;
            same_system_count += 1;
            if (other.travel.last_jump.ms > arrival.ms) arrival = other.travel.last_jump;
        }

        if (same_system_count > group_count) {
            group_count = same_system_count;
            group_system = candidate.system_name;
            group_arrival = arrival;
        }
    }

    const required_count: usize = switch (travel.threshold_mode) {
        .percent => @intFromFloat(@ceil(travel.threshold_percent / 100.0 * @as(f32, @floatFromInt(eligible_count)))),
        .count => travel.threshold_count,
    };
    if (group_count < required_count) return;

    const window_ms: u64 = @as(u64, travel.window_seconds) * std.time.ms_per_s;
    if (now.elapsedSince(group_arrival) < window_ms) return;

    for (painter.thumbnails.items) |*thumbnail| {
        if (!isTracked(thumbnail)) continue;
        if (std.mem.eql(u8, thumbnail.system_name, group_system)) continue;
        if (thumbnail.travel.alert_fired) continue;

        thumbnail.travel.alert_fired = true;
        painter.notify(thumbnail.source_hwnd, .{ .notification_type = .TravelLeftBehind, .source = thumbnail.system_name, .target = group_system });
    }
}

/// Only characters that have jumped this session and aren't excluded from cycling count toward, or get, the alert.
fn isTracked(thumbnail: *const ThumbnailWindow) bool {
    return !thumbnail.travel.last_jump.isZero() and !exclusions.isExcluded(thumbnail.character_name);
}
