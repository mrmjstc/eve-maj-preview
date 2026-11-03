//! Systems named lately in intel channels, shown on the Map Panel until they age out; no I/O.
const std = @import("std");
const universe = @import("universe.zig");
const utf8 = @import("../util/utf8.zig");

const SystemIndex = universe.SystemIndex;

pub const LIFETIME_MS: u64 = 15 * std.time.ms_per_min;
const CAPACITY = 64;
const MESSAGE_MAX = 96;

pub const Pin = struct {
    system: SystemIndex = 0,
    /// In ms since boot; 0 for an unused slot.
    seen_ms: u64 = 0,
    /// The latest report called the system clear.
    is_clear: bool = false,
    message_buffer: [MESSAGE_MAX]u8 = undefined,
    message_length: usize = 0,

    /// Borrows from the pin.
    pub fn message(self: *const Pin) []const u8 {
        return self.message_buffer[0..self.message_length];
    }

    pub fn isLive(self: *const Pin, now_ms: u64) bool {
        return self.seen_ms != 0 and now_ms -| self.seen_ms < LIFETIME_MS;
    }

    /// 100 when fresh, falling to 0 as it ages out.
    pub fn freshnessPercent(self: *const Pin, now_ms: u64) u64 {
        if (!self.isLive(now_ms)) return 0;
        return 100 - (now_ms -| self.seen_ms) * 100 / LIFETIME_MS;
    }

    fn setMessage(self: *Pin, message_text: []const u8) void {
        const length = utf8.prefixLength(message_text, MESSAGE_MAX);
        @memcpy(self.message_buffer[0..length], message_text[0..length]);
        self.message_length = length;
    }
};

/// Main thread only.
pub const IntelPins = struct {
    pins: [CAPACITY]Pin = @splat(.{}),
    /// Changes with every new sighting, for the panel's redraw check.
    revision: u64 = 0,

    /// Each client logs the same line, so a repeat only refreshes the pin; a full list loses its oldest.
    pub fn add(self: *IntelPins, system: SystemIndex, message: []const u8, now_ms: u64) void {
        var slot = &self.pins[0];
        for (&self.pins) |*pin| {
            if (pin.seen_ms != 0 and pin.system == system) {
                slot = pin;
                break;
            }
            if (pin.seen_ms < slot.seen_ms) slot = pin;
        }
        slot.system = system;
        slot.seen_ms = now_ms;
        slot.is_clear = false;
        slot.setMessage(message);
        self.revision += 1;
    }

    /// Restarts the pin, so it shrinks again in its new colour; adds no pin, or quiet channels would fill the map with clear systems.
    pub fn markClear(self: *IntelPins, system: SystemIndex, message: []const u8, now_ms: u64) void {
        for (&self.pins) |*pin| {
            if (pin.system != system or !pin.isLive(now_ms)) continue;
            pin.seen_ms = now_ms;
            pin.is_clear = true;
            pin.setMessage(message);
            self.revision += 1;
            return;
        }
    }

    /// Searched linearly: there are few, and it's only asked per system shown.
    pub fn find(self: *const IntelPins, system: SystemIndex, now_ms: u64) ?*const Pin {
        for (&self.pins) |*pin| {
            if (pin.system == system and pin.isLive(now_ms)) return pin;
        }
        return null;
    }
};

const testing = std.testing;

test "a pin lasts its lifetime and fades" {
    var pins: IntelPins = .{};
    pins.add(7, "hostile", 1000);
    const pin = pins.find(7, 1000).?;
    try testing.expectEqualStrings("hostile", pin.message());
    try testing.expectEqual(@as(u64, 100), pin.freshnessPercent(1000));
    try testing.expectEqual(@as(u64, 50), pin.freshnessPercent(1000 + LIFETIME_MS / 2));
    try testing.expect(pins.find(7, 1000 + LIFETIME_MS) == null);
    try testing.expect(pins.find(8, 1000) == null);
}

test "a repeat refreshes its pin rather than taking another" {
    var pins: IntelPins = .{};
    pins.add(7, "first", 1000);
    pins.add(7, "second", 2000);
    try testing.expectEqualStrings("second", pins.find(7, 2000).?.message());
    var used_count: usize = 0;
    for (pins.pins) |pin| {
        if (pin.seen_ms != 0) used_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), used_count);
}

test "a full list drops its oldest pin" {
    var pins: IntelPins = .{};
    for (0..CAPACITY) |index| pins.add(@intCast(index), "x", 1000 + index);
    pins.add(CAPACITY, "newest", 5000);
    try testing.expect(pins.find(0, 5000) == null);
    try testing.expect(pins.find(1, 5000) != null);
    try testing.expect(pins.find(CAPACITY, 5000) != null);
}

test "a clear report restarts a live pin, and a new sighting undoes it" {
    var pins: IntelPins = .{};
    pins.add(7, "hostile", 1000);
    pins.markClear(7, "clr", 3000);
    const pin = pins.find(7, 3000).?;
    try testing.expect(pin.is_clear);
    try testing.expectEqualStrings("clr", pin.message());
    try testing.expectEqual(@as(u64, 3000), pin.seen_ms);

    pins.add(7, "back again", 4000);
    try testing.expect(!pins.find(7, 4000).?.is_clear);
}

test "a clear report adds no pin of its own" {
    var pins: IntelPins = .{};
    pins.markClear(7, "clr", 1000);
    try testing.expect(pins.find(7, 1000) == null);
    pins.add(8, "hostile", 1000);
    pins.markClear(8, "clr", 1000 + LIFETIME_MS);
    try testing.expect(pins.find(8, 1000 + LIFETIME_MS) == null);
}

test "a long message is cut without splitting a character" {
    var pins: IntelPins = .{};
    const padding: [MESSAGE_MAX - 1]u8 = @splat('x');
    const message = padding ++ "\u{0416}".*;
    pins.add(7, &message, 1000);
    try testing.expectEqual(MESSAGE_MAX - 1, pins.find(7, 1000).?.message().len);
}
