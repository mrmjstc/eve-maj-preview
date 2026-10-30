//! Notification types, their categories, placeholders, and each type's wording.
const std = @import("std");
const template = @import("template.zig");
const log = @import("../log.zig");

const Placeholder = template.Placeholder;
const slog = log.Scoped("notification");

/// For the dialog's preview; Test uses each thumbnail's own name.
pub const SAMPLE_CHARACTER = "Your Pilot";
/// The most a notification's text holds once its placeholders are filled; template.render cuts the rest.
pub const TEXT_MAX: usize = 128;

const CHARACTER: Placeholder = .{ .name = "character", .field = .character };
const CHARACTER_ONLY = [_]Placeholder{CHARACTER};
const PILOT = [_]Placeholder{ .{ .name = "pilot", .field = .source }, CHARACTER };
const LEADER = [_]Placeholder{ .{ .name = "leader", .field = .source }, CHARACTER };
const COMPRESSION = [_]Placeholder{ .{ .name = "ore", .field = .source }, .{ .name = "result", .field = .target }, CHARACTER };
const MODULE = [_]Placeholder{ .{ .name = "module", .field = .source }, CHARACTER };
const CRYSTAL = [_]Placeholder{ .{ .name = "module", .field = .source }, .{ .name = "crystal", .field = .target }, CHARACTER };
const ATTACKER = [_]Placeholder{ .{ .name = "attacker", .field = .source }, CHARACTER };
const OBJECT = [_]Placeholder{ .{ .name = "object", .field = .source }, CHARACTER };
const DESTINATION = [_]Placeholder{ .{ .name = "system", .field = .target }, CHARACTER };
const LEFT_BEHIND = [_]Placeholder{ .{ .name = "system", .field = .source }, .{ .name = "group_system", .field = .target }, CHARACTER };
const GROUP = [_]Placeholder{ .{ .name = "group", .field = .target }, CHARACTER };
const PROFILE = [_]Placeholder{.{ .name = "profile", .field = .target }};
const MESSAGE = [_]Placeholder{ .{ .name = "message", .field = .source }, CHARACTER };
const CHAT_PILOT: Placeholder = .{ .name = "pilot", .field = .source };
const CHAT_CHANNEL: Placeholder = .{ .name = "channel", .field = .channel };
const CHAT_MESSAGE: Placeholder = .{ .name = "message", .field = .message };
const CHAT_INTEL = [_]Placeholder{ .{ .name = "system", .field = .target }, .{ .name = "jumps", .field = .jumps }, CHAT_PILOT, CHAT_CHANNEL, CHAT_MESSAGE, CHARACTER };
const CHAT_KEYWORD = [_]Placeholder{ .{ .name = "keyword", .field = .target }, CHAT_PILOT, CHAT_CHANNEL, CHAT_MESSAGE, CHARACTER };
/// No {system}: the message always names it, as that's what matched.
const CHAT_INTEL_WORDING = "{jumps}j: {message}";
const CHAT_KEYWORD_WORDING = "{channel}: {message}";

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
    ChatIntel,
    ChatKeyword,
    GroupMembership,
    CycleExclusion,
    HotkeySuspend,
    ProfileSwitch,
    AutoMinimizeToggle,
    SavedPositionMove,
    Generic,
};

/// For the History Panel's category filter buttons, and the order the config dialog lists types in.
pub const NotificationCategory = enum {
    Fleet,
    Mining,
    Combat,
    Navigation,
    Chat,
    General,
};

pub const State = enum { on, off, added, removed, suspended, resumed, excluded, included, started, aborted };

/// A notification before it's rendered to text; slices are borrowed from the caller.
pub const Notification = struct {
    notification_type: NotificationType,
    state: ?State = null,
    source: ?[]const u8 = null,
    target: ?[]const u8 = null,
    /// Chat alerts only.
    channel: ?[]const u8 = null,
    /// Chat alerts only.
    message: ?[]const u8 = null,
    /// Chat alerts only; already text, as the template only fills in text.
    jumps: ?[]const u8 = null,
    /// Which of the profile's chat alert rules raised it, whose settings then replace the type's.
    chat_rule_index: ?usize = null,
};

/// Null or empty uses the default wording.
pub const CustomText = struct {
    primary: ?[]const u8 = null,
    /// Used when the notification is in its type's altState.
    alt: ?[]const u8 = null,
};

