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

fn textBefore(text: []const u8, suffix: []const u8) ?[]const u8 {
    const end = std.mem.indexOf(u8, text, suffix) orelse return null;
    return nonEmpty(text[0..end]);
}

fn textAfter(text: []const u8, prefix: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, prefix) orelse return null;
    return nonEmpty(text[start + prefix.len ..]);
}

fn textBetween(text: []const u8, prefix: []const u8, suffix: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, text, prefix) orelse return null) + prefix.len;
    const end = std.mem.indexOfPos(u8, text, start, suffix) orelse return null;
    return nonEmpty(text[start..end]);
}

fn withoutYour(name: ?[]const u8) ?[]const u8 {
    const value = name orelse return null;
    if (!std.mem.startsWith(u8, value, "Your ")) return value;
    return nonEmpty(value["Your ".len..]);
}

fn nonEmpty(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t.");
    return if (trimmed.len == 0) null else trimmed;
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
        return .{ .ntype = .FleetInvite, .source = textBefore(trimmed, " wants you to join their fleet") };
    }

    return null;
}

fn parseNotifyEvent(message: []const u8) ?Notification {
    const trimmed = std.mem.trim(u8, message, " \t\r\n");

    // "Following [leader] in warp"
    if (std.mem.startsWith(u8, trimmed, "Following ") and std.mem.indexOf(u8, trimmed, " in warp") != null) {
        return .{ .ntype = .FleetFollow, .source = textBetween(trimmed, "Following ", " in warp") };
    }

    // "Regrouping to [leader]"
    if (std.mem.indexOf(u8, trimmed, "Regrouping to ") != null) {
        return .{ .ntype = .FleetRegroup, .source = textAfter(trimmed, "Regrouping to ") };
    }

    if (std.mem.indexOf(u8, trimmed, "Your fleet is disbanding") != null) {
        return .{ .ntype = .FleetDisband };
    }

    if (std.mem.indexOf(u8, trimmed, "Starting clone jumping") != null) {
        return .{ .ntype = .JumpCloning };
    }

    // "Successfully compressed [ore] into [count] [compressed]"
    if (std.mem.indexOf(u8, trimmed, "Successfully compressed") != null) {
        return .{ .ntype = .MiningCompression, .source = textBetween(trimmed, "compressed ", " into "), .target = textAfter(trimmed, " into ") };
    }

    // "[miner] deactivates as it finds the resource it was harvesting a pale shadow of its former glory."
    if (std.mem.indexOf(u8, trimmed, "a pale shadow of its former glory") != null) {
        return .{ .ntype = .AsteroidDepleted, .source = withoutYour(textBefore(trimmed, " deactivates as it finds")) };
    }

    // "Your [module] has completed operations. Ship's cargo hold is full."
    if (std.mem.indexOf(u8, trimmed, "cargo hold is full") != null) {
        return .{ .ntype = .CargoFull, .source = withoutYour(textBefore(trimmed, " has completed operations")) };
    }

    // Checked before the proximity decloak below, whose wording this also contains.
    if (std.mem.indexOf(u8, trimmed, "cloak deactivates") != null and
        std.mem.indexOf(u8, trimmed, "Mobile Observatory") != null)
    {
        return .{ .ntype = .ObservatoryDecloak };
    }

    // "Your cloak deactivates due to proximity to [source]"
    if (std.mem.indexOf(u8, trimmed, "cloak deactivates") != null) {
        return .{ .ntype = .Decloak, .source = textAfter(trimmed, "proximity to ") };
    }

    // "Your cloaking systems are unable to activate due to your ship being within..."
    if (std.mem.indexOf(u8, trimmed, "cloaking systems are unable to activate") != null) {
        return .{ .ntype = .CloakFailed };
    }

    // "[module] deactivates due to the destruction of the [crystal]"
    if (std.mem.indexOf(u8, trimmed, "deactivates due to the destruction") != null) {
        return .{ .ntype = .CrystalBroke, .source = withoutYour(textBefore(trimmed, " deactivates due to the destruction")), .target = textAfter(trimmed, "destruction of the ") };
    }

    // "Bomb Launcher II has run out of charges"
    if (std.mem.indexOf(u8, trimmed, "Bomb Launcher") != null and std.mem.indexOf(u8, trimmed, "has run out of charges") != null) {
        return .{ .ntype = .BombLauncherEmpty, .source = textBefore(trimmed, " has run out of charges") };
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
        return .{ .ntype = .WarpBubble, .source = textBetween(trimmed, "meters from ", " to warp") };
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
        return .{ .ntype = .WarpScrambled, .source = textBetween(trimmed, "attempt from ", " to you!") };
    }

    // Same "to you!" requirement as the scramble check above.
    if (std.mem.indexOf(u8, trimmed, "Warp disruption attempt") != null and
        std.mem.endsWith(u8, trimmed, "to you!"))
    {
        return .{ .ntype = .WarpDisrupted, .source = textBetween(trimmed, "attempt from ", " to you!") };
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
        return .{ .ntype = .ConversationInvite, .source = textBefore(trimmed, " is inviting you to a conversation") };
    }

    return genericEvent(trimmed);
}

