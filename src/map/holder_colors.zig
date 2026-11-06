//! The colour each sovereignty holder is shown in: an NPC faction's from a fixed table, an alliance's picked from its logo; no I/O.
const std = @import("std");
const color_mod = @import("../util/color.zig");
const wire = @import("../config/wire.zig");
const log = @import("../log.zig");

const slog = log.Scoped("map");

/// The most alliances whose logo colours are kept, against about 70 holding space today; one more starts the list again.
pub const MAX_ALLIANCES = 200;
/// A cache file with another is ignored, so a change to how colours are picked takes effect.
const CACHE_VERSION = 1;
/// Kept for a logo with no colour to pick, so it isn't fetched again.
pub const NO_COLOR: u32 = 0;
/// NPC factions' IDs lie here; alliances' never do.
const FIRST_FACTION_ID = 500_000;
const LAST_FACTION_ID = 500_999;
/// A pixel more see-through than this is the logo's background.
const MIN_ALPHA = 128;
/// Below this a pixel is grey, black or white, which says nothing of the logo's colour.
const MIN_CHROMA: f32 = 0.05;
/// Darker than this, a pixel's hue can't be told.
const MIN_LIGHTNESS: f32 = 0.25;
/// With less of a logo coloured than this, it has no colour to pick.
const MIN_COLORED_PERCENT = 3;
const HUE_BINS = 36;
/// Every logo's colour is brought to this, so each reads alike on the dark map.
const SHOWN_LIGHTNESS: f32 = 0.75;
const MIN_SHOWN_CHROMA: f32 = 0.10;
const MAX_SHOWN_CHROMA: f32 = 0.18;
/// How far chroma drops at a time to bring a colour inside sRGB.
const CHROMA_STEP: f32 = 0.01;
/// SHOWN_LIGHTNESS with no colour, for a hue no chroma brings inside sRGB.
const SHOWN_GREY: u32 = 0xFFADADAD;

const FactionColor = struct { id: u32, color: u32 };

/// The cache file's JSON.
const CacheFile = struct {
    version: u32 = 0,
    alliances: []const CachedAlliance = &.{},
};

const CachedAlliance = struct {
    id: u32,
    /// Null for a logo with no colour to pick.
    color: ?wire.Argb = null,
};

/// The factions holding systems, in the colours they're known by.
const FACTION_COLORS = [_]FactionColor{
    .{ .id = 500001, .color = 0xFF5B9BD5 }, // Caldari State
    .{ .id = 500002, .color = 0xFFC8643C }, // Minmatar Republic
    .{ .id = 500003, .color = 0xFFE3B341 }, // Amarr Empire
    .{ .id = 500004, .color = 0xFF4FC08D }, // Gallente Federation
    .{ .id = 500005, .color = 0xFFA98BE8 }, // Jove Empire
    .{ .id = 500006, .color = 0xFF6CC3F0 }, // CONCORD Assembly
    .{ .id = 500007, .color = 0xFFC9A46A }, // Ammatar Mandate
    .{ .id = 500008, .color = 0xFFC48AD8 }, // Khanid Kingdom
    .{ .id = 500010, .color = 0xFFE6CF4A }, // Guristas Pirates
    .{ .id = 500011, .color = 0xFFE5534B }, // Angel Cartel
    .{ .id = 500012, .color = 0xFFD4334F }, // Blood Raider Covenant
    .{ .id = 500013, .color = 0xFFF08CC0 }, // EverMore
    .{ .id = 500014, .color = 0xFFF2C14E }, // ORE
    .{ .id = 500015, .color = 0xFFE08F45 }, // Thukker Tribe
    .{ .id = 500016, .color = 0xFFE0E0E0 }, // Servant Sisters of EVE
    .{ .id = 500017, .color = 0xFF7FD6D6 }, // The Society of Conscious Thought
    .{ .id = 500018, .color = 0xFF8E9BB0 }, // Mordu's Legion Command
    .{ .id = 500019, .color = 0xFF3FC8B4 }, // Sansha's Nation
    .{ .id = 500020, .color = 0xFF9CCB3B }, // Serpentis
    .{ .id = 500026, .color = 0xFFB8323C }, // Triglavian Collective
    .{ .id = 500027, .color = 0xFF4A86E8 }, // EDENCOM
    .{ .id = 500029, .color = 0xFFD9824A }, // Deathless Circle
};

