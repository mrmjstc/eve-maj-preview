//! Which chat messages raise an alert, and for which client; no I/O.
const std = @import("std");
const chat_alerts = @import("../config/chat_alerts.zig");
const system_colors = @import("../config/system_colors.zig");
const notification = @import("../notifications/notification.zig");
const universe = @import("../map/universe.zig");
const lines = @import("lines.zig");

const ChatAlertConfig = chat_alerts.ChatAlertConfig;
const ChatAlertKind = chat_alerts.ChatAlertKind;
const SystemIndex = universe.SystemIndex;
const ClientSet = std.StaticBitSet(MAX_CLIENTS);

/// Clients can log the same line up to 2s apart, so this is well past that and short of a real repeat.
pub const DUPLICATE_WINDOW_MS = 5000;
/// Past it, further clients can't be chosen for an alert.
pub const MAX_CLIENTS = 64;
pub const MAX_MENTIONS = 8;
/// "Old Man Star" is the longest.
const MAX_NAME_WORDS = 3;
const RECENT_HIT_CAPACITY = 64;
/// Case-folded.
const CLEAR_WORDS = [_][]const u8{ "clear", "clr" };
/// What separates words when looking for system names; hyphens don't, as they're part of many names, and players often star a system.
const WORD_BREAKS = " \t,.;:!?()[]\"/*";

pub const Client = struct {
    /// Owned by whoever holds the list.
    character_name: []const u8,
    system: SystemIndex,
};

const Keyword = struct {
    /// As typed, for the alert to show; in the rule set's arena.
    text: []const u8,
    /// See foldCase; in the rule set's arena.
    folded: []const u8,
};

const Rule = struct {
    /// Its place in the profile's list, as rules here are sorted by kind.
    config_index: usize,
    kind: ChatAlertKind,
    /// In the rule set's arena.
    channels: []const u8,
    /// In the rule set's arena.
    keywords: []const Keyword,
    /// Each one case-folded; in the rule set's arena.
    exclude: []const []const u8,
    max_jumps: u8,
    cooldown_ms: u32,
};

pub const IntelReport = struct {
    /// Every system the message names, for the Intel Panel; borrows from the caller's buffer.
    systems: []const SystemIndex,
    /// How many of `systems`, from the first, get a map pin; a rule's exclusions keep the rest off the map.
    pin_count: usize = 0,
    /// The message calls the first of `systems` clear, rather than reporting something in it.
    is_clear: bool = false,
};

pub const Hit = struct {
    notification_type: notification.NotificationType,
    /// The system or keyword it matched; borrows from the rule set or the embedded map.
    term: []const u8,
    /// Intel only.
    jumps: ?u8 = null,
    /// Indices into the caller's list of the clients tied for nearest; empty when any client will do.
    nearest_clients: ClientSet = .empty,
    /// See Rule.config_index; set by firstHit.
    rule_index: usize = 0,
    /// Which rule and term share the cooldown; set by firstHit.
    cooldown_key: u64 = 0,
    cooldown_ms: u32 = 0,
};

