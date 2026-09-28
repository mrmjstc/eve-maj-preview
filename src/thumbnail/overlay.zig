//! A thumbnail's text overlay: what to draw (RenderSettings, compared to skip redundant redraws) and drawing it into the layered window over the DWM thumbnail.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const color_mod = @import("../util/color.zig");
const types = @import("../config/types.zig");
const state_mod = @import("state.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const log = @import("../log.zig");
const slog = log.scoped("overlay");
const notification_stack_mod = @import("../notifications/stack.zig");
const draw = @import("draw.zig");
const font_cache_mod = @import("font_cache.zig");
const format = @import("../util/format.zig");

const window_mod = @import("window.zig");
const ThumbnailWindow = window_mod.ThumbnailWindow;
const TextPosition = types.TextPosition;
const BorderStyle = types.BorderStyle;
const TextDimensions = draw.TextDimensions;
const TextOrigin = draw.TextOrigin;
const FontCache = font_cache_mod.FontCache;
const scalePixels = win32.scalePixels;

/// One resolved (text, color) line of the stacked notification block; built by createRenderSettings, drawn by renderThumbnailOverlay.
pub const NotificationLine = struct {
    text: []const u8 = "",
    color: u32 = 0xFFFFFF,
};

const OVERLAY_ALPHA = 255;

/// Everything a thumbnail's overlay depends on, so an unchanged one needn't be redrawn.
/// Combat, mining, bounty and resources config is read straight from the profile instead; every config edit clears the render cache anyway.
pub const RenderSettings = struct {
    /// Every overlay text; the per-element flags below are already false without it.
    show_text: bool = true,
    show_character_name: bool = true,
    display_name: []const u8 = "",
    show_system_name: bool = false,
    system_name: []const u8 = "",
    character_name_color: u32 = 0xFFFFFF,
    system_name_color: u32 = 0xFFFFFF,
    character_name_bg_color: u32 = 0x80000000,
    system_name_bg_color: u32 = 0x80000000,
    character_name_font_name: []const u8 = "Segoe UI",
    character_name_font_size: i32 = 14,
    character_name_font_weight: types.FontWeight = .Regular,
    character_name_position: TextPosition = .TopLeft,
    character_name_offset_x: i32 = 0,
    character_name_offset_y: i32 = 0,
    system_name_position: TextPosition = .BottomLeft,
    system_name_offset_x: i32 = 0,
    system_name_offset_y: i32 = 0,
    system_name_font_name: []const u8 = "Segoe UI",
    system_name_font_size: i32 = 12,
    system_name_font_weight: types.FontWeight = .Regular,
    show_notifications: bool = false,
    notification_lines: [notification_stack_mod.CAPACITY]NotificationLine = .{NotificationLine{}} ** notification_stack_mod.CAPACITY,
    notification_line_count: usize = 0,
    notifications_position: TextPosition = .Center,
    notifications_offset_x: i32 = 0,
    notifications_offset_y: i32 = 0,
    notifications_font_name: []const u8 = "Segoe UI",
    notifications_font_size: i32 = 12,
    notifications_font_weight: types.FontWeight = .Regular,
    notifications_bg_color: u32 = 0x80000000,

    show_border: bool = true,
    border_width: u8 = 2,
    border_color: u32 = 0xFF606060,
    border_style: BorderStyle = .Solid,

    show_exclusion_overlay: bool = false,
    exclusion_overlay_style: types.ExclusionOverlayStyle = .X,
    exclusion_overlay_color: u32 = 0x33A62222,

    show_group_badge: bool = false,
    group_badge_text: []const u8 = "",
    group_badge_color: u32 = 0xFF44FF44,
    group_badge_position: TextPosition = .RightCenter,
    group_badge_offset_x: i32 = 0,
    group_badge_offset_y: i32 = 0,
    group_badge_font_name: []const u8 = "Segoe UI",
    group_badge_font_size: i32 = 12,
    group_badge_font_weight: types.FontWeight = .Regular,
    group_badge_bg_color: u32 = 0x80000000,
    combat_incoming_bg_color: u32 = 0x80000000,
    combat_outgoing_bg_color: u32 = 0x80000000,
    mining_bg_color: u32 = 0x80000000,
    bounty_bg_color: u32 = 0x80000000,
    resources_bg_color: u32 = 0x80000000,

    show_thumbnail: bool = true,
    overlay_alpha: u8 = OVERLAY_ALPHA,

    overlay_width: c_int,
    overlay_height: c_int,

    // -1 stands in for a rate still being calculated (null); no real rate is negative.
    dps_incoming: f32 = 0.0,
    dps_outgoing: f32 = 0.0,
    mining_rate: f32 = 0.0,
    mining_isk_rate: f32 = 0.0,
    bounty_isk_rate: f32 = 0.0,
    resource_cpu_percent: f32 = 0.0,
    resource_ram_mb: f32 = 0.0,
    resource_vram_mb: f32 = 0.0,
    // So a tracker's first report redraws even when the (sentinel) rate itself didn't change.
    has_dps_data: bool = false,
    has_mining_data: bool = false,
    has_bounty_data: bool = false,
    has_resource_data: bool = false,
    has_vram_data: bool = false,

    dps_incoming_color: u32 = 0xFFFF4444,
    dps_outgoing_color: u32 = 0xFF44FF44,
    mining_color: u32 = 0xFF44AAFF,
    bounty_color: u32 = 0xFFFFD700,
    resources_color: u32 = 0xFFFFFFFF,
};

pub fn renderSettingsEqual(a: RenderSettings, b: RenderSettings) bool {
    return a.show_thumbnail == b.show_thumbnail and visualEqual(a, b);
}

pub fn renderSettingsOnlyVisibilityChanged(a: RenderSettings, b: RenderSettings) bool {
    return a.show_thumbnail != b.show_thumbnail and visualEqual(a, b);
}

/// Every field but show_thumbnail, walked at comptime so a field added to RenderSettings is always part of the check.
fn visualEqual(a: RenderSettings, b: RenderSettings) bool {
    inline for (@typeInfo(RenderSettings).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "show_thumbnail")) continue;
        if (!valuesEqual(f.type, @field(a, f.name), @field(b, f.name))) return false;
    }
    return true;
}

