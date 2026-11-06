//! The profile the next- and previous-profile hotkeys switch to.
const std = @import("std");
const config = @import("../config.zig");
const cycle_order = @import("cycle_order.zig");
const strings = @import("../util/strings.zig");
const log = @import("../log.zig");

const slog = log.Scoped("hotkeys");

/// The profile after or before `current_profile` in the profiles folder, wrapping; null, logged, when there's none; owned by the caller.
pub fn cycleTarget(allocator: std.mem.Allocator, io: std.Io, current_profile: []const u8, is_forward: bool) ?[]const u8 {
    slog.info("{s} profile hotkey pressed", .{if (is_forward) "Next" else "Previous"});

    var profiles = config.listProfiles(allocator, io) catch |err| {
        slog.err("Failed to enumerate profiles: {}", .{err});
        return null;
    };
    defer {
        for (profiles.items) |profile| allocator.free(profile);
        profiles.deinit(allocator);
    }

    if (profiles.items.len == 0) {
        slog.warn("No profiles found to cycle through", .{});
        return null;
    }

    const current_index = strings.indexOfString(profiles.items, current_profile);
    var order = cycle_order.CycleOrder.init(current_index, profiles.items.len, .{ .is_forward = is_forward });
    const target_profile = profiles.items[order.next().?];
    slog.info("Cycling to {s} profile: {s} -> {s}", .{ if (is_forward) "next" else "previous", current_profile, target_profile });
    return allocator.dupe(u8, target_profile) catch |err| {
        slog.err("Failed to switch to profile '{s}': {}", .{ target_profile, err });
        return null;
    };
}
