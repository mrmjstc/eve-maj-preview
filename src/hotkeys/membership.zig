const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const strings = @import("../util/strings.zig");
const input = @import("../input.zig");
const protocol = @import("../protocol.zig");
const log = @import("../log.zig");
const slog = log.scoped("hotkeys");
const HotkeyManager = @import("manager.zig").HotkeyManager;

/// Toggles name's membership in list: removes+frees if present (returns false), else dupes+appends (returns true).
fn toggleStringMembership(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), name: []const u8) !bool {
    if (strings.indexOfString(list.items, name)) |index| {
        const removed = list.orderedRemove(index);
        allocator.free(removed);
        return false;
    }
    const duped = try allocator.dupe(u8, name);
    errdefer allocator.free(duped);
    try list.append(allocator, duped);
    return true;
}

fn freeNames(allocator: std.mem.Allocator, names: *std.ArrayList([]const u8)) void {
    for (names.items) |name| allocator.free(name);
    names.deinit(allocator);
}

/// Per-group lists plus a manual fallback for characters in no group; never saved, so a profile reload resets them.
pub const Exclusions = struct {
    /// One list per hotkey group, in config.hotkeyGroups order; the group count can't change without a reload.
    per_group: []std.ArrayList([]const u8),
    /// Shift-click-excluded characters that belong to no hotkey group.
    manual: std.ArrayList([]const u8) = .empty,
    /// Deduplicated union of every group's exclusion list and `manual`. Elements borrow from those lists, so only the backing array is owned here. Rebuilt only when `signature` detects a change.
    cache: std.ArrayList([]const u8) = .empty,
    cache_signature: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator, group_count: usize) !Exclusions {
        const per_group = try allocator.alloc(std.ArrayList([]const u8), group_count);
        @memset(per_group, .empty);
        return .{ .per_group = per_group };
    }

    pub fn deinit(self: *Exclusions, allocator: std.mem.Allocator) void {
        for (self.per_group) |*names| freeNames(allocator, names);
        allocator.free(self.per_group);
        freeNames(allocator, &self.manual);
        self.cache.deinit(allocator);
    }

    pub fn isExcludedInGroup(self: *const Exclusions, group_index: usize, character_name: []const u8) bool {
        return strings.indexOfString(self.per_group[group_index].items, character_name) != null;
    }

    pub fn contains(self: *const Exclusions, config: *const config_mod.Config, character_name: []const u8) bool {
        if (strings.indexOfString(self.manual.items, character_name) != null) return true;

        for (config.hotkeyGroups.items, 0..) |*group, i| {
            const in_group = strings.indexOfString(group.characters.items, character_name) != null;
            if (in_group and self.isExcludedInGroup(i, character_name)) return true;
        }
        return false;
    }

    /// Toggles exclusion in every group containing the character; characters in no group fall back to `manual`.
    pub fn toggle(self: *Exclusions, allocator: std.mem.Allocator, config: *const config_mod.Config, character_name: []const u8) void {
        var found_in_group = false;

        for (config.hotkeyGroups.items, 0..) |*group, i| {
            if (strings.indexOfString(group.characters.items, character_name) == null) continue;
            found_in_group = true;

            const added = toggleStringMembership(allocator, &self.per_group[i], character_name) catch {
                slog.err("Failed to toggle exclusion for {s}", .{character_name});
                return;
            };
            if (added) {
                slog.debug("Added {s} to exclusion list", .{character_name});
            } else {
                slog.debug("Removed {s} from exclusion list", .{character_name});
            }
        }

        if (!found_in_group) self.toggleManual(allocator, character_name);
    }

    fn toggleManual(self: *Exclusions, allocator: std.mem.Allocator, character_name: []const u8) void {
        const added = toggleStringMembership(allocator, &self.manual, character_name) catch {
            slog.err("Failed to toggle manual exclusion for {s}", .{character_name});
            return;
        };
        if (added) {
            slog.debug("Added {s} to manual exclusion list", .{character_name});
        } else {
            slog.debug("Removed {s} from manual exclusion list", .{character_name});
        }
    }

    /// Every excluded character, deduplicated, in the order they were added; shared so cycleExcluded and the focus sync agree.
    pub fn list(self: *Exclusions, allocator: std.mem.Allocator) *const std.ArrayList([]const u8) {
        const sig = self.signature();
        if (self.cache_signature == null or self.cache_signature.? != sig) {
            self.cache.clearRetainingCapacity();

            var seen = std.StringHashMap(void).init(allocator);
            defer seen.deinit();

            for (self.per_group) |names| self.appendUnseenNames(allocator, &seen, names.items);
            self.appendUnseenNames(allocator, &seen, self.manual.items);

            self.cache_signature = sig;
        }
        return &self.cache;
    }

    fn appendUnseenNames(self: *Exclusions, allocator: std.mem.Allocator, seen: *std.StringHashMap(void), names: []const []const u8) void {
        for (names) |excluded_name| {
            const result = seen.getOrPut(excluded_name) catch {
                slog.err("Failed to allocate memory for seen map", .{});
                continue;
            };
            if (!result.found_existing) {
                self.cache.append(allocator, excluded_name) catch {
                    slog.err("Failed to add excluded character to list", .{});
                    continue;
                };
            }
        }
    }

    /// Each name is length-prefixed so moving a name across a group boundary can't leave the concatenated byte stream unchanged.
    fn signature(self: *const Exclusions) u64 {
        var h = std.hash.Wyhash.init(0);
        for (self.per_group) |names| {
            for (names.items) |name| {
                h.update(std.mem.asBytes(&@as(u32, @intCast(name.len))));
                h.update(name);
            }
        }
        for (self.manual.items) |name| {
            h.update(std.mem.asBytes(&@as(u32, @intCast(name.len))));
            h.update(name);
        }
        return h.final();
    }
};