const testing = std.testing;
const NotificationType = notification.NotificationType;

fn classifiedType(line: []const u8) ?NotificationType {
    const n = classify(line) orelse return null;
    return n.ntype;
}

test "classify maps each notify wording to its type" {
    const cases = [_]struct { []const u8, NotificationType }{
        .{ "[ 2026.09.06 16:13:00 ] (notify) Following Some Pilot in warp", .FleetFollow },
        .{ "[ 2026.09.06 16:13:00 ] (notify) Regrouping to Some Pilot", .FleetRegroup },
        .{ "[ 2026.09.06 16:13:00 ] (notify) Your fleet is disbanding", .FleetDisband },
        .{ "[ 2026.09.06 16:13:00 ] (notify) Starting clone jumping", .JumpCloning },
        .{ "[ 2026.09.06 16:13:00 ] (notify) Successfully compressed Veldspar into 10 Compressed Veldspar", .MiningCompression },
        .{ "[ 2026.09.06 16:13:00 ] (notify) Miner II deactivates as it finds the resource it was harvesting a pale shadow of its former glory.", .AsteroidDepleted },
        .{ "[ 2026.09.06 16:13:00 ] (notify) Your Miner II has completed operations. Ship's cargo hold is full.", .CargoFull },
        .{ "[ 2026.09.06 16:13:00 ] (notify) Your cloak deactivates due to proximity to a Stargate.", .Decloak },
        .{ "[ 2026.09.06 16:13:00 ] (notify) Your cloaking systems are unable to activate due to your ship being within 2000 meters", .CloakFailed },
        .{ "[ 2026.09.06 16:13:00 ] (notify) Modulated Strip Miner II deactivates due to the destruction of the Veldspar Mining Crystal", .CrystalBroke },
        .{ "[ 2026.09.06 16:13:00 ] (notify) Bomb Launcher II has run out of charges", .BombLauncherEmpty },
        .{ "[ 2026.09.06 16:13:00 ] (notify) You cannot do that while docking", .Docking },
        .{ "[ 2026.09.06 16:13:00 ] (notify) Autopilot disabled - Waypoint reached", .AutopilotReached },
        .{ "[ 2026.09.06 16:13:00 ] (notify) Autopilot approaching target", .AutopilotApproaching },
        .{ "[ 2026.09.06 16:13:00 ] (notify) Please get within 2500 meters of the stargate to jump.", .JumpRange },
        .{ "[ 2026.09.06 16:13:00 ] (notify) You are within a warp disruption zone. Get 20000.0 meters from Warp Disrupt Probe to warp.", .WarpBubble },
        .{ "[ 2026.09.06 16:13:00 ] (notify) The stargate denies you permission to jump for the moment due to your recent acts of aggression.", .AggressionCantJump },
    };
    for (cases) |case| {
        try testing.expectEqual(case[1], classifiedType(case[0]).?);
    }
    try testing.expect(classify("[ 2026.09.06 16:13:00 ] (notify) Something the app doesn't know about") == null);
}

