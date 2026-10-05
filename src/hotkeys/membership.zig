//! Changes to cycle exclusions and hotkey-group membership.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const input = @import("../thumbnail/input.zig");
const animation = @import("../clients/animation.zig");
const scout = @import("../clients/scout.zig");
const HotkeyManager = @import("manager.zig").HotkeyManager;
const log = @import("../log.zig");

const slog = log.scoped("hotkeys");

/// Toggles a client in/out of cycling, with visual feedback via a semi-transparent overlay.
pub fn toggleThumbnailExclusion(manager: *HotkeyManager, source_hwnd: win32.HWND) void {
    const thumbnail = manager.painter.getThumbnailBySourceHwnd(source_hwnd) orelse return;
    const char_name = thumbnail.character_name;

    // Exclusions are by name, and every login-screen window shares "EVE", so one toggle would hit them all.
    if (scout.isGenericCharacterName(char_name)) {
        slog.debug("Ignoring exclusion toggle for a login-screen client", .{});
        return;
    }

    _ = manager.exclusions.toggle(char_name) catch |err| {
        slog.err("Failed to toggle exclusion for '{s}': {}", .{ char_name, err });
        return;
    };
    // The excluded list's order changed, so its cycle position no longer means anything.
    manager.cycle.excluded_index = null;
    manager.painter.refreshExclusion(thumbnail);

    if (thumbnail.is_excluded_from_cycle and manager.live().exclusion.autoMinimizeExcluded) {
        animation.showClient(manager.live(), source_hwnd, win32.SW_FORCEMINIMIZE);
    }

    manager.painter.notify(source_hwnd, .{ .ntype = .CycleExclusion, .state = if (thumbnail.is_excluded_from_cycle) .excluded else .included });

    manager.painter.renderThumbnail(thumbnail) catch |err| {
        slog.err("Failed to render thumbnail after exclusion toggle: {}", .{err});
    };

    slog.info("Toggled cycle exclusion for {s}: {s}", .{
        char_name,
        if (thumbnail.is_excluded_from_cycle) "Excluded" else "Included",
    });
}

pub fn clearLoggedOutExclusion(manager: *HotkeyManager, character_name: []const u8) void {
    if (!manager.exclusions.remove(character_name)) return;
    manager.cycle.excluded_index = null;
    slog.info("Cleared cycle exclusion for {s} on logout", .{character_name});
}

/// Toggle the thumbnail currently under the cursor in/out of a group; no-op if nothing's hovered.
pub fn assignHoveredToGroup(manager: *HotkeyManager, group_index: usize) void {
    if (group_index >= manager.config.hotkeyGroups.items.len) {
        slog.err("Failed to assign to group: index {} is out of range", .{group_index});
        return;
    }

    const thumbnail = input.resolveThumbnailUnderCursor() orelse {
        slog.debug("Group {} assign pressed but no thumbnail is under the cursor", .{group_index});
        return;
    };

    const group = &manager.config.hotkeyGroups.items[group_index];
    const char_name = thumbnail.character_name;

    const added = manager.store.toggleGroupMember(group_index, char_name) catch |err| {
        slog.err("Failed to toggle '{s}' in group {} [{s}]: {}", .{ char_name, group_index, group.name, err });
        return;
    };
    if (added) {
        slog.info("Added {s} to group {} [{s}]", .{ char_name, group_index, group.name });
    } else {
        slog.info("Removed {s} from group {} [{s}]", .{ char_name, group_index, group.name });
    }

    // Membership changed - old index may now point at a shifted member
    manager.cycle.group_cursors[group_index] = null;

    // Before the reflow, so the reflow's render already has the new label.
    manager.painter.refreshGroupBadge(thumbnail);
    // Group membership only feeds RegionFit's display order under HotkeyGroups ordering; reflowing under Characters ordering would be a no-op.
    if (manager.live().display.regionFitOrder == .HotkeyGroups) manager.painter.reflowIfRegionFitActive();
    manager.painter.renderThumbnail(thumbnail) catch |err| {
        slog.err("Failed to render thumbnail after group assignment: {}", .{err});
    };

    var group_label_buf: [40]u8 = undefined;
    const group_label = if (group.name.len > 0)
        group.name
    else
        std.mem.print(&group_label_buf, "Hotkey Group {}", .{group_index + 1}) catch unreachable;
    manager.painter.notify(thumbnail.source_hwnd, .{ .ntype = .GroupMembership, .state = if (added) .added else .removed, .target = group_label });
}