/// Toggles a client in/out of cycling, with visual feedback via a semi-transparent overlay.
pub fn toggleThumbnailExclusion(m: *HotkeyManager, source_hwnd: win32.HWND) void {
    const thumbnail = m.painter.getThumbnailBySourceHwnd(source_hwnd) orelse return;
    const char_name = thumbnail.character_name;

    m.exclusions.toggle(m.allocator, m.config, char_name);
    // The excluded list's order changed, so its cycle position no longer means anything.
    m.cycle.excluded_index = null;
    thumbnail.is_excluded_from_cycle = m.exclusions.contains(m.config, char_name);

    if (thumbnail.is_excluded_from_cycle and m.config.exclusion.autoMinimizeExcluded) {
        _ = win32.ShowWindowAsync(source_hwnd, win32.SW_FORCEMINIMIZE);
    }

    m.painter.notify(source_hwnd, .{ .ntype = .CycleExclusion, .state = if (thumbnail.is_excluded_from_cycle) .excluded else .included });

    m.painter.renderThumbnail(thumbnail) catch |err| {
        slog.err("Failed to render thumbnail after exclusion toggle: {}", .{err});
    };

    slog.info("Toggled cycle exclusion for {s}: {s}", .{
        char_name,
        if (thumbnail.is_excluded_from_cycle) "Excluded" else "Included",
    });
}

/// Toggle the thumbnail currently under the cursor in/out of a group; no-op if nothing's hovered.
pub fn assignHoveredToGroup(m: *HotkeyManager, group_index: usize) void {
    if (group_index >= m.config.hotkeyGroups.items.len) {
        slog.err("Invalid group index {}", .{group_index});
        return;
    }

    const thumbnail = input.resolveThumbnailUnderCursor() orelse {
        slog.debug("Group {} assign pressed but no thumbnail is under the cursor", .{group_index});
        return;
    };

    const group = &m.config.hotkeyGroups.items[group_index];
    const char_name = thumbnail.character_name;

    const added = toggleStringMembership(m.allocator, &group.characters, char_name) catch {
        slog.err("Failed to toggle {s} in group {} [{s}]", .{ char_name, group_index, group.name });
        return;
    };
    if (added) {
        slog.info("Added {s} to group {} [{s}]", .{ char_name, group_index, group.name });
    } else {
        slog.info("Removed {s} from group {} [{s}]", .{ char_name, group_index, group.name });
    }

    // Membership changed - old index may now point at a shifted member
    m.cycle.group_cursors[group_index] = null;

    if (!group.temporaryMembership) {
        if (m.config.saveCurrentProfile(m.allocator)) {
            protocol.bumpGroupMembershipRevision();
        } else |err| {
            slog.err("Failed to save group {} [{s}] membership: {}", .{ group_index, group.name, err });
        }
    }

    // Badge must be refreshed before the reflow below, so its own render pass bakes in the new label instead of the reflow drawing it once with the stale one and renderThumbnail below redrawing it again.
    m.painter.refreshGroupBadge(thumbnail);
    // Group membership only feeds RegionFit's display order under HotkeyGroups ordering; reflowing under Characters ordering would be a no-op.
    if (m.config.display.regionFitOrder == .HotkeyGroups) m.painter.reflowIfRegionFitActive();
    m.painter.renderThumbnail(thumbnail) catch |err| {
        slog.err("Failed to render thumbnail after group assignment: {}", .{err});
    };

    var group_label_buf: [40]u8 = undefined;
    const group_label = if (group.name.len > 0)
        group.name
    else
        std.fmt.bufPrint(&group_label_buf, "Hotkey Group {}", .{group_index + 1}) catch unreachable;
    m.painter.notify(thumbnail.source_hwnd, .{ .ntype = .GroupMembership, .state = if (added) .added else .removed, .target = group_label });
}