/// Alliances' logo colours, in the order they were looked at; NO_COLOR for a logo that had none.
pub const LogoColors = struct {
    ids: [MAX_ALLIANCES]u32 = undefined,
    colors: [MAX_ALLIANCES]u32 = undefined,
    count: usize = 0,

    /// Null while its logo hasn't been looked at.
    pub fn get(self: *const LogoColors, id: u32) ?u32 {
        const index = std.mem.indexOfScalar(u32, self.ids[0..self.count], id) orelse return null;
        return self.colors[index];
    }

    /// A full list is emptied first, as it fills with alliances long gone.
    pub fn put(self: *LogoColors, id: u32, logo_color: u32) void {
        if (std.mem.indexOfScalar(u32, self.ids[0..self.count], id)) |index| {
            self.colors[index] = logo_color;
            return;
        }
        if (self.count == MAX_ALLIANCES) self.count = 0;
        self.ids[self.count] = id;
        self.colors[self.count] = logo_color;
        self.count += 1;
    }

    /// From what toJson wrote; JSON that doesn't parse, or another version, gives an empty list.
    pub fn parse(allocator: std.mem.Allocator, json_text: []const u8) LogoColors {
        var colors: LogoColors = .{};
        const parsed = wire.parse(CacheFile, allocator, json_text) catch |err| {
            slog.warn("Failed to parse the alliance logo colours, fetching them again: {}", .{err});
            return colors;
        };
        defer parsed.deinit();
        if (parsed.value.version != CACHE_VERSION) return colors;
        for (parsed.value.alliances) |alliance| colors.put(alliance.id, if (alliance.color) |shade| shade.value else NO_COLOR);
        return colors;
    }

    /// Caller frees.
    pub fn toJson(self: *const LogoColors, allocator: std.mem.Allocator) ![]u8 {
        const alliances = try allocator.alloc(CachedAlliance, self.count);
        defer allocator.free(alliances);
        for (alliances, self.ids[0..self.count], self.colors[0..self.count]) |*alliance, id, logo_color| {
            alliance.* = .{ .id = id, .color = if (logo_color == NO_COLOR) null else .{ .value = logo_color } };
        }
        return std.json.Stringify.valueAlloc(allocator, CacheFile{ .version = CACHE_VERSION, .alliances = alliances }, .{ .whitespace = .indent_2 });
    }
};

pub fn isFaction(id: u32) bool {
    return id >= FIRST_FACTION_ID and id <= LAST_FACTION_ID;
}

/// Null for an alliance, or a faction the table doesn't know.
pub fn factionColor(id: u32) ?u32 {
    for (FACTION_COLORS) |faction| {
        if (faction.id == id) return faction.color;
    }
    return null;
}

/// The hue most of a logo's coloured pixels share, brought to the map's lightness; null when too little of it has colour. `pixels` is RGBA, 4 bytes a pixel.
pub fn logoColor(pixels: []const u8) ?u32 {
    var weights: [HUE_BINS]f32 = @splat(0);
    var sums_a: [HUE_BINS]f32 = @splat(0);
    var sums_b: [HUE_BINS]f32 = @splat(0);
    var opaque_count: usize = 0;
    var colored_count: usize = 0;
    var index: usize = 0;
    while (index + 4 <= pixels.len) : (index += 4) {
        if (pixels[index + 3] < MIN_ALPHA) continue;
        opaque_count += 1;
        const rgb = (@as(u32, pixels[index]) << 16) | (@as(u32, pixels[index + 1]) << 8) | pixels[index + 2];
        const lab = color_mod.rgbToOklab(rgb);
        const chroma = @sqrt(lab.a * lab.a + lab.b * lab.b);
        if (chroma < MIN_CHROMA or lab.l < MIN_LIGHTNESS) continue;
        colored_count += 1;
        // Weighted by chroma, so a logo's vivid parts outweigh its washed-out ones.
        const bin = hueBin(lab);
        weights[bin] += chroma;
        sums_a[bin] += lab.a * chroma;
        sums_b[bin] += lab.b * chroma;
    }
    if (colored_count == 0 or colored_count * 100 < opaque_count * MIN_COLORED_PERCENT) return null;

    // A hue on a bin's edge splits between two, so each bin is judged with its neighbours.
    var best_bin: usize = 0;
    var best_weight: f32 = 0;
    for (0..HUE_BINS) |bin| {
        const weight = neighbourhoodSum(&weights, bin);
        if (weight <= best_weight) continue;
        best_weight = weight;
        best_bin = bin;
    }
    const mean_a = neighbourhoodSum(&sums_a, best_bin) / best_weight;
    const mean_b = neighbourhoodSum(&sums_b, best_bin) / best_weight;
    const hue_degrees = std.math.atan2(mean_b, mean_a) * 180 / std.math.pi;
    return shownColor(hue_degrees, std.math.clamp(@sqrt(mean_a * mean_a + mean_b * mean_b), MIN_SHOWN_CHROMA, MAX_SHOWN_CHROMA));
}

fn hueBin(lab: color_mod.Oklab) usize {
    const turns = std.math.atan2(lab.b, lab.a) / (2 * std.math.pi);
    const wrapped = turns - @floor(turns);
    return @min(HUE_BINS - 1, @as(usize, @intFromFloat(wrapped * HUE_BINS)));
}