/// A compiled copy of the profile's rules, so a later edit of the profile can't change them under the reader.
pub const RuleSet = struct {
    allocator: std.mem.Allocator,
    /// Owned; a pointer, so a RuleSet can be moved.
    arena: *std.heap.ArenaAllocator,
    /// By kind, then as listed in the profile; in `arena`.
    rules: []const Rule,
    /// Characters whose chat alerts the user turned off, in `arena`; they never receive one, so another client must.
    muted_characters: []const []const u8,

    /// Copies what it keeps; disabled rules, and ones that can't match, are left out.
    pub fn init(allocator: std.mem.Allocator, configs: []const ChatAlertConfig, muted_characters: []const []const u8) !RuleSet {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = .init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        var rules: std.ArrayList(Rule) = .empty;
        for (std.enums.values(ChatAlertKind)) |kind| {
            for (configs, 0..) |rule_config, config_index| {
                if (rule_config.kind != kind or !rule_config.enabled) continue;
                const rule = try compile(arena_allocator, rule_config, config_index);
                if (canMatch(&rule)) try rules.append(arena_allocator, rule);
            }
        }

        const muted = try arena_allocator.alloc([]const u8, muted_characters.len);
        for (muted, muted_characters) |*copy, name| copy.* = try arena_allocator.dupe(u8, name);
        return .{ .allocator = allocator, .arena = arena, .rules = rules.items, .muted_characters = muted };
    }

    pub fn deinit(self: *RuleSet) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }

    pub fn followsChannel(self: *const RuleSet, channel: []const u8) bool {
        for (self.rules) |*rule| {
            if (matchesChannel(rule.channels, channel)) return true;
        }
        return false;
    }

    /// Searched linearly: there are only ever a few.
    pub fn isMuted(self: *const RuleSet, character_name: []const u8) bool {
        for (self.muted_characters) |muted| {
            if (std.mem.eql(u8, muted, character_name)) return true;
        }
        return false;
    }

    /// What `message` says if an intel rule follows `channel`, at any distance from a client; a clear report's first system passes the rule's exclusions for a pin, and systems fill `out`.
    pub fn intelReport(self: *const RuleSet, channel: []const u8, message: lines.ChatMessage, out: []SystemIndex) IntelReport {
        var folded_buf: [lines.MAX_LINE_LENGTH]u8 = undefined;
        const folded = foldCase(message.body, &folded_buf);
        const is_clear = saysClear(folded);
        var is_followed = false;
        var is_excluded_by_all = true;
        for (self.rules) |*rule| {
            if (rule.kind != .intel or !matchesChannel(rule.channels, channel)) continue;
            is_followed = true;
            if (!isExcluded(rule, folded)) is_excluded_by_all = false;
        }
        if (!is_followed) return .{ .systems = out[0..0] };

        const systems = mentionedSystems(message.body, out);
        const pin_count = if (!is_excluded_by_all) systems.len else if (is_clear) @min(systems.len, 1) else 0;
        return .{ .systems = systems, .pin_count = pin_count, .is_clear = is_clear };
    }

    /// `clients` are the characters intel is measured from, at most MAX_CLIENTS.
    pub fn firstHit(self: *const RuleSet, channel: []const u8, message: lines.ChatMessage, clients: []const Client) ?Hit {
        var folded_buf: [lines.MAX_LINE_LENGTH]u8 = undefined;
        const folded = foldCase(message.body, &folded_buf);
        var mention_buf: [MAX_MENTIONS]SystemIndex = undefined;
        const mentions = mentionedSystems(message.body, &mention_buf);

        for (self.rules, 0..) |*rule, index| {
            if (!matchesChannel(rule.channels, channel) or isExcluded(rule, folded)) continue;
            var hit = (switch (rule.kind) {
                .intel => intelHit(rule, mentions, clients),
                .keyword => keywordHit(rule, folded),
            }) orelse continue;
            hit.rule_index = rule.config_index;
            hit.cooldown_key = std.hash.Wyhash.hash(index, hit.term);
            hit.cooldown_ms = rule.cooldown_ms;
            return hit;
        }
        return null;
    }
};

/// Only hits go in, so a small ring lasts.
pub const RecentHits = struct {
    entries: [RECENT_HIT_CAPACITY]Entry = @splat(.{}),
    next_index: usize = 0,

    const Entry = struct { key: u64 = 0, expires_ms: u64 = 0 };

    /// Whether `key` is still remembered; if not, it is for `lifetime_ms` from now.
    pub fn isRepeat(self: *RecentHits, key: u64, now_ms: u64, lifetime_ms: u64) bool {
        for (self.entries) |entry| {
            if (entry.key == key and entry.expires_ms > now_ms) return true;
        }
        self.entries[self.next_index] = .{ .key = key, .expires_ms = now_ms + lifetime_ms };
        self.next_index = (self.next_index + 1) % RECENT_HIT_CAPACITY;
        return false;
    }
};

/// The channel is left out, so a message pasted into two channels alerts once.
pub fn messageKey(message: lines.ChatMessage) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(message.speaker);
    hasher.update(">");
    hasher.update(message.body);
    return hasher.final();
}

