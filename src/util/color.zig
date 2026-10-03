//! Color math: OKLab-distinct palette picks, fixed per-name auto colors, and ARGB helpers.
const std = @import("std");
const log = @import("../log.zig");

const slog = log.scoped("color");

const DISTINCT_HUE_STEPS = 36;
const DISTINCT_LIGHTNESS = [_]f32{ 0.70, 0.80, 0.90 };
const DISTINCT_CHROMA = [_]f32{ 0.10, 0.15, 0.20, 0.26 };
const MAX_DISTINCT_CANDIDATES = DISTINCT_HUE_STEPS * DISTINCT_LIGHTNESS.len * DISTINCT_CHROMA.len;
const MAX_DISTINCT_TAKEN = 128;

const Oklab = struct { l: f32, a: f32, b: f32 };

const Candidate = struct { rgb: u32, lab: Oklab };

/// Names mapped to colors that stay fixed once assigned, least recently seen first; persistence is the owner's job (see `dirty`).
pub const AutoColors = struct {
    pub const MAX_ENTRIES = 64;
    pub const MAX_AVOIDED = 32;

    pub const Entry = struct {
        name: []const u8,
        color: u32,
    };

    entries: std.ArrayList(Entry) = .empty,
    /// Set whenever an entry is added, evicted or reordered; the owner clears it after persisting.
    dirty: bool = false,

    pub fn deinit(self: *AutoColors, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry.name);
        self.entries.deinit(allocator);
    }

    /// Adds an already-assigned color (e.g. from persisted state) without marking the store dirty.
    pub fn put(self: *AutoColors, allocator: std.mem.Allocator, name: []const u8, color: u32) !void {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        try self.entries.append(allocator, .{ .name = owned_name, .color = color });
    }

    /// The name's existing color, or a new one: the palette color farthest from `avoid` (at most `MAX_AVOIDED` used) and every entry already assigned.
    pub fn colorFor(self: *AutoColors, allocator: std.mem.Allocator, name: []const u8, avoid: []const u32) u32 {
        for (self.entries.items, 0..) |entry, i| {
            if (!std.ascii.eqlIgnoreCase(entry.name, name)) continue;
            if (i + 1 < self.entries.items.len) self.dirty = true;
            const seen = self.entries.orderedRemove(i);
            self.entries.appendAssumeCapacity(seen);
            return seen.color;
        }

        var taken: [MAX_AVOIDED + MAX_ENTRIES]u32 = undefined;
        const avoided = avoid[0..@min(avoid.len, MAX_AVOIDED)];
        @memcpy(taken[0..avoided.len], avoided);
        var count = avoided.len;
        for (self.entries.items) |entry| {
            if (count == taken.len) break;
            taken[count] = entry.color;
            count += 1;
        }

        const picked = 0xFF000000 | pickDistinctColor(name, taken[0..count]);
        self.record(allocator, name, picked);
        return picked;
    }

    fn record(self: *AutoColors, allocator: std.mem.Allocator, name: []const u8, color: u32) void {
        while (self.entries.items.len >= MAX_ENTRIES) {
            const evicted = self.entries.orderedRemove(0);
            allocator.free(evicted.name);
        }
        self.dirty = true;
        self.put(allocator, name, color) catch |err| {
            slog.err("Failed to record color for '{s}': {}", .{ name, err });
        };
    }
};

// Filled on first use; only touched from the main thread.
var g_candidate_table: [MAX_DISTINCT_CANDIDATES]Candidate = undefined;
var g_candidate_count: usize = 0;

/// Picks the palette color farthest (in OKLab) from every color in `taken`; with nothing taken, `seed_string` picks the starting point and breaks ties, so the result is deterministic. Returns 0xRRGGBB.
pub fn pickDistinctColor(seed_string: []const u8, taken: []const u32) u32 {
    const candidates = distinctCandidates();
    const count = candidates.len;

    var taken_labs: [MAX_DISTINCT_TAKEN]Oklab = undefined;
    const taken_count = @min(taken.len, MAX_DISTINCT_TAKEN);
    for (taken[0..taken_count], 0..) |rgb, i| taken_labs[i] = rgbToOklab(rgb);

    const start: usize = @intCast(std.hash.Wyhash.hash(0, seed_string) % count);
    var best_rgb = candidates[start].rgb;
    var best_distance: f32 = -1.0;
    for (0..count) |offset| {
        const candidate = candidates[(start + offset) % count];
        var nearest = std.math.inf(f32);
        for (taken_labs[0..taken_count]) |taken_lab| {
            nearest = @min(nearest, oklabDistance(candidate.lab, taken_lab));
        }
        if (nearest > best_distance) {
            best_distance = nearest;
            best_rgb = candidate.rgb;
        }
    }
    return best_rgb;
}