test "classify tells an observatory decloak from a proximity decloak" {
    try testing.expectEqual(NotificationType.ObservatoryDecloak, classifiedType("[ 2026.09.06 16:13:00 ] (notify) Your cloak deactivates due to a pulse from a Mobile Observatory.").?);
}

test "classify only raises a scramble or disruption aimed at you" {
    try testing.expectEqual(NotificationType.WarpScrambled, classifiedType("[ 2026.09.06 16:13:00 ] (combat) Warp scramble attempt from Some Rat to you!").?);
    try testing.expectEqual(NotificationType.WarpDisrupted, classifiedType("[ 2026.09.06 16:13:00 ] (combat) Warp disruption attempt from Some Rat to you!").?);
    try testing.expect(classify("[ 2026.09.06 16:13:00 ] (combat) Warp scramble attempt from you to Some Rat!") == null);
    try testing.expect(classify("[ 2026.09.06 16:13:00 ] (combat) 484 from Some Rat - Heavy Missile - Hits") == null);
}

test "classify reads self-destruct start and abort, but not another player's" {
    const started = classify("[ 2026.09.06 16:13:00 ] (notify) Your ship will self-destruct in 120 seconds.").?;
    try testing.expectEqual(NotificationType.SelfDestruct, started.ntype);
    try testing.expectEqual(notification.State.started, started.state.?);

    const aborted = classify("[ 2026.09.06 16:13:00 ] (notify) You have aborted the self-destruct sequence.").?;
    try testing.expectEqual(notification.State.aborted, aborted.state.?);

    try testing.expect(classify("[ 2026.09.06 16:13:00 ] (notify) Some Pilot's ship will self-destruct in 120 seconds.") == null);
}

test "classify reads fleet and conversation invites" {
    try testing.expectEqual(NotificationType.FleetInvite, classifiedType("[ 2026.09.06 16:13:00 ] (question) Some Pilot wants you to join their fleet, do you accept?").?);
    try testing.expect(classify("[ 2026.09.06 16:13:00 ] (question) Are you sure you want to quit?") == null);
    try testing.expectEqual(NotificationType.ConversationInvite, classifiedType("[ 2026.09.06 16:13:00 ] (None) Some Pilot is inviting you to a conversation").?);
}

test "classify skips hints and jumps, and keeps untagged lines as generic" {
    try testing.expect(classify("[ 2026.09.06 23:07:39 ] (hint) Attempting to join a channel") == null);
    try testing.expect(classify("[ 2026.09.05 01:16:08 ] (None) Jumping from C-J6MT to 8-WYQZ") == null);

    const generic = classify("[ 2026.09.05 01:16:08 ] Session changed...").?;
    try testing.expectEqual(NotificationType.Generic, generic.ntype);
    try testing.expectEqualStrings("Session changed", generic.source.?);
    try testing.expect(classify("[ 2026.09.05 01:16:08 ]  ...") == null);
}

test "classify reads who a fleet or conversation invite is from" {
    try testing.expectEqualStrings("Some Pilot", classify("[ 2026.09.06 16:13:00 ] (question) Some Pilot wants you to join their fleet, do you accept?").?.source.?);
    try testing.expectEqualStrings("Some Pilot", classify("[ 2026.09.06 16:13:00 ] (None) Some Pilot is inviting you to a conversation").?.source.?);
}

