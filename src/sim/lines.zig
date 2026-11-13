//! What the simulator writes into EVE's log files: their names, headers and lines; no I/O.
const std = @import("std");
const chat_lines = @import("../chatlog/lines.zig");
const gamelog_events = @import("../notifications/gamelog_events.zig");

pub const LOCAL_CHANNEL = "Local";
/// EVE starts each chatlog line with one, inside the UTF-16 file's own.
const LINE_BOM = "\u{FEFF}";
/// EVE's own limit.
pub const MAX_CHARACTER_NAME_LENGTH = 37;
/// Longer names are cut; real ones run under 20.
pub const MAX_SYSTEM_NAME_LENGTH = 64;
/// Ends both kinds of log name.
const NAME_END = "_{d}.txt";
/// EVE's character IDs; matches the PowerShell simulator's, so a character keeps its ID.
const CHARACTER_ID_BASE = 1000000000;
const CHARACTER_ID_SPAN = 1147483647;
/// Fleet logs are named after the fleet's number; one fleet is enough here.
const FLEET_CHANNEL_ID = "fleet_1207012318337";

/// A UTC moment, broken down for EVE's stamps.
pub const Stamp = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,

    /// `seconds` is UTC Unix time.
    pub fn fromUnix(seconds: u64) Stamp {
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds };
        const year_day = epoch_seconds.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const time = epoch_seconds.getDaySeconds();
        return .{
            .year = year_day.year,
            .month = month_day.month.numeric(),
            .day = month_day.day_index + 1,
            .hour = time.getHoursIntoDay(),
            .minute = time.getMinutesIntoHour(),
            .second = time.getSecondsIntoMinute(),
        };
    }

    /// "yyyy.MM.dd HH:mm:ss", as inside a line's brackets.
    fn writeLine(self: Stamp, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d:0>4}.{d:0>2}.{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ self.year, self.month, self.day, self.hour, self.minute, self.second });
    }

    /// "yyyyMMdd_HHmmss", as in a log's file name.
    fn writeFile(self: Stamp, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}", .{ self.year, self.month, self.day, self.hour, self.minute, self.second });
    }
};