fn valuesEqual(comptime T: type, a: T, b: T) bool {
    if (T == []const u8) return stringsEqualFast(a, b);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.fields) |f| {
                if (!valuesEqual(f.type, @field(a, f.name), @field(b, f.name))) return false;
            }
            return true;
        },
        .array => |info| {
            for (a, b) |x, y| {
                if (!valuesEqual(info.child, x, y)) return false;
            }
            return true;
        },
        else => return a == b,
    }
}

/// Pointer+len fast path before falling back to a byte compare; config/notif-owned slices are pointer+len identical every tick when unchanged.
fn stringsEqualFast(a: []const u8, b: []const u8) bool {
    return (a.ptr == b.ptr and a.len == b.len) or std.mem.eql(u8, a, b);
}

/// A text run's measured size and the font it was measured with, so an unchanged run isn't re-measured every render; `font_name` borrows config's font-name buffer.
/// Keyed by font only, so whoever changes the text clears `dims`.
const MeasuredText = struct {
    dims: ?TextDimensions = null,
    font_name: []const u8 = "",
    font_size: i32 = 0,
    font_weight: types.FontWeight = .Regular,

    fn measure(self: *MeasuredText, layout: *Layout, font: win32.HFONT, text: []const u8, font_name: []const u8, font_size: i32, font_weight: types.FontWeight) TextDimensions {
        if (self.dims) |cached| {
            if (stringsEqualFast(self.font_name, font_name) and self.font_size == font_size and self.font_weight == font_weight) return cached;
        }
        const measured = layout.measure(font, text);
        self.* = .{ .dims = measured, .font_name = font_name, .font_size = font_size, .font_weight = font_weight };
        return measured;
    }
};

/// Per-thumbnail state the overlay renderer keeps between renders.
pub const RenderCache = struct {
    /// Recreated only on resize.
    bitmap: ?gdi_overlay.OverlayBitmap = null,
    /// Last rendered settings; Painter.renderThumbnail compares against it to skip redundant redraws.
    settings: ?RenderSettings = null,
    character_name: MeasuredText = .{},
    system_name: MeasuredText = .{},
    group_badge: MeasuredText = .{},

    /// Forces the next render to redraw and re-measure everything, dropping the font-name slices borrowed from config that a preview edit may have just freed.
    pub fn invalidate(self: *RenderCache) void {
        self.settings = null;
        self.character_name = .{};
        self.system_name = .{};
        self.group_badge = .{};
    }

    pub fn deinit(self: *const RenderCache) void {
        if (self.bitmap) |bitmap| bitmap.destroy();
    }
};

/// One paintable text run. render_pos is where its glyphs go; bg_pos/bg_dims bound its background and alpha fixup,
/// which differ for a stacked block's lines: they share the block's width but each aligns to its edge.
const DrawLine = struct {
    font: win32.HFONT,
    text: []const u8,
    render_pos: TextOrigin,
    bg_pos: TextOrigin,
    bg_dims: TextDimensions,
    color: u32,
    bg_color: u32,
};

/// Character name, system, group badge, DPS in and out, mining (and its ISK line), bounty, and up to three resource lines.
const MAX_LINES = 1 + 1 + 1 + 2 + 2 + 1 + 3;
const MAX_STACK = 3;
const TEXT_BUF = 32;

