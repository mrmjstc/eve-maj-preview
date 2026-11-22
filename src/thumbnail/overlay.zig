//! A thumbnail's text overlay: gathering what look.zig decides from, and drawing its RenderSettings into the layered window over the DWM thumbnail.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const config_mod = @import("../config.zig");
const types = @import("../config/types.zig");
const format = @import("../util/format.zig");
const draw = @import("draw.zig");
const font_cache_mod = @import("font_cache.zig");
const window = @import("window.zig");
const look = @import("look.zig");
const stats_mod = @import("../activity/stats.zig");
const stat_text = @import("../activity/stat_text.zig");
const roster = @import("../clients/roster.zig");
const spaces = @import("../layout/spaces.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");
const universe = @import("../map/universe.zig");
const layout_mod = @import("../map/layout.zig");
const connections_mod = @import("../map/connections.zig");
const security = @import("../map/security.zig");
const markers = @import("../map/markers.zig");
const recorder = @import("../diagnostics/recorder.zig");
const log = @import("../log.zig");

const ThumbnailWindow = window.ThumbnailWindow;
const ActivityStats = stats_mod.ActivityStats;
const RenderSettings = look.RenderSettings;
const TextStyle = look.TextStyle;
const TextPosition = types.TextPosition;
const TextDimensions = draw.TextDimensions;
const TextOrigin = draw.TextOrigin;
const FontCache = font_cache_mod.FontCache;
const scalePixels = win32.scalePixels;
const slog = log.Scoped("overlay");

/// Character name, system, group badge, session timer, DPS in and out, mining (and its ISK line), bounty, up to three resource lines, and ping.
const MAX_LINES = 1 + 1 + 1 + 1 + 2 + 2 + 1 + 3 + 1;
const MAX_STACK_LINES = 3;
const TEXT_BUFFER_SIZE = 32;
/// Fits a system name; a longer text is kept cut short.
const DRAWN_TEXT_SIZE = 64;
/// Of the Map Panel's halo, so a new pin doesn't cover a map this small.
const CONNECTION_HALO_SCALE: f32 = 0.5;

/// Keyed by font only, so whoever changes the text clears `dimensions`.
const MeasuredText = struct {
    dimensions: ?TextDimensions = null,
    /// Borrows from config.
    font_name: []const u8 = "",
    font_size: i32 = 0,
    font_weight: types.FontWeight = .Regular,

    fn measure(self: *MeasuredText, layout: *Layout, font: win32.HFONT, text: []const u8, text_style: TextStyle) TextDimensions {
        if (self.dimensions) |cached| {
            if (look.stringsEqualFast(self.font_name, text_style.font_name) and self.font_size == text_style.font_size and self.font_weight == text_style.font_weight) return cached;
        }
        const measured = layout.measure(font, text);
        self.* = .{ .dimensions = measured, .font_name = text_style.font_name, .font_size = text_style.font_size, .font_weight = text_style.font_weight };
        return measured;
    }
};

/// Which of the overlay's texts a line is.
pub const Element = enum {
    character_name,
    system_name,
    group_badge,
    session_timer,
    incoming_dps,
    outgoing_dps,
    mining,
    bounty,
    resources,
    ping,
};

/// In overlay pixels, from its top-left.
pub const DrawnBox = struct {
    left: i32,
    top: i32,
    width: usize,
    height: usize,
};

/// A text the last render drew, with the box its background filled.
pub const DrawnText = struct {
    element: Element,
    text_buffer: [DRAWN_TEXT_SIZE]u8 = undefined,
    text_length: u8 = 0,
    box: DrawnBox,
    color: u32,
    bg_color: u32,

    pub fn text(self: *const DrawnText) []const u8 {
        return self.text_buffer[0..self.text_length];
    }
};

/// What a render drew, for diagnostics/state_file.zig.
pub const Drawn = struct {
    texts: [MAX_LINES]DrawnText = undefined,
    text_count: usize = 0,
    /// The alert block's background; null while no alert text shows.
    notifications: ?DrawnBox = null,
    notifications_bg_color: u32 = 0,
    /// The newest alert line's colour; 0 while no alert text shows.
    notification_color: u32 = 0,
    /// Null while the plain system name shows instead.
    connection_map: ?DrawnBox = null,

    pub fn drawnTexts(self: *const Drawn) []const DrawnText {
        return self.texts[0..self.text_count];
    }
};

