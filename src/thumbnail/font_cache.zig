//! GDI fonts cached per purpose and DPI.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const types = @import("../config/types.zig");
const config = @import("../config.zig");

const CachedFont = gdi_overlay.CachedFont;

/// `combat` is incoming DPS's slot; outgoing DPS has its own.
pub const FontSlot = enum(u4) { main, combat, mining, bounty, system_name, group_badge, notification, combat_outgoing, resources, session_timer, ping };

/// Keyed by slot and DPI, so monitors at different DPIs don't evict each other's fonts.
pub const FontCache = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMap(u32, CachedFont),

    pub fn init(allocator: std.mem.Allocator) FontCache {
        return .{ .allocator = allocator, .entries = .init(allocator) };
    }

    pub fn deinit(self: *FontCache) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| entry.deinit(self.allocator);
        self.entries.deinit();
    }

    /// For overlays not tied to one thumbnail window: ghost outlines, hint box, region-select label.
    pub fn characterNameFont(self: *FontCache, thumbnail_config: *const config.ThumbnailConfig, dpi: u32) !win32.HFONT {
        return self.get(.main, dpi, thumbnail_config.characterNameFontName, win32.scalePixels(thumbnail_config.characterNameFontSize, win32.dpiToScale(dpi)), thumbnail_config.characterNameFontWeight);
    }

    /// Recreated only when its settings change; the cache owns the returned font, and logs a font it couldn't create.
    pub fn get(self: *FontCache, slot: FontSlot, dpi: u32, font_name: []const u8, font_size: i32, font_weight: types.FontWeight) !win32.HFONT {
        const lookup = try self.entries.getOrPut(cacheKey(slot, dpi));
        if (!lookup.found_existing) lookup.value_ptr.* = .{};
        const entry = lookup.value_ptr;
        try entry.ensure(self.allocator, @tagName(slot), font_name, font_size, font_weight);
        return entry.handle orelse error.CreateFontFailed;
    }
};

/// dpi stays far below the 16 bits reserved for it.
fn cacheKey(slot: FontSlot, dpi: u32) u32 {
    return (@as(u32, @backingInt(slot)) << 16) | (dpi & 0xFFFF);
}
