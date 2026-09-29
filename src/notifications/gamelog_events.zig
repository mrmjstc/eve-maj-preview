//! Which gamelog lines raise a notification, and of what type.
const std = @import("std");
const notification = @import("notification.zig");

const Notification = notification.Notification;

/// Classifies an HTML-stripped gamelog line; null means it doesn't warrant a popup.
/// Field slices borrow from `event_text`; ChatlogMonitor.queueNotification copies them.
pub fn classify(event_text: []const u8) ?Notification {
    // EVE gamelog format: "[ timestamp ] (type) message"
    var text_start: usize = 0;
    if (std.mem.indexOf(u8, event_text, "]")) |close_bracket| {
        text_start = close_bracket + 1;
    }

    const remaining = std.mem.trim(u8, event_text[text_start..], " \t\r\n");

    if (std.mem.startsWith(u8, remaining, "(question)")) {
        return parseQuestionEvent(remaining["(question)".len..]);
    } else if (std.mem.startsWith(u8, remaining, "(notify)")) {
        return parseNotifyEvent(remaining["(notify)".len..]);
    } else if (std.mem.startsWith(u8, remaining, "(None)")) {
        return parseNoneEvent(remaining["(None)".len..]);
    } else if (std.mem.startsWith(u8, remaining, "(combat)")) {
        return parseCombatEvent(remaining["(combat)".len..]);
    } else if (std.mem.startsWith(u8, remaining, "(hint)")) {
        return null;
    }

    return genericEvent(remaining);
}

/// "A Conduit Field activated by X jumps you to [System]."; the activator's own line continues ", bringing along N passengers.", so a comma ends the name too.
pub fn conduitDestination(text: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, text, "Conduit Field") == null) return null;
    const needle = "jumps you to ";
    const pos = std.mem.indexOf(u8, text, needle) orelse return null;
    const after = text[pos + needle.len ..];
    const end = std.mem.indexOfAny(u8, after, "\r\n.,") orelse after.len;
    const system = std.mem.trim(u8, after[0..end], " \t");
    return if (system.len == 0) null else system;
}

fn genericEvent(message: []const u8) ?Notification {
    const cleaned = std.mem.trim(u8, message, " \t\r\n.");
    if (cleaned.len == 0) return null;
    return .{ .ntype = .Generic, .source = cleaned };
}

fn parseQuestionEvent(message: []const u8) ?Notification {
    const trimmed = std.mem.trim(u8, message, " \t\r\n");

    // "<a href...>NAME</a> wants you to join their fleet, do you accept?"
    if (std.mem.indexOf(u8, trimmed, "wants you to join their fleet")) |_| {
        return .{ .ntype = .FleetInvite };
    }

    return null;
}