/// The single-rect text runs one render lays out, before any of them is drawn.
const Layout = struct {
    dc: win32.HDC,
    width: usize,
    height: usize,
    lines: [MAX_LINES]DrawLine = undefined,
    count: usize = 0,
    // The lines' formatted text lives here, so a Layout is never copied once built.
    text_bufs: [MAX_LINES][TEXT_BUF]u8 = undefined,
    texts_used: usize = 0,
    // The DC's own font, put back once rendering is done.
    original_font: ?win32.HANDLE = null,

    fn select(self: *Layout, font: win32.HFONT) void {
        const previous = win32.SelectObject(self.dc, font);
        if (self.original_font == null) self.original_font = previous;
    }

    fn restoreFont(self: *Layout) void {
        if (self.original_font) |font| _ = win32.SelectObject(self.dc, font);
    }

    fn measure(self: *Layout, font: win32.HFONT, text: []const u8) TextDimensions {
        self.select(font);
        return draw.measureText(self.dc, text);
    }

    /// Short stat text only, so it can't outgrow its buffer in practice; "---" if it somehow does.
    fn print(self: *Layout, comptime fmt: []const u8, args: anytype) []const u8 {
        const buf = &self.text_bufs[self.texts_used];
        self.texts_used += 1;
        return std.fmt.bufPrint(buf, fmt, args) catch "---";
    }

    fn position(self: *const Layout, pos: TextPosition, dims: TextDimensions, offset_x: i32, offset_y: i32) TextOrigin {
        return draw.calculateTextPosition(pos, dims.width, dims.height, self.width, self.height, offset_x, offset_y);
    }

    fn add(self: *Layout, line: DrawLine) void {
        self.lines[self.count] = line;
        self.count += 1;
    }

    fn addAt(self: *Layout, font: win32.HFONT, text: []const u8, dims: TextDimensions, pos: TextPosition, offset_x: i32, offset_y: i32, color: u32, bg_color: u32) void {
        const origin = self.position(pos, dims, offset_x, offset_y);
        self.add(.{ .font = font, .text = text, .render_pos = origin, .bg_pos = origin, .bg_dims = dims, .color = color, .bg_color = bg_color });
    }

    /// Lines stacked top-down as one block anchored at `pos`, so Bottom*/Center* positions count every line's height.
    fn addStack(self: *Layout, font: win32.HFONT, texts: []const []const u8, pos: TextPosition, offset_x: i32, offset_y: i32, color: u32, bg_color: u32) void {
        var dims: [MAX_STACK]TextDimensions = undefined;
        var block: TextDimensions = .{ .width = 0, .height = 0 };
        for (texts, 0..) |text, i| {
            dims[i] = self.measure(font, text);
            block.width = @max(block.width, dims[i].width);
            block.height += dims[i].height;
        }
        const anchor = self.position(pos, block, offset_x, offset_y);
        const h_align = draw.horizontalAlignOf(pos);
        var y = anchor.y;
        for (texts, dims[0..texts.len]) |text, line_dims| {
            self.add(.{
                .font = font,
                .text = text,
                .render_pos = .{ .x = draw.alignedLineX(anchor.x, block.width, line_dims.width, h_align), .y = y },
                .bg_pos = .{ .x = anchor.x, .y = y },
                .bg_dims = .{ .width = block.width, .height = line_dims.height },
                .color = color,
                .bg_color = bg_color,
            });
            y += @as(i32, @intCast(line_dims.height));
        }
    }
};

/// Several lines, each its own colour, under one background; filled and drawn after everything else so nothing covers them.
const NotificationBlock = struct {
    font: win32.HFONT,
    origin: TextOrigin,
    dims: TextDimensions,
    line_heights: [notification_stack_mod.CAPACITY]usize,
};

/// Fonts are fetched for the window's own DPI; the stat fonts' sizes are scaled here, since their config isn't in RenderSettings.
const Fonts = struct {
    cache: *FontCache,
    dpi: u32,
    scale: f32,

    fn get(self: Fonts, slot: font_cache_mod.FontSlot, name: []const u8, size: i32, weight: types.FontWeight) !win32.HFONT {
        return self.cache.get(slot, self.dpi, name, size, weight);
    }

    fn getScaled(self: Fonts, slot: font_cache_mod.FontSlot, name: []const u8, size: i32, weight: types.FontWeight) !win32.HFONT {
        return self.cache.get(slot, self.dpi, name, scalePixels(size, self.scale), weight);
    }
};

