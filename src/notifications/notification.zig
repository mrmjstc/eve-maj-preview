const std = @import("std");
const log = @import("../log.zig");
const slog = log.scoped("notification");

pub const NotificationType = enum {
    FleetInvite,
    FleetFollow,
    FleetRegroup,
    FleetDisband,
    ConversationInvite,
    JumpCloning,
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

/// Mirrors the 5 categories config_dialog.js's NOTIFICATION_TYPES groups these into, for the History Panel's category filter buttons.
pub const NotificationCategory = enum {
    Fleet,
    Mining,
    Combat,
    Navigation,
    General,
};

pub fn notificationCategory(t: NotificationType) NotificationCategory {
    return switch (t) {
        .FleetInvite, .FleetFollow, .FleetRegroup, .FleetDisband => .Fleet,
        .MiningCompression, .AsteroidDepleted, .MiningIdle, .MiningStopped, .CargoFull, .CrystalBroke => .Mining,
        .TakingDamage, .WarpScrambled, .WarpDisrupted, .Decloak, .ObservatoryDecloak, .CloakFailed, .BombLauncherEmpty, .SelfDestruct, .WarpBubble => .Combat,
        .Docking, .AutopilotReached, .AutopilotApproaching, .JumpRange, .AggressionCantJump, .ConduitJump, .JumpCloning, .SystemChange, .TravelLeftBehind => .Navigation,
        .ConversationInvite, .GroupMembership, .CycleExclusion, .HotkeySuspend, .ProfileSwitch, .AutoMinimizeToggle, .SavedPositionMove, .Generic => .General,
    };
}

pub const State = enum { on, off, added, removed, suspended, resumed, excluded, included, started, aborted };

/// A notification before it's rendered to text; slices are borrowed from the caller.
pub const Notification = struct {
    ntype: NotificationType,
    state: ?State = null,
    source: ?[]const u8 = null,
    target: ?[]const u8 = null,
};

/// Feedback for something the user just did, as opposed to a game event.
pub fn isUserAction(t: NotificationType) bool {
    return switch (t) {
        .GroupMembership, .CycleExclusion, .HotkeySuspend, .ProfileSwitch, .AutoMinimizeToggle, .SavedPositionMove => true,
        else => false,
    };
}

/// Representative field values for the config dialog's Test button.
pub fn sample(t: NotificationType) Notification {
    return switch (t) {
        .SelfDestruct => .{ .ntype = t, .state = .started },
        .CycleExclusion => .{ .ntype = t, .state = .excluded },
        .HotkeySuspend => .{ .ntype = t, .state = .suspended },
        .AutoMinimizeToggle => .{ .ntype = t, .state = .on },
        .GroupMembership => .{ .ntype = t, .state = .added, .target = "Hotkey Group 1" },
        .ProfileSwitch => .{ .ntype = t, .target = "Default" },
        .SystemChange, .ConduitJump => .{ .ntype = t, .target = "Jita" },
        .TravelLeftBehind => .{ .ntype = t, .source = "Perimeter", .target = "Jita" },
        .Generic => .{ .ntype = t, .source = "Generic notification" },
        else => .{ .ntype = t },
    };
}

/// Built-in wording for each type; the returned slice may point into `buf`.
pub fn defaultText(n: Notification, buf: []u8) []const u8 {
    return switch (n.ntype) {
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
        .SelfDestruct => if (n.state == .aborted) "Self-Destruct Aborted" else "Self-Destruct",
        .Docking => "Docking",
        .AutopilotReached => "Waypoint reached",
        .AutopilotApproaching => "Approaching",
        .JumpRange => "Can't Jump: Range",
        .AggressionCantJump => "Can't Jump: Aggression",
        .ConduitJump => withField(buf, "Taking Conduit to {s}", n.target, "Conduit Jump"),
        .SystemChange => withField(buf, "Jumped to {s}", n.target, "Jumped"),
        .TravelLeftBehind => withField(buf, "Left behind in {s}", n.source, "Left behind"),
        .GroupMembership => if (n.state == .removed)
            withField(buf, "Removed from {s}", n.target, "Removed from group")
        else
            withField(buf, "Added to {s}", n.target, "Added to group"),
        .CycleExclusion => if (n.state == .excluded) "Excluded" else "Included",
        .HotkeySuspend => if (n.state == .suspended) "Hotkeys suspended" else "Hotkeys resumed",
        .ProfileSwitch => withField(buf, "Profile: {s}", n.target, "Profile switched"),
        .AutoMinimizeToggle => if (n.state == .on) "Auto-minimize on" else "Auto-minimize off",
        .SavedPositionMove => "Moved to saved position",
        .Generic => n.source orelse "",
    };
}

fn withField(buf: []u8, comptime fmt: []const u8, field: ?[]const u8, fallback: []const u8) []const u8 {
    const value = field orelse return fallback;
    return std.fmt.bufPrint(buf, fmt, .{value}) catch |err| {
        slog.warn("Notification text for {s} didn't fit, using \"{s}\": {}", .{ value, fallback, err });
        return fallback;
    };
}
