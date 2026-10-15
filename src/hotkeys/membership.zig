//! Changes to cycle exclusions and hotkey-group membership.
const win32 = @import("../platform/win32.zig");
const animation = @import("../clients/animation.zig");
const scout = @import("../clients/scout.zig");
const config = @import("../config.zig");
const manager_mod = @import("manager.zig");
const log = @import("../log.zig");

const HotkeyManager = manager_mod.HotkeyManager;
const slog = log.Scoped("hotkeys");

pub fn toggleThumbnailExclusion(manager: *HotkeyManager, source_hwnd: win32.HWND) void {
    const thumbnail_set = manager.app.thumbnail_set orelse return;
    const thumbnail = thumbnail_set.getThumbnailBySourceHwnd(source_hwnd) orelse return;
    const character_name = thumbnail.character_name;

    // Exclusions are by name, and every login-screen window shares "EVE", so one toggle would hit them all.
    if (scout.isGenericCharacterName(character_name)) {
        slog.debug("Ignoring exclusion toggle for a login-screen client", .{});
        return;
    }

    _ = manager.exclusions.toggle(character_name) catch |err| {
        slog.err("Failed to toggle exclusion for '{s}': {}", .{ character_name, err });
        return;
    };
    // The excluded list's order changed, so its cycle position no longer means anything.
    manager.cycle.excluded_index = null;
    thumbnail_set.refreshExclusion(thumbnail);

    if (thumbnail.is_excluded_from_cycle and manager.live().exclusion.autoMinimizeExcluded) {
        animation.showClient(manager.live(), source_hwnd, win32.SW_FORCEMINIMIZE);
    }

    thumbnail_set.notify(source_hwnd, .{ .notification_type = .CycleExclusion, .state = if (thumbnail.is_excluded_from_cycle) .excluded else .included });

    thumbnail_set.renderThumbnail(thumbnail) catch |err| {
        slog.err("Failed to render thumbnail after exclusion toggle: {}", .{err});
    };

    slog.info("Toggled cycle exclusion for {s}: {s}", .{
        character_name,
        if (thumbnail.is_excluded_from_cycle) "Excluded" else "Included",
    });
}

pub fn clearLoggedOutExclusion(manager: *HotkeyManager, character_name: []const u8) void {
    if (!manager.exclusions.remove(character_name)) return;
    manager.cycle.excluded_index = null;
    slog.info("Cleared cycle exclusion for {s} on logout", .{character_name});
}

/// No-op if nothing's hovered.
pub fn assignHoveredToGroup(manager: *HotkeyManager, group_index: usize) void {
    if (group_index >= manager.config.hotkeyGroups.items.len) {
        slog.err("Failed to assign to group: index {} is out of range", .{group_index});
        return;
    }

    const thumbnail_set = manager.app.thumbnail_set orelse return;
    const thumbnail = thumbnail_set.thumbnailUnderCursor() orelse {
        slog.debug("Group {} assign pressed but no thumbnail is under the cursor", .{group_index});
        return;
    };

    const group = &manager.config.hotkeyGroups.items[group_index];
    const character_name = thumbnail.character_name;

    const added = manager.store.toggleGroupMember(group_index, character_name) catch |err| {
        slog.err("Failed to toggle '{s}' in group {} '{s}': {}", .{ character_name, group_index, group.name, err });
        return;
    };
    if (added) {
        slog.info("Added {s} to group {} [{s}]", .{ character_name, group_index, group.name });
    } else {
        slog.info("Removed {s} from group {} [{s}]", .{ character_name, group_index, group.name });
    }

    // Membership changed - old index may now point at a shifted member
    manager.cycle.group_cursors[group_index] = null;

    // Before the reflow, so the reflow's render already has the new label.
    thumbnail_set.refreshGroupBadge(thumbnail);
    // Membership decides which space a character goes to, and its order there.
    thumbnail_set.reflowIfSpacesActive();
    thumbnail_set.renderThumbnail(thumbnail) catch |err| {
        slog.err("Failed to render thumbnail after group assignment: {}", .{err});
    };

    var group_label_buf: [config.HotkeyGroupConfig.DISPLAY_NAME_SIZE]u8 = undefined;
    const group_label = group.displayName(&group_label_buf, group_index);
    thumbnail_set.notify(thumbnail.source_hwnd, .{ .notification_type = .GroupMembership, .state = if (added) .added else .removed, .target = group_label });
}