pub fn renderThumbnailOverlay(fonts: *FontCache, thumbnail: *ThumbnailWindow, settings: RenderSettings, config: *const config_mod.Config) !void {
    const cache = &thumbnail.render_cache;
    if (gdi_overlay.OverlayBitmap.needsResize(cache.bitmap, settings.overlay_width, settings.overlay_height)) {
        const screen_dc = win32.GetDC(null) orelse return error.GetDCFailed;
        defer _ = win32.ReleaseDC(null, screen_dc);
        try gdi_overlay.OverlayBitmap.recreate(&cache.bitmap, screen_dc, settings.overlay_width, settings.overlay_height);
        slog.debug("Allocated overlay bitmap {}x{} for {s}", .{ settings.overlay_width, settings.overlay_height, thumbnail.character_name });
    }
    const overlay = &cache.bitmap.?;
    overlay.clear();

    if (settings.show_exclusion_overlay) {
        draw.drawExclusionOverlay(overlay.pixels, overlay.width, overlay.height, settings.exclusion_overlay_color, settings.exclusion_overlay_style);
    }

    const dpi: u32 = win32.GetDpiForWindow(thumbnail.hwnd);
    const f: Fonts = .{ .cache = fonts, .dpi = dpi, .scale = win32.dpiToScale(dpi) };
    var layout: Layout = .{ .dc = overlay.mem_dc, .width = overlay.width, .height = overlay.height };
    defer layout.restoreFont();

    // Added in painting order: a later background covers an earlier overlapping one.
    try addCharacterName(&layout, f, cache, settings);
    try addSystemName(&layout, f, cache, settings);
    try addGroupBadge(&layout, f, cache, settings);
    if (settings.show_text) {
        const stats = &thumbnail.stats;
        try addCombat(&layout, f, config, stats, settings);
        try addMining(&layout, f, config, stats, settings);
        try addBounty(&layout, f, config, stats, settings);
        try addResources(&layout, f, config, stats, settings);
    }
    const notifications = try layoutNotifications(&layout, f, settings);

    const lines = layout.lines[0..layout.count];
    // Before the border, so it paints over them.
    for (lines) |line| {
        draw.fillTextBackground(overlay.pixels, overlay.width, overlay.height, line.bg_pos.x, line.bg_pos.y, line.bg_dims.width, line.bg_dims.height, line.bg_color);
    }
    if (notifications) |n| {
        draw.fillTextBackground(overlay.pixels, overlay.width, overlay.height, n.origin.x, n.origin.y, n.dims.width, n.dims.height, settings.notifications_bg_color);
    }

    if (settings.show_border) {
        draw.drawBorder(overlay.pixels, overlay.width, overlay.height, @intCast(settings.border_width), settings.border_color, settings.border_style);
    }

    for (lines) |line| {
        layout.select(line.font);
        draw.renderText(overlay.mem_dc, line.text, line.render_pos.x, line.render_pos.y, line.color);
    }
    if (notifications) |n| {
        layout.select(n.font);
        var y = n.origin.y;
        for (settings.notification_lines[0..settings.notification_line_count], n.line_heights[0..settings.notification_line_count]) |line, line_height| {
            draw.renderText(overlay.mem_dc, line.text, n.origin.x, y, line.color);
            y += @as(i32, @intCast(line_height));
        }
    }

    // Bounded to where text was drawn instead of scanning the whole overlay.
    for (lines) |line| {
        gdi_overlay.fixTextAlphaRect(overlay.pixels, overlay.width, overlay.height, line.bg_pos.x, line.bg_pos.y, line.bg_dims.width, line.bg_dims.height);
    }
    if (notifications) |n| {
        gdi_overlay.fixTextAlphaRect(overlay.pixels, overlay.width, overlay.height, n.origin.x, n.origin.y, n.dims.width, n.dims.height);
    }

    gdi_overlay.presentLayered(thumbnail.text_hwnd, overlay, settings.overlay_alpha);
}

fn addCharacterName(layout: *Layout, f: Fonts, cache: *RenderCache, s: RenderSettings) !void {
    if (!s.show_character_name) return;
    const font = try f.get(.main, s.character_name_font_name, s.character_name_font_size, s.character_name_font_weight);
    const dims = cache.character_name.measure(layout, font, s.display_name, s.character_name_font_name, s.character_name_font_size, s.character_name_font_weight);
    layout.addAt(font, s.display_name, dims, s.character_name_position, s.character_name_offset_x, s.character_name_offset_y, s.character_name_color, s.character_name_bg_color);
}

fn addSystemName(layout: *Layout, f: Fonts, cache: *RenderCache, s: RenderSettings) !void {
    if (!s.show_system_name) return;
    const font = try f.get(.system_name, s.system_name_font_name, s.system_name_font_size, s.system_name_font_weight);
    const dims = cache.system_name.measure(layout, font, s.system_name, s.system_name_font_name, s.system_name_font_size, s.system_name_font_weight);
    layout.addAt(font, s.system_name, dims, s.system_name_position, s.system_name_offset_x, s.system_name_offset_y, s.system_name_color, s.system_name_bg_color);
}