/// Where a text sits on the overlay, and in what colours.
const Placement = struct {
    element: Element,
    anchor: TextPosition,
    offset_x: i32,
    offset_y: i32,
    color: u32,
    bg_color: u32,
};

pub const RenderCache = struct {
    /// Recreated only on resize.
    bitmap: ?gdi_overlay.OverlayBitmap = null,
    /// Skips redundant redraws; borrows the thumbnail's strings, so whatever frees one must null this.
    settings: ?RenderSettings = null,
    character_name: MeasuredText = .{},
    system_name: MeasuredText = .{},
    group_badge: MeasuredText = .{},

    /// Also drops font-name slices borrowed from config, which a preview edit may have freed.
    pub fn invalidate(self: *RenderCache) void {
        self.settings = null;
        self.character_name = .{};
        self.system_name = .{};
        self.group_badge = .{};
    }

    pub fn deinit(self: *const RenderCache) void {
        if (self.bitmap) |bitmap| bitmap.deinit();
    }
};

/// render_origin places the glyphs; in a stacked block the background differs from it.
const DrawLine = struct {
    element: Element,
    font: win32.HFONT,
    /// Borrowed for one render pass.
    text: []const u8,
    render_origin: TextOrigin,
    background_origin: TextOrigin,
    background_dimensions: TextDimensions,
    color: u32,
    bg_color: u32,
};

/// The single-rect text runs one render lays out, before any of them is drawn.
const Layout = struct {
    dc: win32.HDC,
    width: usize,
    height: usize,
    lines: [MAX_LINES]DrawLine = undefined,
    line_count: usize = 0,
    /// The lines' formatted text lives here, so a Layout is never copied once built.
    text_buffers: [MAX_LINES][TEXT_BUFFER_SIZE]u8 = undefined,
    used_text_count: usize = 0,
    /// The DC's own font, put back once rendering is done.
    original_font: ?win32.HANDLE = null,

    fn select(self: *Layout, font: win32.HFONT) void {
        const previous = win32.SelectObject(self.dc, font);
        if (self.original_font == null) self.original_font = previous;
    }

    fn restoreFont(self: *const Layout) void {
        if (self.original_font) |font| _ = win32.SelectObject(self.dc, font);
    }

    fn measure(self: *Layout, font: win32.HFONT, text: []const u8) TextDimensions {
        self.select(font);
        return draw.measureText(self.dc, text);
    }

    /// Without measureText's padding, for text sharing a line.
    fn measureRun(self: *Layout, font: win32.HFONT, text: []const u8) TextDimensions {
        const padded = self.measure(font, text);
        return .{ .width = padded.width - draw.TEXT_PADDING_X * 2, .height = padded.height - draw.TEXT_PADDING_Y * 2 };
    }

    /// Short stat text only, so it can't outgrow its buffer in practice; "---" if it somehow does.
    fn print(self: *Layout, comptime text_format: []const u8, args: anytype) []const u8 {
        return std.mem.print(self.nextTextBuffer(), text_format, args) catch "---";
    }

    fn nextTextBuffer(self: *Layout) *[TEXT_BUFFER_SIZE]u8 {
        defer self.used_text_count += 1;
        return &self.text_buffers[self.used_text_count];
    }

    fn position(self: *const Layout, anchor: TextPosition, dimensions: TextDimensions, offset_x: i32, offset_y: i32) TextOrigin {
        return draw.calculateTextPosition(anchor, dimensions, .{ .width = self.width, .height = self.height }, offset_x, offset_y);
    }

    fn add(self: *Layout, line: DrawLine) void {
        self.lines[self.line_count] = line;
        self.line_count += 1;
    }

    fn addAt(self: *Layout, font: win32.HFONT, text: []const u8, dimensions: TextDimensions, placement: Placement) void {
        const origin = self.position(placement.anchor, dimensions, placement.offset_x, placement.offset_y);
        self.add(.{ .element = placement.element, .font = font, .text = text, .render_origin = origin, .background_origin = origin, .background_dimensions = dimensions, .color = placement.color, .bg_color = placement.bg_color });
    }

    /// One block anchored at `placement.anchor`, so Bottom and Center positions count every line.
    fn addStack(self: *Layout, font: win32.HFONT, texts: []const []const u8, placement: Placement) void {
        var dimensions: [MAX_STACK_LINES]TextDimensions = undefined;
        var block: TextDimensions = .{ .width = 0, .height = 0 };
        for (texts, 0..) |text, i| {
            dimensions[i] = self.measure(font, text);
            block.width = @max(block.width, dimensions[i].width);
            block.height += dimensions[i].height;
        }
        const origin = self.position(placement.anchor, block, placement.offset_x, placement.offset_y);
        const horizontal_align = draw.horizontalAlignOf(placement.anchor);
        var y = origin.y;
        for (texts, dimensions[0..texts.len]) |text, line_dimensions| {
            self.add(.{
                .element = placement.element,
                .font = font,
                .text = text,
                .render_origin = .{ .x = draw.alignedLineX(origin.x, block.width, line_dimensions.width, horizontal_align), .y = y },
                .background_origin = .{ .x = origin.x, .y = y },
                .background_dimensions = .{ .width = block.width, .height = line_dimensions.height },
                .color = placement.color,
                .bg_color = placement.bg_color,
            });
            y += @as(i32, @intCast(line_dimensions.height));
        }
    }
};