pub fn withAlpha(rgb: u32, alpha: u8) u32 {
    return (@as(u32, alpha) << 24) | (rgb & 0x00FF_FFFF);
}

/// For layered windows, which are presented premultiplied; valid only when drawing onto an already-transparent buffer.
pub fn premultiplyAlpha(color: u32) u32 {
    const fg_alpha = (color >> 24) & 0xFF;
    if (fg_alpha == 255) return color;
    const r = ((color >> 16) & 0xFF) * fg_alpha / 255;
    const g = ((color >> 8) & 0xFF) * fg_alpha / 255;
    const b = (color & 0xFF) * fg_alpha / 255;
    return (fg_alpha << 24) | (r << 16) | (g << 8) | b;
}

/// Mixes each channel `percent`% of the way toward white, keeping alpha.
pub fn lighten(color: u32, percent: u32) u32 {
    var out = color & 0xFF00_0000;
    inline for (.{ 16, 8, 0 }) |shift| {
        const channel = (color >> shift) & 0xFF;
        out |= (channel + (255 - channel) * percent / 100) << shift;
    }
    return out;
}

/// Text color that stays readable on `background`: dark ink on light colors, light ink on dark ones.
pub fn inkFor(background: u32) u32 {
    const r = (background >> 16) & 0xFF;
    const g = (background >> 8) & 0xFF;
    const b = background & 0xFF;
    return if (299 * r + 587 * g + 114 * b > 550 * 255) 0xFF1A1408 else 0xFFF5F0E6;
}

fn distinctCandidates() []const Candidate {
    if (g_candidate_count == 0) {
        for (0..DISTINCT_HUE_STEPS) |hue_step| {
            const hue = @as(f32, @floatFromInt(hue_step)) * (360.0 / @as(f32, DISTINCT_HUE_STEPS));
            for (DISTINCT_LIGHTNESS) |lightness| {
                for (DISTINCT_CHROMA) |chroma| {
                    const rgb = oklchToRgb(lightness, chroma, hue) orelse continue;
                    g_candidate_table[g_candidate_count] = .{ .rgb = rgb, .lab = rgbToOklab(rgb) };
                    g_candidate_count += 1;
                }
            }
        }
    }
    return g_candidate_table[0..g_candidate_count];
}

fn srgbByteToLinear(byte: u32) f32 {
    const c = @as(f32, @floatFromInt(byte & 0xFF)) / 255.0;
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

fn linearToSrgbByte(linear: f32) u32 {
    const c = std.math.clamp(linear, 0.0, 1.0);
    const encoded = if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(encoded * 255.0));
}

fn rgbToOklab(rgb: u32) Oklab {
    const r = srgbByteToLinear(rgb >> 16);
    const g = srgbByteToLinear(rgb >> 8);
    const b = srgbByteToLinear(rgb);

    const l = std.math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const m = std.math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const s = std.math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);

    return .{
        .l = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        .a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        .b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    };
}

/// Null when the color falls outside the sRGB gamut.
fn oklchToRgb(lightness: f32, chroma: f32, hue_degrees: f32) ?u32 {
    const radians = hue_degrees * std.math.pi / 180.0;
    const a = chroma * @cos(radians);
    const b = chroma * @sin(radians);

    const l_ = lightness + 0.3963377774 * a + 0.2158037573 * b;
    const m_ = lightness - 0.1055613458 * a - 0.0638541728 * b;
    const s_ = lightness - 0.0894841775 * a - 1.2914855480 * b;
    const l = l_ * l_ * l_;
    const m = m_ * m_ * m_;
    const s = s_ * s_ * s_;

    const r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
    const g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
    const bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;

    const tolerance = 0.002;
    for ([_]f32{ r, g, bl }) |channel| {
        if (channel < -tolerance or channel > 1.0 + tolerance) return null;
    }
    return (linearToSrgbByte(r) << 16) | (linearToSrgbByte(g) << 8) | linearToSrgbByte(bl);
}

