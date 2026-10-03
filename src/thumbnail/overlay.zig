//! A thumbnail's text overlay: what to draw (RenderSettings, compared to skip redundant redraws) and drawing it into the layered window over the DWM thumbnail.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const config_mod = @import("../config.zig");
const types = @import("../config/types.zig");
const color_mod = @import("../util/color.zig");
const format = @import("../util/format.zig");
const stack = @import("../notifications/stack.zig");
const state_mod = @import("state.zig");
const draw = @import("draw.zig");
const font_cache_mod = @import("font_cache.zig");
const window = @import("window.zig");
const log = @import("../log.zig");

const ThumbnailWindow = window.ThumbnailWindow;
const TextPosition = types.TextPosition;
const BorderStyle = types.BorderStyle;
const TextDimensions = draw.TextDimensions;
const TextOrigin = draw.TextOrigin;
const FontCache = font_cache_mod.FontCache;
const scalePixels = win32.scalePixels;
const slog = log.scoped("overlay");

const OVERLAY_ALPHA = 255;
/// Custom text can split a notification over lines (see notifications/template.zig).
const MAX_LINES_PER_NOTIFICATION = 3;
const MAX_NOTIFICATION_LINES = stack.CAPACITY * MAX_LINES_PER_NOTIFICATION;

/// Character name, system, group badge, DPS in and out, mining (and its ISK line), bounty, and up to three resource lines.
const MAX_LINES = 1 + 1 + 1 + 2 + 2 + 1 + 3;
const MAX_STACK = 3;
const TEXT_BUF = 32;

/// One resolved (text, color) line of the stacked notification block; built by createRenderSettings, drawn by renderThumbnailOverlay.
pub const NotificationLine = struct {
    text: []const u8 = "",
    color: u32 = 0xFFFFFF,
};

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
    notification_lines: [MAX_NOTIFICATION_LINES]NotificationLine = .{NotificationLine{}} ** MAX_NOTIFICATION_LINES,
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

/// A text run's size and the font it was measured in, keyed by font only, so whoever changes the text clears `dims`; `font_name` borrows config's buffer.
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

/// One text run: render_pos places its glyphs, bg_pos/bg_dims its background, which differ in a stacked block (shared width, per-line alignment).
const DrawLine = struct {
    font: win32.HFONT,
    /// Borrowed for one render pass.
    text: []const u8,
    render_pos: TextOrigin,
    bg_pos: TextOrigin,
    bg_dims: TextDimensions,
    color: u32,
    bg_color: u32,
};

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
    line_heights: [MAX_NOTIFICATION_LINES]usize,
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

const IskPeriod = struct { seconds: f32, suffix: []const u8 };

const Border = struct { show: bool, width: u8, color: u32, style: BorderStyle };

pub fn renderSettingsEqual(a: RenderSettings, b: RenderSettings) bool {
    return a.show_thumbnail == b.show_thumbnail and visualEqual(a, b);
}

pub fn renderSettingsOnlyVisibilityChanged(a: RenderSettings, b: RenderSettings) bool {
    return a.show_thumbnail != b.show_thumbnail and visualEqual(a, b);
}

