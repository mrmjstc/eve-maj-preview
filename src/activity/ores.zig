//! The ores, ice and gases mining yields are rated by: their volumes and a snapshot of their prices; no I/O.
const std = @import("std");

/// One mined material; built in, never saved.
pub const Ore = struct {
    name: []const u8,
    category: []const u8 = "Ore",
    volume_m3: f64,
    price: f64 = 0,
};

/// The prices are a Jita snapshot that drifts; Fetch Prices overrides them.
pub const CATALOG = [_]Ore{
    .{ .name = "Veldspar", .category = "Ore", .volume_m3 = 0.10, .price = 11.53 },
    .{ .name = "Mordunium", .category = "Ore", .volume_m3 = 0.10, .price = 12.83 },
    .{ .name = "Scordite", .category = "Ore", .volume_m3 = 0.15, .price = 22.05 },
    .{ .name = "Pyroxeres", .category = "Ore", .volume_m3 = 0.30, .price = 32 },
    .{ .name = "Plagioclase", .category = "Ore", .volume_m3 = 0.35, .price = 33.4 },
    .{ .name = "Omber", .category = "Ore", .volume_m3 = 0.60, .price = 112.5 },
    .{ .name = "Ytirium", .category = "Ore", .volume_m3 = 0.60, .price = 350.9 },
    .{ .name = "Griemeer", .category = "Ore", .volume_m3 = 0.80, .price = 111.1 },
    .{ .name = "Kernite", .category = "Ore", .volume_m3 = 1.20, .price = 207 },
    .{ .name = "Kylixium", .category = "Ore", .volume_m3 = 1.20, .price = 252.5 },
    .{ .name = "Jaspet", .category = "Ore", .volume_m3 = 2.00, .price = 374.5 },
    .{ .name = "Hedbergite", .category = "Ore", .volume_m3 = 3.00, .price = 627.6 },
    .{ .name = "Hemorphite", .category = "Ore", .volume_m3 = 3.00, .price = 808.9 },
    .{ .name = "Talassonite", .category = "Ore", .volume_m3 = 3.00, .price = 8421 },
    .{ .name = "Nocxite", .category = "Ore", .volume_m3 = 4.00, .price = 605.3 },
    .{ .name = "Gneiss", .category = "Ore", .volume_m3 = 5.00, .price = 2100 },
    .{ .name = "Hezorime", .category = "Ore", .volume_m3 = 5.00, .price = 957.1 },
    .{ .name = "Rakovene", .category = "Ore", .volume_m3 = 5.00, .price = 7520 },
    .{ .name = "Ueganite", .category = "Ore", .volume_m3 = 5.00, .price = 900 },
    .{ .name = "Bezdnacine", .category = "Ore", .volume_m3 = 8.00, .price = 9220 },
    .{ .name = "Dark Ochre", .category = "Ore", .volume_m3 = 8.00, .price = 4200 },

    .{ .name = "Bitumens", .category = "Moons", .volume_m3 = 10.00, .price = 1164 },
    .{ .name = "Coesite", .category = "Moons", .volume_m3 = 10.00, .price = 0 },
    .{ .name = "Sylvite", .category = "Moons", .volume_m3 = 10.00, .price = 801 },
    .{ .name = "Cobaltite", .category = "Moons", .volume_m3 = 10.00, .price = 285.8 },
    .{ .name = "Euxenite", .category = "Moons", .volume_m3 = 10.00, .price = 900.6 },
    .{ .name = "Scheelite", .category = "Moons", .volume_m3 = 10.00, .price = 253.1 },
    .{ .name = "Titanite", .category = "Moons", .volume_m3 = 10.00, .price = 211.1 },
    .{ .name = "Chromite", .category = "Moons", .volume_m3 = 10.00, .price = 1611 },
    .{ .name = "Otavite", .category = "Moons", .volume_m3 = 10.00, .price = 1439 },
    .{ .name = "Sperrylite", .category = "Moons", .volume_m3 = 10.00, .price = 1548 },
    .{ .name = "Vanadinite", .category = "Moons", .volume_m3 = 10.00, .price = 634.6 },
    .{ .name = "Carnotite", .category = "Moons", .volume_m3 = 10.00, .price = 4706 },
    .{ .name = "Cinnabar", .category = "Moons", .volume_m3 = 10.00, .price = 600.3 },
    .{ .name = "Pollucite", .category = "Moons", .volume_m3 = 10.00, .price = 1644 },
    .{ .name = "Zircon", .category = "Moons", .volume_m3 = 10.00, .price = 439.7 },
    .{ .name = "Monazite", .category = "Moons", .volume_m3 = 10.00, .price = 9800 },
    .{ .name = "Loparite", .category = "Moons", .volume_m3 = 10.00, .price = 8060 },
    .{ .name = "Xenotime", .category = "Moons", .volume_m3 = 10.00, .price = 8166 },
    .{ .name = "Ytterbite", .category = "Moons", .volume_m3 = 10.00, .price = 4728 },
    .{ .name = "Zeolites", .category = "Moons", .volume_m3 = 10.00, .price = 1360 },
    .{ .name = "Arkonor", .category = "Ore", .volume_m3 = 16.00, .price = 4264 },
    .{ .name = "Bistot", .category = "Ore", .volume_m3 = 16.00, .price = 3613 },
    .{ .name = "Crokite", .category = "Ore", .volume_m3 = 16.00, .price = 5300 },
    .{ .name = "Ducinium", .category = "Ore", .volume_m3 = 16.00, .price = 3629 },
    .{ .name = "Eifyrium", .category = "Ore", .volume_m3 = 16.00, .price = 2889 },
    .{ .name = "Spodumain", .category = "Ore", .volume_m3 = 16.00, .price = 8507 },
    .{ .name = "Mercoxit", .category = "Ore", .volume_m3 = 40.00, .price = 18460 },
    .{ .name = "Prismaticite", .category = "Ore", .volume_m3 = 40.00, .price = 18740 },

    .{ .name = "Fullerite-C50", .category = "Gas", .volume_m3 = 1.00, .price = 4707 },
    .{ .name = "Fullerite-C60", .category = "Gas", .volume_m3 = 1.00, .price = 4683 },
    .{ .name = "Fullerite-C70", .category = "Gas", .volume_m3 = 1.00, .price = 8211 },
    .{ .name = "Fullerite-C28", .category = "Gas", .volume_m3 = 2.00, .price = 13100 },
    .{ .name = "Fullerite-C72", .category = "Gas", .volume_m3 = 2.00, .price = 6990 },
    .{ .name = "Fullerite-C84", .category = "Gas", .volume_m3 = 2.00, .price = 9896 },
    .{ .name = "Fullerite-C32", .category = "Gas", .volume_m3 = 5.00, .price = 20000 },
    .{ .name = "Fullerite-C320", .category = "Gas", .volume_m3 = 5.00, .price = 32400 },
    .{ .name = "Fullerite-C540", .category = "Gas", .volume_m3 = 10.00, .price = 47410 },
    .{ .name = "Amber Cytoserocin", .category = "Gas", .volume_m3 = 10.00, .price = 30600 },
    .{ .name = "Azure Cytoserocin", .category = "Gas", .volume_m3 = 10.00, .price = 19150 },
    .{ .name = "Celadon Cytoserocin", .category = "Gas", .volume_m3 = 10.00, .price = 26130 },
    .{ .name = "Golden Cytoserocin", .category = "Gas", .volume_m3 = 10.00, .price = 36220 },
    .{ .name = "Lime Cytoserocin", .category = "Gas", .volume_m3 = 10.00, .price = 31100 },
    .{ .name = "Malachite Cytoserocin", .category = "Gas", .volume_m3 = 10.00, .price = 133300 },
    .{ .name = "Vermillion Cytoserocin", .category = "Gas", .volume_m3 = 10.00, .price = 25120 },
    .{ .name = "Viridian Cytoserocin", .category = "Gas", .volume_m3 = 10.00, .price = 51080 },
    .{ .name = "Amber Mykoserocin", .category = "Gas", .volume_m3 = 10.00, .price = 95230 },
    .{ .name = "Azure Mykoserocin", .category = "Gas", .volume_m3 = 10.00, .price = 48370 },
    .{ .name = "Celadon Mykoserocin", .category = "Gas", .volume_m3 = 10.00, .price = 83500 },
    .{ .name = "Golden Mykoserocin", .category = "Gas", .volume_m3 = 10.00, .price = 97940 },
    .{ .name = "Lime Mykoserocin", .category = "Gas", .volume_m3 = 10.00, .price = 77980 },
    .{ .name = "Malachite Mykoserocin", .category = "Gas", .volume_m3 = 10.00, .price = 88850 },
    .{ .name = "Vermillion Mykoserocin", .category = "Gas", .volume_m3 = 10.00, .price = 77970 },
    .{ .name = "Viridian Mykoserocin", .category = "Gas", .volume_m3 = 10.00, .price = 91090 },

    .{ .name = "Clear Icicle", .category = "Ice", .volume_m3 = 1000.00, .price = 234300 },
    .{ .name = "Blue Ice", .category = "Ice", .volume_m3 = 1000.00, .price = 187200 },
    .{ .name = "Glacial Mass", .category = "Ice", .volume_m3 = 1000.00, .price = 170800 },
    .{ .name = "White Glaze", .category = "Ice", .volume_m3 = 1000.00, .price = 196600 },
    .{ .name = "Dark Glitter", .category = "Ice", .volume_m3 = 1000.00, .price = 332000 },
    .{ .name = "Gelidus", .category = "Ice", .volume_m3 = 1000.00, .price = 350100 },
    .{ .name = "Krystallos", .category = "Ice", .volume_m3 = 1000.00, .price = 592500 },
    .{ .name = "Glare Crust", .category = "Ice", .volume_m3 = 1000.00, .price = 220200 },
};