/// Lines in their own colours under one background, drawn last so nothing covers them.
const NotificationBlock = struct {
    font: win32.HFONT,
    origin: TextOrigin,
    dimensions: TextDimensions,
    line_heights: [look.MAX_NOTIFICATION_LINES]usize,
};

/// For the window's own DPI; scales the stat fonts, whose config isn't in RenderSettings.
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

/// Keyed by the overlay's window.
pub const DrawnRecorder = recorder.Recorder(Drawn);

/// Set only while the state file is on; main thread only.
var g_recorder: ?*DrawnRecorder = null;

/// Null stops recording; `drawn_recorder` must outlive the setting.
pub fn setRecorder(drawn_recorder: ?*DrawnRecorder) void {
    g_recorder = drawn_recorder;
}

pub fn renderThumbnailOverlay(font_cache: *FontCache, thumbnail: *ThumbnailWindow, settings: RenderSettings, config: *const config_mod.Config) !void {
    try renderOverlay(font_cache, &thumbnail.render_cache, thumbnail.text_hwnd, thumbnail, settings, config);
}

/// `cache` must belong to `target_hwnd`, since it holds that window's bitmap.
pub fn renderOverlay(font_cache: *FontCache, cache: *RenderCache, target_hwnd: win32.HWND, thumbnail: *const ThumbnailWindow, settings: RenderSettings, config: *const config_mod.Config) !void {
    // Only the first: a live size edit resizes every thumbnail each frame.
    const is_first = cache.bitmap == null;
    const overlay = try gdi_overlay.OverlayBitmap.ensureSize(&cache.bitmap, settings.overlay_width, settings.overlay_height);
    if (is_first) slog.debug("Allocated overlay bitmap {}x{} for {s}", .{ settings.overlay_width, settings.overlay_height, thumbnail.character_name });
    overlay.clear();

    if (settings.show_exclusion_overlay) {
        draw.drawExclusionOverlay(overlay.canvas(), settings.exclusion_overlay_color, settings.exclusion_overlay_style);
    }

    const dpi: u32 = win32.GetDpiForWindow(thumbnail.hwnd);
    const fonts: Fonts = .{ .cache = font_cache, .dpi = dpi, .scale = win32.dpiToScale(dpi) };
    var layout: Layout = .{ .dc = overlay.mem_dc, .width = overlay.width, .height = overlay.height };
    defer layout.restoreFont();

    // Added in painting order: a later background covers an earlier overlapping one.
    try addCharacterName(&layout, fonts, cache, settings);
    try addSystemName(&layout, fonts, cache, settings);
    try addGroupBadge(&layout, fonts, cache, settings);
    try addSessionTimer(&layout, fonts, settings);
    if (settings.show_text) {
        const stats = &settings.stats;
        try addCombat(&layout, fonts, config, stats, settings);
        try addMining(&layout, fonts, config, stats, settings);
        try addBounty(&layout, fonts, config, stats, settings);
        try addResources(&layout, fonts, config, stats, settings);
        try addPing(&layout, fonts, config, stats, settings);
    }
    var connection_map: layout_mod.Layout = .{};
    const connection_font = try layoutConnectionMap(&connection_map, &layout, fonts, settings);
    const notifications = try layoutNotifications(&layout, fonts, settings);

    const lines = layout.lines[0..layout.line_count];
    // Before the border, so it paints over them.
    for (lines) |line| {
        draw.fillTextBackground(overlay.canvas(), line.background_origin.x, line.background_origin.y, line.background_dimensions.width, line.background_dimensions.height, line.bg_color);
    }
    if (connection_font != null) drawConnectionMap(overlay.canvas(), &connection_map, settings);
    if (notifications) |block| {
        draw.fillTextBackground(overlay.canvas(), block.origin.x, block.origin.y, block.dimensions.width, block.dimensions.height, settings.notifications_bg_color);
    }

    if (settings.show_border) {
        draw.drawBorder(overlay.canvas(), @intCast(settings.border_width), settings.border_color, settings.border_style);
    }

    for (lines) |line| {
        layout.select(line.font);
        draw.renderText(overlay.mem_dc, line.text, line.render_origin.x, line.render_origin.y, line.color);
    }
    if (connection_font) |font| {
        layout.select(font);
        renderConnectionLabels(overlay.mem_dc, &connection_map, settings);
    }
    if (notifications) |block| {
        layout.select(block.font);
        var y = block.origin.y;
        for (settings.notification_lines[0..settings.notification_line_count], block.line_heights[0..settings.notification_line_count]) |line, line_height| {
            if (line.lead_length > 0) {
                draw.renderTextWithLead(overlay.mem_dc, line.text, line.lead_length, line.lead_color, block.origin.x, y, line.color);
            } else {
                draw.renderText(overlay.mem_dc, line.text, block.origin.x, y, line.color);
            }
            y += @as(i32, @intCast(line_height));
        }
    }

    // Bounded to where text was drawn instead of scanning the whole overlay.
    for (lines) |line| {
        pixel_buffer.fixTextAlphaRect(overlay.canvas(), line.background_origin.x, line.background_origin.y, line.background_dimensions.width, line.background_dimensions.height);
    }
    if (connection_font != null) {
        const area = connection_map.area;
        pixel_buffer.fixTextAlphaRect(overlay.canvas(), area.left, area.top, @intCast(area.right - area.left), @intCast(area.bottom - area.top));
    }
    if (notifications) |block| {
        pixel_buffer.fixTextAlphaRect(overlay.canvas(), block.origin.x, block.origin.y, block.dimensions.width, block.dimensions.height);
    }

    if (g_recorder) |drawn_recorder| {
        if (drawn_recorder.begin(@intFromPtr(target_hwnd))) |drawn| drawn.* = recordDrawn(lines, notifications, settings, if (connection_font != null) connection_map.area else null);
    }
    gdi_overlay.presentLayered(target_hwnd, overlay, settings.overlay_alpha);
}