/// The one-shot gamelog lines, each raising one NotificationType.
pub const Alert = enum {
    fleet_invite,
    fleet_follow,
    fleet_regroup,
    fleet_disband,
    mining_compression,
    asteroid_depleted,
    cargo_full,
    crystal_broke,
    warp_scrambled,
    warp_disrupted,
    decloak,
    observatory_decloak,
    cloak_failed,
    bomb_launcher_empty,
    self_destruct,
    warp_bubble,
    docking,
    autopilot_reached,
    autopilot_approaching,
    jump_range,
    aggression_cant_jump,
    cloaked_cant_warp,
    conduit_jump,
    jump_cloning,
    conversation_invite,

    /// The NotificationType it raises, spelled as notification.zig spells it.
    pub fn notificationName(self: Alert) []const u8 {
        return switch (self) {
            .fleet_invite => "FleetInvite",
            .fleet_follow => "FleetFollow",
            .fleet_regroup => "FleetRegroup",
            .fleet_disband => "FleetDisband",
            .mining_compression => "MiningCompression",
            .asteroid_depleted => "AsteroidDepleted",
            .cargo_full => "CargoFull",
            .crystal_broke => "CrystalBroke",
            .warp_scrambled => "WarpScrambled",
            .warp_disrupted => "WarpDisrupted",
            .decloak => "Decloak",
            .observatory_decloak => "ObservatoryDecloak",
            .cloak_failed => "CloakFailed",
            .bomb_launcher_empty => "BombLauncherEmpty",
            .self_destruct => "SelfDestruct",
            .warp_bubble => "WarpBubble",
            .docking => "Docking",
            .autopilot_reached => "AutopilotReached",
            .autopilot_approaching => "AutopilotApproaching",
            .jump_range => "JumpRange",
            .aggression_cant_jump => "AggressionCantJump",
            .cloaked_cant_warp => "CloakedCantWarp",
            .conduit_jump => "ConduitJump",
            .jump_cloning => "JumpCloning",
            .conversation_invite => "ConversationInvite",
        };
    }

    /// After the timestamp; a conduit jump names `destination`.
    pub fn write(self: Alert, writer: *std.Io.Writer, destination: []const u8) std.Io.Writer.Error!void {
        switch (self) {
            .fleet_invite => try writer.writeAll("(question) Someone wants you to join their fleet, do you accept?"),
            .fleet_follow => try writer.writeAll("(notify) Following Fleet Commander in warp"),
            .fleet_regroup => try writer.writeAll("(notify) Regrouping to Fleet Commander"),
            .fleet_disband => try writer.writeAll("(notify) Your fleet is disbanding"),
            .mining_compression => try writer.writeAll("(notify) Successfully compressed Veldspar into 10 Compressed Veldspar"),
            .asteroid_depleted => try writer.writeAll("(notify) Your Miner II deactivates as it finds the resource it was harvesting a pale shadow of its former glory."),
            .cargo_full => try writer.writeAll("(notify) Your Miner II has completed operations. Ship's cargo hold is full."),
            .crystal_broke => try writer.writeAll("(notify) Mining Laser Upgrade II deactivates due to the destruction of the Mining Crystal II."),
            .warp_scrambled => try writer.writeAll("(combat) Warp scramble attempt from Hostile Pilot to you!"),
            .warp_disrupted => try writer.writeAll("(combat) Warp disruption attempt from Hostile Pilot to you!"),
            .decloak => try writer.writeAll("(notify) Your cloak deactivates due to proximity to a nearby Purifier."),
            .observatory_decloak => try writer.writeAll("(notify) Your cloak deactivates due to a pulse from a Mobile Observatory in the area."),
            .cloak_failed => try writer.writeAll("(notify) Your cloaking systems are unable to activate due to your ship being within 2000m of a hostile."),
            .bomb_launcher_empty => try writer.writeAll("(notify) Bomb Launcher II has run out of charges"),
            .self_destruct => try writer.writeAll("(notify) Your Capsule will self-destruct in 5 seconds."),
            .warp_bubble => try writer.writeAll("(notify) You are within a warp disruption zone. Get 20000.0 meters from Warp Disrupt Probe to warp."),
            .docking => try writer.writeAll("(notify) You cannot do that while docking."),
            .autopilot_reached => try writer.writeAll("(notify) Autopilot disabled - Waypoint reached"),
            .autopilot_approaching => try writer.writeAll("(notify) Autopilot approaching target"),
            .jump_range => try writer.writeAll("(notify) Please get within 2500 meters of the stargate to jump."),
            .aggression_cant_jump => try writer.writeAll("(notify) The stargate denies you permission to jump for the moment due to your recent acts of aggression."),
            .cloaked_cant_warp => try writer.writeAll("(notify) You cannot warp while you are cloaked."),
            .conduit_jump => try writer.print("(notify) A Conduit Field jumps you to {s}.", .{destination}),
            .jump_cloning => try writer.writeAll("(notify) Starting clone jumping"),
            .conversation_invite => try writer.writeAll("(None) Some Pilot is inviting you to a conversation"),
        }
    }
};