fn compile(arena: std.mem.Allocator, rule_config: ChatAlertConfig, config_index: usize) !Rule {
    var keywords: std.ArrayList(Keyword) = .empty;
    if (rule_config.kind == .keyword) {
        var parts = termIterator(rule_config.keywords);
        while (parts.next()) |raw| {
            const text = std.mem.trim(u8, raw, " \t");
            if (text.len > 0) try keywords.append(arena, .{ .text = try arena.dupe(u8, text), .folded = try foldedCopy(arena, text) });
        }
    }

    var exclude: std.ArrayList([]const u8) = .empty;
    var parts = termIterator(rule_config.exclude);
    while (parts.next()) |raw| {
        const text = std.mem.trim(u8, raw, " \t");
        if (text.len > 0) try exclude.append(arena, try foldedCopy(arena, text));
    }

    return .{
        .config_index = config_index,
        .kind = rule_config.kind,
        .channels = try arena.dupe(u8, rule_config.channels),
        .keywords = keywords.items,
        .exclude = exclude.items,
        .max_jumps = rule_config.max_jumps,
        .cooldown_ms = rule_config.cooldown_ms,
    };
}

fn termIterator(list: []const u8) std.mem.TokenIterator(u8, .scalar) {
    return std.mem.tokenizeScalar(u8, list, ',');
}

fn foldedCopy(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const copy = try arena.alloc(u8, text.len);
    return foldCase(text, copy);
}

fn canMatch(rule: *const Rule) bool {
    if (std.mem.trim(u8, rule.channels, " \t,").len == 0) return false;
    return switch (rule.kind) {
        .intel => true,
        .keyword => rule.keywords.len > 0,
    };
}

fn matchesChannel(patterns: []const u8, channel: []const u8) bool {
    var parts = termIterator(patterns);
    while (parts.next()) |raw| {
        const pattern = std.mem.trim(u8, raw, " \t");
        if (pattern.len > 0 and system_colors.globMatch(pattern, channel)) return true;
    }
    return false;
}

fn isExcluded(rule: *const Rule, folded_body: []const u8) bool {
    for (rule.exclude) |word| {
        if (containsWord(folded_body, word)) return true;
    }
    return false;
}

/// "Hek clr?" asks and "Hek not clear" warns, so neither counts; a pin wrongly marked safe is the costly mistake.
fn saysClear(folded_body: []const u8) bool {
    if (std.mem.indexOfScalar(u8, folded_body, '?') != null or containsWord(folded_body, "not")) return false;
    for (CLEAR_WORDS) |word| {
        if (containsWord(folded_body, word)) return true;
    }
    return false;
}

fn keywordHit(rule: *const Rule, folded_body: []const u8) ?Hit {
    for (rule.keywords) |keyword| {
        if (containsWord(folded_body, keyword.folded)) return .{ .notification_type = rule.kind.notificationType(), .term = keyword.text };
    }
    return null;
}

fn intelHit(rule: *const Rule, mentions: []const SystemIndex, clients: []const Client) ?Hit {
    var nearest: ?Hit = null;
    var nearest_jumps: u8 = universe.UNREACHED;
    var distances: universe.Distances = undefined;
    for (mentions) |system| {
        universe.measureDistances(system, rule.max_jumps, &distances);
        for (clients, 0..) |client, index| {
            const jumps = distances[client.system];
            if (jumps == universe.UNREACHED or jumps > nearest_jumps) continue;
            if (jumps < nearest_jumps) {
                nearest_jumps = jumps;
                nearest = .{ .notification_type = rule.kind.notificationType(), .term = universe.systemName(system), .jumps = jumps };
            }
            if (nearest) |*hit| hit.nearest_clients.set(index);
        }
    }
    return nearest;
}

/// In order, each once.
fn mentionedSystems(body: []const u8, out: []SystemIndex) []const SystemIndex {
    var mention_count: usize = 0;
    var words = std.mem.tokenizeAny(u8, body, WORD_BREAKS);
    while (mention_count < out.len) {
        const first = words.next() orelse break;
        const start = words.index - first.len;
        var system = mentionedSystem(first);

        // The longest name wins, so "Old Man Star" isn't taken for a word of it.
        var ahead = words;
        for (1..MAX_NAME_WORDS) |_| {
            _ = ahead.next() orelse break;
            if (mentionedSystem(body[start..ahead.index])) |longer| {
                system = longer;
                words = ahead;
            }
        }

        const found = system orelse continue;
        if (std.mem.indexOfScalar(SystemIndex, out[0..mention_count], found) != null) continue;
        out[mention_count] = found;
        mention_count += 1;
    }
    return out[0..mention_count];
}