pub fn notificationCategory(notification_type: NotificationType) NotificationCategory {
    return switch (notification_type) {
        .FleetInvite, .FleetFollow, .FleetRegroup, .FleetDisband => .Fleet,
        .MiningCompression, .AsteroidDepleted, .MiningIdle, .MiningStopped, .CargoFull, .CrystalBroke => .Mining,
        .TakingDamage, .WarpScrambled, .WarpDisrupted, .Decloak, .ObservatoryDecloak, .CloakFailed, .BombLauncherEmpty, .SelfDestruct, .WarpBubble => .Combat,
        .Docking, .AutopilotReached, .AutopilotApproaching, .JumpRange, .AggressionCantJump, .ConduitJump, .JumpCloning, .SystemChange, .TravelLeftBehind => .Navigation,
        .ChatIntel, .ChatKeyword => .Chat,
        .ConversationInvite, .GroupMembership, .CycleExclusion, .HotkeySuspend, .ProfileSwitch, .AutoMinimizeToggle, .SavedPositionMove, .Generic => .General,
    };
}

/// Feedback for something the user just did, as opposed to a game event.
pub fn isUserAction(notification_type: NotificationType) bool {
    return switch (notification_type) {
        .GroupMembership, .CycleExclusion, .HotkeySuspend, .ProfileSwitch, .AutoMinimizeToggle, .SavedPositionMove => true,
        .FleetInvite, .FleetFollow, .FleetRegroup, .FleetDisband, .ConversationInvite, .MiningCompression, .AsteroidDepleted, .MiningIdle, .MiningStopped, .CargoFull, .TakingDamage, .WarpScrambled, .WarpDisrupted, .Decloak, .ObservatoryDecloak, .CloakFailed, .CrystalBroke, .BombLauncherEmpty, .SelfDestruct, .Docking, .AutopilotReached, .AutopilotApproaching, .JumpRange, .AggressionCantJump, .WarpBubble, .ConduitJump, .JumpCloning, .SystemChange, .TravelLeftBehind, .ChatIntel, .ChatKeyword, .Generic => false,
    };
}

/// notifyAll types, one popup for every client, have no `{character}`.
pub fn placeholders(notification_type: NotificationType) []const Placeholder {
    return switch (notification_type) {
        .FleetInvite, .ConversationInvite => &PILOT,
        .FleetFollow, .FleetRegroup => &LEADER,
        .MiningCompression => &COMPRESSION,
        .AsteroidDepleted, .CargoFull, .BombLauncherEmpty => &MODULE,
        .CrystalBroke => &CRYSTAL,
        .WarpScrambled, .WarpDisrupted => &ATTACKER,
        .Decloak, .WarpBubble => &OBJECT,
        .SystemChange, .ConduitJump => &DESTINATION,
        .TravelLeftBehind => &LEFT_BEHIND,
        .ChatIntel => &CHAT_INTEL,
        .ChatKeyword => &CHAT_KEYWORD,
        .GroupMembership => &GROUP,
        .ProfileSwitch => &PROFILE,
        .Generic => &MESSAGE,
        .HotkeySuspend, .AutoMinimizeToggle => &.{},
        .FleetDisband, .MiningIdle, .MiningStopped, .TakingDamage, .ObservatoryDecloak, .CloakFailed, .SelfDestruct, .Docking, .AutopilotReached, .AutopilotApproaching, .JumpRange, .AggressionCantJump, .JumpCloning, .CycleExclusion, .SavedPositionMove => &CHARACTER_ONLY,
    };
}

/// A two-state type's second state, which has its own custom text.
pub fn altState(notification_type: NotificationType) ?State {
    return switch (notification_type) {
        .SelfDestruct => .aborted,
        .HotkeySuspend => .resumed,
        .AutoMinimizeToggle => .off,
        .GroupMembership => .removed,
        .CycleExclusion => .included,
        .FleetInvite, .FleetFollow, .FleetRegroup, .FleetDisband, .ConversationInvite, .MiningCompression, .AsteroidDepleted, .MiningIdle, .MiningStopped, .CargoFull, .TakingDamage, .WarpScrambled, .WarpDisrupted, .Decloak, .ObservatoryDecloak, .CloakFailed, .CrystalBroke, .BombLauncherEmpty, .Docking, .AutopilotReached, .AutopilotApproaching, .JumpRange, .AggressionCantJump, .WarpBubble, .ConduitJump, .JumpCloning, .SystemChange, .TravelLeftBehind, .ChatIntel, .ChatKeyword, .ProfileSwitch, .SavedPositionMove, .Generic => null,
    };
}

