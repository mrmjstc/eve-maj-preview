//! The systems a few gates out from one system, and the intel pinned on them, for a thumbnail's overlay; no I/O.
const std = @import("std");
const universe = @import("universe.zig");
const intel_pins = @import("intel_pins.zig");

const IntelPins = intel_pins.IntelPins;
const SystemIndex = universe.SystemIndex;

pub const MAX_JUMPS = 3;
/// Fits what MAX_JUMPS reaches from anywhere, 63 systems at most; a test holds it to that.
pub const CAPACITY = 64;
/// So an aging pin redraws its thumbnail now and then, not every tick.
const STEP_PERCENT = 5;

/// What to mark, and over how long a new pin's halo shrinks.
pub const IntelView = struct {
    /// Borrowed for the call.
    pins: *const IntelPins,
    shrink_ms: u64,
};

pub const Connection = struct {
    system: SystemIndex = 0,
    /// From the start, which is the first connection and the only one at 0.
    jumps: u8 = 0,
    /// Of a live pin, in STEP_PERCENT steps; 0 for no pin.
    intel_freshness_percent: u8 = 0,
    /// How far a pin's halo has shrunk, in STEP_PERCENT steps.
    intel_shrink_percent: u8 = 0,
    /// The pin's latest report called the system clear.
    is_clear: bool = false,

    /// Returns whether it changed.
    fn markIntel(self: *Connection, intel: ?IntelView, now_ms: u64) bool {
        var marked: Connection = .{ .system = self.system, .jumps = self.jumps };
        if (intel) |view| {
            if (view.pins.find(self.system, now_ms)) |pin| {
                marked.intel_freshness_percent = stepUp(pin.freshnessPercent(now_ms));
                marked.intel_shrink_percent = shrinkPercent(now_ms -| pin.seen_ms, view.shrink_ms);
                marked.is_clear = pin.is_clear;
            }
        }
        if (std.meta.eql(marked, self.*)) return false;
        self.* = marked;
        return true;
    }
};

/// The start, then what lies around it, nearest first; the search stops at the region's edge, keeping only the gates' far ends.
pub const Connections = struct {
    items: [CAPACITY]Connection = @splat(.{}),
    count: usize = 0,
    /// Null shows nothing.
    start: ?SystemIndex = null,
    max_jumps: u8 = 0,

    /// `max_jumps` is at most MAX_JUMPS.
    fn init(start: SystemIndex, max_jumps: u8) Connections {
        var self: Connections = .{ .start = start, .max_jumps = max_jumps, .count = 1 };
        self.items[0] = .{ .system = start };
        const region = universe.systemInfo(start).region;
        var head: usize = 0;
        while (head < self.count and self.items[head].jumps < max_jumps) : (head += 1) {
            const from = self.items[head];
            if (universe.systemInfo(from.system).region != region) continue;
            var links = universe.neighbours(from.system);
            while (links.next()) |neighbour| {
                if (self.count == CAPACITY) break;
                if (self.find(neighbour) != null) continue;
                self.items[self.count] = .{ .system = neighbour, .jumps = from.jumps + 1 };
                self.count += 1;
            }
        }
        return self;
    }

    pub fn slice(self: *const Connections) []const Connection {
        return self.items[0..self.count];
    }

    /// Follows `start` and the pins on what it reaches, leaving systems unmarked with no `intel`; returns whether anything shown changed.
    pub fn refresh(self: *Connections, start: ?SystemIndex, max_jumps: u8, intel: ?IntelView, now_ms: u64) bool {
        var has_changed = false;
        if (self.start != start or self.max_jumps != max_jumps) {
            self.* = if (start) |system| .init(system, max_jumps) else .{};
            has_changed = true;
        }
        for (self.items[0..self.count]) |*connection| {
            if (connection.markIntel(intel, now_ms)) has_changed = true;
        }
        return has_changed;
    }

    /// Who gets a name when there's no room for all: the start, then systems with intel, then the nearest.
    pub fn labelOrder(self: *const Connections, order: *[CAPACITY]u16) []const u16 {
        var order_count: usize = 0;
        for (self.slice(), 0..) |connection, index| {
            if (index > 0 and connection.intel_freshness_percent == 0) continue;
            order[order_count] = @intCast(index);
            order_count += 1;
        }
        for (self.slice(), 0..) |connection, index| {
            if (index == 0 or connection.intel_freshness_percent > 0) continue;
            order[order_count] = @intCast(index);
            order_count += 1;
        }
        return order[0..order_count];
    }

    /// Searched linearly: there are a few dozen at most.
    pub fn find(self: *const Connections, system: SystemIndex) ?Connection {
        for (self.slice()) |connection| {
            if (connection.system == system) return connection;
        }
        return null;
    }
};