/// Reads what only Win32 can tell (DPI, client size, minimized, the clock), and look.renderSettings decides the rest from the client's `readings`.
pub fn createRenderSettings(config: *const config_mod.Config, thumbnail: *const ThumbnailWindow, readings: roster.Readings, is_excluded_from_cycle: bool, active_source_hwnd: ?win32.HWND) RenderSettings {
    // Read live, so fonts and size track the monitor this window is on now.
    const dpi_scale = win32.dpiToScale(win32.GetDpiForWindow(thumbnail.hwnd));
    const size = overlaySize(config, thumbnail, dpi_scale);
    const now = win32.Ticks.now();
    return look.renderSettings(config, &.{
        .state = thumbnail.effectiveRenderState(active_source_hwnd, readings.alerts),
        .is_shown = thumbnail.isShown(readings.alerts),
        .is_focused = thumbnail.isFocused(active_source_hwnd),
        .is_excluded_from_cycle = is_excluded_from_cycle,
        .is_hidden_for_character = thumbnail.cached_is_thumbnail_hidden,
        .display_name = thumbnail.cached_display_name,
        .system_name = thumbnail.system_name,
        .group_badge_label = thumbnail.cached_group_badge_label,
        .connections = &thumbnail.connections,
        .character_color = thumbnail.cached_character_color,
        .system_color = thumbnail.cached_system_color,
        .border_colors = thumbnail.cached_border_colors,
        .opacity = thumbnail.cached_opacity,
        .session_minutes = readings.sessionMinutes(now),
        .stats = readings.stats,
        .notifications = readings.alerts,
        .overlay_width = size.width,
        .overlay_height = size.height,
        .dpi_scale = dpi_scale,
        .now = now,
    });
}

