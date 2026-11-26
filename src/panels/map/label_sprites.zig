//! The Map Panel's names with their halos, each drawn by GDI once and kept as coverage to blend into later frames.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const gdi_overlay = @import("../../platform/gdi_overlay.zig");
const look = @import("look.zig");
const panel_chrome = @import("../panel_chrome.zig");
const layout = @import("../../map/layout.zig");
const pixel_buffer = @import("../../util/pixel_buffer.zig");
const log = @import("../../log.zig");

const slog = log.Scoped("map_panel");

/// Room round the text for its halo, and for a glyph reaching a pixel past its advance.
const MARGIN = 2;
/// Past this many names all are dropped and drawn again as needed; twice what the most regions shown can label.
const MAX_SPRITES = 2 * (layout.MAX_NODES + layout.MAX_EXITS + layout.MAX_PORTALS);
/// The scratch bitmap's least size; it grows to fit the widest name.
const SCRATCH_WIDTH = 256;
const SCRATCH_HEIGHT = 32;

/// GDI covers light text and dark text by different curves, so each name keeps both.
const Curve = enum { light, dark };

/// A sprite's coverage of the text, then of its halo, by each Curve.
const Plane = enum { text_light, text_dark, halo_light, halo_dark };

/// One name's coverage, a MARGIN wider than the text all round.
const Sprite = struct {
    width: usize,
    /// Owned; one plane of the sprite's size per Plane, in its order.
    coverage: []u8,

    fn plane(self: Sprite, which: Plane) []const u8 {
        return planeOf(self.coverage, which);
    }
};

pub const LabelSprites = struct {
    allocator: std.mem.Allocator,
    /// Keyed by the drawn text, which each entry owns; all drawn in `font`.
    sprites: std.StringHashMapUnmanaged(Sprite) = .empty,
    /// Borrowed from the window's label font; null until useFont.
    font: ?win32.HFONT = null,
    /// What `font` was made from, since a remade font can reuse a deleted one's handle.
    font_signature: u64 = 0,
    /// Where GDI draws each new name.
    scratch: ?gdi_overlay.OverlayBitmap = null,
    /// Only the first failure since the font changed is logged, as every frame retries it.
    has_logged_failure: bool = false,

    pub fn init(allocator: std.mem.Allocator) LabelSprites {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LabelSprites) void {
        self.clear();
        self.sprites.deinit(self.allocator);
        if (self.scratch) |scratch| scratch.deinit();
        self.scratch = null;
    }

    /// Drops every name once the font or `signature`, what it was made from, changes.
    pub fn useFont(self: *LabelSprites, font: win32.HFONT, signature: u64) void {
        if (self.font == font and self.font_signature == signature) return;
        self.clear();
        self.font = font;
        self.font_signature = signature;
        self.has_logged_failure = false;
    }

    /// Blends `text` and its halo in as drawHaloText would, at its top left `x`,`y`; logs its own failures.
    pub fn draw(self: *LabelSprites, canvas: pixel_buffer.Canvas, text: []const u8, x: i32, y: i32, color: u32) !void {
        const shown = text[0..@min(text.len, panel_chrome.MAX_TEXT_LENGTH - 1)];
        const sprite = self.sprites.get(shown) orelse try self.add(shown);
        const left = x - MARGIN;
        const top = y - MARGIN;
        pixel_buffer.fillGdiCoverage(canvas, left, top, sprite.plane(.halo_light), sprite.plane(.halo_dark), sprite.width, look.BACKGROUND);
        pixel_buffer.fillGdiCoverage(canvas, left, top, sprite.plane(.text_light), sprite.plane(.text_dark), sprite.width, color);
    }

    fn add(self: *LabelSprites, text: []const u8) !Sprite {
        return self.cache(text) catch |err| {
            if (!self.has_logged_failure) slog.warn("Failed to prepare the map name '{s}', so names are drawn directly, which is slower: {}", .{ text, err });
            self.has_logged_failure = true;
            return err;
        };
    }

    fn cache(self: *LabelSprites, text: []const u8) !Sprite {
        if (self.sprites.count() >= MAX_SPRITES) self.clear();
        const sprite = try self.rasterize(text);
        errdefer self.allocator.free(sprite.coverage);
        const key = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(key);
        try self.sprites.put(self.allocator, key, sprite);
        return sprite;
    }

    fn rasterize(self: *LabelSprites, text: []const u8) !Sprite {
        const font = self.font orelse return error.MissingFont;
        const terminated = gdi_overlay.terminatedCopy(panel_chrome.MAX_TEXT_LENGTH, text);
        const length: c_int = @intCast(text.len);
        const extent = try measure(try self.scratchOfAtLeast(1, 1), font, &terminated, length);
        const width: usize = @intCast(@max(0, extent.cx) + 2 * MARGIN);
        const height: usize = @intCast(@max(0, extent.cy) + 2 * MARGIN);
        const scratch = try self.scratchOfAtLeast(width, height);

        const coverage = try self.allocator.alloc(u8, std.enums.values(Plane).len * width * height);
        errdefer self.allocator.free(coverage);
        try drawCoverage(scratch, font, &terminated, length, width, height, .light, planeOf(coverage, .text_light));
        try drawCoverage(scratch, font, &terminated, length, width, height, .dark, planeOf(coverage, .text_dark));
        pixel_buffer.haloCoverage(planeOf(coverage, .text_light), width, planeOf(coverage, .halo_light));
        pixel_buffer.haloCoverage(planeOf(coverage, .text_dark), width, planeOf(coverage, .halo_dark));
        return .{ .width = width, .coverage = coverage };
    }

    /// Grown only, so names of every size share one.
    fn scratchOfAtLeast(self: *LabelSprites, width: usize, height: usize) !*gdi_overlay.OverlayBitmap {
        var current_width: usize = SCRATCH_WIDTH;
        var current_height: usize = SCRATCH_HEIGHT;
        if (self.scratch) |*scratch| {
            if (scratch.width >= width and scratch.height >= height) return scratch;
            current_width = scratch.width;
            current_height = scratch.height;
        }
        return gdi_overlay.OverlayBitmap.ensureSize(&self.scratch, @intCast(@max(width, current_width)), @intCast(@max(height, current_height)));
    }

    fn clear(self: *LabelSprites) void {
        var entries = self.sprites.iterator();
        while (entries.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.coverage);
        }
        self.sprites.clearRetainingCapacity();
    }
};

