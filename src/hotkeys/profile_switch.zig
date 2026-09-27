const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const tray_mod = @import("../tray.zig");
const main_mod = @import("../main.zig");
const log = @import("../log.zig");
const slog = log.scoped("hotkeys");
const cycling = @import("cycling.zig");
const strings = @import("../util/strings.zig");

// Static since WM_SWITCH_PROFILE is handled asynchronously, after the caller's copy of the name may be freed.
var g_profile_cycle_buffer: [256]u8 = undefined;
var g_profile_switch_buffer: [256]u8 = undefined;

pub fn cycle(allocator: std.mem.Allocator, current_profile: []const u8, forward: bool) void {
    slog.info("{s} profile hotkey pressed", .{if (forward) "Next" else "Previous"});

    var profiles = config_mod.GlobalSettings.enumerateProfiles(allocator) catch |err| {
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
    requestSwitch(&g_profile_cycle_buffer, target_profile);
}

pub fn switchTo(gs: *const config_mod.GlobalSettings, current_profile: []const u8, profile_index: usize) void {
    if (profile_index >= gs.profileSwitchHotkeys.items.len) {
        slog.err("Invalid profile switch index {}", .{profile_index});
        return;
    }

    const target_profile = gs.profileSwitchHotkeys.items[profile_index].targetProfile;
    slog.info("Switch to profile hotkey pressed: {s} -> {s}", .{ current_profile, target_profile });
    requestSwitch(&g_profile_switch_buffer, target_profile);
}

fn requestSwitch(buffer: []u8, target_profile: []const u8) void {
    if (target_profile.len >= buffer.len) {
        slog.err("Profile name too long: {s}", .{target_profile});
        return;
    }
    @memcpy(buffer[0..target_profile.len], target_profile);

    // Safe because it points into static storage; tray.zig's takePendingProfileName() doesn't dupe it.
    tray_mod.g_pending_profile_name = buffer[0..target_profile.len];

    if (main_mod.g_timer_hwnd) |hwnd| {
        _ = win32.PostMessageA(hwnd, win32.WM_SWITCH_PROFILE, 0, 0);
    } else {
        slog.err("Timer window not available for profile switch", .{});
    }
}