fn oklabDistance(x: Oklab, y: Oklab) f32 {
    const dl = x.l - y.l;
    const da = x.a - y.a;
    const db = x.b - y.b;
    return @sqrt(dl * dl + da * da + db * db);
}

const testing = std.testing;

test "withAlpha replaces only the alpha byte" {
    try testing.expectEqual(@as(u32, 0x80345678), withAlpha(0x12345678, 0x80));
}

test "lighten mixes toward white and keeps alpha" {
    try testing.expectEqual(@as(u32, 0xFF123456), lighten(0xFF123456, 0));
    try testing.expectEqual(@as(u32, 0x80FFFFFF), lighten(0x80000000, 100));
    try testing.expectEqual(@as(u32, 0xFF7F7F7F), lighten(0xFF000000, 50));
}

test "inkFor picks dark ink on light backgrounds and light ink on dark ones" {
    try testing.expectEqual(@as(u32, 0xFF1A1408), inkFor(0xFFFFFFFF));
    try testing.expectEqual(@as(u32, 0xFF1A1408), inkFor(0xFFFFFF00));
    try testing.expectEqual(@as(u32, 0xFFF5F0E6), inkFor(0xFF000000));
    try testing.expectEqual(@as(u32, 0xFFF5F0E6), inkFor(0xFF0000FF));
}

test "pickDistinctColor is deterministic and avoids taken colors" {
    const first = pickDistinctColor("Some Pilot", &.{});
    try testing.expectEqual(first, pickDistinctColor("Some Pilot", &.{}));
    try testing.expectEqual(@as(u32, 0), first & 0xFF000000);
    const second = pickDistinctColor("Some Pilot", &.{first});
    try testing.expect(second != first);
    try testing.expect(pickDistinctColor("Other Pilot", &.{ first, second }) != first);
}

test "AutoColors keeps a name's color and marks only new assignments dirty" {
    var colors: AutoColors = .{};
    defer colors.deinit(testing.allocator);

    const assigned = colors.colorFor(testing.allocator, "Some Pilot", &.{});
    try testing.expectEqual(@as(u32, 0xFF000000), assigned & 0xFF000000);
    try testing.expect(colors.dirty);

    colors.dirty = false;
    try testing.expectEqual(assigned, colors.colorFor(testing.allocator, "SOME PILOT", &.{}));
    try testing.expect(!colors.dirty);
    try testing.expect(colors.colorFor(testing.allocator, "Other Pilot", &.{}) != assigned);
}

test "AutoColors marks the store dirty when a lookup changes the recency order" {
    var colors: AutoColors = .{};
    defer colors.deinit(testing.allocator);

    try colors.put(testing.allocator, "Older Pilot", 0xFF123456);
    try colors.put(testing.allocator, "Newer Pilot", 0xFF654321);
    _ = colors.colorFor(testing.allocator, "Older Pilot", &.{});
    try testing.expect(colors.dirty);
    try testing.expectEqualStrings("Older Pilot", colors.entries.items[1].name);
}

test "AutoColors.put restores a color without marking the store dirty" {
    var colors: AutoColors = .{};
    defer colors.deinit(testing.allocator);

    try colors.put(testing.allocator, "Some Pilot", 0xFF123456);
    try testing.expect(!colors.dirty);
    try testing.expectEqual(@as(u32, 0xFF123456), colors.colorFor(testing.allocator, "some pilot", &.{}));
}

test "AutoColors evicts the least recently seen name past MAX_ENTRIES" {
    var colors: AutoColors = .{};
    defer colors.deinit(testing.allocator);

    var name_buf: [16]u8 = undefined;
    for (0..AutoColors.MAX_ENTRIES + 1) |i| {
        const name = std.fmt.bufPrint(&name_buf, "Pilot {d}", .{i}) catch unreachable;
        _ = colors.colorFor(testing.allocator, name, &.{});
    }
    try testing.expectEqual(@as(usize, AutoColors.MAX_ENTRIES), colors.entries.items.len);
    try testing.expectEqualStrings("Pilot 1", colors.entries.items[0].name);
}
