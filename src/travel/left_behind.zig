//! The travel check that alerts characters left behind in another system when the group moves on.
const win32 = @import("../platform/win32.zig");
const set = @import("../thumbnail/set.zig");
const roster_mod = @import("../clients/roster.zig");
const exclusions_mod = @import("../clients/exclusions.zig");
const stragglers = @import("stragglers.zig");
const log = @import("../log.zig");

const ThumbnailSet = set.ThumbnailSet;
const Roster = roster_mod.Roster;
const Exclusions = exclusions_mod.Exclusions;
const slog = log.Scoped("left_behind");

/// Flags characters behind the group's current system by more than config.travel.window_seconds; alerts through `thumbnail_set`.
pub fn check(thumbnail_set: *ThumbnailSet, roster: *Roster, exclusions: *const Exclusions, now: win32.Ticks) void {
    const travel = &thumbnail_set.config.travel;
    if (!travel.enabled) return;

    const allocator = thumbnail_set.allocator;
    const clients = roster.clients.items;
    const travelers = allocator.alloc(stragglers.Traveler, clients.len) catch |err| {
        slog.warn("Failed to check for characters left behind: {}", .{err});
        return;
    };
    defer allocator.free(travelers);
    for (clients, travelers) |*client, *traveler| {
        traveler.* = .{
            .system_name = client.system_name,
            .last_jump_ms = client.travel.last_jump_ms,
            .is_excluded = exclusions.contains(client.character_name),
        };
    }

    const group_system = stragglers.groupSystem(travel, travelers, now.ms) orelse return;
    for (clients, travelers) |*client, traveler| {
        if (!stragglers.isLeftBehind(traveler, group_system) or client.travel.alert_fired) continue;
        client.travel.alert_fired = true;
        thumbnail_set.notify(client.hwnd, .{ .notification_type = .TravelLeftBehind, .source = client.system_name, .target = group_system });
    }
}