fn addGroupBadge(layout: *Layout, f: Fonts, cache: *RenderCache, s: RenderSettings) !void {
    if (!s.show_group_badge) return;
    const font = try f.get(.group_badge, s.group_badge_font_name, s.group_badge_font_size, s.group_badge_font_weight);
    const dims = cache.group_badge.measure(layout, font, s.group_badge_text, s.group_badge_font_name, s.group_badge_font_size, s.group_badge_font_weight);
    layout.addAt(font, s.group_badge_text, dims, s.group_badge_position, s.group_badge_offset_x, s.group_badge_offset_y, s.group_badge_color, s.group_badge_bg_color);
}

fn addCombat(layout: *Layout, f: Fonts, config: *const config_mod.Config, stats: *const window_mod.ActivityStats, s: RenderSettings) !void {
    const cfg = &config.combat;
    if (!cfg.enabled) return;
    if (cfg.show_incoming and stats.showsIncoming()) {
        const font = try f.getScaled(.combat, cfg.incoming_font_name, cfg.incoming_font_size, cfg.incoming_font_weight);
        const text = rateText(layout, if (cfg.incoming_show_prefix) "IN: " else "", stats.incoming_dps);
        layout.addAt(font, text, layout.measure(font, text), cfg.incoming_position, cfg.incoming_offset_x, cfg.incoming_offset_y, cfg.incoming_color, s.combat_incoming_bg_color);
    }
    if (cfg.show_outgoing and stats.showsOutgoing()) {
        const font = try f.getScaled(.combat_outgoing, cfg.outgoing_font_name, cfg.outgoing_font_size, cfg.outgoing_font_weight);
        const text = rateText(layout, if (cfg.outgoing_show_prefix) "OUT: " else "", stats.outgoing_dps);
        layout.addAt(font, text, layout.measure(font, text), cfg.outgoing_position, cfg.outgoing_offset_x, cfg.outgoing_offset_y, cfg.outgoing_color, s.combat_outgoing_bg_color);
    }
}

fn rateText(layout: *Layout, prefix: []const u8, rate: ?f32) []const u8 {
    if (rate) |value| return layout.print("{s}{d:.0}", .{ prefix, value });
    return layout.print("{s}??", .{prefix});
}

fn addMining(layout: *Layout, f: Fonts, config: *const config_mod.Config, stats: *const window_mod.ActivityStats, s: RenderSettings) !void {
    const cfg = &config.mining;
    if (!cfg.enabled or !stats.showsMining()) return;
    const font = try f.getScaled(.mining, cfg.font_name, cfg.font_size, cfg.font_weight);
    const prefix: []const u8 = if (cfg.show_prefix) "M: " else "";

    var texts: [2][]const u8 = undefined;
    var count: usize = 1;
    texts[0] = if (stats.mining_rate) |rate| blk: {
        // Per minute rather than per second, so low-yield ore doesn't round to "0".
        const rate_per_min = rate * 60.0;
        var raw_buf: [16]u8 = undefined;
        const raw = if (rate_per_min < 10.0)
            std.fmt.bufPrint(&raw_buf, "{d:.1}", .{rate_per_min}) catch "---"
        else
            std.fmt.bufPrint(&raw_buf, "{d:.0}", .{rate_per_min}) catch "---";
        var comma_buf: [16]u8 = undefined;
        break :blk layout.print("{s}{s} m3/min", .{ prefix, format.insertThousandsSeparators(&comma_buf, raw) });
    } else layout.print("{s}?? m3/min", .{prefix});

    if (cfg.show_isk_rate) {
        texts[1] = iskRateText(layout, "", stats.mining_isk_rate, iskPeriod(cfg.isk_rate_unit));
        count = 2;
    }
    layout.addStack(font, texts[0..count], cfg.position, cfg.offset_x, cfg.offset_y, cfg.color, s.mining_bg_color);
}

fn addBounty(layout: *Layout, f: Fonts, config: *const config_mod.Config, stats: *const window_mod.ActivityStats, s: RenderSettings) !void {
    const cfg = &config.bounty;
    if (!cfg.enabled or !stats.showsBounty()) return;
    const font = try f.getScaled(.bounty, cfg.font_name, cfg.font_size, cfg.font_weight);
    const text = iskRateText(layout, if (cfg.show_prefix) "ISK: " else "", stats.bounty_isk_rate, iskPeriod(cfg.isk_rate_unit));
    layout.addAt(font, text, layout.measure(font, text), cfg.position, cfg.offset_x, cfg.offset_y, cfg.color, s.bounty_bg_color);
}

const IskPeriod = struct { seconds: f32, suffix: []const u8 };