fn recordDrawn(lines: []const DrawLine, notifications: ?NotificationBlock, settings: RenderSettings, connection_area: ?layout_mod.Box) Drawn {
    var drawn: Drawn = .{ .text_count = lines.len };
    for (lines, drawn.texts[0..lines.len]) |line, *entry| {
        const length = @min(line.text.len, DRAWN_TEXT_SIZE);
        entry.* = .{
            .element = line.element,
            .text_length = @intCast(length),
            .box = .{ .left = line.background_origin.x, .top = line.background_origin.y, .width = line.background_dimensions.width, .height = line.background_dimensions.height },
            .color = line.color,
            .bg_color = line.bg_color,
        };
        @memcpy(entry.text_buffer[0..length], line.text[0..length]);
    }
    if (notifications) |block| {
        drawn.notifications = .{ .left = block.origin.x, .top = block.origin.y, .width = block.dimensions.width, .height = block.dimensions.height };
        drawn.notifications_bg_color = settings.notifications_bg_color;
        drawn.notification_color = settings.notification_lines[0].color;
    }
    if (connection_area) |area| drawn.connection_map = .{ .left = area.left, .top = area.top, .width = @intCast(area.right - area.left), .height = @intCast(area.bottom - area.top) };
    return drawn;
}

fn addCharacterName(layout: *Layout, fonts: Fonts, cache: *RenderCache, settings: RenderSettings) !void {
    if (!settings.show_character_name) return;
    try addStyledText(layout, fonts, .main, .character_name, settings.display_name, settings.character_name_style, &cache.character_name);
}

fn addSystemName(layout: *Layout, fonts: Fonts, cache: *RenderCache, settings: RenderSettings) !void {
    if (!settings.show_system_name or settings.connections.count > 0) return;
    try addStyledText(layout, fonts, .system_name, .system_name, settings.system_name, settings.system_name_style, &cache.system_name);
}

fn addGroupBadge(layout: *Layout, fonts: Fonts, cache: *RenderCache, settings: RenderSettings) !void {
    if (!settings.show_group_badge) return;
    try addStyledText(layout, fonts, .group_badge, .group_badge, settings.group_badge_text, settings.group_badge_style, &cache.group_badge);
}

fn addSessionTimer(layout: *Layout, fonts: Fonts, settings: RenderSettings) !void {
    if (!settings.show_session_timer) return;
    try addStyledText(layout, fonts, .session_timer, .session_timer, format.formatSessionDuration(layout.nextTextBuffer(), settings.session_minutes), settings.session_timer_style, null);
}

/// Measured through `cache` when given, for a text that rarely changes.
fn addStyledText(layout: *Layout, fonts: Fonts, slot: font_cache_mod.FontSlot, element: Element, text: []const u8, text_style: TextStyle, cache: ?*MeasuredText) !void {
    const font = try fonts.get(slot, text_style.font_name, text_style.font_size, text_style.font_weight);
    const dimensions = if (cache) |measured| measured.measure(layout, font, text, text_style) else layout.measure(font, text);
    layout.addAt(font, text, dimensions, .{ .element = element, .anchor = text_style.position, .offset_x = text_style.offset_x, .offset_y = text_style.offset_y, .color = text_style.color, .bg_color = text_style.bg_color });
}

fn addCombat(layout: *Layout, fonts: Fonts, config: *const config_mod.Config, stats: *const ActivityStats, settings: RenderSettings) !void {
    const combat = &config.thumbnail.combatText;
    if (!combat.shown) return;
    const incoming = if (combat.show_incoming) stats.shownIncoming() else null;
    if (incoming) |rate| {
        const font = try fonts.getScaled(.combat, combat.incoming_font_name, combat.incoming_font_size, combat.incoming_font_weight);
        const text = statText(layout, .{ .kind = .incoming_dps, .value = rate, .has_prefix = combat.incoming_show_prefix });
        layout.addAt(font, text, layout.measure(font, text), .{ .element = .incoming_dps, .anchor = combat.incoming_position, .offset_x = combat.incoming_offset_x, .offset_y = combat.incoming_offset_y, .color = combat.incoming_color, .bg_color = settings.combat_incoming_bg_color });
    }
    const outgoing = if (combat.show_outgoing) stats.shownOutgoing() else null;
    if (outgoing) |rate| {
        const font = try fonts.getScaled(.combat_outgoing, combat.outgoing_font_name, combat.outgoing_font_size, combat.outgoing_font_weight);
        const text = statText(layout, .{ .kind = .outgoing_dps, .value = rate, .has_prefix = combat.outgoing_show_prefix });
        layout.addAt(font, text, layout.measure(font, text), .{ .element = .outgoing_dps, .anchor = combat.outgoing_position, .offset_x = combat.outgoing_offset_x, .offset_y = combat.outgoing_offset_y, .color = combat.outgoing_color, .bg_color = settings.combat_outgoing_bg_color });
    }
}

