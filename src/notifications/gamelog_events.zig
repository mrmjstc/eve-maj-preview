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
        // Skip "(question) "
        return parseQuestionEvent(remaining[10..]);
    } else if (std.mem.startsWith(u8, remaining, "(notify)")) {
        // Skip "(notify) "
        return parseNotifyEvent(remaining[8..]);
    } else if (std.mem.startsWith(u8, remaining, "(None)")) {
        // Skip "(None) "
        return parseNoneEvent(remaining[6..]);
    } else if (std.mem.startsWith(u8, remaining, "(combat)")) {
        // Skip "(combat) "
        return parseCombatEvent(remaining[8..]);
    } else if (std.mem.startsWith(u8, remaining, "(hint)")) {
        // Skip hint spam
        return null;
    }

    return genericEvent(remaining);
}

fn genericEvent(message: []const u8) ?Notification {
    const cleaned = std.mem.trim(u8, message, " \t\r\n.");
    if (cleaned.len == 0) return null;
    return .{ .ntype = .Generic, .source = cleaned };
}

/// Parse (question) type events
fn parseQuestionEvent(message: []const u8) ?Notification {
    const trimmed = std.mem.trim(u8, message, " \t\r\n");

    // Fleet invite: "<a href...>NAME</a> wants you to join their fleet, do you accept?"
    if (std.mem.indexOf(u8, trimmed, "wants you to join their fleet")) |_| {
        return .{ .ntype = .FleetInvite };
    }

    // Skip other question dialogs (confirmations, prompts)
    return null;
}

/// Parse (notify) type events
fn parseNotifyEvent(message: []const u8) ?Notification {
    const trimmed = std.mem.trim(u8, message, " \t\r\n");

    // Follow warp: "Following [leader] in warp"
    if (std.mem.startsWith(u8, trimmed, "Following ") and std.mem.indexOf(u8, trimmed, " in warp") != null) {
        return .{ .ntype = .FleetFollow };
    }

    // Regroup: "Regrouping to [leader]"
    if (std.mem.indexOf(u8, trimmed, "Regrouping to ") != null) {
        return .{ .ntype = .FleetRegroup };
    }

    // Fleet disbanding: "Your fleet is disbanding"
    if (std.mem.indexOf(u8, trimmed, "Your fleet is disbanding") != null) {
        return .{ .ntype = .FleetDisband };
    }

    // Jump clone: "Starting clone jumping"
    if (std.mem.indexOf(u8, trimmed, "Starting clone jumping") != null) {
        return .{ .ntype = .JumpCloning };
    }

    // Compression: "Successfully compressed [ore] into [count] [compressed]"
    if (std.mem.indexOf(u8, trimmed, "Successfully compressed") != null) {
        return .{ .ntype = .MiningCompression };
    }

    // Asteroid depleted: "[miner] deactivates as it finds the resource it was harvesting
    // a pale shadow of its former glory."
    if (std.mem.indexOf(u8, trimmed, "a pale shadow of its former glory") != null) {
        return .{ .ntype = .AsteroidDepleted };
    }

    // Cargo hold full: "Your [module] has completed operations. Ship's cargo hold is full."
    if (std.mem.indexOf(u8, trimmed, "cargo hold is full") != null) {
        return .{ .ntype = .CargoFull };
    }

    // Observatory decloak: "Your cloak deactivates due to a pulse from a Mobile Observatory..."
    if (std.mem.indexOf(u8, trimmed, "cloak deactivates") != null and
        std.mem.indexOf(u8, trimmed, "Mobile Observatory") != null)
    {
        return .{ .ntype = .ObservatoryDecloak };
    }

    // Proximity decloak: "Your cloak deactivates due to proximity to [source]"
    if (std.mem.indexOf(u8, trimmed, "cloak deactivates") != null) {
        return .{ .ntype = .Decloak };
    }

    // Cloak failed: "Your cloaking systems are unable to activate due to your ship being within..."
    if (std.mem.indexOf(u8, trimmed, "cloaking systems are unable to activate") != null) {
        return .{ .ntype = .CloakFailed };
    }

    // Crystal broke: "[module] deactivates due to the destruction of the [crystal]"
    if (std.mem.indexOf(u8, trimmed, "deactivates due to the destruction") != null) {
        return .{ .ntype = .CrystalBroke };
    }

    // Bomb Launcher out of charges: "Bomb Launcher II has run out of charges"
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

    // Docking: "You cannot do that while docking."
    if (std.mem.indexOf(u8, trimmed, "You cannot do that while docking") != null) {
        return .{ .ntype = .Docking };
    }

    // Autopilot reached: "Autopilot disabled - Waypoint reached"
    if (std.mem.indexOf(u8, trimmed, "Autopilot disabled - Waypoint reached") != null) {
        return .{ .ntype = .AutopilotReached };
    }

    // Autopilot approaching: "Autopilot approaching target"
    if (std.mem.indexOf(u8, trimmed, "Autopilot approaching target") != null) {
        return .{ .ntype = .AutopilotApproaching };
    }

    // Jump range: "Please get within 2500 meters of the stargate to jump."
    if (std.mem.indexOf(u8, trimmed, "get within") != null and std.mem.indexOf(u8, trimmed, "stargate to jump") != null) {
        return .{ .ntype = .JumpRange };
    }

    // Warp disruption bubble: "You are within a warp disruption zone. Get 20000.0 meters
    // from Warp Disrupt Probe to warp."
    if (std.mem.indexOf(u8, trimmed, "within a warp disruption zone") != null) {
        return .{ .ntype = .WarpBubble };
    }

    // Aggression timer blocking jump: "The stargate denies you permission to jump for
    // the moment due to your recent acts of aggression."
    if (std.mem.indexOf(u8, trimmed, "recent acts of aggression") != null) {
        return .{ .ntype = .AggressionCantJump };
    }

    // Same comma-termination quirk as chatlog.zig's parseConduitJumpFromGamelog (activating character's line ends in "...N passengers." instead of a period).
    if (std.mem.indexOf(u8, trimmed, "Conduit Field") != null and
        std.mem.indexOf(u8, trimmed, "jumps you to") != null)
    {
        if (std.mem.indexOf(u8, trimmed, "jumps you to ")) |idx| {
            const after = trimmed[idx + "jumps you to ".len ..];
            const end = std.mem.indexOfAny(u8, after, "\r\n.,") orelse after.len;
            const system = std.mem.trim(u8, after[0..end], " \t");
            if (system.len > 0) return .{ .ntype = .ConduitJump, .target = system };
        }
        return .{ .ntype = .ConduitJump };
    }

    // Skip other generic notify messages
    return null;
}

/// Parse (combat) type events for the rare cases worth a popup (e.g. being
/// scrambled). Plain damage/miss lines are handled by the DPS tracker
/// elsewhere and are intentionally skipped here to avoid popup spam.
/// `message` must already have HTML stripped by the caller.
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

    // Skip other combat spam (damage/misses - handled by the DPS tracker, not popups)
    return null;
}

/// Parse (None) type events
fn parseNoneEvent(message: []const u8) ?Notification {
    const trimmed = std.mem.trim(u8, message, " \t\r\n");

    // System jump: "Jumping from [SystemA] to [SystemB]" - handled elsewhere
    if (std.mem.startsWith(u8, trimmed, "Jumping from")) {
        return null;
    }

    // Conversation invite: "<a href...>NAME</a> is inviting you to a conversation"
    if (std.mem.indexOf(u8, trimmed, "is inviting you to a conversation") != null) {
        return .{ .ntype = .ConversationInvite };
    }

    return genericEvent(trimmed);
}