/// Per unit; an exact name beats a grade variant.
pub fn volume(name: []const u8) ?f64 {
    inline for (.{ true, false }) |is_exact| {
        if (find(&CATALOG, name, is_exact)) |ore| return ore.volume_m3;
    }
    return null;
}

/// An exact name beats a grade variant; within each, a saved price beats the catalogue's snapshot.
/// `saved`: a slice of anything with `name` and `price`, e.g. GlobalConfig.oreTable's items.
pub fn price(saved: anytype, name: []const u8) ?f64 {
    inline for (.{ true, false }) |is_exact| {
        if (find(saved, name, is_exact)) |entry| return entry.price;
        if (find(&CATALOG, name, is_exact)) |entry| return entry.price;
    }
    return null;
}

/// `entries` is a slice of anything with a `name` field; past `is_exact`, a grade variant of the name matches too.
pub fn find(entries: anytype, name: []const u8, comptime is_exact: bool) ?@TypeOf(entries[0]) {
    for (entries) |entry| {
        const is_match = if (is_exact) std.mem.eql(u8, entry.name, name) else isGradeVariant(name, entry.name);
        if (is_match) return entry;
    }
    return null;
}

/// True if `name` is `base` with a quality word before or after it, e.g. "Shining Loparite" or "Nocxite II-Grade".
fn isGradeVariant(name: []const u8, base: []const u8) bool {
    if (base.len == 0 or base.len >= name.len) return false;
    var search_start: usize = 0;
    while (std.mem.findPos(u8, name, search_start, base)) |match_index| {
        const starts_word = match_index == 0 or name[match_index - 1] == ' ';
        const after_index = match_index + base.len;
        const ends_word = after_index == name.len or name[after_index] == ' ';
        if (starts_word and ends_word) return true;
        search_start = match_index + 1;
    }
    return false;
}

