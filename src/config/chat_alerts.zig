//! Rules for which chat messages raise an alert.
const notification = @import("../notifications/notification.zig");
const wire = @import("wire.zig");
const ranges_mod = @import("ranges.zig");
const notifications = @import("notifications.zig");

/// Declared by priority: a message matching several rules alerts once, for the first kind here.
pub const ChatAlertKind = enum {
    intel,
    keyword,

    pub fn notificationType(self: ChatAlertKind) notification.NotificationType {
        return switch (self) {
            .intel => .ChatIntel,
            .keyword => .ChatKeyword,
        };
    }
};

pub const ChatAlertConfig = struct {
    name: []const u8 = "",
    enabled: bool = true,
    kind: ChatAlertKind = .intel,
    /// Comma-separated channel names and `*`/`?`/`#` patterns.
    channels: []const u8 = "",
    /// Comma-separated words or phrases; keyword rules only.
    keywords: []const u8 = "",
    /// Comma-separated words or phrases that stop a message matching this rule.
    exclude: []const u8 = "",
    /// Intel rules only: how far a mentioned system may be from a client.
    max_jumps: u8 = 5,
    /// How long the same system or keyword stays quiet after alerting for this rule.
    cooldown_ms: u32 = 15000,
    /// How this rule's alerts look and sound; no throttle, as that would drop a different message and cooldown_ms does its job.
    alert: notifications.NotificationTypeConfig = .{ .throttle_ms = 0 },

    pub const ranges = .{
        .max_jumps = .{ 0, 30 },
        .cooldown_ms = .{ 0, 300000 },
    };

    pub fn validate(self: *ChatAlertConfig) void {
        ranges_mod.clamp(ChatAlertConfig, self);
    }

    pub const Wire = wire.Wire(ChatAlertConfig);
};
