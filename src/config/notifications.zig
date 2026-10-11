//! Notification popups: shared appearance and each type's own settings.
const std = @import("std");
const types = @import("types.zig");
const notification = @import("../notifications/notification.zig");
const wire = @import("wire.zig");
const ranges_mod = @import("ranges.zig");

pub const NotificationTypeConfig = struct {
    enabled: bool = true,
    duration_ms: u32 = 10000,
    suppress_when_focused: bool = false,
    suppress_when_clicked: bool = false,
    throttle_ms: u32 = 10000,
    border_color: ?u32 = null,
    text_color: ?u32 = null,
    show_border: bool = false,
    flash_border: bool = false,
    tts_enabled: bool = false,
    sound_enabled: bool = false,
    sound_path: ?[]const u8 = null,
    sound_volume: u8 = 100,
    /// Null uses the type's default wording.
    custom_text: ?[]const u8 = null,
    /// custom_text for the type's second state (see notification.altState).
    custom_text_alt: ?[]const u8 = null,

    pub fn customText(self: *const NotificationTypeConfig) notification.CustomText {
        return .{ .primary = self.custom_text, .alt = self.custom_text_alt };
    }

    pub fn defaultFor(notification_type: notification.NotificationType) NotificationTypeConfig {
        return if (notification.isUserAction(notification_type)) .{ .duration_ms = 3000, .throttle_ms = 0 } else .{};
    }

    /// A const, not a fn: evaluated once instead of per comptime Wire field default, which exceeded the branch quota.
    pub const defaults_by_type = blk: {
        var map = std.enums.EnumArray(notification.NotificationType, NotificationTypeConfig).initFill(.{});
        for (std.enums.values(notification.NotificationType)) |notification_type| map.set(notification_type, defaultFor(notification_type));
        break :blk map;
    };

    pub const ranges = .{
        .duration_ms = .{ 0, 60000 },
        .throttle_ms = .{ 0, 300000 },
        .sound_volume = ranges_mod.PERCENT,
    };

    pub fn validate(self: *NotificationTypeConfig) void {
        ranges_mod.clamp(NotificationTypeConfig, self);
    }

    pub const Wire = wire.Wire(NotificationTypeConfig);
};