const testing = std.testing;

test "isGradeVariant matches the base ore name as a whole word" {
    try testing.expect(isGradeVariant("Shining Loparite", "Loparite"));
    try testing.expect(isGradeVariant("Nocxite II-Grade", "Nocxite"));
    try testing.expect(!isGradeVariant("Loparite", "Loparite"));
    try testing.expect(!isGradeVariant("Veldspars", "Veldspar"));
    try testing.expect(!isGradeVariant("Dense Veldspar", ""));
}

test "a grade variant has its base ore's volume, and an unknown name none" {
    try testing.expectEqual(@as(?f64, 0.10), volume("Veldspar"));
    try testing.expectEqual(@as(?f64, 0.10), volume("Veldspar II-Grade"));
    try testing.expectEqual(@as(?f64, null), volume("Not An Ore"));
}

test "a saved price beats the catalogue's, and an exact name beats a grade variant" {
    const Saved = struct { name: []const u8, price: f64 };
    const saved = [_]Saved{.{ .name = "Veldspar", .price = 20 }};
    try testing.expectEqual(@as(?f64, 20), price(&saved, "Veldspar"));
    try testing.expectEqual(@as(?f64, 20), price(&saved, "Dense Veldspar"));
    const none: []const Saved = &.{};
    try testing.expectEqual(@as(?f64, 11.53), price(none, "Veldspar"));
    try testing.expectEqual(@as(?f64, null), price(&saved, "Unobtainium"));
}
