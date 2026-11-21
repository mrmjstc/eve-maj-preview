//! Intel from the chat channels, held once for every view that shows it; main thread only.
const std = @import("std");
const universe = @import("universe.zig");
const intel_pins = @import("intel_pins.zig");
const history_mod = @import("../notifications/history.zig");

const SystemIndex = universe.SystemIndex;

/// How a report changes the map, from the Map Panel's settings.
pub const PinRules = struct {
    /// A report calling a system clear marks its pin so, rather than being ignored.
    shows_clear: bool,
    /// How long a pin stays live; a clear report only marks a live one.
    lifetime_ms: u64,
};

/// App owns it, so a thumbnail set rebuild or profile switch keeps it.
pub const Intel = struct {
    /// Systems named lately: the Map Panel marks them and the thumbnails' connection map lights them.
    pins: intel_pins.IntelPins = .{},
    /// Every report, listed by the Intel Panel and the map's attached Intel card.
    history: history_mod.NotificationHistory = .{},

    /// For a report the map shows; the Notifier lists reports in `history` itself, since it measures from the nearest client.
    pub fn pin(self: *Intel, system: SystemIndex, message: []const u8, is_clear: bool, rules: PinRules, now_ms: u64) void {
        if (!is_clear) return self.pins.add(system, message, now_ms);
        if (rules.shows_clear) self.pins.markClear(system, message, rules.lifetime_ms, now_ms);
    }
};

const testing = std.testing;

const TEST_RULES: PinRules = .{ .shows_clear = true, .lifetime_ms = 60_000 };

fn systemNamed(name: []const u8) !SystemIndex {
    return universe.findSystem(name) orelse error.TestUnknownSystem;
}

test "a report pins its system, and a clear one marks the live pin clear" {
    var intel: Intel = .{};
    const jita = try systemNamed("Jita");
    intel.pin(jita, "hostile", false, TEST_RULES, 1_000);
    intel.pin(jita, "jita clr", true, TEST_RULES, 2_000);

    const found = intel.pins.find(jita, TEST_RULES.lifetime_ms, 2_000) orelse return error.TestExpectedPin;
    try testing.expect(found.is_clear);
}

test "with clear reports off, a clear report leaves the pin as it was" {
    var intel: Intel = .{};
    const jita = try systemNamed("Jita");
    var rules = TEST_RULES;
    rules.shows_clear = false;
    intel.pin(jita, "hostile", false, rules, 1_000);
    intel.pin(jita, "jita clr", true, rules, 2_000);

    const found = intel.pins.find(jita, rules.lifetime_ms, 2_000) orelse return error.TestExpectedPin;
    try testing.expect(!found.is_clear);
}

test "a clear report for a system with no pin pins nothing" {
    var intel: Intel = .{};
    const jita = try systemNamed("Jita");
    intel.pin(jita, "jita clr", true, TEST_RULES, 2_000);

    try testing.expectEqual(@as(?*const intel_pins.Pin, null), intel.pins.find(jita, TEST_RULES.lifetime_ms, 2_000));
}