/// Representative field values for the config dialog's Test button and preview.
pub fn sample(notification_type: NotificationType) Notification {
    return switch (notification_type) {
        .SelfDestruct => .{ .notification_type = notification_type, .state = .started },
        .CycleExclusion => .{ .notification_type = notification_type, .state = .excluded },
        .HotkeySuspend => .{ .notification_type = notification_type, .state = .suspended },
        .AutoMinimizeToggle => .{ .notification_type = notification_type, .state = .on },
        .GroupMembership => .{ .notification_type = notification_type, .state = .added, .target = "Hotkey Group 1" },
        .ProfileSwitch => .{ .notification_type = notification_type, .target = "Default" },
        .SystemChange, .ConduitJump => .{ .notification_type = notification_type, .target = "Jita" },
        .TravelLeftBehind => .{ .notification_type = notification_type, .source = "Perimeter", .target = "Jita" },
        .ChatIntel => .{ .notification_type = notification_type, .source = "Some Pilot", .target = "Perimeter", .channel = "Intel", .message = "Perimeter spike 10", .jumps = "2" },
        .ChatKeyword => .{ .notification_type = notification_type, .source = "Some Pilot", .target = "bubble", .channel = "Fleet", .message = "bubble on the gate" },
        .Generic => .{ .notification_type = notification_type, .source = "Generic notification" },
        .FleetInvite, .ConversationInvite => .{ .notification_type = notification_type, .source = "Some Pilot" },
        .FleetFollow, .FleetRegroup => .{ .notification_type = notification_type, .source = "Fleet Commander" },
        .MiningCompression => .{ .notification_type = notification_type, .source = "Veldspar", .target = "10 Compressed Veldspar" },
        .AsteroidDepleted, .CargoFull => .{ .notification_type = notification_type, .source = "Miner II" },
        .BombLauncherEmpty => .{ .notification_type = notification_type, .source = "Bomb Launcher II" },
        .CrystalBroke => .{ .notification_type = notification_type, .source = "Modulated Strip Miner II", .target = "Veldspar Mining Crystal II" },
        .WarpScrambled, .WarpDisrupted => .{ .notification_type = notification_type, .source = "Hostile Pilot" },
        .Decloak => .{ .notification_type = notification_type, .source = "Guristas Pith Ship" },
        .WarpBubble => .{ .notification_type = notification_type, .source = "Warp Disrupt Probe" },
        .FleetDisband, .MiningIdle, .MiningStopped, .TakingDamage, .ObservatoryDecloak, .CloakFailed, .Docking, .AutopilotReached, .AutopilotApproaching, .JumpRange, .AggressionCantJump, .JumpCloning, .SavedPositionMove => .{ .notification_type = notification_type },
    };
}

/// Falls back to defaultText when unset or a used placeholder has no value; may point into `buf`.
pub fn text(notification: Notification, custom: CustomText, character_name: ?[]const u8, buf: []u8) []const u8 {
    const is_alt = if (altState(notification.notification_type)) |alt| notification.state == alt else false;
    const custom_text = (if (is_alt) custom.alt else custom.primary) orelse return defaultText(notification, buf);
    if (custom_text.len == 0) return defaultText(notification, buf);

    return template.render(custom_text, placeholders(notification.notification_type), templateValues(notification, character_name), buf) orelse {
        slog.debug("Custom {s} text uses a placeholder this event has no value for, using the default", .{@tagName(notification.notification_type)});
        return defaultText(notification, buf);
    };
}

/// Borrows from both arguments.
pub fn templateValues(notification: Notification, character_name: ?[]const u8) template.Values {
    return .{
        .source = notification.source,
        .target = notification.target,
        .character = character_name,
        .channel = notification.channel,
        .message = notification.message,
        .jumps = notification.jumps,
    };
}

