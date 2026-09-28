//! Patches the dialog's unsaved edits into the running config; ProfileStore.discard undoes them if it closes unsaved.
const std = @import("std");
const config_mod = @import("../config.zig");
const notification_mod = @import("../notifications/notification.zig");
const wire = @import("wire.zig");
const log = @import("../log.zig");

const slog = log.scoped("config");
const Config = config_mod.Config;

/// Sections the dialog sends under their own key beside the thumbnail fields.
const sections = .{ "display", "combat", "mining", "bounty", "resources" };

pub const Applied = struct {
    /// Display settings changed, so thumbnails need repositioning as well as repainting.
    layout: bool = false,
};

/// `json_data` is a patch of thumbnail settings, carrying the other previewed sections and lists as extra keys.
pub fn apply(cfg: *Config, allocator: std.mem.Allocator, json_data: []const u8) !Applied {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_data, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJsonFormat;
    const obj = parsed.value.object;

    try wire.applyPatch(config_mod.ThumbnailConfig, &cfg.thumbnail, obj, allocator);
    cfg.thumbnail.validate();

    var applied: Applied = .{};
    inline for (sections) |key| {
        if (obj.get(key)) |value| {
            if (value == .object) {
                const section = &@field(cfg, key);
                wire.applyPatch(@TypeOf(section.*), section, value.object, allocator) catch |err| {
                    slog.err("Failed to apply " ++ key ++ " preview: {}", .{err});
                };
                section.validate();
                if (comptime std.mem.eql(u8, key, "display")) applied.layout = true;
            }
        }
    }

    if (obj.get("systemColors")) |value| {
        if (value == .array) {
            replaceSystemColors(cfg, allocator, value.array.items) catch |err| {
                slog.err("Failed to apply system color overrides preview: {}", .{err});
            };
        }
    }

    if (obj.get("hotkeyGroupBadges")) |value| {
        if (value == .array) applyGroupBadges(cfg, value.array.items);
    }

    if (obj.get("characterOverrides")) |value| {
        if (value == .array) {
            applyCharacterOverrides(cfg, allocator, value.array.items) catch |err| {
                slog.err("Failed to apply character overrides preview: {}", .{err});
            };
        }
    }

    return applied;
}

/// Replaces the whole list, keeping the old one if any entry fails to parse.
fn replaceSystemColors(cfg: *Config, allocator: std.mem.Allocator, colors: []const std.json.Value) !void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    var new_list: std.ArrayList(config_mod.SystemColorConfig) = .empty;
    errdefer wire.freeList(config_mod.SystemColorConfig, &new_list, allocator);
    try new_list.ensureTotalCapacity(allocator, colors.len);
    for (colors) |value| {
        if (value != .object) continue;
        const saved = try std.json.parseFromValueLeaky(config_mod.SystemColorConfig.Wire, scratch.allocator(), value, .{ .ignore_unknown_fields = true });
        new_list.appendAssumeCapacity(try wire.decode(config_mod.SystemColorConfig, saved, allocator));
    }

    wire.freeList(config_mod.SystemColorConfig, &cfg.systemColors, allocator);
    cfg.systemColors = new_list;
}

/// Matched by index, so a group added or removed in the dialog skips the preview until Save reloads the profile.
fn applyGroupBadges(cfg: *Config, flags: []const std.json.Value) void {
    if (flags.len != cfg.hotkeyGroups.items.len) return;
    for (flags, 0..) |flag, i| {
        if (flag != .bool) continue;
        cfg.hotkeyGroups.items[i].showBadge = flag.bool;
    }
}

/// Matched by name; an unsaved "Populate from Open Clients" character gets a live entry to preview against, which a discard removes again.
fn applyCharacterOverrides(cfg: *Config, allocator: std.mem.Allocator, overrides: []const std.json.Value) !void {
    for (overrides) |item| {
        if (item != .object) continue;
        const name = item.object.get("name") orelse continue;
        if (name != .string) continue;
        const char = cfg.getOrCreateCharacter(allocator, name.string) catch |err| {
            slog.err("Failed to create live-preview entry for character '{s}': {}", .{ name.string, err });
            continue;
        };
        try wire.applyPatch(config_mod.CharacterConfig, char, item.object, allocator);
        char.validate();
    }
}

pub const TestNotification = struct {
    ntype: notification_mod.NotificationType,
    /// Owned; free with `deinit`.
    config: config_mod.NotificationTypeConfig,

    pub fn deinit(self: *TestNotification, allocator: std.mem.Allocator) void {
        wire.free(config_mod.NotificationTypeConfig, &self.config, allocator);
    }
};

/// Parses the dialog's Test button request, `{type, config}`, where `config` holds that type's unsaved settings.
pub fn parseTestNotification(allocator: std.mem.Allocator, json_data: []const u8) !TestNotification {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_data, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJsonFormat;
    const obj = parsed.value.object;

    const type_name = switch (obj.get("type") orelse return error.MissingNotificationType) {
        .string => |s| s,
        else => return error.InvalidJsonFormat,
    };
    const config_obj = switch (obj.get("config") orelse return error.InvalidJsonFormat) {
        .object => |o| o,
        else => return error.InvalidJsonFormat,
    };
    const ntype = std.meta.stringToEnum(notification_mod.NotificationType, type_name) orelse {
        slog.warn("Unknown notification type in test request: {s}", .{type_name});
        return error.InvalidNotificationType;
    };

    var type_config: config_mod.NotificationTypeConfig = .{};
    errdefer wire.free(config_mod.NotificationTypeConfig, &type_config, allocator);
    try wire.applyPatch(config_mod.NotificationTypeConfig, &type_config, config_obj, allocator);
    return .{ .ntype = ntype, .config = type_config };
}