fn iskPeriod(unit: anytype) IskPeriod {
    return if (unit == .hour) .{ .seconds = 3600.0, .suffix = "hr" } else .{ .seconds = 60.0, .suffix = "min" };
}

fn iskRateText(layout: *Layout, prefix: []const u8, isk_per_second: ?f32, period: IskPeriod) []const u8 {
    const rate = isk_per_second orelse return layout.print("{s}?? ISK/{s}", .{ prefix, period.suffix });
    var isk_buf: [16]u8 = undefined;
    return layout.print("{s}{s} ISK/{s}", .{ prefix, format.formatIskAbbrev(&isk_buf, rate * period.seconds), period.suffix });
}

fn addResources(layout: *Layout, f: Fonts, config: *const config_mod.Config, stats: *const window_mod.ActivityStats, s: RenderSettings) !void {
    const cfg = &config.resources;
    if (!cfg.enabled or !stats.has_resources) return;
    const font = try f.getScaled(.resources, cfg.font_name, cfg.font_size, cfg.font_weight);

    var texts: [MAX_STACK][]const u8 = undefined;
    var count: usize = 0;
    if (cfg.show_cpu) {
        texts[count] = layout.print("CPU: {d:.0}%", .{stats.cpu_percent});
        count += 1;
    }
    if (cfg.show_ram) {
        texts[count] = layout.print("RAM: {d:.0}MB", .{stats.ram_mb});
        count += 1;
    }
    if (cfg.show_vram and stats.has_vram) {
        texts[count] = layout.print("VRAM: {d:.0}MB", .{stats.vram_mb});
        count += 1;
    }
    if (count > 0) layout.addStack(font, texts[0..count], cfg.position, cfg.offset_x, cfg.offset_y, cfg.color, s.resources_bg_color);
}

/// Not size-cached like the names: the stack changes far more often, so a cache would miss almost every render.
fn layoutNotifications(layout: *Layout, f: Fonts, s: RenderSettings) !?NotificationBlock {
    if (!s.show_notifications or s.notification_line_count == 0) return null;
    const font = try f.get(.notification, s.notifications_font_name, s.notifications_font_size, s.notifications_font_weight);
    var block: NotificationBlock = .{ .font = font, .origin = undefined, .dims = .{ .width = 0, .height = 0 }, .line_heights = undefined };
    for (s.notification_lines[0..s.notification_line_count], 0..) |line, i| {
        const dims = layout.measure(font, line.text);
        block.line_heights[i] = dims.height;
        block.dims.width = @max(block.dims.width, dims.width);
        block.dims.height += dims.height;
    }
    block.origin = layout.position(s.notifications_position, block.dims, s.notifications_offset_x, s.notifications_offset_y);
    return block;
}

/// Per-state override (if any) wins, then opacity is forced fully opaque when the window's own
/// Opacity setting should apply instead, so it isn't compounded with this color's own alpha.
fn resolveTextBgColor(state_cfg: config_mod.StateVisualConfig, base_color: u32, force_opaque: bool) u32 {
    const resolved = state_cfg.textBgColor orelse base_color;
    return if (force_opaque) color_mod.withAlpha(resolved, 255) else resolved;
}

const Border = struct { show: bool, width: u8, color: u32, style: BorderStyle };

/// Colour precedence, lowest first: the Active/Inactive base, the state's own override, the newest notification's type while alerting, then the character's own colours.
fn resolveBorder(cfg: *const config_mod.Config, thumbnail: *const ThumbnailWindow, state: state_mod.ThumbnailState, state_cfg: config_mod.StateVisualConfig, is_focused: bool, hide_all: bool) Border {
    const tc = &cfg.thumbnail;
    // Alert builds on Active, being an attention event.
    const focused_look = state == .Active or state == .Alert;
    // Only the newest notification drives border effects; older entries only add text lines.
    const newest = if (state == .Alert) thumbnail.notifications.newest() else null;

    // A notification hiding or flashing the border is skipped for the focused character, so it can't fight that character's active border.
    const notification_hides = if (newest) |n| !is_focused and (!n.show_border or n.isFlashOff(win32.Ticks.now())) else false;
    const show = !hide_all and !notification_hides and (state_cfg.showBorder orelse (if (focused_look) tc.showBorderWhenFocused else tc.showBorderWhenInactive));

    // With suppress_when_focused, a focused character's alert borders as Active.
    const suppressed = if (newest) |n| n.suppress_when_focused and is_focused else false;
    var color = state_cfg.borderColor orelse (if (focused_look) tc.borderColor else tc.inactiveBorderColor);
    if (newest) |n| {
        if (!suppressed) {
            if (n.border_color_override) |override| color = override;
        }
    }
    if (thumbnail.cached_border_colors) |char_colors| {
        const override = if (state == .Active or (state == .Alert and suppressed))
            char_colors.activeBorderColor
        else if (state == .Inactive or state == .Minimized)
            char_colors.inactiveBorderColor
        else
            null;
        if (override) |c| color = c;
    }

    return .{
        .show = show,
        .width = state_cfg.borderWidth orelse (if (focused_look) tc.borderWidth else tc.inactiveBorderWidth),
        .color = color,
        .style = state_cfg.borderStyle orelse (if (focused_look) tc.borderStyle else tc.inactiveBorderStyle),
    };
}