pub fn renderThumbnailOverlay(font_cache: *FontCache, thumbnail: *ThumbnailWindow, settings: RenderSettings, config: *const config_mod.Config) !void {
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
    const fonts: Fonts = .{ .cache = font_cache, .dpi = dpi, .scale = win32.dpiToScale(dpi) };
    var layout: Layout = .{ .dc = overlay.mem_dc, .width = overlay.width, .height = overlay.height };
    defer layout.restoreFont();

    // Added in painting order: a later background covers an earlier overlapping one.
    try addCharacterName(&layout, fonts, cache, settings);
    try addSystemName(&layout, fonts, cache, settings);
    try addGroupBadge(&layout, fonts, cache, settings);
    if (settings.show_text) {
        const stats = &thumbnail.stats;
        try addCombat(&layout, fonts, config, stats, settings);
        try addMining(&layout, fonts, config, stats, settings);
        try addBounty(&layout, fonts, config, stats, settings);
        try addResources(&layout, fonts, config, stats, settings);
    }
    const notifications = try layoutNotifications(&layout, fonts, settings);

    const lines = layout.lines[0..layout.count];
    // Before the border, so it paints over them.
    for (lines) |line| {
        draw.fillTextBackground(overlay.pixels, overlay.width, overlay.height, line.bg_pos.x, line.bg_pos.y, line.bg_dims.width, line.bg_dims.height, line.bg_color);
    }
    if (notifications) |block| {
        draw.fillTextBackground(overlay.pixels, overlay.width, overlay.height, block.origin.x, block.origin.y, block.dims.width, block.dims.height, settings.notifications_bg_color);
    }

    if (settings.show_border) {
        draw.drawBorder(overlay.pixels, overlay.width, overlay.height, @intCast(settings.border_width), settings.border_color, settings.border_style);
    }

    for (lines) |line| {
        layout.select(line.font);
        draw.renderText(overlay.mem_dc, line.text, line.render_pos.x, line.render_pos.y, line.color);
    }
    if (notifications) |block| {
        layout.select(block.font);
        var y = block.origin.y;
        for (settings.notification_lines[0..settings.notification_line_count], block.line_heights[0..settings.notification_line_count]) |line, line_height| {
            draw.renderText(overlay.mem_dc, line.text, block.origin.x, y, line.color);
            y += @as(i32, @intCast(line_height));
        }
    }

    // Bounded to where text was drawn instead of scanning the whole overlay.
    for (lines) |line| {
        gdi_overlay.fixTextAlphaRect(overlay.pixels, overlay.width, overlay.height, line.bg_pos.x, line.bg_pos.y, line.bg_dims.width, line.bg_dims.height);
    }
    if (notifications) |block| {
        gdi_overlay.fixTextAlphaRect(overlay.pixels, overlay.width, overlay.height, block.origin.x, block.origin.y, block.dims.width, block.dims.height);
    }

    gdi_overlay.presentLayered(thumbnail.text_hwnd, overlay, settings.overlay_alpha);
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
    const active_hidden = state == .active and tc.activeThumbnailHidden;
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

fn addCharacterName(layout: *Layout, fonts: Fonts, cache: *RenderCache, settings: RenderSettings) !void {
    if (!settings.show_character_name) return;
    const font = try fonts.get(.main, settings.character_name_font_name, settings.character_name_font_size, settings.character_name_font_weight);
    const dims = cache.character_name.measure(layout, font, settings.display_name, settings.character_name_font_name, settings.character_name_font_size, settings.character_name_font_weight);
    layout.addAt(font, settings.display_name, dims, settings.character_name_position, settings.character_name_offset_x, settings.character_name_offset_y, settings.character_name_color, settings.character_name_bg_color);
}

fn addSystemName(layout: *Layout, fonts: Fonts, cache: *RenderCache, settings: RenderSettings) !void {
    if (!settings.show_system_name) return;
    const font = try fonts.get(.system_name, settings.system_name_font_name, settings.system_name_font_size, settings.system_name_font_weight);
    const dims = cache.system_name.measure(layout, font, settings.system_name, settings.system_name_font_name, settings.system_name_font_size, settings.system_name_font_weight);
    layout.addAt(font, settings.system_name, dims, settings.system_name_position, settings.system_name_offset_x, settings.system_name_offset_y, settings.system_name_color, settings.system_name_bg_color);
}

fn addGroupBadge(layout: *Layout, fonts: Fonts, cache: *RenderCache, settings: RenderSettings) !void {
    if (!settings.show_group_badge) return;
    const font = try fonts.get(.group_badge, settings.group_badge_font_name, settings.group_badge_font_size, settings.group_badge_font_weight);
    const dims = cache.group_badge.measure(layout, font, settings.group_badge_text, settings.group_badge_font_name, settings.group_badge_font_size, settings.group_badge_font_weight);
    layout.addAt(font, settings.group_badge_text, dims, settings.group_badge_position, settings.group_badge_offset_x, settings.group_badge_offset_y, settings.group_badge_color, settings.group_badge_bg_color);
}

fn addCombat(layout: *Layout, fonts: Fonts, config: *const config_mod.Config, stats: *const window.ActivityStats, settings: RenderSettings) !void {
    const cfg = &config.combat;
    if (!cfg.enabled) return;
    if (cfg.show_incoming and stats.showsIncoming()) {
        const font = try fonts.getScaled(.combat, cfg.incoming_font_name, cfg.incoming_font_size, cfg.incoming_font_weight);
        const text = rateText(layout, if (cfg.incoming_show_prefix) "IN: " else "", stats.incoming_dps);
        layout.addAt(font, text, layout.measure(font, text), cfg.incoming_position, cfg.incoming_offset_x, cfg.incoming_offset_y, cfg.incoming_color, settings.combat_incoming_bg_color);
    }
    if (cfg.show_outgoing and stats.showsOutgoing()) {
        const font = try fonts.getScaled(.combat_outgoing, cfg.outgoing_font_name, cfg.outgoing_font_size, cfg.outgoing_font_weight);
        const text = rateText(layout, if (cfg.outgoing_show_prefix) "OUT: " else "", stats.outgoing_dps);
        layout.addAt(font, text, layout.measure(font, text), cfg.outgoing_position, cfg.outgoing_offset_x, cfg.outgoing_offset_y, cfg.outgoing_color, settings.combat_outgoing_bg_color);
    }
}

fn rateText(layout: *Layout, prefix: []const u8, rate: ?f32) []const u8 {
    if (rate) |value| return layout.print("{s}{d:.0}", .{ prefix, value });
    return layout.print("{s}??", .{prefix});
}

fn addMining(layout: *Layout, fonts: Fonts, config: *const config_mod.Config, stats: *const window.ActivityStats, settings: RenderSettings) !void {
    const cfg = &config.mining;
    if (!cfg.enabled or !stats.showsMining()) return;
    const font = try fonts.getScaled(.mining, cfg.font_name, cfg.font_size, cfg.font_weight);
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
    layout.addStack(font, texts[0..count], cfg.position, cfg.offset_x, cfg.offset_y, cfg.color, settings.mining_bg_color);
}

fn addBounty(layout: *Layout, fonts: Fonts, config: *const config_mod.Config, stats: *const window.ActivityStats, settings: RenderSettings) !void {
    const cfg = &config.bounty;
    if (!cfg.enabled or !stats.showsBounty()) return;
    const font = try fonts.getScaled(.bounty, cfg.font_name, cfg.font_size, cfg.font_weight);
    const text = iskRateText(layout, if (cfg.show_prefix) "ISK: " else "", stats.bounty_isk_rate, iskPeriod(cfg.isk_rate_unit));
    layout.addAt(font, text, layout.measure(font, text), cfg.position, cfg.offset_x, cfg.offset_y, cfg.color, settings.bounty_bg_color);
}

fn iskPeriod(unit: anytype) IskPeriod {
    return if (unit == .hour) .{ .seconds = 3600.0, .suffix = "hr" } else .{ .seconds = 60.0, .suffix = "min" };
}

fn iskRateText(layout: *Layout, prefix: []const u8, isk_per_second: ?f32, period: IskPeriod) []const u8 {
    const rate = isk_per_second orelse return layout.print("{s}?? ISK/{s}", .{ prefix, period.suffix });
    var isk_buf: [16]u8 = undefined;
    return layout.print("{s}{s} ISK/{s}", .{ prefix, format.formatIskAbbrev(&isk_buf, rate * period.seconds), period.suffix });
}

fn addResources(layout: *Layout, fonts: Fonts, config: *const config_mod.Config, stats: *const window.ActivityStats, settings: RenderSettings) !void {
    const cfg = &config.resources;
    if (!cfg.enabled or !stats.has_resources) return;
    const font = try fonts.getScaled(.resources, cfg.font_name, cfg.font_size, cfg.font_weight);

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
    if (count > 0) layout.addStack(font, texts[0..count], cfg.position, cfg.offset_x, cfg.offset_y, cfg.color, settings.resources_bg_color);
}

/// Not size-cached like the names: the stack changes far more often, so a cache would miss almost every render.
fn layoutNotifications(layout: *Layout, fonts: Fonts, settings: RenderSettings) !?NotificationBlock {
    if (!settings.show_notifications or settings.notification_line_count == 0) return null;
    const font = try fonts.get(.notification, settings.notifications_font_name, settings.notifications_font_size, settings.notifications_font_weight);
    var block: NotificationBlock = .{ .font = font, .origin = undefined, .dims = .{ .width = 0, .height = 0 }, .line_heights = undefined };
    for (settings.notification_lines[0..settings.notification_line_count], 0..) |line, i| {
        const dims = layout.measure(font, line.text);
        block.line_heights[i] = dims.height;
        block.dims.width = @max(block.dims.width, dims.width);
        block.dims.height += dims.height;
    }
    block.origin = layout.position(settings.notifications_position, block.dims, settings.notifications_offset_x, settings.notifications_offset_y);
    return block;
}

/// The state's override wins; forced opaque when the window's Opacity applies instead, so the two alphas don't compound.
fn resolveTextBgColor(state_cfg: config_mod.StateVisualConfig, base_color: u32, force_opaque: bool) u32 {
    const resolved = state_cfg.textBgColor orelse base_color;
    return if (force_opaque) color_mod.withAlpha(resolved, 255) else resolved;
}

/// Colour precedence, lowest first: the Active/Inactive base, the state's own override, the newest notification's type while alerting, then the character's own colours.
fn resolveBorder(cfg: *const config_mod.Config, thumbnail: *const ThumbnailWindow, state: state_mod.ThumbnailState, state_cfg: config_mod.StateVisualConfig, is_focused: bool, hide_all: bool) Border {
    const tc = &cfg.thumbnail;
    // Alert builds on Active, being an attention event.
    const focused_look = state == .active or state == .alert;
    // Only the newest notification drives border effects; older entries only add text lines.
    const newest = if (state == .alert) thumbnail.notifications.newest() else null;

    // A notification hiding or flashing the border is skipped for the focused character, so it can't fight that character's active border.
    const notification_hides = if (newest) |notification| !is_focused and (!notification.show_border or notification.isFlashOff(win32.Ticks.now())) else false;
    const show = !hide_all and !notification_hides and (state_cfg.showBorder orelse (if (focused_look) tc.showBorderWhenFocused else tc.showBorderWhenInactive));

    // With suppress_when_focused, a focused character's alert borders as Active.
    const suppressed = if (newest) |notification| notification.suppress_when_focused and is_focused else false;
    var color = state_cfg.borderColor orelse (if (focused_look) tc.borderColor else tc.inactiveBorderColor);
    if (newest) |notification| {
        if (!suppressed) {
            if (notification.border_color_override) |override| color = override;
        }
    }
    if (thumbnail.cached_border_colors) |char_colors| {
        const override = if (state == .active or (state == .alert and suppressed))
            char_colors.activeBorderColor
        else if (state == .inactive or state == .minimized)
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
fn overlaySize(cfg: *const config_mod.Config, thumbnail: *const ThumbnailWindow, dpi_scale: f32) window.Size {
    if (cfg.display.layoutMode == .RegionFit) {
        var client_rect: win32.RECT = undefined;
        if (win32.toBool(win32.GetClientRect(thumbnail.hwnd, &client_rect)) and client_rect.right > 0 and client_rect.bottom > 0) {
            return .{ .width = client_rect.right, .height = client_rect.bottom };
        }
    }
    const char_size = thumbnail.cached_thumbnail_size;
    const width = if (char_size) |cs| cs.width orelse cfg.thumbnail.width else cfg.thumbnail.width;
    const height = if (char_size) |cs| cs.height orelse cfg.thumbnail.height else cfg.thumbnail.height;
    return .{ .width = scalePixels(width, dpi_scale), .height = scalePixels(height, dpi_scale) };
}

/// Newest first; each entry keeps its own suppress_when_focused and colour, so types in one stack filter and colour independently.
fn notificationLines(out: *[MAX_NOTIFICATION_LINES]NotificationLine, thumbnail: *const ThumbnailWindow, is_focused: bool, base_color: u32) usize {
    var count: usize = 0;
    for (thumbnail.notifications.items()) |entry| {
        if (entry.suppress_when_focused and is_focused) continue;
        const color = entry.text_color_override orelse base_color;
        var lines = std.mem.splitScalar(u8, entry.text, '\n');
        var line_index: usize = 0;
        while (lines.next()) |line| : (line_index += 1) {
            if (line_index == MAX_LINES_PER_NOTIFICATION) break;
            out[count] = .{ .text = line, .color = color };
            count += 1;
        }
    }
    return count;
}