/// A name with a digit or hyphen is unmistakable in any case; one that's an ordinary word ("Pain", "Reset") must be written as it's spelled.
fn mentionedSystem(text: []const u8) ?SystemIndex {
    const system = universe.findSystem(text) orelse return null;
    const name = universe.systemName(system);
    for (name) |c| {
        if (c == '-' or std.ascii.isDigit(c)) return system;
    }
    return if (std.mem.eql(u8, name, text)) system else null;
}

/// Both already case-folded.
fn containsWord(text: []const u8, word: []const u8) bool {
    var start: usize = 0;
    while (std.mem.findPos(u8, text, start, word)) |index| {
        const end = index + word.len;
        const is_start_clear = index == 0 or !isWordByte(text[index - 1]);
        const is_end_clear = end == text.len or !isWordByte(text[end]);
        if (is_start_clear and is_end_clear) return true;
        start = index + 1;
    }
    return false;
}

/// Bytes of a multi-byte character count, so a word's letters in any script stay together.
fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '\'' or byte >= 0x80;
}

/// Lowers ASCII and Russian letters, which keep their length in UTF-8; cut to `out`'s length, and the result points into it.
fn foldCase(text: []const u8, out: []u8) []const u8 {
    const length = @min(text.len, out.len);
    @memcpy(out[0..length], text[0..length]);
    var i: usize = 0;
    while (i < length) : (i += 1) {
        const byte = out[i];
        if (byte < 0x80) {
            out[i] = std.ascii.toLower(byte);
        } else if (byte == 0xD0 and i + 1 < length) {
            const next = out[i + 1];
            i += 1;
            switch (next) {
                // U+0401, Ё.
                0x81 => {
                    out[i - 1] = 0xD1;
                    out[i] = 0x91;
                },
                // А to П stay on the 0xD0 lead byte; Р to Я move to 0xD1.
                0x90...0x9F => out[i] = next + 0x20,
                0xA0...0xAF => {
                    out[i - 1] = 0xD1;
                    out[i] = next - 0x20;
                },
                else => {},
            }
        }
    }
    return out[0..length];
}

const testing = std.testing;

const NO_MUTES: []const []const u8 = &.{};

fn clientAt(character_name: []const u8, system_name: []const u8) Client {
    return .{ .character_name = character_name, .system = universe.findSystem(system_name).? };
}

fn said(body: []const u8) lines.ChatMessage {
    return .{ .speaker = "Some Pilot", .body = body };
}

test "an intel rule picks the client nearest the mentioned system" {
    var rules = try RuleSet.init(testing.allocator, &.{.{ .channels = "*.imperium", .max_jumps = 5 }}, NO_MUTES);
    defer rules.deinit();
    const clients = [_]Client{ clientAt("Far", "Jita"), clientAt("Near", "Perimeter"), clientAt("Same", "Maurasi") };

    const hit = rules.firstHit("east.imperium", said("Maurasi hostile gang"), &clients).?;
    try testing.expectEqual(notification.NotificationType.ChatIntel, hit.notification_type);
    try testing.expectEqualStrings("Maurasi", hit.term);
    try testing.expectEqual(@as(?u8, 0), hit.jumps);
    try testing.expectEqual(@as(usize, 1), hit.nearest_clients.count());
    try testing.expect(hit.nearest_clients.isSet(2));
}

test "an intel rule names every client tied for nearest, and only them" {
    var rules = try RuleSet.init(testing.allocator, &.{.{ .channels = "*", .max_jumps = 5 }}, NO_MUTES);
    defer rules.deinit();
    const clients = [_]Client{ clientAt("Near", "Perimeter"), clientAt("Same", "Maurasi"), clientAt("Also Same", "Maurasi") };

    const hit = rules.firstHit("Fleet", said("Maurasi hostile gang"), &clients).?;
    try testing.expectEqual(@as(usize, 2), hit.nearest_clients.count());
    try testing.expect(hit.nearest_clients.isSet(1));
    try testing.expect(hit.nearest_clients.isSet(2));
}