/// Reads RegionFit's already-sized window back rather than repeating the grid math; otherwise the configured (or per-character) size at the window's DPI.
fn overlaySize(cfg: *const config_mod.Config, thumbnail: *const ThumbnailWindow, dpi_scale: f32) window_mod.Size {
    if (cfg.display.layoutMode == .RegionFit) {
        var client_rect: win32.RECT = undefined;
        if (win32.GetClientRect(thumbnail.hwnd, &client_rect) != 0 and client_rect.right > 0 and client_rect.bottom > 0) {
            return .{ .width = client_rect.right, .height = client_rect.bottom };
        }
    }
    const char_size = thumbnail.cached_thumbnail_size;
    const width = if (char_size) |cs| cs.width orelse cfg.thumbnail.width else cfg.thumbnail.width;
    const height = if (char_size) |cs| cs.height orelse cfg.thumbnail.height else cfg.thumbnail.height;
    return .{ .width = scalePixels(width, dpi_scale), .height = scalePixels(height, dpi_scale) };
}

/// Newest first; each entry keeps its own suppress_when_focused and colour, so types in one stack filter and colour independently.
fn notificationLines(out: *[notification_stack_mod.CAPACITY]NotificationLine, thumbnail: *const ThumbnailWindow, is_focused: bool, base_color: u32) usize {
    var count: usize = 0;
    for (thumbnail.notifications.items()) |notif| {
        if (notif.suppress_when_focused and is_focused) continue;
        out[count] = .{ .text = notif.text, .color = notif.text_color_override orelse base_color };
        count += 1;
    }
    return count;
}