/// `bin` and the bins either side of it, wrapping round the hue circle.
fn neighbourhoodSum(values: *const [HUE_BINS]f32, bin: usize) f32 {
    return values[(bin + HUE_BINS - 1) % HUE_BINS] + values[bin] + values[(bin + 1) % HUE_BINS];
}

/// At SHOWN_LIGHTNESS, with chroma lowered until the colour fits sRGB.
fn shownColor(hue_degrees: f32, chroma: f32) u32 {
    var shown_chroma = chroma;
    while (shown_chroma > 0) : (shown_chroma -= CHROMA_STEP) {
        if (color_mod.oklchToRgb(SHOWN_LIGHTNESS, shown_chroma, hue_degrees)) |rgb| return 0xFF000000 | rgb;
    }
    return SHOWN_GREY;
}

const testing = std.testing;

/// An 8×8 logo, its pixels `first_count` of `first` and the rest `rest`.
fn testLogo(first: [4]u8, first_count: usize, rest: [4]u8) [8 * 8 * 4]u8 {
    var pixels: [8 * 8 * 4]u8 = undefined;
    for (0..64) |pixel| @memcpy(pixels[pixel * 4 ..][0..4], if (pixel < first_count) &first else &rest);
    return pixels;
}

fn channel(shade: u32, shift: u5) u32 {
    return (shade >> shift) & 0xFF;
}

test "a yellow emblem on black is picked as yellow" {
    const pixels = testLogo(.{ 255, 210, 0, 255 }, 24, .{ 0, 0, 0, 255 });
    const picked = logoColor(&pixels).?;
    try testing.expect(channel(picked, 16) > 150 and channel(picked, 8) > 150 and channel(picked, 0) < 120);
}

test "the hue covering most of a logo wins over a smaller one" {
    const pixels = testLogo(.{ 40, 90, 230, 255 }, 40, .{ 220, 30, 30, 255 });
    const picked = logoColor(&pixels).?;
    try testing.expect(channel(picked, 0) > channel(picked, 16));
}

test "a grey or see-through logo has no colour to pick" {
    const grey = testLogo(.{ 128, 128, 128, 255 }, 32, .{ 255, 255, 255, 255 });
    try testing.expect(logoColor(&grey) == null);
    const clear = testLogo(.{ 255, 0, 0, 0 }, 64, .{ 255, 0, 0, 0 });
    try testing.expect(logoColor(&clear) == null);
}

test "factions have fixed colours, and alliances' IDs are never factions'" {
    try testing.expect(factionColor(500010) != null);
    try testing.expect(factionColor(500999) == null);
    try testing.expect(isFaction(500003));
    // Goonswarm Federation, and one of the older nine-digit alliance IDs.
    try testing.expect(!isFaction(1354830081));
    try testing.expect(!isFaction(498125261));
}

test "logo colours read back as written, a missing colour included" {
    var colors: LogoColors = .{};
    colors.put(1354830081, 0xFFE8C547);
    colors.put(99003581, NO_COLOR);
    const json_text = try colors.toJson(testing.allocator);
    defer testing.allocator.free(json_text);
    const read = LogoColors.parse(testing.allocator, json_text);
    try testing.expectEqual(@as(usize, 2), read.count);
    try testing.expectEqual(@as(?u32, 0xFFE8C547), read.get(1354830081));
    try testing.expectEqual(@as(?u32, NO_COLOR), read.get(99003581));
    try testing.expectEqual(@as(?u32, null), read.get(498125261));
}

test "a cache from another version, or that doesn't parse, is ignored" {
    try testing.expectEqual(@as(usize, 0), LogoColors.parse(testing.allocator, "{\"version\":0,\"alliances\":[{\"id\":99,\"color\":\"0xFFFF0000\"}]}").count);
    try testing.expectEqual(@as(usize, 0), LogoColors.parse(testing.allocator, "{not json").count);
    const read = LogoColors.parse(testing.allocator, "{\"version\":1,\"alliances\":[{\"id\":99,\"color\":\"0xFF00FF00\"}]}");
    try testing.expectEqual(@as(?u32, 0xFF00FF00), read.get(99));
}

test "a full list starts again rather than growing" {
    var colors: LogoColors = .{};
    for (0..MAX_ALLIANCES) |index| colors.put(@intCast(index + 1), 0xFF123456);
    try testing.expectEqual(@as(usize, MAX_ALLIANCES), colors.count);
    colors.put(MAX_ALLIANCES + 1, 0xFF654321);
    try testing.expectEqual(@as(usize, 1), colors.count);
    try testing.expectEqual(@as(?u32, null), colors.get(1));
    try testing.expectEqual(@as(?u32, 0xFF654321), colors.get(MAX_ALLIANCES + 1));
}
