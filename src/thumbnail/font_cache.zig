const std = @import("std");
const win32 = @import("../platform/win32.zig");
const types = @import("../types.zig");
const config_mod = @import("../config.zig");
const log = @import("../log.zig");
const slog = log.scoped("font_cache");

/// Per-purpose font cache slot. Kept as u4 (not u3) so a future slot doesn't need a resize.
/// `combat` is incoming DPS's slot; outgoing DPS has its own.
pub const FontSlot = enum(u4) { main, combat, mining, bounty, system_name, group_badge, notification, combat_outgoing, resources };

const Entry = struct {
    font: ?win32.HFONT = null,
    name: []const u8 = "",
    size: i32 = 0,
    weight: types.FontWeight = .Regular,
};

/// dpi realistically never exceeds ~480 (5x scale), well under the 16 bits reserved here.
fn cacheKey(slot: FontSlot, dpi: u32) u32 {
    return (@as(u32, @intFromEnum(slot)) << 16) | (dpi & 0xFFFF);
}

/// GDI fonts keyed by (FontSlot, DPI), so different-DPI monitors don't evict each other's fonts every render.
pub const FontCache = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMap(u32, Entry),

    pub fn init(allocator: std.mem.Allocator) FontCache {
        return .{ .allocator = allocator, .entries = std.AutoHashMap(u32, Entry).init(allocator) };
    }

    pub fn deinit(self: *FontCache) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| {
            if (entry.font) |font| _ = win32.DeleteObject(font);
            self.allocator.free(entry.name);
        }
        self.entries.deinit();
    }

    /// The thumbnail character-name font at `dpi`, for overlays not tied to one thumbnail window (ghost outlines, hint box, region-select label).
    pub fn characterNameFont(self: *FontCache, thumbnail_cfg: *const config_mod.Config.ThumbnailConfig, dpi: u32) !win32.HFONT {
        return self.get(.main, dpi, thumbnail_cfg.characterNameFontName, win32.scalePixels(thumbnail_cfg.characterNameFontSize, win32.dpiToScale(dpi)), thumbnail_cfg.characterNameFontWeight);
    }

    /// Gets or creates the cached font for the given (slot, dpi), recreating it only if its settings changed.
    pub fn get(self: *FontCache, slot: FontSlot, dpi: u32, font_name: []const u8, font_size: i32, font_weight: types.FontWeight) !win32.HFONT {
        const gop = try self.entries.getOrPut(cacheKey(slot, dpi));
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const entry = gop.value_ptr;

        const cache_valid = entry.font != null and
            std.mem.eql(u8, entry.name, font_name) and
            entry.size == font_size and
            entry.weight == font_weight;

        if (cache_valid) {
            return entry.font.?;
        }

        if (entry.font) |old_font| {
            _ = win32.DeleteObject(old_font);
            entry.font = null;
            slog.debug("Font cache invalidated for slot {} @ {} DPI (settings changed)", .{ slot, dpi });
        }

        const font_name_z = try self.allocator.dupeZ(u8, font_name);
        defer self.allocator.free(font_name_z);

        // Owns a copy rather than borrowing font_name, which may be freed/replaced out from under a cached entry.
        const name_copy = try self.allocator.dupe(u8, font_name);
        errdefer self.allocator.free(name_copy);

        const font = win32.CreateFontA(
            -font_size,
            0,
            0,
            0,
            font_weight.toWin32Weight(),
            if (font_weight.isItalic()) 1 else 0,
            0,
            0,
            win32.DEFAULT_CHARSET,
            win32.OUT_DEFAULT_PRECIS,
            win32.CLIP_DEFAULT_PRECIS,
            win32.CLEARTYPE_QUALITY,
            win32.DEFAULT_PITCH,
            font_name_z,
        );

        if (font == null) {
            return error.CreateFontFailed;
        }

        self.allocator.free(entry.name);
        entry.font = font;
        entry.name = name_copy;
        entry.size = font_size;
        entry.weight = font_weight;

        slog.debug("Created cached font for slot {} @ {} DPI: {s} size={} weight={}", .{ slot, dpi, font_name, font_size, font_weight });

        return font.?;
    }
};
