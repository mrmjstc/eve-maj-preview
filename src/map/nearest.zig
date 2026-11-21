//! Which of a list of positions is nearest a system by gate jumps; no I/O.
const std = @import("std");
const universe = @import("universe.zig");

const SystemIndex = universe.SystemIndex;

/// Positions past this are ignored.
pub const MAX_POSITIONS = 64;

pub const Tied = std.StaticBitSet(MAX_POSITIONS);

pub const Nearest = struct {
    jumps: u8,
    /// Indices into the positions given, every one at `jumps`.
    tied: Tied,
    /// The lowest of them.
    first_index: usize,
};

/// `distances` from universe.measureDistances, whose range decides what counts; null where none is in range, or every position is unknown (null).
pub fn nearest(distances: *const universe.Distances, positions: []const ?SystemIndex) ?Nearest {
    var found: ?Nearest = null;
    for (positions[0..@min(positions.len, MAX_POSITIONS)], 0..) |position, index| {
        const system = position orelse continue;
        const jumps = distances[system];
        if (jumps == universe.UNREACHED) continue;
        const best_jumps = if (found) |best| best.jumps else universe.UNREACHED;
        if (jumps > best_jumps) continue;
        if (jumps < best_jumps) found = .{ .jumps = jumps, .tied = .empty, .first_index = index };
        if (found) |*best| best.tied.set(index);
    }
    return found;
}

const testing = std.testing;

fn systemNamed(name: []const u8) !SystemIndex {
    return universe.findSystem(name) orelse error.TestUnknownSystem;
}

test "the nearest position wins, and ties are all kept" {
    const jita = try systemNamed("Jita");
    const perimeter = try systemNamed("Perimeter");
    const amarr = try systemNamed("Amarr");
    var distances: universe.Distances = undefined;
    universe.measureDistances(jita, universe.UNREACHED - 1, &distances);

    const found = nearest(&distances, &.{ amarr, perimeter, perimeter }) orelse return error.TestExpectedNearest;
    try testing.expectEqual(@as(u8, 1), found.jumps);
    try testing.expect(!found.tied.isSet(0));
    try testing.expect(found.tied.isSet(1));
    try testing.expect(found.tied.isSet(2));
    try testing.expectEqual(@as(usize, 1), found.first_index);
}

test "unknown positions and ones out of range count for nothing" {
    const jita = try systemNamed("Jita");
    const amarr = try systemNamed("Amarr");
    var distances: universe.Distances = undefined;
    universe.measureDistances(jita, 1, &distances);

    try testing.expect(nearest(&distances, &.{ null, amarr }) == null);
}