/// Repeated gamelog lines that the activity trackers count.
pub const Activity = enum {
    bounty,
    combat_in,
    combat_out,
    miss,

    /// After the timestamp; amounts are drawn from `random`.
    pub fn write(self: Activity, writer: *std.Io.Writer, random: std.Random) std.Io.Writer.Error!void {
        switch (self) {
            .bounty => try writer.print("(bounty) <font size=12><b><color=0xff00aa00>{f} ISK</b><color=0x77ffffff> added to next bounty payout (payment adjusted)", .{Thousands{ .value = random.intRangeLessThan(u32, 1000, 500000) }}),
            .combat_in => try writer.print("(combat) <color=0xffcc0000><b>{d}</b> <color=0x77ffffff><font size=10>from</font> <b><color=0xffffffff>Gist Seraphim</b><font size=10><color=0x77ffffff> - Heavy Missile - Hits", .{random.intRangeLessThan(u32, 10, 500)}),
            .combat_out => try writer.print("(combat) <color=0xff00ffff><b>{d}</b> <color=0x77ffffff><font size=10>to</font> <b><color=0xffffffff>Gistatis Tribunus</b><font size=10><color=0x77ffffff> - Nova Cruise Missile - Hits", .{random.intRangeLessThan(u32, 10, 500)}),
            .miss => try writer.writeAll("(combat) Gist Seraphim misses you completely"),
        }
    }
};

/// One line of MINING_REPLAY.
const Replayed = struct {
    /// From the replay's start.
    offset_seconds: u16,
    /// After the timestamp.
    text: []const u8,
};

/// 3 minutes of real mining from a captured gamelog: two lasers on 12s cycles, with two critical successes.
pub const MINING_REPLAY = blk: {
    const Yield = struct { offset_seconds: u16, units: u16, is_critical: bool = false };
    const yields = [_]Yield{
        .{ .offset_seconds = 0, .units = 110 },                        .{ .offset_seconds = 0, .units = 110 },
        .{ .offset_seconds = 12, .units = 111 },                       .{ .offset_seconds = 12, .units = 112 },
        .{ .offset_seconds = 24, .units = 114 },                       .{ .offset_seconds = 24, .units = 112 },
        .{ .offset_seconds = 36, .units = 114 },                       .{ .offset_seconds = 36, .units = 112 },
        .{ .offset_seconds = 48, .units = 112 },                       .{ .offset_seconds = 48, .units = 111 },
        .{ .offset_seconds = 60, .units = 111 },                       .{ .offset_seconds = 60, .units = 113 },
        .{ .offset_seconds = 72, .units = 111 },                       .{ .offset_seconds = 72, .units = 114 },
        .{ .offset_seconds = 84, .units = 112 },                       .{ .offset_seconds = 84, .units = 112 },
        .{ .offset_seconds = 96, .units = 111 },                       .{ .offset_seconds = 96, .units = 113 },
        .{ .offset_seconds = 108, .units = 111 },                      .{ .offset_seconds = 108, .units = 110 },
        .{ .offset_seconds = 120, .units = 160, .is_critical = true }, .{ .offset_seconds = 120, .units = 113 },
        .{ .offset_seconds = 120, .units = 114 },                      .{ .offset_seconds = 132, .units = 110 },
        .{ .offset_seconds = 132, .units = 111 },                      .{ .offset_seconds = 144, .units = 113 },
        .{ .offset_seconds = 144, .units = 113 },                      .{ .offset_seconds = 156, .units = 110 },
        .{ .offset_seconds = 156, .units = 111 },                      .{ .offset_seconds = 168, .units = 113 },
        .{ .offset_seconds = 168, .units = 187, .is_critical = true }, .{ .offset_seconds = 168, .units = 114 },
        .{ .offset_seconds = 180, .units = 110 },                      .{ .offset_seconds = 180, .units = 113 },
    };
    @setEvalBranchQuota(100000);
    const ore = "<color=0xffffffff><font size=12>Nocxite II-Grade";
    var replay: [yields.len]Replayed = undefined;
    for (yields, &replay) |yield, *line| {
        const text = if (yield.is_critical)
            std.fmt.comptimePrint("(mining) <color=#fff0ff45>Critical mining success!<color=0x77ffffff><font size=10> You mined an additional <color=#fff0ff45><font size=12>{d}<color=0x77ffffff><font size=10> units of ", .{yield.units}) ++ ore
        else
            std.fmt.comptimePrint("(mining) <color=0x77ffffff>You mined <font size=12><color=#ff8dc169>{d}<color=0x77ffffff><font size=10> units of ", .{yield.units}) ++ ore;
        line.* = .{ .offset_seconds = yield.offset_seconds, .text = text };
    }
    const fixed = replay;
    break :blk fixed;
};