fn addMining(layout: *Layout, fonts: Fonts, config: *const config_mod.Config, stats: *const ActivityStats, settings: RenderSettings) !void {
    const mining = &config.thumbnail.miningText;
    if (!mining.shown) return;
    const rate = stats.shownMining() orelse return;
    const font = try fonts.getScaled(.mining, mining.font_name, mining.font_size, mining.font_weight);

    var texts: [2][]const u8 = undefined;
    var text_count: usize = 1;
    const unit = config.mining.m3_rate_unit;
    texts[0] = statText(layout, .{ .kind = .mining_volume, .value = rate * unit.seconds(), .has_prefix = mining.show_prefix, .unit = unit });

    const isk_rate = if (mining.show_isk_rate) stats.shownMiningIsk() else null;
    if (isk_rate) |isk_per_second| {
        const isk_unit = config.mining.isk_rate_unit;
        texts[1] = statText(layout, .{ .kind = .mining_isk, .value = isk_per_second * isk_unit.seconds(), .has_prefix = false, .unit = isk_unit });
        text_count = 2;
    }
    layout.addStack(font, texts[0..text_count], .{ .element = .mining, .anchor = mining.position, .offset_x = mining.offset_x, .offset_y = mining.offset_y, .color = mining.color, .bg_color = settings.mining_bg_color });
}

fn addBounty(layout: *Layout, fonts: Fonts, config: *const config_mod.Config, stats: *const ActivityStats, settings: RenderSettings) !void {
    const bounty = &config.thumbnail.bountyText;
    if (!bounty.shown) return;
    const isk_per_second = stats.shownBounty() orelse return;
    const font = try fonts.getScaled(.bounty, bounty.font_name, bounty.font_size, bounty.font_weight);
    const unit = config.bounty.isk_rate_unit;
    const text = statText(layout, .{ .kind = .bounty_isk, .value = isk_per_second * unit.seconds(), .has_prefix = bounty.show_prefix, .unit = unit });
    layout.addAt(font, text, layout.measure(font, text), .{ .element = .bounty, .anchor = bounty.position, .offset_x = bounty.offset_x, .offset_y = bounty.offset_y, .color = bounty.color, .bg_color = settings.bounty_bg_color });
}

fn statText(layout: *Layout, reading: stat_text.Reading) []const u8 {
    var writer: std.Io.Writer = .fixed(layout.nextTextBuffer());
    stat_text.write(&writer, reading);
    return writer.buffered();
}

fn addResources(layout: *Layout, fonts: Fonts, config: *const config_mod.Config, stats: *const ActivityStats, settings: RenderSettings) !void {
    const resources = &config.thumbnail.resourcesText;
    if (!resources.shown or !stats.has_resources) return;
    const font = try fonts.getScaled(.resources, resources.font_name, resources.font_size, resources.font_weight);

    var texts: [MAX_STACK_LINES][]const u8 = undefined;
    var text_count: usize = 0;
    if (resources.show_cpu) {
        texts[text_count] = layout.print("CPU: {d:.0}%", .{stats.cpu_percent});
        text_count += 1;
    }
    if (resources.show_ram) {
        texts[text_count] = layout.print("RAM: {d:.0}MB", .{stats.ram_mb});
        text_count += 1;
    }
    if (resources.show_vram and stats.has_vram) {
        texts[text_count] = layout.print("VRAM: {d:.0}MB", .{stats.vram_mb});
        text_count += 1;
    }
    if (text_count > 0) layout.addStack(font, texts[0..text_count], .{ .element = .resources, .anchor = resources.position, .offset_x = resources.offset_x, .offset_y = resources.offset_y, .color = resources.color, .bg_color = settings.resources_bg_color });
}