/// The single point where a thumbnail's state and the profile decide everything its overlay shows.
pub fn createRenderSettings(cfg: *const config_mod.Config, thumbnail: *const ThumbnailWindow, active_source_hwnd: ?win32.HWND) RenderSettings {
    const tc = &cfg.thumbnail;
    const state = thumbnail.effectiveRenderState(active_source_hwnd);
    const state_cfg = tc.getStateConfig(state);
    const is_visible = thumbnail.visibility_state.isVisible();
    const is_focused = thumbnail.isFocused(active_source_hwnd);
    // Read live rather than cached, so fonts and size track whichever monitor this window is on right now.
    const dpi_scale = win32.dpiToScale(win32.GetDpiForWindow(thumbnail.hwnd));
    const active_hidden = state == .Active and tc.activeThumbnailHidden;
    // A hidden thumbnail shows no border or text either.
    const hide_all = !is_visible or thumbnail.cached_hide_thumbnail or active_hidden;
    const show_text = !hide_all and tc.showText;
    const opaque_bgs = tc.applyOpacityToOverlayTexts;
    const border = resolveBorder(cfg, thumbnail, state, state_cfg, is_focused, hide_all);
    const size = overlaySize(cfg, thumbnail, dpi_scale);
    const stats = &thumbnail.stats;

    var settings: RenderSettings = .{
        .show_text = show_text,
        .show_character_name = show_text and tc.showCharacterName,
        .display_name = thumbnail.cached_display_name,
        .show_system_name = show_text and tc.showSystemName and thumbnail.system_name.len > 0,
        .system_name = thumbnail.system_name,
        // Unique character colours win over the state's text colour.
        .character_name_color = thumbnail.cached_character_color orelse state_cfg.textColor orelse tc.characterNameColor,
        .system_name_color = thumbnail.cached_system_color,
        .character_name_bg_color = resolveTextBgColor(state_cfg, tc.characterNameBgColor, opaque_bgs),
        .system_name_bg_color = resolveTextBgColor(state_cfg, tc.systemNameBgColor, opaque_bgs),
        .group_badge_bg_color = resolveTextBgColor(state_cfg, tc.quickGroupBadgeBgColor, opaque_bgs),
        .notifications_bg_color = resolveTextBgColor(state_cfg, tc.notifications.bg_color, opaque_bgs),
        .combat_incoming_bg_color = resolveTextBgColor(state_cfg, cfg.combat.incoming_bg_color, opaque_bgs),
        .combat_outgoing_bg_color = resolveTextBgColor(state_cfg, cfg.combat.outgoing_bg_color, opaque_bgs),
        .mining_bg_color = resolveTextBgColor(state_cfg, cfg.mining.bg_color, opaque_bgs),
        .bounty_bg_color = resolveTextBgColor(state_cfg, cfg.bounty.bg_color, opaque_bgs),
        .resources_bg_color = resolveTextBgColor(state_cfg, cfg.resources.bg_color, opaque_bgs),
        .character_name_font_name = tc.characterNameFontName,
        .character_name_font_size = scalePixels(tc.characterNameFontSize, dpi_scale),
        .character_name_font_weight = tc.characterNameFontWeight,
        .character_name_position = tc.characterNamePosition,
        .character_name_offset_x = tc.characterNameOffsetX,
        .character_name_offset_y = tc.characterNameOffsetY,
        .system_name_position = tc.systemNamePosition,
        .system_name_offset_x = tc.systemNameOffsetX,
        .system_name_offset_y = tc.systemNameOffsetY,
        .system_name_font_name = tc.systemNameFontName,
        .system_name_font_size = scalePixels(tc.systemNameFontSize, dpi_scale),
        .system_name_font_weight = tc.systemNameFontWeight,
        .show_notifications = show_text and tc.notifications.enabled,
        .notifications_position = tc.notifications.position,
        .notifications_offset_x = tc.notifications.offset_x,
        .notifications_offset_y = tc.notifications.offset_y,
        .notifications_font_name = tc.notifications.font_name,
        .notifications_font_size = scalePixels(tc.notifications.font_size, dpi_scale),
        .notifications_font_weight = tc.notifications.font_weight,
        .show_border = border.show,
        .border_width = border.width,
        .border_color = border.color,
        .border_style = border.style,
        .show_exclusion_overlay = thumbnail.is_excluded_from_cycle and is_visible,
        .exclusion_overlay_style = tc.exclusionOverlayStyle,
        .exclusion_overlay_color = tc.exclusionOverlayColor,
        .show_group_badge = show_text and tc.showQuickGroupBadge and thumbnail.cached_group_badge_label.len > 0,
        .group_badge_text = thumbnail.cached_group_badge_label,
        .group_badge_color = tc.quickGroupBadgeColor,
        .group_badge_position = tc.quickGroupBadgePosition,
        .group_badge_offset_x = tc.quickGroupBadgeOffsetX,
        .group_badge_offset_y = tc.quickGroupBadgeOffsetY,
        .group_badge_font_name = tc.quickGroupBadgeFontName,
        .group_badge_font_size = scalePixels(tc.quickGroupBadgeFontSize, dpi_scale),
        .group_badge_font_weight = tc.quickGroupBadgeFontWeight,
        // Visibility and the character's own hideThumbnail win over the state's showThumbnail.
        .show_thumbnail = if (!is_visible or thumbnail.cached_hide_thumbnail) false else state_cfg.showThumbnail orelse !active_hidden,
        .overlay_alpha = if (opaque_bgs) thumbnail.cached_opacity else OVERLAY_ALPHA,
        .overlay_width = size.width,
        .overlay_height = size.height,
        .dps_incoming = if (cfg.combat.enabled) (stats.incoming_dps orelse -1.0) else 0.0,
        .dps_outgoing = if (cfg.combat.enabled) (stats.outgoing_dps orelse -1.0) else 0.0,
        .mining_rate = if (cfg.mining.enabled) (stats.mining_rate orelse -1.0) else 0.0,
        .mining_isk_rate = if (cfg.mining.enabled and cfg.mining.show_isk_rate) (stats.mining_isk_rate orelse -1.0) else 0.0,
        .bounty_isk_rate = if (cfg.bounty.enabled) (stats.bounty_isk_rate orelse -1.0) else 0.0,
        .resource_cpu_percent = if (cfg.resources.enabled) stats.cpu_percent else 0.0,
        .resource_ram_mb = if (cfg.resources.enabled) stats.ram_mb else 0.0,
        .resource_vram_mb = if (cfg.resources.enabled) stats.vram_mb else 0.0,
        .has_dps_data = stats.has_dps,
        .has_mining_data = stats.has_mining,
        .has_bounty_data = stats.has_bounty,
        .has_resource_data = cfg.resources.enabled and stats.has_resources,
        .has_vram_data = stats.has_vram,
        .dps_incoming_color = cfg.combat.incoming_color,
        .dps_outgoing_color = cfg.combat.outgoing_color,
        .mining_color = cfg.mining.color,
        .bounty_color = cfg.bounty.color,
        .resources_color = cfg.resources.color,
    };
    if (settings.show_notifications) {
        settings.notification_line_count = notificationLines(&settings.notification_lines, thumbnail, is_focused, state_cfg.textColor orelse tc.characterNameColor);
    }
    return settings;
}