/// Each notification type's settings, defaulting to that type's own defaults (see NotificationTypeConfig.defaultFor).
pub const NotificationTypeConfigs = struct {
    const Map = std.enums.EnumArray(notification.NotificationType, NotificationTypeConfig);

    map: Map = NotificationTypeConfig.defaults_by_type,

    pub fn get(self: *const NotificationTypeConfigs, notification_type: notification.NotificationType) NotificationTypeConfig {
        return self.map.get(notification_type);
    }

    pub fn set(self: *NotificationTypeConfigs, notification_type: notification.NotificationType, value: NotificationTypeConfig) void {
        self.map.set(notification_type, value);
    }

    pub fn iterator(self: *NotificationTypeConfigs) Map.Iterator {
        return self.map.iterator();
    }

    pub fn validate(self: *NotificationTypeConfigs) void {
        for (&self.map.values) |*type_config| type_config.validate();
    }

    pub fn deinit(self: *NotificationTypeConfigs, allocator: std.mem.Allocator) void {
        for (&self.map.values) |*type_config| wire.free(NotificationTypeConfig, type_config, allocator);
    }

    pub fn clone(self: *const NotificationTypeConfigs, allocator: std.mem.Allocator) !NotificationTypeConfigs {
        var out: NotificationTypeConfigs = .{};
        errdefer out.deinit(allocator);
        for (&out.map.values, self.map.values) |*destination, source| destination.* = try wire.clone(NotificationTypeConfig, source, allocator);
        return out;
    }

    pub const Wire = struct {
        map: std.enums.EnumArray(notification.NotificationType, NotificationTypeConfig.Wire) = default_wire_map,

        const default_wire_map = blk: {
            @setEvalBranchQuota(10_000_000);
            var map = std.enums.EnumArray(notification.NotificationType, NotificationTypeConfig.Wire).initFill(.{});
            for (std.enums.values(notification.NotificationType)) |notification_type| map.set(notification_type, wire.encode(NotificationTypeConfig, NotificationTypeConfig.defaults_by_type.get(notification_type)));
            break :blk map;
        };

        pub fn jsonStringify(self: Wire, json_writer: anytype) !void {
            try json_writer.beginObject();
            inline for (@typeInfo(notification.NotificationType).@"enum".field_names) |name| {
                try json_writer.objectField(name);
                try json_writer.write(self.map.get(@field(notification.NotificationType, name)));
            }
            try json_writer.endObject();
        }

        /// Lets wire.parse check each type's settings on their own, so one bad value doesn't reset every type.
        pub const MapValue = NotificationTypeConfig.Wire;

        pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Wire {
            var result: Wire = .{};
            if (source != .object) return result;
            var it = source.object.iterator();
            while (it.next()) |entry| {
                const notification_type = std.meta.stringToEnum(notification.NotificationType, entry.key_ptr.*) orelse continue;
                const type_wire = try std.json.parseFromValue(NotificationTypeConfig.Wire, allocator, entry.value_ptr.*, options);
                defer type_wire.deinit();
                var wire_value = type_wire.value;
                // type_wire's arena is freed by the defer above, so its strings must be re-duped.
                if (wire_value.sound_path) |sound_path| wire_value.sound_path = try allocator.dupe(u8, sound_path);
                if (wire_value.custom_text) |custom_text| wire_value.custom_text = try allocator.dupe(u8, custom_text);
                if (wire_value.custom_text_alt) |custom_text_alt| wire_value.custom_text_alt = try allocator.dupe(u8, custom_text_alt);
                result.map.set(notification_type, wire_value);
            }
            return result;
        }
    };

    pub fn toWire(self: *const NotificationTypeConfigs) Wire {
        var out: Wire = .{};
        inline for (@typeInfo(notification.NotificationType).@"enum".field_names) |name| {
            const notification_type = @field(notification.NotificationType, name);
            out.map.set(notification_type, wire.encode(NotificationTypeConfig, self.map.get(notification_type)));
        }
        return out;
    }

    pub fn fromWire(encoded: Wire, allocator: std.mem.Allocator) !NotificationTypeConfigs {
        var out: NotificationTypeConfigs = .{};
        errdefer out.deinit(allocator);
        inline for (@typeInfo(notification.NotificationType).@"enum".field_names) |name| {
            const notification_type = @field(notification.NotificationType, name);
            out.map.set(notification_type, try wire.decode(NotificationTypeConfig, encoded.map.get(notification_type), allocator));
        }
        return out;
    }

    /// One type's settings by name, so an edit path can reach them (see config/patch.zig).
    pub fn childAt(self: *NotificationTypeConfigs, key: []const u8) ?*NotificationTypeConfig {
        const notification_type = std.meta.stringToEnum(notification.NotificationType, key) orelse return null;
        return self.map.getPtr(notification_type);
    }

    pub fn childAtConst(self: *const NotificationTypeConfigs, key: []const u8) ?*const NotificationTypeConfig {
        const notification_type = std.meta.stringToEnum(notification.NotificationType, key) orelse return null;
        return self.map.getPtrConst(notification_type);
    }
};

pub const NotificationConfig = struct {
    enabled: bool = true,
    position: types.TextPosition = .Center,
    offset_x: i32 = 0,
    offset_y: i32 = 0,
    font_name: []const u8 = "Segoe UI",
    font_size: i32 = 12,
    font_weight: types.FontWeight = .Regular,
    /// A type without a text colour of its own uses this.
    color: u32 = 0xFFFFFFFF,
    bg_color: u32 = 0xE6000000,

    suppress_click_duration_ms: u32 = 2000,

    tts_volume: u8 = 100,
    tts_rate: i8 = 0,
    tts_speak_character_name: bool = true,
    tts_use_display_name: bool = false,

    notified_cycle_retention_seconds: u32 = 30,

    type_configs: NotificationTypeConfigs = .{},

    pub const ranges = .{
        .offset_x = ranges_mod.TEXT_OFFSET,
        .offset_y = ranges_mod.TEXT_OFFSET,
        .font_size = ranges_mod.FONT_SIZE,
        .suppress_click_duration_ms = .{ 0, 60000 },
        .tts_volume = ranges_mod.PERCENT,
        .tts_rate = .{ -10, 10 },
        .notified_cycle_retention_seconds = .{ 5, 600 },
    };

    pub fn validate(self: *NotificationConfig) void {
        ranges_mod.clamp(NotificationConfig, self);
    }

    pub fn getTypeConfig(self: *const NotificationConfig, notification_type: notification.NotificationType) NotificationTypeConfig {
        return self.type_configs.get(notification_type);
    }

    pub const Wire = wire.Wire(NotificationConfig);
};