fn addPing(layout: *Layout, fonts: Fonts, config: *const config_mod.Config, stats: *const ActivityStats, settings: RenderSettings) !void {
    const ping = &config.thumbnail.pingText;
    if (!ping.shown or !stats.has_ping) return;
    const font = try fonts.getScaled(.ping, ping.font_name, ping.font_size, ping.font_weight);
    const text = if (stats.ping_ms) |ms| layout.print("{d} ms", .{ms}) else layout.print("?? ms", .{});
    layout.addAt(font, text, layout.measure(font, text), .{ .element = .ping, .anchor = ping.position, .offset_x = ping.offset_x, .offset_y = ping.offset_y, .color = ping.color, .bg_color = settings.ping_bg_color });
}

/// Fills `map` and returns its labels' font; null while the plain system name shows instead.
fn layoutConnectionMap(map: *layout_mod.Layout, layout: *Layout, fonts: Fonts, settings: RenderSettings) !?win32.HFONT {
    const connections = settings.connections.slice();
    if (!settings.show_system_name or connections.len == 0) return null;
    const text_style = settings.system_name_style;
    const font = try fonts.get(.system_name, text_style.font_name, text_style.font_size, text_style.font_weight);

    var systems: [connections_mod.CAPACITY]universe.SystemIndex = undefined;
    for (connections, 0..) |connection, index| systems[index] = connection.system;
    const dimensions: TextDimensions = .{
        .width = @min(@as(usize, @intCast(settings.connection_map_width)), layout.width),
        .height = @min(@as(usize, @intCast(settings.connection_map_height)), layout.height),
    };
    const origin = layout.position(text_style.position, dimensions, text_style.offset_x, text_style.offset_y);
    const area: layout_mod.Box = .{ .left = origin.x, .top = origin.y, .right = origin.x + @as(i32, @intCast(dimensions.width)), .bottom = origin.y + @as(i32, @intCast(dimensions.height)) };
    map.buildAround(systems[0..connections.len], area);

    var node_widths: [connections_mod.CAPACITY]i32 = undefined;
    var line_height: i32 = 0;
    for (map.nodes[0..map.node_count], 0..) |node, index| {
        const label = layout.measureRun(font, universe.systemName(node.system));
        node_widths[index] = @intCast(label.width);
        line_height = @max(line_height, @as(i32, @intCast(label.height)));
    }
    var exit_widths: [layout_mod.MAX_EXITS]i32 = undefined;
    for (map.exits[0..map.exit_count], 0..) |exit, index| {
        exit_widths[index] = @intCast(layout.measureRun(font, exitLabel(exit, settings)).width);
    }

    var connection_order: [connections_mod.CAPACITY]u16 = undefined;
    var node_order: [connections_mod.CAPACITY]u16 = undefined;
    var node_order_count: usize = 0;
    for (settings.connections.labelOrder(&connection_order)) |connection_index| {
        node_order[node_order_count] = map.nodeOf(connections[connection_index].system) orelse continue;
        node_order_count += 1;
    }
    map.placeLabelsInOrder(node_order[0..node_order_count], &node_widths, &exit_widths, line_height);
    return font;
}

fn hasIntel(connection: ?connections_mod.Connection) bool {
    const marked = connection orelse return false;
    return marked.intel_freshness_percent > 0;
}

/// The region it leads to, as on the Map Panel; with intel, the system the report names.
fn exitLabel(exit: layout_mod.Exit, settings: RenderSettings) []const u8 {
    return if (hasIntel(settings.connections.find(exit.destination))) universe.systemName(exit.destination) else universe.regionName(exit.region);
}

fn labelColor(connection: ?connections_mod.Connection, plain_color: u32) u32 {
    const marked = connection orelse return plain_color;
    return if (marked.intel_freshness_percent > 0) markers.intelColor(marked.is_clear) else plain_color;
}

fn drawIntelHalo(canvas: pixel_buffer.Canvas, x: i32, y: i32, connection: ?connections_mod.Connection) void {
    const marked = connection orelse return;
    if (marked.intel_freshness_percent == 0) return;
    const halo_radius = markers.intelHaloRadius(marked.intel_shrink_percent, 100) * CONNECTION_HALO_SCALE;
    markers.drawIntelHalo(canvas, x, y, halo_radius, marked.is_clear, marked.intel_freshness_percent);
}

