//! How far jump drives reach and which systems that puts in range, by true distance; no I/O.
const std = @import("std");
const universe = @import("universe.zig");

const SystemIndex = universe.SystemIndex;

/// Region-wide jammers stop cynosural fields there, though ships can jump out.
const POCHVEN_REGION_ID = 10000070;
/// Jump drives can't reach it.
const ZARZAKH_SYSTEM_ID = 30100000;

pub const Ship = enum { titan, jump_freighter, carrier, command_carrier, dreadnought, lancer_dreadnought, black_ops };
pub const SHIPS = std.enums.values(Ship);

/// The systems a ship can jump to from one system.
pub const Reach = struct {
    origin: SystemIndex,
    ship: Ship,
    /// By SystemIndex, without `origin`.
    systems: universe.SystemSet = .empty,
    /// How many of `systems` each region holds, by RegionIndex.
    region_counts: [universe.REGION_COUNT]u16 = @splat(0),
    count: u16 = 0,

    pub fn measure(origin: SystemIndex, ship: Ship) Reach {
        var reach: Reach = .{ .origin = origin, .ship = ship };
        const range = rangeLightYears(ship);
        for (0..universe.SYSTEM_COUNT) |index| {
            const system: SystemIndex = @intCast(index);
            if (system == origin or !acceptsJumps(system) or distanceLightYears(origin, system) > range) continue;
            reach.systems.set(index);
            reach.region_counts[universe.systemInfo(system).region] += 1;
            reach.count += 1;
        }
        return reach;
    }

    pub fn includes(self: *const Reach, system: SystemIndex) bool {
        return self.systems.isSet(system);
    }
};

pub fn shipName(ship: Ship) []const u8 {
    return switch (ship) {
        .titan => "Titan",
        .jump_freighter => "Jump Freighter",
        .carrier => "Carrier",
        .command_carrier => "Command Carrier",
        .dreadnought => "Dreadnought",
        .lancer_dreadnought => "Lancer Dreadnought",
        .black_ops => "Black Ops",
    };
}

/// With Jump Drive Calibration V, which doubles the hull's base range; assumed, as the app can't see a character's skills.
pub fn rangeLightYears(ship: Ship) f32 {
    return switch (ship) {
        .titan => 6,
        .jump_freighter => 10,
        .carrier, .dreadnought => 7,
        .command_carrier => 7.5,
        .lancer_dreadnought, .black_ops => 8,
    };
}

pub fn distanceLightYears(from: SystemIndex, to: SystemIndex) f32 {
    const start = universe.systemPosition(from);
    const end = universe.systemPosition(to);
    const delta: @Vector(3, f32) = .{ end.x - start.x, end.y - start.y, end.z - start.z };
    return @sqrt(@reduce(.Add, delta * delta));
}

/// A cynosural field can be lit there, which high security forbids; a cyno jammer in the system can't be known here.
pub fn acceptsJumps(system: SystemIndex) bool {
    const info = universe.systemInfo(system);
    return info.security_tenths < universe.HIGH_SECURITY_TENTHS and universe.regionId(info.region) != POCHVEN_REGION_ID and info.id != ZARZAKH_SYSTEM_ID;
}

const testing = std.testing;

fn systemNamed(name: []const u8) !SystemIndex {
    return universe.findSystem(name) orelse error.TestExpectedSystem;
}

test "distance matches the static data's positions, either way round" {
    const jita = try systemNamed("Jita");
    const perimeter = try systemNamed("Perimeter");
    try testing.expectApproxEqAbs(@as(f32, 2.1027), distanceLightYears(jita, perimeter), 0.0001);
    try testing.expectEqual(distanceLightYears(jita, perimeter), distanceLightYears(perimeter, jita));
}

test "a system between two ships' ranges is in reach of only the longer" {
    const origin = try systemNamed("1DQ1-A");
    const between = try systemNamed("UEXO-Z");
    try testing.expect(!Reach.measure(origin, .titan).includes(between));
    try testing.expect(Reach.measure(origin, .carrier).includes(between));
}

test "a longer range reaches at least as much" {
    const origin = try systemNamed("1DQ1-A");
    try testing.expect(Reach.measure(origin, .titan).count < Reach.measure(origin, .carrier).count);
    try testing.expectEqual(Reach.measure(origin, .carrier).count, Reach.measure(origin, .dreadnought).count);
    try testing.expect(Reach.measure(origin, .carrier).count < Reach.measure(origin, .command_carrier).count);
    try testing.expect(Reach.measure(origin, .command_carrier).count < Reach.measure(origin, .black_ops).count);
    try testing.expectEqual(Reach.measure(origin, .lancer_dreadnought).count, Reach.measure(origin, .black_ops).count);
    try testing.expect(Reach.measure(origin, .black_ops).count < Reach.measure(origin, .jump_freighter).count);
}

test "high security is never in reach, however close" {
    const reach: Reach = .measure(try systemNamed("Amamake"), .jump_freighter);
    try testing.expect(!reach.includes(try systemNamed("Osoggur")));
}

test "Pochven is never in reach, however close" {
    const pochven = try systemNamed("Otanuomi");
    try testing.expect(!acceptsJumps(pochven));
    try testing.expect(!Reach.measure(try systemNamed("Walvalin"), .jump_freighter).includes(pochven));
}

test "Zarzakh can't be jumped to, though it's null security" {
    const zarzakh = try systemNamed("Zarzakh");
    try testing.expect(universe.systemInfo(zarzakh).security_tenths < 0);
    try testing.expect(!acceptsJumps(zarzakh));
}

test "a reach leaves out its origin, and its region counts add up to it" {
    const origin = try systemNamed("1DQ1-A");
    const reach: Reach = .measure(origin, .jump_freighter);
    try testing.expect(!reach.includes(origin));
    var total: u32 = 0;
    for (reach.region_counts) |count| total += count;
    try testing.expectEqual(@as(u32, reach.count), total);
    try testing.expectEqual(reach.systems.count(), reach.count);
}