/// "1,234,567", as EVE prints ISK.
const Thousands = struct {
    value: u32,

    pub fn format(self: Thousands, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var digits_buf: [10]u8 = undefined;
        const digits = std.fmt.bufPrint(&digits_buf, "{d}", .{self.value}) catch unreachable;
        for (digits, 0..) |digit, index| {
            if (index > 0 and (digits.len - index) % 3 == 0) try writer.writeByte(',');
            try writer.writeByte(digit);
        }
    }
};

/// Hashed rather than random, so a character keeps one ID across runs, as in EVE.
pub fn characterId(name: []const u8) u64 {
    var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(name, &digest, .{});
    return CHARACTER_ID_BASE + @as(u64, std.mem.readInt(u32, digest[0..4], .little)) % CHARACTER_ID_SPAN;
}

/// "<channel>_yyyyMMdd_HHmmss_<id>.txt".
pub fn writeChatlogName(writer: *std.Io.Writer, channel: []const u8, started: Stamp, character_id: u64) std.Io.Writer.Error!void {
    try writer.print("{s}_", .{channel});
    try started.writeFile(writer);
    try writer.print(NAME_END, .{character_id});
}

/// "yyyyMMdd_HHmmss_<id>.txt".
pub fn writeGamelogName(writer: *std.Io.Writer, started: Stamp, character_id: u64) std.Io.Writer.Error!void {
    try started.writeFile(writer);
    try writer.print(NAME_END, .{character_id});
}

/// The header of a captured chatlog, LF-separated, then its first line: Local's system, or another channel's MOTD.
pub fn writeChatlogHeader(writer: *std.Io.Writer, channel: []const u8, listener: []const u8, started: Stamp, system: []const u8) std.Io.Writer.Error!void {
    const dashes = "        ---------------------------------------------------------------";
    try writer.writeAll("\r\n\r\n\n\n" ++ dashes ++ "\n\n          Channel ID:      ");
    try writeChannelId(writer, channel);
    try writer.print("\n          Channel Name:    {s}\n          Listener:        {s}\n          Session started: ", .{ channel, listener });
    try started.writeLine(writer);
    try writer.writeAll("\n" ++ dashes ++ "\n\n");
    if (std.mem.eql(u8, channel, LOCAL_CHANNEL)) return writeLocalChange(writer, started, system);
    // Names a system and a keyword, as a real MOTD can: EVE's own lines must never alert.
    var motd_buf: [160]u8 = undefined;
    const motd = std.fmt.bufPrint(&motd_buf, "Channel MOTD: Welcome to {s}. Report every bubble near Jita and Perimeter.", .{channel[0..@min(channel.len, MAX_SYSTEM_NAME_LENGTH)]}) catch unreachable;
    try writeChatLine(writer, started, "EVE System", motd);
}

/// "[ stamp ] speaker > text", CRLF-terminated, led by EVE's per-line BOM.
pub fn writeChatLine(writer: *std.Io.Writer, stamp: Stamp, speaker: []const u8, text: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll(LINE_BOM ++ "[ ");
    try stamp.writeLine(writer);
    try writer.print(" ] {s} > {s}\r\n", .{ speaker, text });
}

pub fn writeLocalChange(writer: *std.Io.Writer, stamp: Stamp, system: []const u8) std.Io.Writer.Error!void {
    var text_buf: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "Channel changed to Local : {s}", .{system[0..@min(system.len, MAX_SYSTEM_NAME_LENGTH)]}) catch unreachable;
    try writeChatLine(writer, stamp, "EVE System", text);
}

