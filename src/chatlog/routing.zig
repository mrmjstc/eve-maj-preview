//! Which clients a chat alert goes to, where each client is, and which system reports count; no I/O.
const std = @import("std");
const universe = @import("../map/universe.zig");
const alert_rules = @import("alert_rules.zig");
const lines = @import("lines.zig");

const Client = alert_rules.Client;
const Hit = alert_rules.Hit;
const RecentHits = alert_rules.RecentHits;
const RuleSet = alert_rules.RuleSet;
const SystemIndex = universe.SystemIndex;

/// A chat message that alerts.
pub const Alert = struct {
    hit: Hit,
    /// Borrows from the listener's name or the clients'; empty when no client can show it.
    recipients: []const []const u8,
};

/// What a system report changes.
pub const SystemReport = struct {
    /// A gate jump or conduit, rather than an undock or Local naming where the character already was.
    is_jump: bool,
    /// Gate jumps only: an undock and Local report the same arrival, and would alert twice.
    notifies: bool,
};

/// Where each client last was, for measuring intel from; searched linearly, as there's one per client.
pub const ClientSystems = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct {
        /// Owned; freed in deinit or forget.
        character_name: []const u8,
        /// Null off the gate map, as in a wormhole.
        system: ?SystemIndex,
        /// See lines.SystemMatch; a quiet log can be read after a newer one.
        event_timestamp: u64,
    };

    pub fn deinit(self: *ClientSystems, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry.character_name);
        self.entries.deinit(allocator);
    }

    /// Ignores an update older than the one recorded, unless its timestamp is unknown (0); copies `character_name`.
    pub fn record(self: *ClientSystems, allocator: std.mem.Allocator, character_name: []const u8, system_name: []const u8, event_timestamp: u64) !void {
        const system = universe.findSystem(system_name);
        for (self.entries.items) |*entry| {
            if (!std.mem.eql(u8, entry.character_name, character_name)) continue;
            if (event_timestamp != 0 and event_timestamp < entry.event_timestamp) return;
            entry.system = system;
            entry.event_timestamp = event_timestamp;
            return;
        }

        const owned_name = try allocator.dupe(u8, character_name);
        errdefer allocator.free(owned_name);
        try self.entries.append(allocator, .{ .character_name = owned_name, .system = system, .event_timestamp = event_timestamp });
    }

    pub fn forget(self: *ClientSystems, allocator: std.mem.Allocator, character_name: []const u8) void {
        for (self.entries.items, 0..) |entry, index| {
            if (!std.mem.eql(u8, entry.character_name, character_name)) continue;
            allocator.free(entry.character_name);
            _ = self.entries.swapRemove(index);
            return;
        }
    }

    /// The clients intel is measured from: on the gate map and not muted; names borrow from the entries.
    pub fn alertable(self: *const ClientSystems, rules: *const RuleSet, buffer: []Client) []const Client {
        var client_count: usize = 0;
        for (self.entries.items) |entry| {
            if (client_count == buffer.len) break;
            const system = entry.system orelse continue;
            if (rules.isMuted(entry.character_name)) continue;
            buffer[client_count] = .{ .character_name = entry.character_name, .system = system };
            client_count += 1;
        }
        return buffer[0..client_count];
    }
};

/// Null when the message alerts no one: one of the user's own characters said it, no rule matches, another client's copy already alerted, or the rule's term is cooling down; `listener` logged the line.
pub fn route(rules: *const RuleSet, recent_hits: *RecentHits, channel: []const u8, listener: []const u8, message: lines.ChatMessage, is_own_character: bool, clients: []const Client, now_ms: u64, out: *[alert_rules.MAX_CLIENTS][]const u8) ?Alert {
    if (is_own_character) return null;
    const hit = rules.firstHit(channel, message, clients) orelse return null;
    if (recent_hits.isRepeat(alert_rules.messageKey(message), now_ms, alert_rules.DUPLICATE_WINDOW_MS)) return null;
    if (recent_hits.isRepeat(hit.cooldown_key, now_ms, hit.cooldown_ms)) return null;
    return .{ .hit = hit, .recipients = recipients(rules, hit, listener, clients, out) };
}

/// Null for an undock or Local report repeating the last system, which never holds back a jump; `last_hash` is the log's, and updated here.
pub fn systemReport(last_hash: *u64, system: []const u8, source: lines.SystemSource) ?SystemReport {
    const system_hash = std.hash.Wyhash.hash(0, system);
    const is_jump = source == .jump or source == .conduit;
    if (!is_jump and last_hash.* == system_hash) return null;
    last_hash.* = system_hash;
    return .{ .is_jump = is_jump, .notifies = source == .jump };
}

/// The clients tied for nearest; with none, the listener, or another client if the listener is muted, since its alert would never show.
fn recipients(rules: *const RuleSet, hit: Hit, listener: []const u8, clients: []const Client, out: *[alert_rules.MAX_CLIENTS][]const u8) []const []const u8 {
    var recipient_count: usize = 0;
    var nearest = hit.nearest_clients.iterator(.{});
    while (nearest.next()) |index| {
        out[recipient_count] = clients[index].character_name;
        recipient_count += 1;
    }
    if (recipient_count > 0) return out[0..recipient_count];

    if (!rules.isMuted(listener)) {
        out[0] = listener;
        return out[0..1];
    }
    if (clients.len == 0) return out[0..0];
    out[0] = clients[0].character_name;
    return out[0..1];
}

