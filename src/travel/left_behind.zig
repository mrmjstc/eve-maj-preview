//! The travel check that alerts characters left behind in another system when the group moves on.
const win32 = @import("../platform/win32.zig");
const exclusions_mod = @import("../clients/exclusions.zig");
const notifier_mod = @import("../notifications/notifier.zig");
const stragglers = @import("stragglers.zig");
const log = @import("../log.zig");

const Exclusions = exclusions_mod.Exclusions;
const Notifier = notifier_mod.Notifier;
const slog = log.Scoped("left_behind");

/// Flags the notifier's clients behind the group's current system by more than config.travel.window_seconds.
pub fn check(notifier: *const Notifier, exclusions: *const Exclusions, now: win32.Ticks) void {
    const travel = &notifier.config.travel;
    if (!travel.enabled) return;

    const allocator = notifier.allocator;
    const clients = notifier.roster.clients.items;
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
        notifier.notify(client.hwnd, .{ .notification_type = .TravelLeftBehind, .source = client.system_name, .target = group_system });
    }
}