test "an intel rule ignores systems out of range" {
    var rules = try RuleSet.init(testing.allocator, &.{.{ .channels = "*", .max_jumps = 5 }}, NO_MUTES);
    defer rules.deinit();
    const clients = [_]Client{clientAt("Trader", "Jita")};
    try testing.expect(rules.firstHit("Fleet", said("C-J6MT hostile"), &clients) == null);
    try testing.expect(rules.firstHit("Fleet", said("Perimeter hostile"), &clients) != null);
}

test "intelReport pins systems out of alert range, but not in other channels or excluded lines" {
    var rules = try RuleSet.init(testing.allocator, &.{.{ .channels = "I. * Intel", .max_jumps = 1, .exclude = "nv" }}, NO_MUTES);
    defer rules.deinit();
    var buffer: [MAX_MENTIONS]SystemIndex = undefined;
    try testing.expectEqual(@as(usize, 1), rules.intelReport("I. Delve Intel", said("C-J6MT hostile"), &buffer).pin_count);
    try testing.expectEqual(@as(usize, 0), rules.intelReport("Corp", said("C-J6MT hostile"), &buffer).systems.len);
    try testing.expectEqual(@as(usize, 0), rules.intelReport("I. Delve Intel", said("C-J6MT nv"), &buffer).pin_count);
}

test "an excluded line still reports its systems for the feed, without a pin" {
    var rules = try RuleSet.init(testing.allocator, &.{.{ .channels = "I. * Intel", .exclude = "nv" }}, NO_MUTES);
    defer rules.deinit();
    var buffer: [MAX_MENTIONS]SystemIndex = undefined;
    const report = rules.intelReport("I. Delve Intel", said("C-J6MT nv"), &buffer);
    try testing.expectEqual(@as(usize, 1), report.systems.len);
    try testing.expectEqual(@as(usize, 0), report.pin_count);
}

test "a line excluded by one rule still pins for another following the channel" {
    var rules = try RuleSet.init(testing.allocator, &.{ .{ .channels = "I. * Intel", .exclude = "nv" }, .{ .channels = "I. *" } }, NO_MUTES);
    defer rules.deinit();
    var buffer: [MAX_MENTIONS]SystemIndex = undefined;
    try testing.expectEqual(@as(usize, 1), rules.intelReport("I. Delve Intel", said("C-J6MT nv"), &buffer).pin_count);
}

test "a starred system is found, in alerts and on the map" {
    var rules = try RuleSet.init(testing.allocator, &.{.{ .channels = "I. * Intel", .max_jumps = 1 }}, NO_MUTES);
    defer rules.deinit();
    var buffer: [MAX_MENTIONS]SystemIndex = undefined;
    const report = rules.intelReport("I. Delve Intel", said("Hatsashin Purvanen  C-J6MT*"), &buffer);
    try testing.expectEqual(@as(usize, 1), report.systems.len);
    try testing.expectEqual(universe.findSystem("C-J6MT").?, report.systems[0]);
    const clients = [_]Client{clientAt("Trader", "Perimeter")};
    try testing.expect(rules.firstHit("I. Delve Intel", said("Perimeter* 9+"), &clients) != null);
}

test "only a clear report's first system passes a rule's exclusions" {
    var rules = try RuleSet.init(testing.allocator, &.{.{ .channels = "I. * Intel", .exclude = "clr" }}, NO_MUTES);
    defer rules.deinit();
    var buffer: [MAX_MENTIONS]SystemIndex = undefined;
    const report = rules.intelReport("I. Delve Intel", said("C-J6MT clr, watch X-1QGA"), &buffer);
    try testing.expect(report.is_clear);
    try testing.expectEqual(@as(usize, 2), report.systems.len);
    try testing.expectEqual(@as(usize, 1), report.pin_count);
    try testing.expectEqual(universe.findSystem("C-J6MT").?, report.systems[0]);
}

test "a rule without the exclusion keeps a clear report's other systems" {
    var rules = try RuleSet.init(testing.allocator, &.{.{ .channels = "I. * Intel" }}, NO_MUTES);
    defer rules.deinit();
    var buffer: [MAX_MENTIONS]SystemIndex = undefined;
    const report = rules.intelReport("I. Delve Intel", said("C-J6MT clr, watch X-1QGA"), &buffer);
    try testing.expect(report.is_clear);
    try testing.expectEqual(@as(usize, 2), report.pin_count);
}