/// Rounds up, so a live pin never reads as no pin.
fn stepUp(percent: u64) u8 {
    return @intCast((percent + STEP_PERCENT - 1) / STEP_PERCENT * STEP_PERCENT);
}

fn shrinkPercent(age_ms: u64, shrink_ms: u64) u8 {
    const percent = @min(100, age_ms * 100 / @max(1, shrink_ms));
    return @intCast(percent / STEP_PERCENT * STEP_PERCENT);
}

const testing = std.testing;

const TEST_SHRINK_MS: u64 = 60_000;

fn systemNamed(name: []const u8) !SystemIndex {
    return universe.findSystem(name) orelse error.TestExpectedSystem;
}

fn connectionTo(connections: *const Connections, name: []const u8) !Connection {
    return connections.find(try systemNamed(name)) orelse error.TestExpectedConnection;
}

fn testView(pins: *const IntelPins) IntelView {
    return .{ .pins = pins, .shrink_ms = TEST_SHRINK_MS };
}

test "the start comes first, then the rest nearest first" {
    const connections: Connections = .init(try systemNamed("Jita"), 3);
    const list = connections.slice();
    try testing.expectEqualStrings("Jita", universe.systemName(list[0].system));
    try testing.expectEqual(@as(u8, 0), list[0].jumps);
    for (list[1..], list[0 .. list.len - 1]) |connection, previous| {
        try testing.expect(connection.jumps >= previous.jumps);
    }
}

test "max_jumps limits how far it reaches" {
    const one_jump: Connections = .init(try systemNamed("Jita"), 1);
    for (one_jump.slice()) |connection| try testing.expect(connection.jumps <= 1);
    try testing.expectEqual(@as(u8, 1), (try connectionTo(&one_jump, "Perimeter")).jumps);
    try testing.expectError(error.TestExpectedConnection, connectionTo(&one_jump, "Urlen"));

    const two_jumps: Connections = .init(try systemNamed("Jita"), 2);
    try testing.expectEqual(@as(u8, 2), (try connectionTo(&two_jumps, "Urlen")).jumps);
}

test "the search takes a gate over the border, but doesn't carry on beyond it" {
    const connections: Connections = .init(try systemNamed("Dodixie"), 2);
    try testing.expectEqual(@as(u8, 1), (try connectionTo(&connections, "Athinard")).jumps);
    try testing.expectError(error.TestExpectedConnection, connectionTo(&connections, "Ethernity"));
    try testing.expectEqual(@as(u8, 2), (try connectionTo(&connections, "Aunia")).jumps);
    try testing.expectEqual(@as(u8, 2), (try connectionTo(&connections, "Blameston")).jumps);
}

test "CAPACITY holds what MAX_JUMPS reaches from every system" {
    var distances: universe.Distances = undefined;
    for (0..universe.SYSTEM_COUNT) |index| {
        const start: SystemIndex = @intCast(index);
        universe.measureDistances(start, MAX_JUMPS, &distances);
        var reached_count: usize = 0;
        for (distances) |jumps| {
            if (jumps != universe.UNREACHED) reached_count += 1;
        }
        try testing.expect(reached_count <= CAPACITY);
    }
}

test "refresh rebuilds after a move and shows nothing without a start" {
    var connections: Connections = .{};
    const jita = try systemNamed("Jita");
    try testing.expect(connections.refresh(jita, 2, null, 1000));
    try testing.expect(connections.count > 1);
    try testing.expect(!connections.refresh(jita, 2, null, 2000));
    try testing.expect(connections.refresh(jita, 1, null, 2000));
    try testing.expect(connections.refresh(try systemNamed("Amarr"), 1, null, 2000));
    try testing.expectEqualStrings("Amarr", universe.systemName(connections.slice()[0].system));
    try testing.expect(connections.refresh(null, 1, null, 2000));
    try testing.expectEqual(@as(usize, 0), connections.count);
}

