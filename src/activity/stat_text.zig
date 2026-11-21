//! How an activity rate reads wherever it's shown, e.g. "IN: 412" or "M: 1,284 m3/hr"; no I/O.
const std = @import("std");
const activity = @import("../config/activity.zig");
const format = @import("../util/format.zig");

const RateUnit = activity.RateUnit;

pub const Kind = enum { incoming_dps, outgoing_dps, mining_volume, mining_isk, bounty_isk };

pub const Reading = struct {
    kind: Kind,
    /// Per second for DPS, else per `unit`.
    value: f32,
    has_prefix: bool,
    /// Written after the value as " m3/min" or " ISK/hr"; null for DPS.
    unit: ?RateUnit = null,
};

/// Overflow is ignored, since a truncated result is still drawn.
pub fn write(writer: *std.Io.Writer, reading: Reading) void {
    if (reading.has_prefix) writer.writeAll(prefix(reading.kind)) catch {};
    var number_buf: [24]u8 = undefined;
    switch (reading.kind) {
        .incoming_dps, .outgoing_dps => writer.print("{d:.0}", .{reading.value}) catch {},
        .mining_volume => writer.writeAll(format.formatMinedVolume(&number_buf, reading.value)) catch {},
        .mining_isk, .bounty_isk => writer.writeAll(format.formatIskAbbreviated(&number_buf, reading.value)) catch {},
    }
    if (reading.unit) |unit| writer.print(" {s}/{s}", .{ quantity(reading.kind), unit.suffix() }) catch {};
}

fn prefix(kind: Kind) []const u8 {
    return switch (kind) {
        .incoming_dps => "IN: ",
        .outgoing_dps => "OUT: ",
        .mining_volume => "M: ",
        .mining_isk, .bounty_isk => "ISK: ",
    };
}

/// What a rate counts, before its period.
fn quantity(kind: Kind) []const u8 {
    return switch (kind) {
        .incoming_dps, .outgoing_dps => "HP",
        .mining_volume => "m3",
        .mining_isk, .bounty_isk => "ISK",
    };
}

const testing = std.testing;

fn expectText(expected: []const u8, reading: Reading) !void {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    write(&writer, reading);
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "write adds the prefix and rounds by kind" {
    try expectText("IN: 412", .{ .kind = .incoming_dps, .value = 412.4, .has_prefix = true });
    try expectText("M: 4.2", .{ .kind = .mining_volume, .value = 4.24, .has_prefix = true });
    try expectText("87", .{ .kind = .outgoing_dps, .value = 87, .has_prefix = false });
}

test "write groups mined volume and ends a rate with its period" {
    try expectText("M: 1,284 m3/hr", .{ .kind = .mining_volume, .value = 1284, .has_prefix = true, .unit = .hour });
    try expectText("200k ISK/min", .{ .kind = .bounty_isk, .value = 200_000, .has_prefix = false, .unit = .minute });
}