test "a clear report passes a rule's exclusions, but a question or a denial doesn't count" {
    var rules = try RuleSet.init(testing.allocator, &.{.{ .channels = "I. * Intel", .exclude = "clr, clear" }}, NO_MUTES);
    defer rules.deinit();
    var buffer: [MAX_MENTIONS]SystemIndex = undefined;
    const clear = rules.intelReport("I. Delve Intel", said("C-J6MT CLR"), &buffer);
    try testing.expectEqual(@as(usize, 1), clear.pin_count);
    try testing.expect(clear.is_clear);
    try testing.expect(rules.intelReport("I. Delve Intel", said("C-J6MT clear"), &buffer).is_clear);
    try testing.expect(!rules.intelReport("I. Delve Intel", said("C-J6MT hostile"), &buffer).is_clear);
    try testing.expectEqual(@as(usize, 0), rules.intelReport("I. Delve Intel", said("C-J6MT clr?"), &buffer).pin_count);
    try testing.expectEqual(@as(usize, 0), rules.intelReport("I. Delve Intel", said("C-J6MT not clear"), &buffer).pin_count);
}

test "only channels a rule names are followed, and the Utopia in Corp stays quiet" {
    var rules = try RuleSet.init(testing.allocator, &.{.{ .channels = "I. * Intel, Fleet" }}, NO_MUTES);
    defer rules.deinit();
    const clients = [_]Client{clientAt("Main", "Utopia")};
    try testing.expect(rules.followsChannel("I. Delve Intel"));
    try testing.expect(rules.followsChannel("fleet"));
    try testing.expect(!rules.followsChannel("Corp"));
    try testing.expect(rules.firstHit("Corp", said("Utopia is nice"), &clients) == null);
}

test "a word in exclude stops a message matching its rule" {
    var rules = try RuleSet.init(testing.allocator, &.{.{ .channels = "*", .exclude = "clr, all clear" }}, NO_MUTES);
    defer rules.deinit();
    const clients = [_]Client{clientAt("Main", "Jita")};
    try testing.expect(rules.firstHit("Fleet", said("Jita CLR"), &clients) == null);
    try testing.expect(rules.firstHit("Fleet", said("Jita All Clear now"), &clients) == null);
    try testing.expect(rules.firstHit("Fleet", said("Jita clear"), &clients) != null);
}

test "a keyword matches a whole word in any case, in Russian too" {
    var rules = try RuleSet.init(testing.allocator, &.{.{ .kind = .keyword, .channels = "*", .keywords = "bubble, warp in, Пузырь" }}, NO_MUTES);
    defer rules.deinit();
    const hit = rules.firstHit("Fleet", said("BUBBLE on gate"), &.{}).?;
    try testing.expectEqual(notification.NotificationType.ChatKeyword, hit.notification_type);
    try testing.expectEqualStrings("bubble", hit.term);
    try testing.expectEqual(@as(usize, 0), hit.nearest_clients.count());
    try testing.expect(rules.firstHit("Fleet", said("Warp In now"), &.{}) != null);
    try testing.expect(rules.firstHit("Fleet", said("пузырь на гейте"), &.{}) != null);
    try testing.expect(rules.firstHit("Fleet", said("bubbles everywhere"), &.{}) == null);
    try testing.expect(rules.firstHit("Fleet", said("rebubble"), &.{}) == null);
}

test "intel beats a keyword, however the rules are listed" {
    const configs = [_]ChatAlertConfig{
        .{ .kind = .keyword, .channels = "*", .keywords = "bubble" },
        .{ .kind = .intel, .channels = "*", .max_jumps = 1 },
    };
    var rules = try RuleSet.init(testing.allocator, &configs, NO_MUTES);
    defer rules.deinit();
    const clients = [_]Client{clientAt("Main", "Jita")};
    try testing.expectEqual(notification.NotificationType.ChatIntel, rules.firstHit("Fleet", said("bubble in Perimeter"), &clients).?.notification_type);
    try testing.expectEqual(notification.NotificationType.ChatKeyword, rules.firstHit("Fleet", said("bubble in C-J6MT"), &clients).?.notification_type);
}