/// CRLF-separated, ending with the hint line EVE writes on joining.
pub fn writeGamelogHeader(writer: *std.Io.Writer, listener: []const u8, started: Stamp) std.Io.Writer.Error!void {
    const dashes = "------------------------------------------------------------";
    try writer.print(dashes ++ "\r\n  Gamelog\r\n  Listener: {s}\r\n  Session Started: ", .{listener});
    try started.writeLine(writer);
    try writer.writeAll("\r\n" ++ dashes ++ "\r\n");
    try writeGameLine(writer, started, "(hint) Attempting to join a channel");
}

/// "[ stamp ] text", CRLF-terminated.
pub fn writeGameLine(writer: *std.Io.Writer, stamp: Stamp, text: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll("[ ");
    try stamp.writeLine(writer);
    try writer.print(" ] {s}\r\n", .{text});
}

pub fn writeJump(writer: *std.Io.Writer, stamp: Stamp, from: []const u8, to: []const u8) std.Io.Writer.Error!void {
    var text_buf: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "Jumping from {s} to {s}", .{ from[0..@min(from.len, MAX_SYSTEM_NAME_LENGTH)], to[0..@min(to.len, MAX_SYSTEM_NAME_LENGTH)] }) catch unreachable;
    try writeGameLine(writer, stamp, text);
}

/// Letters and digits kept, anything else an underscore, for a file named after a character.
pub fn writeSafeName(writer: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    for (name) |byte| try writer.writeByte(if (std.ascii.isAlphanumeric(byte)) byte else '_');
}

/// As in real logs: built-in channels have fixed IDs, a fleet its fleet's number, and a player channel a hash.
fn writeChannelId(writer: *std.Io.Writer, channel: []const u8) std.Io.Writer.Error!void {
    const fixed_ids = [_]struct { []const u8, []const u8 }{
        .{ LOCAL_CHANNEL, "local" },
        .{ "Corp", "corp" },
        .{ "Alliance", "alliance" },
        .{ "Fleet", FLEET_CHANNEL_ID },
    };
    for (fixed_ids) |fixed| {
        if (std.mem.eql(u8, channel, fixed[0])) return writer.writeAll(fixed[1]);
    }
    var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(channel, &digest, .{});
    try writer.print("player_{s}", .{&std.fmt.bytesToHex(digest, .lower)});
}

const testing = std.testing;
/// 2026-11-06 21:04:05 UTC.
const TEST_SECONDS = 1793999045;
/// TEST_SECONDS as a gamelog line starts.
const TEST_LINE_START = "[ 2026.11.06 21:04:05 ] ";

test "a log name's stamp reads back as the same moment" {
    var name_buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&name_buf);
    try writeGamelogName(&writer, Stamp.fromUnix(TEST_SECONDS), 1480182092);
    const timestamp = chat_lines.logFileTimestamp(writer.buffered(), false);
    try testing.expectEqual(@as(?i64, TEST_SECONDS), chat_lines.logTimestampToUnixSeconds(timestamp));
}

test "character IDs match the PowerShell simulator's" {
    try testing.expectEqual(@as(u64, 1480182092), characterId("Test Client 1"));
    try testing.expectEqual(@as(u64, 1443042026), characterId("Aria Kestrel"));
}

test "a player channel's ID is its name's MD5" {
    var id_buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&id_buf);
    try writeChannelId(&writer, "Intel Test");
    try testing.expectEqualStrings("player_feab51c03054529f1fd22f1bf014a53d", writer.buffered());
}

test "a chatlog name gives the app its channel and character ID" {
    var name_buf: [96]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&name_buf);
    try writeChatlogName(&writer, "east.imperium", Stamp.fromUnix(TEST_SECONDS), 1480182092);
    const channel_file = chat_lines.channelFile(writer.buffered()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("east.imperium", channel_file.channel);
    try testing.expectEqualStrings("1480182092", chat_lines.characterIdFromFileName(writer.buffered()) orelse "");
}

