//! The travel check that alerts characters left behind in another system when the group moves on.
const win32 = @import("../platform/win32.zig");
const set = @import("../thumbnail/set.zig");
const exclusions_mod = @import("../clients/exclusions.zig");
const stragglers = @import("stragglers.zig");
const log = @import("../log.zig");

const ThumbnailSet = set.ThumbnailSet;
const Exclusions = exclusions_mod.Exclusions;
const slog = log.Scoped("left_behind");

/// Flags characters behind the group's current system by more than config.travel.window_seconds.
pub fn check(thumbnail_set: *ThumbnailSet, exclusions: *const Exclusions, now: win32.Ticks) void {
    const travel = &thumbnail_set.config.travel;
    if (!travel.enabled) return;

    const allocator = thumbnail_set.allocator;
    const travelers = allocator.alloc(stragglers.Traveler, thumbnail_set.thumbnails.items.len) catch |err| {
        slog.warn("Failed to check for characters left behind: {}", .{err});
        return;
    };
    defer allocator.free(travelers);
    for (thumbnail_set.thumbnails.items, travelers) |*thumbnail, *traveler| {
        traveler.* = .{
            .system_name = thumbnail.system_name,
            .last_jump_ms = thumbnail.travel.last_jump.ms,
            .is_excluded = exclusions.contains(thumbnail.character_name),
        };
    }

    const group_system = stragglers.groupSystem(travel, travelers, now.ms) orelse return;
    for (thumbnail_set.thumbnails.items, travelers) |*thumbnail, traveler| {
        if (!stragglers.isLeftBehind(traveler, group_system) or thumbnail.travel.alert_fired) continue;
        thumbnail.travel.alert_fired = true;
        thumbnail_set.notify(thumbnail.source_hwnd, .{ .notification_type = .TravelLeftBehind, .source = thumbnail.system_name, .target = group_system });
    }
}