/// Layered like the Map Panel: halos, gates, then systems; no background, so the client shows through.
fn drawConnectionMap(canvas: pixel_buffer.Canvas, map: *const layout_mod.Layout, settings: RenderSettings) void {
    const nodes = map.nodes[0..map.node_count];
    const exits = map.exits[0..map.exit_count];
    for (nodes) |node| drawIntelHalo(canvas, node.x, node.y, settings.connections.find(node.system));
    for (exits) |exit| drawIntelHalo(canvas, exit.x, exit.y, settings.connections.find(exit.destination));
    for (map.edges[0..map.edge_count]) |edge| {
        const first = nodes[edge.first_index];
        const second = nodes[edge.second_index];
        pixel_buffer.drawLine(canvas, first.x, first.y, second.x, second.y, markers.edgeColor(edge.kind));
    }
    for (exits) |exit| markers.drawExit(canvas, nodes[exit.from_index], exit, markers.EXIT);
    const marker_radius = markers.NODE_RADIUS;
    for (nodes) |node| {
        pixel_buffer.fillCircle(canvas, node.x, node.y, marker_radius, security.securityColor(universe.systemInfo(node.system).security_tenths));
    }
    pixel_buffer.drawRing(canvas, nodes[0].x, nodes[0].y, marker_radius + markers.RING_GAP, markers.RING_THICKNESS, markers.FOCUS);
}

/// In the font already selected into `dc`; the character's own system keeps its colour unless intel names it.
fn renderConnectionLabels(dc: win32.HDC, map: *const layout_mod.Layout, settings: RenderSettings) void {
    for (map.nodes[0..map.node_count], 0..) |node, index| {
        const label = node.label orelse continue;
        const plain_color = if (index == 0) settings.system_name_style.color else settings.connection_color;
        draw.renderText(dc, universe.systemName(node.system), label.left - draw.TEXT_PADDING_X, label.top - draw.TEXT_PADDING_Y, labelColor(settings.connections.find(node.system), plain_color));
    }
    for (map.exits[0..map.exit_count]) |exit| {
        const label = exit.label orelse continue;
        draw.renderText(dc, exitLabel(exit, settings), label.left - draw.TEXT_PADDING_X, label.top - draw.TEXT_PADDING_Y, labelColor(settings.connections.find(exit.destination), markers.EXIT));
    }
}

/// Not size-cached: the stack changes too often for a cache to hit.
fn layoutNotifications(layout: *Layout, fonts: Fonts, settings: RenderSettings) !?NotificationBlock {
    if (!settings.show_notifications or settings.notification_line_count == 0) return null;
    const font = try fonts.get(.notification, settings.notifications_font_name, settings.notifications_font_size, settings.notifications_font_weight);
    var block: NotificationBlock = .{ .font = font, .origin = undefined, .dimensions = .{ .width = 0, .height = 0 }, .line_heights = undefined };
    for (settings.notification_lines[0..settings.notification_line_count], 0..) |line, i| {
        const dimensions = layout.measure(font, line.text);
        block.line_heights[i] = dimensions.height;
        block.dimensions.width = @max(block.dimensions.width, dimensions.width);
        block.dimensions.height += dimensions.height;
    }
    block.origin = layout.position(settings.notifications_position, block.dimensions, settings.notifications_offset_x, settings.notifications_offset_y);
    return block;
}

/// A space's window size as already laid out, else the configured or per-character size at the window's DPI.
fn overlaySize(config: *const config_mod.Config, thumbnail: *const ThumbnailWindow, dpi_scale: f32) window.Size {
    if (spaces.spaceFor(config, thumbnail.character_name) != null) {
        var client_rect: win32.RECT = undefined;
        if (!win32.toBool(win32.GetClientRect(thumbnail.hwnd, &client_rect))) {
            slog.debug("Failed to read the laid-out size of '{s}', using the configured one", .{thumbnail.character_name});
        } else if (client_rect.right > 0 and client_rect.bottom > 0) {
            return .{ .width = client_rect.right, .height = client_rect.bottom };
        }
    }
    const character_size = thumbnail.cached_thumbnail_size;
    const width = if (character_size) |own_size| own_size.width orelse config.thumbnail.width else config.thumbnail.width;
    const height = if (character_size) |own_size| own_size.height orelse config.thumbnail.height else config.thumbnail.height;
    return .{ .width = scalePixels(width, dpi_scale), .height = scalePixels(height, dpi_scale) };
}