test "a Local header names its listener and system" {
    var header_buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&header_buf);
    try writeChatlogHeader(&writer, LOCAL_CHANNEL, "Test Client 1", Stamp.fromUnix(TEST_SECONDS), "Jita");
    try testing.expectEqualStrings("Test Client 1", chat_lines.listenerName(writer.buffered()) orelse "");
    try testing.expectEqualStrings("Jita", (chat_lines.lastSystemInChat(writer.buffered()) orelse return error.TestUnexpectedResult).system);
}

test "another channel's MOTD is never read as someone talking" {
    var header_buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&header_buf);
    try writeChatlogHeader(&writer, "Intel Test", "Test Client 1", Stamp.fromUnix(TEST_SECONDS), "Jita");
    const header = writer.buffered();
    const last_line_start = std.mem.findLast(u8, header, LINE_BOM) orelse return error.TestUnexpectedResult;
    try testing.expect(chat_lines.parseChatMessage(header[last_line_start..]) == null);
}

test "a chat line reads back as its speaker and message" {
    var line_buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&line_buf);
    try writeChatLine(&writer, Stamp.fromUnix(TEST_SECONDS), "Scout One", "Perimeter 3 hostiles on gate");
    const message = chat_lines.parseChatMessage(std.mem.trimEnd(u8, writer.buffered(), "\r\n")) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Scout One", message.speaker);
    try testing.expectEqualStrings("Perimeter 3 hostiles on gate", message.body);
}

test "a jump line moves the character to its destination" {
    var line_buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&line_buf);
    try writeJump(&writer, Stamp.fromUnix(TEST_SECONDS), "Jita", "New Caldari");
    const change = chat_lines.parseGameLine(writer.buffered()).system orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("New Caldari", change.system);
    try testing.expectEqual(chat_lines.SystemSource.jump, change.source);
}

test "every alert line raises the notification it's named for" {
    for (std.enums.values(Alert)) |alert| {
        var line_buf: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&line_buf);
        try writer.writeAll(TEST_LINE_START);
        try alert.write(&writer, "Amarr");
        const raised = gamelog_events.classify(writer.buffered()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(alert.notificationName(), @tagName(raised.notification_type));
    }
}

test "a conduit jump also moves the character" {
    var line_buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&line_buf);
    try writer.writeAll(TEST_LINE_START);
    try Alert.conduit_jump.write(&writer, "Amarr");
    const change = chat_lines.parseGameLine(writer.buffered()).system orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Amarr", change.system);
}

test "activity lines are counted as their activity" {
    var random_source: std.Random.DefaultPrng = .init(1);
    const expected = [_]struct { Activity, chat_lines.Activity }{
        .{ .bounty, .bounty },
        .{ .combat_in, .event },
        .{ .combat_out, .event },
        .{ .miss, .event },
    };
    for (expected) |pair| {
        var line_buf: [512]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&line_buf);
        try writer.writeAll(TEST_LINE_START);
        try pair[0].write(&writer, random_source.random());
        try testing.expectEqual(@as(?chat_lines.Activity, pair[1]), chat_lines.parseGameLine(writer.buffered()).activity);
    }
}

test "the mining replay runs three minutes in order" {
    try testing.expectEqual(@as(u16, 180), MINING_REPLAY[MINING_REPLAY.len - 1].offset_seconds);
    for (MINING_REPLAY[0 .. MINING_REPLAY.len - 1], MINING_REPLAY[1..]) |first, second| {
        try testing.expect(first.offset_seconds <= second.offset_seconds);
    }
}

test "ISK amounts are grouped in thousands" {
    var amount_buf: [16]u8 = undefined;
    try testing.expectEqualStrings("1,234,567", try std.fmt.bufPrint(&amount_buf, "{f}", .{Thousands{ .value = 1234567 }}));
    try testing.expectEqualStrings("999", try std.fmt.bufPrint(&amount_buf, "{f}", .{Thousands{ .value = 999 }}));
}