test "refresh marks pinned systems, and changes only as they age a step" {
    var pins: IntelPins = .{};
    var connections: Connections = .{};
    const jita = try systemNamed("Jita");
    _ = connections.refresh(jita, 2, testView(&pins), 1000);

    pins.add(try systemNamed("Perimeter"), "hostile", 1000);
    try testing.expect(connections.refresh(jita, 2, testView(&pins), 1000));
    const marked = try connectionTo(&connections, "Perimeter");
    try testing.expectEqual(@as(u8, 100), marked.intel_freshness_percent);
    try testing.expectEqual(@as(u8, 0), marked.intel_shrink_percent);
    try testing.expectEqual(@as(u8, 0), (try connectionTo(&connections, "Jita")).intel_freshness_percent);

    try testing.expect(!connections.refresh(jita, 2, testView(&pins), 1500));
    try testing.expect(connections.refresh(jita, 2, testView(&pins), 1000 + TEST_SHRINK_MS / 2));
    try testing.expectEqual(@as(u8, 50), (try connectionTo(&connections, "Perimeter")).intel_shrink_percent);
    try testing.expect(connections.refresh(jita, 2, testView(&pins), 1000 + intel_pins.LIFETIME_MS / 2));
    const aged = try connectionTo(&connections, "Perimeter");
    try testing.expectEqual(@as(u8, 50), aged.intel_freshness_percent);
    try testing.expectEqual(@as(u8, 100), aged.intel_shrink_percent);
}

test "refresh shows a pin going clear and aging out" {
    var pins: IntelPins = .{};
    var connections: Connections = .{};
    const jita = try systemNamed("Jita");
    pins.add(jita, "hostile", 1000);
    _ = connections.refresh(jita, 1, testView(&pins), 1000);

    pins.markClear(jita, "clr", 2000);
    try testing.expect(connections.refresh(jita, 1, testView(&pins), 2000));
    try testing.expect(connections.slice()[0].is_clear);

    try testing.expect(connections.refresh(jita, 1, testView(&pins), 2000 + intel_pins.LIFETIME_MS));
    try testing.expectEqual(@as(u8, 0), connections.slice()[0].intel_freshness_percent);
    try testing.expect(!connections.slice()[0].is_clear);
}

test "refresh leaves systems unmarked without intel, as when the setting is off" {
    var pins: IntelPins = .{};
    var connections: Connections = .{};
    const jita = try systemNamed("Jita");
    pins.add(jita, "hostile", 1000);
    _ = connections.refresh(jita, 1, testView(&pins), 1000);
    try testing.expect(connections.refresh(jita, 1, null, 1000));
    try testing.expectEqual(@as(u8, 0), connections.slice()[0].intel_freshness_percent);
}

test "labelOrder puts the start first, then intel, then the nearest" {
    var pins: IntelPins = .{};
    var connections: Connections = .{};
    const jita = try systemNamed("Jita");
    const urlen = try systemNamed("Urlen");
    pins.add(urlen, "hostile", 1000);
    _ = connections.refresh(jita, 2, testView(&pins), 1000);

    var order_buffer: [CAPACITY]u16 = undefined;
    const order = connections.labelOrder(&order_buffer);
    try testing.expectEqual(connections.count, order.len);
    try testing.expectEqual(@as(u16, 0), order[0]);
    try testing.expectEqual(urlen, connections.items[order[1]].system);
    try testing.expectEqual(@as(u8, 1), connections.items[order[2]].jumps);
}

test "a pin about to age out still shows" {
    try testing.expectEqual(@as(u8, 5), stepUp(1));
    try testing.expectEqual(@as(u8, 5), stepUp(5));
    try testing.expectEqual(@as(u8, 10), stepUp(6));
    try testing.expectEqual(@as(u8, 0), stepUp(0));
}

test "a halo's shrink stops at its end" {
    try testing.expectEqual(@as(u8, 0), shrinkPercent(1000, 60_000));
    try testing.expectEqual(@as(u8, 50), shrinkPercent(30_000, 60_000));
    try testing.expectEqual(@as(u8, 100), shrinkPercent(120_000, 60_000));
    try testing.expectEqual(@as(u8, 100), shrinkPercent(1, 0));
}