test "a hit names its rule's place in the profile, not its place after sorting by kind" {
    const configs = [_]ChatAlertConfig{
        .{ .kind = .keyword, .channels = "*", .keywords = "bubble" },
        .{ .kind = .intel, .channels = "*", .max_jumps = 1 },
    };
    var rules = try RuleSet.init(testing.allocator, &configs, NO_MUTES);
    defer rules.deinit();
    const clients = [_]Client{clientAt("Main", "Jita")};
    try testing.expectEqual(@as(usize, 1), rules.firstHit("Fleet", said("Perimeter hostile"), &clients).?.rule_index);
    try testing.expectEqual(@as(usize, 0), rules.firstHit("Fleet", said("bubble"), &clients).?.rule_index);
}

test "disabled rules and ones that can't match are left out" {
    const configs = [_]ChatAlertConfig{
        .{ .enabled = false, .channels = "*" },
        .{ .channels = " , " },
        .{ .kind = .keyword, .channels = "*", .keywords = " , " },
    };
    var rules = try RuleSet.init(testing.allocator, &configs, NO_MUTES);
    defer rules.deinit();
    try testing.expectEqual(@as(usize, 0), rules.rules.len);
    try testing.expect(!rules.followsChannel("Fleet"));
}

test "isMuted reads the copied character names" {
    const muted = [_][]const u8{"Alt"};
    var rules = try RuleSet.init(testing.allocator, &.{}, &muted);
    defer rules.deinit();
    try testing.expect(rules.isMuted("Alt"));
    try testing.expect(!rules.isMuted("Main"));
}

test "mentionedSystems reads names in any case, and multi-word ones, each once" {
    var buffer: [MAX_MENTIONS]SystemIndex = undefined;
    const found = mentionedSystems("c-j6mt, Old Man Star (Jita) c-j6mt", &buffer);
    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expectEqualStrings("C-J6MT", universe.systemName(found[0]));
    try testing.expectEqualStrings("Old Man Star", universe.systemName(found[1]));
    try testing.expectEqualStrings("Jita", universe.systemName(found[2]));
}

test "a system named like an ordinary word must be written as it's spelled" {
    var buffer: [MAX_MENTIONS]SystemIndex = undefined;
    try testing.expectEqual(@as(usize, 0), mentionedSystems("that was a pain, reset it", &buffer).len);
    try testing.expectEqual(@as(usize, 1), mentionedSystems("hostile in Pain", &buffer).len);
}

test "mentionedSystems stops at its limit" {
    var buffer: [2]SystemIndex = undefined;
    try testing.expectEqual(@as(usize, 2), mentionedSystems("Jita Amarr Dodixie", &buffer).len);
}

test "RecentHits remembers a key until its lifetime ends" {
    var recent: RecentHits = .{};
    try testing.expect(!recent.isRepeat(1, 1000, DUPLICATE_WINDOW_MS));
    try testing.expect(recent.isRepeat(1, 1000 + DUPLICATE_WINDOW_MS - 1, DUPLICATE_WINDOW_MS));
    try testing.expect(!recent.isRepeat(1, 1000 + DUPLICATE_WINDOW_MS, DUPLICATE_WINDOW_MS));
    try testing.expect(!recent.isRepeat(2, 1000, DUPLICATE_WINDOW_MS));
}

test "RecentHits with no lifetime never repeats" {
    var recent: RecentHits = .{};
    try testing.expect(!recent.isRepeat(1, 1000, 0));
    try testing.expect(!recent.isRepeat(1, 1000, 0));
}

test "messageKey ignores which client saw it but not who said what" {
    try testing.expectEqual(messageKey(said("hello")), messageKey(said("hello")));
    try testing.expect(messageKey(said("hello")) != messageKey(said("hello there")));
    try testing.expect(messageKey(.{ .speaker = "A", .body = "x" }) != messageKey(.{ .speaker = "B", .body = "x" }));
}

test "foldCase lowers ASCII and Russian, including Ё, and leaves other text alone" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("abc-1", foldCase("AbC-1", &buffer));
    try testing.expectEqualStrings("привет ёж", foldCase("ПРИВЕТ ЁЖ", &buffer));
    try testing.expectEqualStrings("ñ", foldCase("ñ", &buffer));
}