const testing = std.testing;

const NO_MUTES: []const []const u8 = &.{};
const NOW_MS: u64 = 1_000_000;

fn clientAt(character_name: []const u8, system_name: []const u8) Client {
    return .{ .character_name = character_name, .system = universe.findSystem(system_name).? };
}

fn said(speaker: []const u8, body: []const u8) lines.ChatMessage {
    return .{ .speaker = speaker, .body = body };
}

test "a newer system update replaces a client's last one, and an older one is ignored" {
    var systems: ClientSystems = .{};
    defer systems.deinit(testing.allocator);
    try systems.record(testing.allocator, "Pilot", "Jita", 200);
    try systems.record(testing.allocator, "Pilot", "Perimeter", 100);
    try testing.expectEqual(universe.findSystem("Jita"), systems.entries.items[0].system);
    try systems.record(testing.allocator, "Pilot", "Perimeter", 300);
    try testing.expectEqual(universe.findSystem("Perimeter"), systems.entries.items[0].system);
    try testing.expectEqual(@as(usize, 1), systems.entries.items.len);
}

test "a system update without a timestamp always applies" {
    var systems: ClientSystems = .{};
    defer systems.deinit(testing.allocator);
    try systems.record(testing.allocator, "Pilot", "Jita", 200);
    try systems.record(testing.allocator, "Pilot", "Perimeter", 0);
    try testing.expectEqual(universe.findSystem("Perimeter"), systems.entries.items[0].system);
}

test "forget drops only that client" {
    var systems: ClientSystems = .{};
    defer systems.deinit(testing.allocator);
    try systems.record(testing.allocator, "First", "Jita", 1);
    try systems.record(testing.allocator, "Second", "Perimeter", 1);
    systems.forget(testing.allocator, "First");
    try testing.expectEqual(@as(usize, 1), systems.entries.items.len);
    try testing.expectEqualStrings("Second", systems.entries.items[0].character_name);
}

test "alertable leaves out muted clients and ones off the gate map" {
    var rules = try RuleSet.init(testing.allocator, &.{.{ .channels = "*" }}, &.{"Muted"});
    defer rules.deinit();
    var systems: ClientSystems = .{};
    defer systems.deinit(testing.allocator);
    try systems.record(testing.allocator, "Muted", "Jita", 1);
    try systems.record(testing.allocator, "Wormhole", "J123456", 1);
    try systems.record(testing.allocator, "Trader", "Perimeter", 1);

    var buffer: [alert_rules.MAX_CLIENTS]Client = undefined;
    const clients = systems.alertable(&rules, &buffer);
    try testing.expectEqual(@as(usize, 1), clients.len);
    try testing.expectEqualStrings("Trader", clients[0].character_name);
}

test "a message from one of the user's own characters alerts no one" {
    var rules = try RuleSet.init(testing.allocator, &.{.{ .kind = .keyword, .channels = "*", .keywords = "cyno" }}, NO_MUTES);
    defer rules.deinit();
    var recent_hits: RecentHits = .{};
    var out: [alert_rules.MAX_CLIENTS][]const u8 = undefined;
    try testing.expect(route(&rules, &recent_hits, "Fleet", "Listener", said("Alt", "cyno up"), true, &.{}, NOW_MS, &out) == null);
}

test "an intel hit goes to every client tied for nearest" {
    var rules = try RuleSet.init(testing.allocator, &.{.{ .channels = "*", .max_jumps = 5 }}, NO_MUTES);
    defer rules.deinit();
    var recent_hits: RecentHits = .{};
    var out: [alert_rules.MAX_CLIENTS][]const u8 = undefined;
    const clients = [_]Client{ clientAt("Near", "Perimeter"), clientAt("Same", "Maurasi"), clientAt("Also Same", "Maurasi") };

    const alert = route(&rules, &recent_hits, "Fleet", "Near", said("Scout", "Maurasi hostile gang"), false, &clients, NOW_MS, &out).?;
    try testing.expectEqual(@as(usize, 2), alert.recipients.len);
    try testing.expectEqualStrings("Same", alert.recipients[0]);
    try testing.expectEqualStrings("Also Same", alert.recipients[1]);
}

test "a keyword hit goes to the client that logged the line" {
    var rules = try RuleSet.init(testing.allocator, &.{.{ .kind = .keyword, .channels = "*", .keywords = "cyno" }}, NO_MUTES);
    defer rules.deinit();
    var recent_hits: RecentHits = .{};
    var out: [alert_rules.MAX_CLIENTS][]const u8 = undefined;
    const clients = [_]Client{ clientAt("Other", "Jita"), clientAt("Listener", "Perimeter") };

    const alert = route(&rules, &recent_hits, "Fleet", "Listener", said("Scout", "cyno up"), false, &clients, NOW_MS, &out).?;
    try testing.expectEqual(@as(usize, 1), alert.recipients.len);
    try testing.expectEqualStrings("Listener", alert.recipients[0]);
}