fn parseNotifyEvent(message: []const u8) ?Notification {
    const trimmed = std.mem.trim(u8, message, " \t\r\n");

    // "Following [leader] in warp"
    if (std.mem.startsWith(u8, trimmed, "Following ") and std.mem.indexOf(u8, trimmed, " in warp") != null) {
        return .{ .ntype = .FleetFollow };
    }

    // "Regrouping to [leader]"
    if (std.mem.indexOf(u8, trimmed, "Regrouping to ") != null) {
        return .{ .ntype = .FleetRegroup };
    }

    if (std.mem.indexOf(u8, trimmed, "Your fleet is disbanding") != null) {
        return .{ .ntype = .FleetDisband };
    }

    if (std.mem.indexOf(u8, trimmed, "Starting clone jumping") != null) {
        return .{ .ntype = .JumpCloning };
    }

    // "Successfully compressed [ore] into [count] [compressed]"
    if (std.mem.indexOf(u8, trimmed, "Successfully compressed") != null) {
        return .{ .ntype = .MiningCompression };
    }

    // "[miner] deactivates as it finds the resource it was harvesting a pale shadow of its former glory."
    if (std.mem.indexOf(u8, trimmed, "a pale shadow of its former glory") != null) {
        return .{ .ntype = .AsteroidDepleted };
    }

    // "Your [module] has completed operations. Ship's cargo hold is full."
    if (std.mem.indexOf(u8, trimmed, "cargo hold is full") != null) {
        return .{ .ntype = .CargoFull };
    }

    // Checked before the proximity decloak below, whose wording this also contains.
    if (std.mem.indexOf(u8, trimmed, "cloak deactivates") != null and
        std.mem.indexOf(u8, trimmed, "Mobile Observatory") != null)
    {
        return .{ .ntype = .ObservatoryDecloak };
    }

    // "Your cloak deactivates due to proximity to [source]"
    if (std.mem.indexOf(u8, trimmed, "cloak deactivates") != null) {
        return .{ .ntype = .Decloak };
    }

    // "Your cloaking systems are unable to activate due to your ship being within..."
    if (std.mem.indexOf(u8, trimmed, "cloaking systems are unable to activate") != null) {
        return .{ .ntype = .CloakFailed };
    }

    // "[module] deactivates due to the destruction of the [crystal]"
    if (std.mem.indexOf(u8, trimmed, "deactivates due to the destruction") != null) {
        return .{ .ntype = .CrystalBroke };
    }

    // "Bomb Launcher II has run out of charges"
    if (std.mem.indexOf(u8, trimmed, "Bomb Launcher") != null and std.mem.indexOf(u8, trimmed, "has run out of charges") != null) {
        return .{ .ntype = .BombLauncherEmpty };
    }

    // Checks for "Your" to avoid triggering on other players' self-destructs.
    if (std.mem.indexOf(u8, trimmed, "Your") != null and std.mem.indexOf(u8, trimmed, "will self-destruct in") != null) {
        return .{ .ntype = .SelfDestruct, .state = .started };
    }
    if (std.mem.indexOf(u8, trimmed, "You have aborted the self-destruct") != null) {
        return .{ .ntype = .SelfDestruct, .state = .aborted };
    }

    if (std.mem.indexOf(u8, trimmed, "You cannot do that while docking") != null) {
        return .{ .ntype = .Docking };
    }

    if (std.mem.indexOf(u8, trimmed, "Autopilot disabled - Waypoint reached") != null) {
        return .{ .ntype = .AutopilotReached };
    }

    if (std.mem.indexOf(u8, trimmed, "Autopilot approaching target") != null) {
        return .{ .ntype = .AutopilotApproaching };
    }

    // "Please get within 2500 meters of the stargate to jump."
    if (std.mem.indexOf(u8, trimmed, "get within") != null and std.mem.indexOf(u8, trimmed, "stargate to jump") != null) {
        return .{ .ntype = .JumpRange };
    }

    // "You are within a warp disruption zone. Get 20000.0 meters from Warp Disrupt Probe to warp."
    if (std.mem.indexOf(u8, trimmed, "within a warp disruption zone") != null) {
        return .{ .ntype = .WarpBubble };
    }

    // "The stargate denies you permission to jump for the moment due to your recent acts of aggression."
    if (std.mem.indexOf(u8, trimmed, "recent acts of aggression") != null) {
        return .{ .ntype = .AggressionCantJump };
    }

    if (conduitDestination(trimmed)) |system| return .{ .ntype = .ConduitJump, .target = system };
    if (std.mem.indexOf(u8, trimmed, "Conduit Field") != null and std.mem.indexOf(u8, trimmed, "jumps you to") != null) {
        return .{ .ntype = .ConduitJump };
    }

    return null;
}

/// Only scrambles and disruptions pop up; damage lines feed the DPS tracker instead, and `message` must already be HTML-stripped.
fn parseCombatEvent(message: []const u8) ?Notification {
    const trimmed = std.mem.trim(u8, message, " \t\r\n");

    // Must end in "to you!" - a scramble landing on someone else instead reads "...to [target name]!".
    if (std.mem.indexOf(u8, trimmed, "Warp scramble attempt") != null and
        std.mem.endsWith(u8, trimmed, "to you!"))
    {
        return .{ .ntype = .WarpScrambled };
    }

    // Same "to you!" requirement as the scramble check above.
    if (std.mem.indexOf(u8, trimmed, "Warp disruption attempt") != null and
        std.mem.endsWith(u8, trimmed, "to you!"))
    {
        return .{ .ntype = .WarpDisrupted };
    }

    return null;
}

fn parseNoneEvent(message: []const u8) ?Notification {
    const trimmed = std.mem.trim(u8, message, " \t\r\n");

    // ChatlogMonitor.parseLine handles system jumps.
    if (std.mem.startsWith(u8, trimmed, "Jumping from")) {
        return null;
    }

    // "<a href...>NAME</a> is inviting you to a conversation"
    if (std.mem.indexOf(u8, trimmed, "is inviting you to a conversation") != null) {
        return .{ .ntype = .ConversationInvite };
    }

    return genericEvent(trimmed);
}