/// Built-in wording for each type; the returned slice may point into `buf`.
pub fn defaultText(notification: Notification, buf: []u8) []const u8 {
    return switch (notification.notification_type) {
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
        .ChatIntel => chatText(notification, CHAT_INTEL_WORDING, &CHAT_INTEL, "Chat intel", buf),
        .ChatKeyword => chatText(notification, CHAT_KEYWORD_WORDING, &CHAT_KEYWORD, "Chat keyword", buf),
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

/// Through the template rather than a format, so a long message is cut instead of losing the whole text.
fn chatText(notification: Notification, wording: []const u8, chat_placeholders: []const Placeholder, fallback: []const u8, buf: []u8) []const u8 {
    return template.render(wording, chat_placeholders, templateValues(notification, null), buf) orelse fallback;
}

fn withField(buf: []u8, comptime format: []const u8, field: ?[]const u8, fallback: []const u8) []const u8 {
    const value = field orelse return fallback;
    return std.mem.print(buf, format, .{value}) catch |err| {
        slog.warn("Failed to fit notification text for '{s}', using \"{s}\": {}", .{ value, fallback, err });
        return fallback;
    };
}

const testing = std.testing;

test "defaultText inserts the target, or falls back without one" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Taking Conduit to Ahbazon", defaultText(.{ .notification_type = .ConduitJump, .target = "Ahbazon" }, &buf));
    try testing.expectEqualStrings("Conduit Jump", defaultText(.{ .notification_type = .ConduitJump }, &buf));
    try testing.expectEqualStrings("Jumped to Jita", defaultText(.{ .notification_type = .SystemChange, .target = "Jita" }, &buf));
    try testing.expectEqualStrings("Left behind in Perimeter", defaultText(.{ .notification_type = .TravelLeftBehind, .source = "Perimeter", .target = "Jita" }, &buf));
    try testing.expectEqualStrings("Profile switched", defaultText(.{ .notification_type = .ProfileSwitch }, &buf));
}

test "defaultText falls back when the text doesn't fit the buffer" {
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("Jumped", defaultText(.{ .notification_type = .SystemChange, .target = "Jita" }, &buf));
}

test "defaultText words each state" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Self-Destruct", defaultText(.{ .notification_type = .SelfDestruct, .state = .started }, &buf));
    try testing.expectEqualStrings("Self-Destruct Aborted", defaultText(.{ .notification_type = .SelfDestruct, .state = .aborted }, &buf));
    try testing.expectEqualStrings("Added to Wing A", defaultText(.{ .notification_type = .GroupMembership, .state = .added, .target = "Wing A" }, &buf));
    try testing.expectEqualStrings("Removed from Wing A", defaultText(.{ .notification_type = .GroupMembership, .state = .removed, .target = "Wing A" }, &buf));
    try testing.expectEqualStrings("Hotkeys suspended", defaultText(.{ .notification_type = .HotkeySuspend, .state = .suspended }, &buf));
    try testing.expectEqualStrings("Hotkeys resumed", defaultText(.{ .notification_type = .HotkeySuspend, .state = .resumed }, &buf));
    try testing.expectEqualStrings("Auto-minimize off", defaultText(.{ .notification_type = .AutoMinimizeToggle, .state = .off }, &buf));
}

test "defaultText cuts a long chat message rather than dropping it" {
    var buf: [24]u8 = undefined;
    const long_message: Notification = .{ .notification_type = .ChatKeyword, .channel = "Fleet", .message = "bubble on the gate and more besides" };
    try testing.expectEqualStrings("Fleet: bubble on the gat", defaultText(long_message, &buf));
    try testing.expectEqualStrings("Chat keyword", defaultText(.{ .notification_type = .ChatKeyword }, &buf));
}

test "text fills custom wording, picking the alt state's own" {
    var buf: [64]u8 = undefined;
    const custom: CustomText = .{ .primary = "{character} invited by {pilot}", .alt = "unused" };
    try testing.expectEqualStrings("Main invited by Some Pilot", text(.{ .notification_type = .FleetInvite, .source = "Some Pilot" }, custom, "Main", &buf));

    const self_destruct: CustomText = .{ .primary = "Boom", .alt = "Phew" };
    try testing.expectEqualStrings("Boom", text(.{ .notification_type = .SelfDestruct, .state = .started }, self_destruct, null, &buf));
    try testing.expectEqualStrings("Phew", text(.{ .notification_type = .SelfDestruct, .state = .aborted }, self_destruct, null, &buf));
}

test "text falls back to the default wording when unset or missing a value" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Fleet invite", text(.{ .notification_type = .FleetInvite }, .{}, null, &buf));
    try testing.expectEqualStrings("Fleet invite", text(.{ .notification_type = .FleetInvite }, .{ .primary = "" }, null, &buf));
    try testing.expectEqualStrings("Fleet invite", text(.{ .notification_type = .FleetInvite }, .{ .primary = "From {pilot}" }, null, &buf));
    try testing.expectEqualStrings("Self-Destruct Aborted", text(.{ .notification_type = .SelfDestruct, .state = .aborted }, .{ .primary = "Boom" }, null, &buf));
}

test "every placeholder a type offers is filled by its sample" {
    for (std.enums.values(NotificationType)) |notification_type| {
        const example = sample(notification_type);
        for (placeholders(notification_type)) |placeholder| {
            const value = switch (placeholder.field) {
                .source => example.source,
                .target => example.target,
                .character => SAMPLE_CHARACTER,
                .channel => example.channel,
                .message => example.message,
                .jumps => example.jumps,
            };
            try testing.expect(value != null);
        }
    }
}

test "every notification type's sample has wording" {
    var buf: [64]u8 = undefined;
    for (std.enums.values(NotificationType)) |notification_type| {
        try testing.expect(defaultText(sample(notification_type), &buf).len > 0);
    }
}
