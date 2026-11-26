//! Where a system or region can be looked up on the web; no I/O.
const std = @import("std");
const evestars = @import("evestars.zig");
const universe = @import("universe.zig");

const RegionIndex = universe.RegionIndex;
const SystemIndex = universe.SystemIndex;

/// Fits the longest system name; a test holds the map to it.
const MAX_NAME_LENGTH = 32;

/// In menu order.
pub const Site = enum { dotlan, zkillboard, eve_stars };
pub const SITES = std.enums.values(Site);

pub fn siteName(site: Site) []const u8 {
    return switch (site) {
        .dotlan => "Dotlan",
        .zkillboard => "zKillboard",
        .eve_stars => "Eve Stars",
    };
}

pub fn siteUrl(site: Site, system: SystemIndex) evestars.Text {
    const info = universe.systemInfo(system);
    var name_buf: [MAX_NAME_LENGTH]u8 = undefined;
    return switch (site) {
        .dotlan => .print("https://evemaps.dotlan.net/system/{s}", .{dotlanName(&name_buf, universe.systemName(system))}),
        .zkillboard => .print("https://zkillboard.com/system/{d}/", .{info.id}),
        .eve_stars => .print(evestars.SITE_URL ++ "/{s}", .{eveStarsName(&name_buf, universe.systemName(system))}),
    };
}

pub fn regionUrl(site: Site, region: RegionIndex) evestars.Text {
    var name_buf: [MAX_NAME_LENGTH]u8 = undefined;
    return switch (site) {
        .dotlan => .print("https://evemaps.dotlan.net/map/{s}", .{dotlanName(&name_buf, universe.regionName(region))}),
        .zkillboard => .print("https://zkillboard.com/region/{d}/", .{universe.regionId(region)}),
        .eve_stars => .print(evestars.SITE_URL ++ "/{s}", .{eveStarsName(&name_buf, universe.regionName(region))}),
    };
}

fn dotlanName(buffer: *[MAX_NAME_LENGTH]u8, name: []const u8) []const u8 {
    const copy = buffer[0..name.len];
    @memcpy(copy, name);
    std.mem.replaceScalar(u8, copy, ' ', '_');
    return copy;
}

fn eveStarsName(buffer: *[MAX_NAME_LENGTH]u8, name: []const u8) []const u8 {
    const lowered = std.ascii.lowerString(buffer, name);
    std.mem.replaceScalar(u8, lowered, ' ', '-');
    return lowered;
}

const testing = std.testing;

test "every system's and region's name fits the buffer" {
    for (0..universe.SYSTEM_COUNT) |index| {
        try testing.expect(universe.systemName(@intCast(index)).len <= MAX_NAME_LENGTH);
    }
    for (0..universe.REGION_COUNT) |index| {
        try testing.expect(universe.regionName(@intCast(index)).len <= MAX_NAME_LENGTH);
    }
}

test "Dotlan swaps a name's spaces for underscores" {
    const url = siteUrl(.dotlan, universe.findSystem("Old Man Star").?);
    try testing.expectEqualStrings("https://evemaps.dotlan.net/system/Old_Man_Star", url.slice());
}

test "zKillboard goes by the system's id" {
    const url = siteUrl(.zkillboard, universe.findSystem("Jita").?);
    try testing.expectEqualStrings("https://zkillboard.com/system/30000142/", url.slice());
}

test "a region's links go by its name, or zKillboard's by its id" {
    const forge = universe.systemInfo(universe.findSystem("Jita").?).region;
    try testing.expectEqualStrings("https://evemaps.dotlan.net/map/The_Forge", regionUrl(.dotlan, forge).slice());
    try testing.expectEqualStrings("https://zkillboard.com/region/10000002/", regionUrl(.zkillboard, forge).slice());
    try testing.expectEqualStrings(evestars.SITE_URL ++ "/the-forge", regionUrl(.eve_stars, forge).slice());
}

test "Eve Stars goes by the system's name, lowercased with hyphens for spaces" {
    const url = siteUrl(.eve_stars, universe.findSystem("9-02G0").?);
    try testing.expectEqualStrings(evestars.SITE_URL ++ "/9-02g0", url.slice());
    const spaced = siteUrl(.eve_stars, universe.findSystem("Old Man Star").?);
    try testing.expectEqualStrings(evestars.SITE_URL ++ "/old-man-star", spaced.slice());
}
