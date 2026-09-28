const std = @import("std");
const config_mod = @import("../config.zig");
const main_mod = @import("../main.zig");
const log = @import("../log.zig");
const slog = log.scoped("hotkeys");
const cycling = @import("cycling.zig");
const strings = @import("../util/strings.zig");

pub fn cycle(allocator: std.mem.Allocator, current_profile: []const u8, forward: bool) void {
    slog.info("{s} profile hotkey pressed", .{if (forward) "Next" else "Previous"});

    var profiles = config_mod.listProfiles(allocator) catch |err| {
        slog.err("Failed to enumerate profiles: {}", .{err});
        return;
    };
    defer {
        for (profiles.items) |profile| {
            allocator.free(profile);
        }
        profiles.deinit(allocator);
    }

    if (profiles.items.len == 0) {
        slog.warn("No profiles found to cycle through", .{});
        return;
    }

    const current_index = strings.indexOfString(profiles.items, current_profile);
    var order = cycling.CycleOrder.init(current_index, profiles.items.len, forward);
    const target_profile = profiles.items[order.next().?];
    slog.info("Cycling to {s} profile: {s} -> {s}", .{ if (forward) "next" else "previous", current_profile, target_profile });
    main_mod.requestProfileSwitch(target_profile);
}

pub fn switchTo(gs: *const config_mod.GlobalConfig, current_profile: []const u8, profile_index: usize) void {
    if (profile_index >= gs.profileSwitchHotkeys.items.len) {
        slog.err("Invalid profile switch index {}", .{profile_index});
        return;
    }

    const target_profile = gs.profileSwitchHotkeys.items[profile_index].targetProfile;
    slog.info("Switch to profile hotkey pressed: {s} -> {s}", .{ current_profile, target_profile });
    main_mod.requestProfileSwitch(target_profile);
}