test "a hit logged by a muted client goes to another client instead" {
    var rules = try RuleSet.init(testing.allocator, &.{.{ .kind = .keyword, .channels = "*", .keywords = "cyno" }}, &.{"Listener"});
    defer rules.deinit();
    var recent_hits: RecentHits = .{};
    var out: [alert_rules.MAX_CLIENTS][]const u8 = undefined;
    const clients = [_]Client{clientAt("Other", "Jita")};

    const alert = route(&rules, &recent_hits, "Fleet", "Listener", said("Scout", "cyno up"), false, &clients, NOW_MS, &out).?;
    try testing.expectEqualStrings("Other", alert.recipients[0]);
}

test "a hit with every client muted still alerts, but goes to no one" {
    var rules = try RuleSet.init(testing.allocator, &.{.{ .kind = .keyword, .channels = "*", .keywords = "cyno" }}, &.{"Listener"});
    defer rules.deinit();
    var recent_hits: RecentHits = .{};
    var out: [alert_rules.MAX_CLIENTS][]const u8 = undefined;

    const alert = route(&rules, &recent_hits, "Fleet", "Listener", said("Scout", "cyno up"), false, &.{}, NOW_MS, &out).?;
    try testing.expectEqual(@as(usize, 0), alert.recipients.len);
}

test "the same message logged by a second client alerts once" {
    var rules = try RuleSet.init(testing.allocator, &.{.{ .kind = .keyword, .channels = "*", .keywords = "cyno", .cooldown_ms = 0 }}, NO_MUTES);
    defer rules.deinit();
    var recent_hits: RecentHits = .{};
    var out: [alert_rules.MAX_CLIENTS][]const u8 = undefined;
    const message = said("Scout", "cyno up");

    try testing.expect(route(&rules, &recent_hits, "Fleet", "First", message, false, &.{}, NOW_MS, &out) != null);
    try testing.expect(route(&rules, &recent_hits, "Fleet", "Second", message, false, &.{}, NOW_MS + 1500, &out) == null);
    try testing.expect(route(&rules, &recent_hits, "Fleet", "First", message, false, &.{}, NOW_MS + alert_rules.DUPLICATE_WINDOW_MS + 1, &out) != null);
}

test "a rule's cooldown holds back its term from another message until it ends" {
    var rules = try RuleSet.init(testing.allocator, &.{.{ .kind = .keyword, .channels = "*", .keywords = "cyno", .cooldown_ms = 15000 }}, NO_MUTES);
    defer rules.deinit();
    var recent_hits: RecentHits = .{};
    var out: [alert_rules.MAX_CLIENTS][]const u8 = undefined;

    try testing.expect(route(&rules, &recent_hits, "Fleet", "Listener", said("Scout", "cyno up"), false, &.{}, NOW_MS, &out) != null);
    try testing.expect(route(&rules, &recent_hits, "Fleet", "Listener", said("Other Scout", "second cyno"), false, &.{}, NOW_MS + 10_000, &out) == null);
    try testing.expect(route(&rules, &recent_hits, "Fleet", "Listener", said("Third Scout", "cyno again"), false, &.{}, NOW_MS + 15_001, &out) != null);
}

test "a message no rule matches alerts no one" {
    var rules = try RuleSet.init(testing.allocator, &.{.{ .kind = .keyword, .channels = "Fleet", .keywords = "cyno" }}, NO_MUTES);
    defer rules.deinit();
    var recent_hits: RecentHits = .{};
    var out: [alert_rules.MAX_CLIENTS][]const u8 = undefined;
    try testing.expect(route(&rules, &recent_hits, "Fleet", "Listener", said("Scout", "all quiet"), false, &.{}, NOW_MS, &out) == null);
    try testing.expect(route(&rules, &recent_hits, "Corp", "Listener", said("Scout", "cyno up"), false, &.{}, NOW_MS, &out) == null);
}

test "a repeated undock or Local report is ignored, but a repeated jump isn't" {
    var last_hash: u64 = 0;
    try testing.expect(systemReport(&last_hash, "Jita", .undock) != null);
    try testing.expect(systemReport(&last_hash, "Jita", .chatlog) == null);
    try testing.expect(systemReport(&last_hash, "Jita", .undock) == null);
    try testing.expect(systemReport(&last_hash, "Jita", .jump) != null);
    try testing.expect(systemReport(&last_hash, "Jita", .conduit) != null);
    try testing.expect(systemReport(&last_hash, "Perimeter", .chatlog) != null);
}

test "only a gate jump notifies, though a conduit counts as a jump" {
    var last_hash: u64 = 0;
    const jump = systemReport(&last_hash, "Jita", .jump).?;
    try testing.expect(jump.is_jump and jump.notifies);
    const conduit = systemReport(&last_hash, "Perimeter", .conduit).?;
    try testing.expect(conduit.is_jump and !conduit.notifies);
    const undock = systemReport(&last_hash, "Maurasi", .undock).?;
    try testing.expect(!undock.is_jump and !undock.notifies);
}