fn planeOf(coverage: []u8, which: Plane) []u8 {
    const size = coverage.len / std.enums.values(Plane).len;
    return coverage[@as(usize, @backingInt(which)) * size ..][0..size];
}

/// Puts the DC's own font back, so the window can delete `font` when its settings change.
fn measure(scratch: *const gdi_overlay.OverlayBitmap, font: win32.HFONT, text: [*:0]const u8, length: c_int) !win32.SIZE {
    const previous_font = win32.SelectObject(scratch.mem_dc, font);
    defer if (previous_font) |previous| {
        _ = win32.SelectObject(scratch.mem_dc, previous);
    };
    var extent: win32.SIZE = .{ .cx = 0, .cy = 0 };
    if (!win32.toBool(win32.GetTextExtentPoint32A(scratch.mem_dc, text, length, &extent))) return error.MeasureTextFailed;
    return extent;
}

/// The text at MARGIN by `curve`: white on black for light text's, and black on white, read inverted, for dark text's.
fn drawCoverage(scratch: *const gdi_overlay.OverlayBitmap, font: win32.HFONT, text: [*:0]const u8, length: c_int, width: usize, height: usize, curve: Curve, coverage: []u8) !void {
    const background: u32 = switch (curve) {
        .light => 0,
        .dark => 0xFFFF_FFFF,
    };
    for (0..height) |row| @memset(scratch.pixels[row * scratch.width ..][0..width], background);

    const dc = scratch.mem_dc;
    const previous_font = win32.SelectObject(dc, font);
    defer if (previous_font) |previous| {
        _ = win32.SelectObject(dc, previous);
    };
    _ = win32.SetBkMode(dc, win32.TRANSPARENT);
    _ = win32.SetTextColor(dc, gdi_overlay.toColorRef(~background));
    if (!win32.toBool(win32.TextOutA(dc, MARGIN, MARGIN, text, length))) return error.TextOutFailed;
    _ = win32.GdiFlush();

    for (0..height) |row| {
        for (0..width) |column| {
            const green: u8 = @truncate(scratch.pixels[row * scratch.width + column] >> 8);
            coverage[row * width + column] = switch (curve) {
                .light => green,
                .dark => 255 - green,
            };
        }
    }
}
