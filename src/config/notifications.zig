//! How alerts behave wherever they show: the master switch, speech, and each type's own settings.
const std = @import("std");
const notification = @import("../notifications/notification.zig");
const wire = @import("wire.zig");
const ranges_mod = @import("ranges.zig");

/// Combat runs on for minutes, so a reminder a minute is enough.
const TAKING_DAMAGE_THROTTLE_MS: u32 = 60_000;

pub const NotificationTypeConfig = struct {
    enabled: bool = true,
    /// Off leaves its border, sound, speech and history entry, for an alert with no words on screen.
    show_text: bool = true,
    duration_ms: u32 = 10000,
    suppress_when_focused: bool = false,
    suppress_when_clicked: bool = false,
    /// Shows a thumbnail hidden by auto-hide or the visibility toggle while this alert is up.
    show_hidden_thumbnail: bool = false,
    throttle_ms: u32 = 10000,
    border_color: ?u32 = null,
    text_color: ?u32 = null,
    /// Chat intel only: draws the system its text starts with in that system's name colour.
    color_system_name: bool = false,
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

    /// Chat alerts have no throttle: it would drop a different message, and each rule has a cooldown instead.
    fn defaultFor(notification_type: notification.NotificationType) NotificationTypeConfig {
        if (notification.isUserAction(notification_type)) return .{ .duration_ms = 3000, .throttle_ms = 0 };
        if (notification_type == .TakingDamage) return .{ .throttle_ms = TAKING_DAMAGE_THROTTLE_MS };
        return if (notification.notificationCategory(notification_type) == .Chat) .{ .throttle_ms = 0 } else .{};
    }

    /// A const, not a fn: evaluated once instead of per comptime Wire field default, which exceeded the branch quota.
    pub const DEFAULTS_BY_TYPE = blk: {
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

pub const NotificationTypeConfigs = struct {
    const Map = std.enums.EnumArray(notification.NotificationType, NotificationTypeConfig);

    map: Map = NotificationTypeConfig.DEFAULTS_BY_TYPE,

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
        map: std.enums.EnumArray(notification.NotificationType, NotificationTypeConfig.Wire) = DEFAULT_WIRE_MAP,

        const DEFAULT_WIRE_MAP = blk: {
            @setEvalBranchQuota(10_000_000);
            var map = std.enums.EnumArray(notification.NotificationType, NotificationTypeConfig.Wire).initFill(.{});
            for (std.enums.values(notification.NotificationType)) |notification_type| map.set(notification_type, wire.encode(NotificationTypeConfig, NotificationTypeConfig.DEFAULTS_BY_TYPE.get(notification_type)));
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
                // A field left out takes this type's default, not NotificationTypeConfig's: they differ for throttle_ms and duration_ms.
                const type_defaults = DEFAULT_WIRE_MAP.get(notification_type);
                inline for (@typeInfo(NotificationTypeConfig.Wire).@"struct".field_names) |name| {
                    if (!entry.value_ptr.object.contains(name)) @field(wire_value, name) = @field(type_defaults, name);
                }
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
    /// A type without a text colour of its own uses this, on thumbnails and in the History and Intel panels.
    color: u32 = 0xFFFFFFFF,

    suppress_click_duration_ms: u32 = 2000,

    tts_volume: u8 = 100,
    tts_rate: i8 = 0,
    tts_speak_character_name: bool = true,
    tts_use_display_name: bool = false,
    /// Spoken alerts waiting behind the one speaking; past it the oldest is dropped.
    tts_max_waiting: u8 = 3,

    notified_cycle_retention_seconds: u32 = 30,

    type_configs: NotificationTypeConfigs = .{},

    pub const ranges = .{
        .suppress_click_duration_ms = .{ 0, 60000 },
        .tts_volume = ranges_mod.PERCENT,
        .tts_rate = .{ -10, 10 },
        .tts_max_waiting = .{ 1, 10 },
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

const testing = std.testing;

/// Parsed as loading parses it, then decoded into configs the caller frees with deinit.
fn parseTestConfigs(arena: std.mem.Allocator, text: []const u8) !NotificationTypeConfigs {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    const saved = try std.json.parseFromValueLeaky(NotificationTypeConfigs.Wire, arena, value, .{ .ignore_unknown_fields = true });
    return NotificationTypeConfigs.fromWire(saved, testing.allocator);
}

test "a type's left-out fields take that type's defaults, not the general ones" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var configs = try parseTestConfigs(arena_state.allocator(),
        \\{"ProfileSwitch":{"enabled":false},"TakingDamage":{"tts_enabled":true},"ChatKeyword":{"show_border":true},"FleetInvite":{"flash_border":true}}
    );
    defer configs.deinit(testing.allocator);
    const profile_switch = configs.get(.ProfileSwitch);
    try testing.expect(!profile_switch.enabled);
    try testing.expectEqual(@as(u32, 3000), profile_switch.duration_ms);
    try testing.expectEqual(@as(u32, 0), profile_switch.throttle_ms);
    try testing.expect(configs.get(.TakingDamage).tts_enabled);
    try testing.expectEqual(TAKING_DAMAGE_THROTTLE_MS, configs.get(.TakingDamage).throttle_ms);
    try testing.expectEqual(@as(u32, 0), configs.get(.ChatKeyword).throttle_ms);
    try testing.expectEqual(@as(u32, 10000), configs.get(.FleetInvite).throttle_ms);
}

test "a type the file leaves out keeps its own defaults" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var configs = try parseTestConfigs(arena_state.allocator(), "{\"FleetInvite\":{\"enabled\":false}}");
    defer configs.deinit(testing.allocator);
    try testing.expect(!configs.get(.FleetInvite).enabled);
    try testing.expect(configs.get(.Decloak).enabled);
    try testing.expectEqual(@as(u32, 3000), configs.get(.HotkeySuspend).duration_ms);
    try testing.expectEqual(TAKING_DAMAGE_THROTTLE_MS, configs.get(.TakingDamage).throttle_ms);
}

test "saved strings survive the per-type parse's arena" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var configs = try parseTestConfigs(arena_state.allocator(),
        \\{"Decloak":{"sound_path":"C:\\sounds\\decloak.wav","custom_text":"{character} decloaked","custom_text_alt":"Cloak back up"}}
    );
    defer configs.deinit(testing.allocator);
    const decloak = configs.get(.Decloak);
    try testing.expectEqualStrings("C:\\sounds\\decloak.wav", decloak.sound_path.?);
    try testing.expectEqualStrings("{character} decloaked", decloak.custom_text.?);
    try testing.expectEqualStrings("Cloak back up", decloak.custom_text_alt.?);
}

test "unknown alert types are skipped and a non-object leaves every default" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var unknown = try parseTestConfigs(arena, "{\"RemovedType\":{\"enabled\":false},\"Docking\":{\"enabled\":false}}");
    defer unknown.deinit(testing.allocator);
    try testing.expect(!unknown.get(.Docking).enabled);
    try testing.expect(unknown.get(.FleetInvite).enabled);
    var not_object = try parseTestConfigs(arena, "[]");
    defer not_object.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3000), not_object.get(.ProfileSwitch).duration_ms);
    try testing.expect(not_object.get(.Docking).enabled);
}

test "toWire then fromWire keeps every type's settings" {
    var original: NotificationTypeConfigs = .{};
    original.set(.CargoFull, .{ .enabled = false, .duration_ms = 4500, .border_color = 0xFF112233 });
    var copy = try NotificationTypeConfigs.fromWire(original.toWire(), testing.allocator);
    defer copy.deinit(testing.allocator);
    const cargo = copy.get(.CargoFull);
    try testing.expect(!cargo.enabled);
    try testing.expectEqual(@as(u32, 4500), cargo.duration_ms);
    try testing.expectEqual(@as(u32, 0xFF112233), cargo.border_color.?);
    try testing.expectEqual(@as(u32, 0), copy.get(.ProfileSwitch).throttle_ms);
}