test "classify reads the fleet leader being followed or regrouped to" {
    try testing.expectEqualStrings("Fleet Commander", classify("[ 2026.09.06 16:13:00 ] (notify) Following Fleet Commander in warp").?.source.?);
    try testing.expectEqualStrings("Fleet Commander", classify("[ 2026.09.06 16:13:00 ] (notify) Regrouping to Fleet Commander").?.source.?);
}

test "classify reads the ore and result of a compression" {
    const compressed = classify("[ 2026.09.06 16:13:00 ] (notify) Successfully compressed Veldspar into 10 Compressed Veldspar").?;
    try testing.expectEqualStrings("Veldspar", compressed.source.?);
    try testing.expectEqualStrings("10 Compressed Veldspar", compressed.target.?);
}

test "classify reads the module, dropping a leading Your" {
    try testing.expectEqualStrings("Miner II", classify("[ 2026.09.06 16:13:00 ] (notify) Your Miner II deactivates as it finds the resource it was harvesting a pale shadow of its former glory.").?.source.?);
    try testing.expectEqualStrings("Miner II", classify("[ 2026.09.06 16:13:00 ] (notify) Miner II deactivates as it finds the resource it was harvesting a pale shadow of its former glory.").?.source.?);
    try testing.expectEqualStrings("Miner II", classify("[ 2026.09.06 16:13:00 ] (notify) Your Miner II has completed operations. Ship's cargo hold is full.").?.source.?);
    try testing.expectEqualStrings("Bomb Launcher II", classify("[ 2026.09.06 16:13:00 ] (notify) Bomb Launcher II has run out of charges").?.source.?);
}

test "classify reads the module and crystal when a crystal breaks" {
    const broke = classify("[ 2026.09.06 16:13:00 ] (notify) Modulated Strip Miner II deactivates due to the destruction of the Veldspar Mining Crystal II.").?;
    try testing.expectEqualStrings("Modulated Strip Miner II", broke.source.?);
    try testing.expectEqualStrings("Veldspar Mining Crystal II", broke.target.?);
}

test "classify reads who scrambled or disrupted you" {
    try testing.expectEqualStrings("Some Rat", classify("[ 2026.09.06 16:13:00 ] (combat) Warp scramble attempt from Some Rat to you!").?.source.?);
    try testing.expectEqualStrings("Some Rat", classify("[ 2026.09.06 16:13:00 ] (combat) Warp disruption attempt from Some Rat to you!").?.source.?);
}

test "classify reads what decloaked you or holds you in a bubble" {
    try testing.expectEqualStrings("Guristas Pith Ship", classify("[ 2026.09.06 16:13:00 ] (notify) Your cloak deactivates due to proximity to Guristas Pith Ship.").?.source.?);
    try testing.expectEqualStrings("Warp Disrupt Probe", classify("[ 2026.09.06 16:13:00 ] (notify) You are within a warp disruption zone. Get 20000.0 meters from Warp Disrupt Probe to warp.").?.source.?);
}

test "classify leaves a field unset when the line has no name in it" {
    try testing.expect(classify("[ 2026.09.06 16:13:00 ] (notify) Following  in warp").?.source == null);
    try testing.expect(classify("[ 2026.09.06 16:13:00 ] (notify) Your fleet is disbanding").?.source == null);
}

test "classify reads the conduit destination" {
    const conduit = classify("[ 2026.09.06 16:13:01 ] (notify) The Conduit Field activated by Some Pilot jumps you to Ahbazon.").?;
    try testing.expectEqual(NotificationType.ConduitJump, conduit.ntype);
    try testing.expectEqualStrings("Ahbazon", conduit.target.?);
}

test "conduitDestination stops at the activator's passenger count" {
    try testing.expectEqualStrings("Ahbazon", conduitDestination("A Conduit Field activated by you jumps you to Ahbazon, bringing along 3 passengers.").?);
    try testing.expect(conduitDestination("A Conduit Field activated by you jumps you to .") == null);
    try testing.expect(conduitDestination("Something jumps you to Ahbazon.") == null);
}
