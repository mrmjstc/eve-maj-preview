//! Notification types, their categories, and each type's default wording.
const std = @import("std");
const log = @import("../log.zig");

const slog = log.scoped("notification");

pub const NotificationType = enum {
    FleetInvite,
    FleetFollow,
    FleetRegroup,
    FleetDisband,
    ConversationInvite,
    MiningCompression,
    AsteroidDepleted,
    MiningIdle,
    MiningStopped,
    CargoFull,
    TakingDamage,
    WarpScrambled,
    WarpDisrupted,
    Decloak,
    ObservatoryDecloak,
    CloakFailed,
    CrystalBroke,
    BombLauncherEmpty,
    SelfDestruct,
    Docking,
    AutopilotReached,
    AutopilotApproaching,
    JumpRange,
    AggressionCantJump,
    WarpBubble,
    ConduitJump,
    JumpCloning,
    SystemChange,
    TravelLeftBehind,
    GroupMembership,
    CycleExclusion,
    HotkeySuspend,
    ProfileSwitch,
    AutoMinimizeToggle,
    SavedPositionMove,
    Generic,
};

/// For the History Panel's category filter buttons, and the order the config dialog lists types in (see config/schema.zig).
pub const NotificationCategory = enum {
    Fleet,
    Mining,
    Combat,
    Navigation,
    General,
};

pub const State = enum { on, off, added, removed, suspended, resumed, excluded, included, started, aborted };

/// A notification before it's rendered to text; slices are borrowed from the caller.
pub const Notification = struct {
    ntype: NotificationType,
    state: ?State = null,
    source: ?[]const u8 = null,
    target: ?[]const u8 = null,
};

pub fn notificationCategory(ntype: NotificationType) NotificationCategory {
    return switch (ntype) {
        .FleetInvite, .FleetFollow, .FleetRegroup, .FleetDisband => .Fleet,
        .MiningCompression, .AsteroidDepleted, .MiningIdle, .MiningStopped, .CargoFull, .CrystalBroke => .Mining,
        .TakingDamage, .WarpScrambled, .WarpDisrupted, .Decloak, .ObservatoryDecloak, .CloakFailed, .BombLauncherEmpty, .SelfDestruct, .WarpBubble => .Combat,
        .Docking, .AutopilotReached, .AutopilotApproaching, .JumpRange, .AggressionCantJump, .ConduitJump, .JumpCloning, .SystemChange, .TravelLeftBehind => .Navigation,
        .ConversationInvite, .GroupMembership, .CycleExclusion, .HotkeySuspend, .ProfileSwitch, .AutoMinimizeToggle, .SavedPositionMove, .Generic => .General,
    };
}

/// Feedback for something the user just did, as opposed to a game event.
pub fn isUserAction(ntype: NotificationType) bool {
    return switch (ntype) {
        .GroupMembership, .CycleExclusion, .HotkeySuspend, .ProfileSwitch, .AutoMinimizeToggle, .SavedPositionMove => true,
        else => false,
    };
}

/// Representative field values for the config dialog's Test button.
pub fn sample(ntype: NotificationType) Notification {
    return switch (ntype) {
        .SelfDestruct => .{ .ntype = ntype, .state = .started },
        .CycleExclusion => .{ .ntype = ntype, .state = .excluded },
        .HotkeySuspend => .{ .ntype = ntype, .state = .suspended },
        .AutoMinimizeToggle => .{ .ntype = ntype, .state = .on },
        .GroupMembership => .{ .ntype = ntype, .state = .added, .target = "Hotkey Group 1" },
        .ProfileSwitch => .{ .ntype = ntype, .target = "Default" },
        .SystemChange, .ConduitJump => .{ .ntype = ntype, .target = "Jita" },
        .TravelLeftBehind => .{ .ntype = ntype, .source = "Perimeter", .target = "Jita" },
        .Generic => .{ .ntype = ntype, .source = "Generic notification" },
        else => .{ .ntype = ntype },
    };
}

/// Built-in wording for each type; the returned slice may point into `buf`.
pub fn defaultText(notification: Notification, buf: []u8) []const u8 {
    return switch (notification.ntype) {
        .FleetInvite => "Fleet invite",
        .FleetFollow => "Following",
        .FleetRegroup => "Regrouping",
        .FleetDisband => "Fleet disbanding",
        .ConversationInvite => "Convo request",
        .JumpCloning => "Jump Cloning",
        .MiningCompression => "Compressed",
        .AsteroidDepleted => "Asteroid Depleted",
        .MiningIdle => "Laser idle",
        .MiningStopped => "Mining stopped",
        .CargoFull => "Cargo full",
        .TakingDamage => "Taking damage",
        .WarpScrambled => "Warp Scrambled",
        .WarpDisrupted, .WarpBubble => "Warp Disrupted",
        .Decloak => "Decloaked",
        .ObservatoryDecloak => "Observatory Decloak",
        .CloakFailed => "Can't cloak",
        .CrystalBroke => "Crystal broke",
        .BombLauncherEmpty => "Bomb Launcher Empty",
        .SelfDestruct => if (notification.state == .aborted) "Self-Destruct Aborted" else "Self-Destruct",
        .Docking => "Docking",
        .AutopilotReached => "Waypoint reached",
        .AutopilotApproaching => "Approaching",
        .JumpRange => "Can't Jump: Range",
        .AggressionCantJump => "Can't Jump: Aggression",
        .ConduitJump => withField(buf, "Taking Conduit to {s}", notification.target, "Conduit Jump"),
        .SystemChange => withField(buf, "Jumped to {s}", notification.target, "Jumped"),
        .TravelLeftBehind => withField(buf, "Left behind in {s}", notification.source, "Left behind"),
        .GroupMembership => if (notification.state == .removed)
            withField(buf, "Removed from {s}", notification.target, "Removed from group")
        else
            withField(buf, "Added to {s}", notification.target, "Added to group"),
        .CycleExclusion => if (notification.state == .excluded) "Excluded" else "Included",
        .HotkeySuspend => if (notification.state == .suspended) "Hotkeys suspended" else "Hotkeys resumed",
        .ProfileSwitch => withField(buf, "Profile: {s}", notification.target, "Profile switched"),
        .AutoMinimizeToggle => if (notification.state == .on) "Auto-minimize on" else "Auto-minimize off",
        .SavedPositionMove => "Moved to saved position",
        .Generic => notification.source orelse "",
    };
}

fn withField(buf: []u8, comptime fmt: []const u8, field: ?[]const u8, fallback: []const u8) []const u8 {
    const value = field orelse return fallback;
    return std.fmt.bufPrint(buf, fmt, .{value}) catch |err| {
        slog.warn("Notification text for '{s}' didn't fit, using \"{s}\": {}", .{ value, fallback, err });
        return fallback;
    };
}
