const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const color_mod = @import("../util/color.zig");
const types = @import("../types.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const log = @import("../log.zig");
const slog = log.scoped("overlay");
// Only for the ThumbnailWindow type; painter.zig imports this module back.
const painter_mod = @import("../painter.zig");
const notification_stack_mod = @import("../notifications/stack.zig");
const draw = @import("draw.zig");
const font_cache_mod = @import("font_cache.zig");
const format = @import("../util/format.zig");

const ThumbnailWindow = painter_mod.ThumbnailWindow;
const TextPosition = types.TextPosition;
const BorderStyle = types.BorderStyle;
const TextDimensions = draw.TextDimensions;
const TextOrigin = draw.TextOrigin;
const scalePixels = win32.scalePixels;

/// One resolved (text, color) line of the stacked notification block; built by createRenderSettings, drawn by renderThumbnailOverlay.
pub const NotificationLine = struct {
    text: []const u8 = "",
    color: u32 = 0xFFFFFF,
};

const OVERLAY_ALPHA = 255;

/// Settings for rendering thumbnail overlays (text and border).
pub const RenderSettings = struct {
    show_text: bool = true,
    show_character_name: bool = true,
    character_name: []const u8 = "",
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

    dps_incoming: f32 = 0.0,
    dps_outgoing: f32 = 0.0,
    mining_rate: f32 = 0.0,
    mining_isk_rate: f32 = 0.0,
    bounty_isk_rate: f32 = 0.0,
    resource_cpu_percent: f32 = 0.0,
    resource_ram_mb: f32 = 0.0,
    resource_vram_mb: f32 = 0.0,
    // Included so the false->true transition on first tracker push invalidates the cache even when the (sentineled) rate value itself didn't change.
    has_dps_data: bool = false,
    has_mining_data: bool = false,
    has_bounty_data: bool = false,
    has_resource_data: bool = false,
    has_vram_data: bool = false,

    // Included so a config-only color change still invalidates renderThumbnail's cache even when the DPS/rate value itself hasn't moved.
    dps_incoming_color: u32 = 0xFFFF4444,
    dps_outgoing_color: u32 = 0xFF44FF44,
    mining_color: u32 = 0xFF44AAFF,
    bounty_color: u32 = 0xFFFFD700,
    resources_color: u32 = 0xFFFFFFFF,
};

/// Compares all visual fields of RenderSettings except show_thumbnail; shared by renderSettingsEqual and renderSettingsOnlyVisibilityChanged.
fn renderSettingsVisualEqual(a: RenderSettings, b: RenderSettings) bool {
    return a.show_text == b.show_text and
        a.show_character_name == b.show_character_name and
        stringsEqualFast(a.character_name, b.character_name) and
        a.show_system_name == b.show_system_name and
        stringsEqualFast(a.system_name, b.system_name) and
        a.character_name_color == b.character_name_color and
        a.system_name_color == b.system_name_color and
        a.character_name_bg_color == b.character_name_bg_color and
        a.system_name_bg_color == b.system_name_bg_color and
        stringsEqualFast(a.character_name_font_name, b.character_name_font_name) and
        a.character_name_font_size == b.character_name_font_size and
        a.character_name_font_weight == b.character_name_font_weight and
        a.character_name_position == b.character_name_position and
        a.character_name_offset_x == b.character_name_offset_x and
        a.character_name_offset_y == b.character_name_offset_y and
        a.system_name_position == b.system_name_position and
        a.system_name_offset_x == b.system_name_offset_x and
        a.system_name_offset_y == b.system_name_offset_y and
        stringsEqualFast(a.system_name_font_name, b.system_name_font_name) and
        a.system_name_font_size == b.system_name_font_size and
        a.system_name_font_weight == b.system_name_font_weight and
        a.show_notifications == b.show_notifications and
        a.notification_line_count == b.notification_line_count and
        (blk: {
            var idx: usize = 0;
            while (idx < a.notification_line_count) : (idx += 1) {
                const al = a.notification_lines[idx];
                const bl = b.notification_lines[idx];
                if (al.color != bl.color) break :blk false;
                if (!stringsEqualFast(al.text, bl.text)) break :blk false;
            }
            break :blk true;
        }) and
        a.notifications_position == b.notifications_position and
        a.notifications_offset_x == b.notifications_offset_x and
        a.notifications_offset_y == b.notifications_offset_y and
        stringsEqualFast(a.notifications_font_name, b.notifications_font_name) and
        a.notifications_font_size == b.notifications_font_size and
        a.notifications_font_weight == b.notifications_font_weight and
        a.notifications_bg_color == b.notifications_bg_color and
        a.show_border == b.show_border and
        a.border_width == b.border_width and
        a.border_color == b.border_color and
        a.border_style == b.border_style and
        a.show_exclusion_overlay == b.show_exclusion_overlay and
        a.exclusion_overlay_style == b.exclusion_overlay_style and
        a.exclusion_overlay_color == b.exclusion_overlay_color and
        a.show_group_badge == b.show_group_badge and
        stringsEqualFast(a.group_badge_text, b.group_badge_text) and
        a.group_badge_color == b.group_badge_color and
        a.group_badge_position == b.group_badge_position and
        a.group_badge_offset_x == b.group_badge_offset_x and
        a.group_badge_offset_y == b.group_badge_offset_y and
        stringsEqualFast(a.group_badge_font_name, b.group_badge_font_name) and
        a.group_badge_font_size == b.group_badge_font_size and
        a.group_badge_font_weight == b.group_badge_font_weight and
        a.group_badge_bg_color == b.group_badge_bg_color and
        a.overlay_alpha == b.overlay_alpha and
        a.overlay_width == b.overlay_width and
        a.overlay_height == b.overlay_height and
        a.dps_incoming == b.dps_incoming and
        a.dps_outgoing == b.dps_outgoing and
        a.mining_rate == b.mining_rate and
        a.mining_isk_rate == b.mining_isk_rate and
        a.bounty_isk_rate == b.bounty_isk_rate and
        a.resource_cpu_percent == b.resource_cpu_percent and
        a.resource_ram_mb == b.resource_ram_mb and
        a.resource_vram_mb == b.resource_vram_mb and
        a.has_dps_data == b.has_dps_data and
        a.has_mining_data == b.has_mining_data and
        a.has_bounty_data == b.has_bounty_data and
        a.has_resource_data == b.has_resource_data and
        a.has_vram_data == b.has_vram_data and
        a.dps_incoming_color == b.dps_incoming_color and
        a.dps_outgoing_color == b.dps_outgoing_color and
        a.mining_color == b.mining_color and
        a.bounty_color == b.bounty_color and
        a.resources_color == b.resources_color and
        a.combat_incoming_bg_color == b.combat_incoming_bg_color and
        a.combat_outgoing_bg_color == b.combat_outgoing_bg_color and
        a.mining_bg_color == b.mining_bg_color and
        a.bounty_bg_color == b.bounty_bg_color and
        a.resources_bg_color == b.resources_bg_color;
}

pub fn renderSettingsEqual(a: RenderSettings, b: RenderSettings) bool {
    return a.show_thumbnail == b.show_thumbnail and renderSettingsVisualEqual(a, b);
}

pub fn renderSettingsOnlyVisibilityChanged(a: RenderSettings, b: RenderSettings) bool {
    return a.show_thumbnail != b.show_thumbnail and renderSettingsVisualEqual(a, b);
}

/// One paintable text run inside the thumbnail overlay. render_pos is where its glyphs are drawn;
/// bg_pos/bg_dims bound its background-fill and alpha-fixup rect. These differ for stacked
/// mining/resources lines, which share one block-wide background but render at their own
/// individually-aligned x.
const DrawLine = struct {
    font: win32.HFONT,
    text: []const u8,
    render_pos: TextOrigin,
    bg_pos: TextOrigin,
    bg_dims: TextDimensions,
    color: u32,
    bg_color: u32,
};

/// Pointer+len fast path before falling back to a byte compare; config/notif-owned slices are pointer+len identical every tick when unchanged.
fn stringsEqualFast(a: []const u8, b: []const u8) bool {
    return (a.ptr == b.ptr and a.len == b.len) or std.mem.eql(u8, a, b);
}

/// A text run's measured size and the font it was measured with, so an unchanged run isn't re-measured every render; `font_name` borrows config's font-name buffer.
const MeasuredText = struct {
    dims: ?TextDimensions = null,
    font_name: []const u8 = "",
    font_size: i32 = 0,
    font_weight: types.FontWeight = .Regular,

    /// Re-measures `text` in `font` only when invalidated or the font settings changed; leaves `restore_font` selected into `dc`.
    fn measure(self: *MeasuredText, dc: win32.HDC, font: win32.HFONT, restore_font: win32.HFONT, text: []const u8, font_name: []const u8, font_size: i32, font_weight: types.FontWeight) TextDimensions {
        if (self.dims) |cached| {
            if (stringsEqualFast(self.font_name, font_name) and self.font_size == font_size and self.font_weight == font_weight) return cached;
        }
        _ = win32.SelectObject(dc, font);
        const measured = draw.measureText(dc, text);
        _ = win32.SelectObject(dc, restore_font);
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

pub fn renderThumbnailOverlay(fonts: *font_cache_mod.FontCache, thumbnail: *ThumbnailWindow, settings: RenderSettings, config: *const config_mod.Config) !void {
    const hwnd = thumbnail.text_hwnd;
    const system_name = thumbnail.system_name;

    const width = settings.overlay_width;
    const height = settings.overlay_height;

    // Reuse the cached overlay bitmap unless dimensions changed (first render or resize).
    const cache = &thumbnail.render_cache;
    if (gdi_overlay.OverlayBitmap.needsResize(cache.bitmap, width, height)) {
        const init_dc = win32.GetDC(null) orelse return error.GetDCFailed;
        defer _ = win32.ReleaseDC(null, init_dc);
        try gdi_overlay.OverlayBitmap.recreate(&cache.bitmap, init_dc, width, height);
        slog.debug("Allocated overlay bitmap {}x{} for {s}", .{ width, height, thumbnail.character_name });
    }

    const overlay = &cache.bitmap.?;

    overlay.clear();

    if (settings.show_exclusion_overlay) {
        draw.drawExclusionOverlay(overlay.pixels, overlay.width, overlay.height, settings.exclusion_overlay_color, settings.exclusion_overlay_style);
    }

    const dpi: u32 = win32.GetDpiForWindow(thumbnail.hwnd);
    // Combat/mining/bounty font sizes bypass RenderSettings (see createRenderSettings), so they're scaled here instead.
    const dpi_scale = win32.dpiToScale(dpi);
    const font = try fonts.get(
        .main,
        dpi,
        settings.character_name_font_name,
        settings.character_name_font_size,
        settings.character_name_font_weight,
    );

    // Select the main font once for all char/system/notification measure+render calls; restore the original object on function exit.
    const old_main_font = win32.SelectObject(overlay.mem_dc, font);
    defer {
        if (old_main_font) |of| _ = win32.SelectObject(overlay.mem_dc, of);
    }

    const display_name = thumbnail.cached_display_name;

    var char_text_dims: TextDimensions = .{ .width = 0, .height = 0 };
    if (settings.show_character_name) {
        char_text_dims = cache.character_name.measure(overlay.mem_dc, font, font, display_name, settings.character_name_font_name, settings.character_name_font_size, settings.character_name_font_weight);
    }

    // Resolved once here and reused at the render phase below, since that's a separate `if (settings.show_system_name)` block where a local const wouldn't be in scope.
    var system_text_dims: TextDimensions = .{ .width = 0, .height = 0 };
    var sys_font: ?win32.HFONT = null;
    if (settings.show_system_name) {
        const sf = try fonts.get(.system_name, dpi, settings.system_name_font_name, settings.system_name_font_size, settings.system_name_font_weight);
        sys_font = sf;
        system_text_dims = cache.system_name.measure(overlay.mem_dc, sf, font, system_name, settings.system_name_font_name, settings.system_name_font_size, settings.system_name_font_weight);
    }

    // Stacked notification lines aren't dims-cached (unlike char/system name above): the stack's contents change
    // far more often than those, so a cache would invalidate almost every render anyway.
    var notif_line_dims: [notification_stack_mod.CAPACITY]TextDimensions = undefined;
    var notifications_text_dims: TextDimensions = .{ .width = 0, .height = 0 };
    const has_notification_text = settings.notification_line_count > 0;
    var notif_font: ?win32.HFONT = null;
    if (settings.show_notifications and has_notification_text) {
        const nf = try fonts.get(.notification, dpi, settings.notifications_font_name, settings.notifications_font_size, settings.notifications_font_weight);
        notif_font = nf;
        _ = win32.SelectObject(overlay.mem_dc, nf);
        var idx: usize = 0;
        while (idx < settings.notification_line_count) : (idx += 1) {
            notif_line_dims[idx] = draw.measureText(overlay.mem_dc, settings.notification_lines[idx].text);
            notifications_text_dims.width = @max(notifications_text_dims.width, notif_line_dims[idx].width);
            notifications_text_dims.height += notif_line_dims[idx].height;
        }
        _ = win32.SelectObject(overlay.mem_dc, font);
    }

    var badge_dims: TextDimensions = .{ .width = 0, .height = 0 };
    var badge_font: ?win32.HFONT = null;
    if (settings.show_group_badge) {
        const badge_hfont = try fonts.get(.group_badge, dpi, settings.group_badge_font_name, settings.group_badge_font_size, settings.group_badge_font_weight);
        badge_font = badge_hfont;
        badge_dims = cache.group_badge.measure(overlay.mem_dc, badge_hfont, font, settings.group_badge_text, settings.group_badge_font_name, settings.group_badge_font_size, settings.group_badge_font_weight);
    }

    const char_text_pos: TextOrigin = if (settings.show_character_name)
        draw.calculateTextPosition(
            settings.character_name_position,
            char_text_dims.width,
            char_text_dims.height,
            overlay.width,
            overlay.height,
            settings.character_name_offset_x,
            settings.character_name_offset_y,
        )
    else
        TextOrigin{ .x = 0, .y = 0 };

    const system_text_pos: TextOrigin = if (settings.show_system_name)
        draw.calculateTextPosition(
            settings.system_name_position,
            system_text_dims.width,
            system_text_dims.height,
            overlay.width,
            overlay.height,
            settings.system_name_offset_x,
            settings.system_name_offset_y,
        )
    else
        TextOrigin{ .x = 0, .y = 0 };

    const notifications_text_pos: TextOrigin = if (settings.show_notifications and has_notification_text)
        draw.calculateTextPosition(
            settings.notifications_position,
            notifications_text_dims.width,
            notifications_text_dims.height,
            overlay.width,
            overlay.height,
            settings.notifications_offset_x,
            settings.notifications_offset_y,
        )
    else
        TextOrigin{ .x = 0, .y = 0 };

    const badge_pos: TextOrigin = if (settings.show_group_badge)
        draw.calculateTextPosition(
            settings.group_badge_position,
            badge_dims.width,
            badge_dims.height,
            overlay.width,
            overlay.height,
            settings.group_badge_offset_x,
            settings.group_badge_offset_y,
        )
    else
        TextOrigin{ .x = 0, .y = 0 };

    // Collects every single-rect text run (character/system/badge/DPS/mining/bounty/resources) so their
    // background-fill, glyph-render, and alpha-fixup passes can share one loop each below. Notifications
    // are excluded: they fill/fixup as one combined multi-line rect but render each line separately, so
    // they don't fit this one-rect-per-entry model and stay handled inline where they already were.
    var draw_lines: [11]DrawLine = undefined;
    var draw_line_count: usize = 0;

    if (settings.show_character_name) {
        draw_lines[draw_line_count] = .{
            .font = font,
            .text = display_name,
            .render_pos = char_text_pos,
            .bg_pos = char_text_pos,
            .bg_dims = char_text_dims,
            .color = settings.character_name_color,
            .bg_color = settings.character_name_bg_color,
        };
        draw_line_count += 1;
    }

    if (settings.show_system_name) {
        draw_lines[draw_line_count] = .{
            .font = sys_font.?,
            .text = system_name,
            .render_pos = system_text_pos,
            .bg_pos = system_text_pos,
            .bg_dims = system_text_dims,
            .color = settings.system_name_color,
            .bg_color = settings.system_name_bg_color,
        };
        draw_line_count += 1;
    }

    if (settings.show_notifications and has_notification_text) {
        draw.fillTextBackground(
            overlay.pixels,
            overlay.width,
            overlay.height,
            notifications_text_pos.x,
            notifications_text_pos.y,
            notifications_text_dims.width,
            notifications_text_dims.height,
            settings.notifications_bg_color,
        );
    }

    if (settings.show_group_badge) {
        draw_lines[draw_line_count] = .{
            .font = badge_font.?,
            .text = settings.group_badge_text,
            .render_pos = badge_pos,
            .bg_pos = badge_pos,
            .bg_dims = badge_dims,
            .color = settings.group_badge_color,
            .bg_color = settings.group_badge_bg_color,
        };
        draw_line_count += 1;
    }

    // DPS text runs are collected below and painted via the shared draw_lines loops after the border.
    var dps_in_buf: [32]u8 = undefined;
    var dps_out_buf: [32]u8 = undefined;
    var dps_in_text: []const u8 = "";
    var dps_out_text: []const u8 = "";
    var dps_in_pos: TextOrigin = .{ .x = 0, .y = 0 };
    var dps_out_pos: TextOrigin = .{ .x = 0, .y = 0 };
    var dps_in_dims: TextDimensions = .{ .width = 0, .height = 0 };
    var dps_out_dims: TextDimensions = .{ .width = 0, .height = 0 };
    if (config.combat.enabled and config.thumbnail.showText) {
        const combat_cfg = &config.combat;
        if (combat_cfg.show_incoming and thumbnail.has_dps_data and (thumbnail.last_incoming_dps == null or thumbnail.last_incoming_dps.? > 0)) {
            const f = try fonts.get(.combat, dpi, combat_cfg.incoming_font_name, scalePixels(combat_cfg.incoming_font_size, dpi_scale), combat_cfg.incoming_font_weight);
            _ = win32.SelectObject(overlay.mem_dc, f);
            dps_in_text = if (thumbnail.last_incoming_dps) |dps|
                (if (combat_cfg.incoming_show_prefix)
                    std.fmt.bufPrint(&dps_in_buf, "IN: {d:.0}", .{dps}) catch "IN: ---"
                else
                    std.fmt.bufPrint(&dps_in_buf, "{d:.0}", .{dps}) catch "---")
            else if (combat_cfg.incoming_show_prefix) "IN: ??" else "??";
            dps_in_dims = draw.measureText(overlay.mem_dc, dps_in_text);
            dps_in_pos = draw.calculateTextPosition(combat_cfg.incoming_position, dps_in_dims.width, dps_in_dims.height, overlay.width, overlay.height, combat_cfg.incoming_offset_x, combat_cfg.incoming_offset_y);
            draw_lines[draw_line_count] = .{ .font = f, .text = dps_in_text, .render_pos = dps_in_pos, .bg_pos = dps_in_pos, .bg_dims = dps_in_dims, .color = combat_cfg.incoming_color, .bg_color = settings.combat_incoming_bg_color };
            draw_line_count += 1;
            _ = win32.SelectObject(overlay.mem_dc, font);
        }
        if (combat_cfg.show_outgoing and thumbnail.has_dps_data and (thumbnail.last_outgoing_dps == null or thumbnail.last_outgoing_dps.? > 0)) {
            const f = try fonts.get(.combat_outgoing, dpi, combat_cfg.outgoing_font_name, scalePixels(combat_cfg.outgoing_font_size, dpi_scale), combat_cfg.outgoing_font_weight);
            _ = win32.SelectObject(overlay.mem_dc, f);
            dps_out_text = if (thumbnail.last_outgoing_dps) |dps|
                (if (combat_cfg.outgoing_show_prefix)
                    std.fmt.bufPrint(&dps_out_buf, "OUT: {d:.0}", .{dps}) catch "OUT: ---"
                else
                    std.fmt.bufPrint(&dps_out_buf, "{d:.0}", .{dps}) catch "---")
            else if (combat_cfg.outgoing_show_prefix) "OUT: ??" else "??";
            dps_out_dims = draw.measureText(overlay.mem_dc, dps_out_text);
            dps_out_pos = draw.calculateTextPosition(combat_cfg.outgoing_position, dps_out_dims.width, dps_out_dims.height, overlay.width, overlay.height, combat_cfg.outgoing_offset_x, combat_cfg.outgoing_offset_y);
            draw_lines[draw_line_count] = .{ .font = f, .text = dps_out_text, .render_pos = dps_out_pos, .bg_pos = dps_out_pos, .bg_dims = dps_out_dims, .color = combat_cfg.outgoing_color, .bg_color = settings.combat_outgoing_bg_color };
            draw_line_count += 1;
            _ = win32.SelectObject(overlay.mem_dc, font);
        }
    }

    // Mining text runs are collected below and painted via the shared draw_lines loops after the border.
    // ISK rate (if shown) stacks as a second GDI-single-line text; both lines share one background width so text can align to mining_cfg.position's edge without a gap.
    var mining_buf: [32]u8 = undefined;
    var mining_isk_buf: [24]u8 = undefined;
    var mining_text: []const u8 = "";
    var mining_isk_text: []const u8 = "";
    var mining_pos: TextOrigin = .{ .x = 0, .y = 0 };
    var mining_isk_pos: TextOrigin = .{ .x = 0, .y = 0 };
    var mining_dims: TextDimensions = .{ .width = 0, .height = 0 };
    var mining_isk_dims: TextDimensions = .{ .width = 0, .height = 0 };
    var mining_block_x: i32 = 0;
    var mining_block_width: usize = 0;
    if (config.mining.enabled and config.thumbnail.showText and thumbnail.has_mining_data and (thumbnail.last_mining_rate == null or thumbnail.last_mining_rate.? > 0)) {
        const mining_cfg = &config.mining;
        const mf = try fonts.get(.mining, dpi, mining_cfg.font_name, scalePixels(mining_cfg.font_size, dpi_scale), mining_cfg.font_weight);
        _ = win32.SelectObject(overlay.mem_dc, mf);
        if (thumbnail.last_mining_rate) |rate| {
            // Displayed per-minute rather than per-second so low-yield ore doesn't round to "0".
            const rate_per_min = rate * 60.0;
            var raw_buf: [16]u8 = undefined;
            const raw = if (rate_per_min < 10.0)
                std.fmt.bufPrint(&raw_buf, "{d:.1}", .{rate_per_min}) catch "---"
            else
                std.fmt.bufPrint(&raw_buf, "{d:.0}", .{rate_per_min}) catch "---";
            var comma_buf: [16]u8 = undefined;
            const formatted = format.insertThousandsSeparators(&comma_buf, raw);
            mining_text = if (mining_cfg.show_prefix)
                std.fmt.bufPrint(&mining_buf, "M: {s} m3/min", .{formatted}) catch "M: ---"
            else
                std.fmt.bufPrint(&mining_buf, "{s} m3/min", .{formatted}) catch "---";
        } else {
            mining_text = if (mining_cfg.show_prefix) "M: ?? m3/min" else "?? m3/min";
        }
        mining_dims = draw.measureText(overlay.mem_dc, mining_text);

        if (mining_cfg.show_isk_rate) {
            const period_secs: f32 = if (mining_cfg.isk_rate_unit == .hour) 3600.0 else 60.0;
            const unit_suffix: []const u8 = if (mining_cfg.isk_rate_unit == .hour) "hr" else "min";
            if (thumbnail.last_mining_isk_rate) |isk_rate| {
                var isk_buf: [16]u8 = undefined;
                const isk_abbrev = format.formatIskAbbrev(&isk_buf, isk_rate * period_secs);
                mining_isk_text = std.fmt.bufPrint(&mining_isk_buf, "{s} ISK/{s}", .{ isk_abbrev, unit_suffix }) catch "";
            } else {
                mining_isk_text = std.fmt.bufPrint(&mining_isk_buf, "?? ISK/{s}", .{unit_suffix}) catch "";
            }
            mining_isk_dims = draw.measureText(overlay.mem_dc, mining_isk_text);
        }

        // Anchored as one combined block so Bottom*/Center* positions account for both lines' height, not just the first; each line then just stacks top-down from there.
        mining_block_width = @max(mining_dims.width, mining_isk_dims.width);
        const combined_height = mining_dims.height + mining_isk_dims.height;
        const anchor = draw.calculateTextPosition(mining_cfg.position, mining_block_width, combined_height, overlay.width, overlay.height, mining_cfg.offset_x, mining_cfg.offset_y);
        mining_block_x = anchor.x;

        const h_align = draw.horizontalAlignOf(mining_cfg.position);
        mining_pos = .{ .x = draw.alignedLineX(anchor.x, mining_block_width, mining_dims.width, h_align), .y = anchor.y };
        mining_isk_pos = .{ .x = draw.alignedLineX(anchor.x, mining_block_width, mining_isk_dims.width, h_align), .y = anchor.y + @as(i32, @intCast(mining_dims.height)) };

        draw_lines[draw_line_count] = .{
            .font = mf,
            .text = mining_text,
            .render_pos = mining_pos,
            .bg_pos = .{ .x = mining_block_x, .y = mining_pos.y },
            .bg_dims = .{ .width = mining_block_width, .height = mining_dims.height },
            .color = config.mining.color,
            .bg_color = settings.mining_bg_color,
        };
        draw_line_count += 1;
        if (mining_isk_text.len > 0) {
            draw_lines[draw_line_count] = .{
                .font = mf,
                .text = mining_isk_text,
                .render_pos = mining_isk_pos,
                .bg_pos = .{ .x = mining_block_x, .y = mining_isk_pos.y },
                .bg_dims = .{ .width = mining_block_width, .height = mining_isk_dims.height },
                .color = config.mining.color,
                .bg_color = settings.mining_bg_color,
            };
            draw_line_count += 1;
        }
        _ = win32.SelectObject(overlay.mem_dc, font);
    }

    // Bounty text run is collected below and painted via the shared draw_lines loops after the border.
    var bounty_buf: [24]u8 = undefined;
    var bounty_text: []const u8 = "";
    var bounty_pos: TextOrigin = .{ .x = 0, .y = 0 };
    var bounty_dims: TextDimensions = .{ .width = 0, .height = 0 };
    if (config.bounty.enabled and config.thumbnail.showText and thumbnail.has_bounty_data and (thumbnail.last_bounty_isk_rate == null or thumbnail.last_bounty_isk_rate.? > 0)) {
        const bounty_cfg = &config.bounty;
        const bf = try fonts.get(.bounty, dpi, bounty_cfg.font_name, scalePixels(bounty_cfg.font_size, dpi_scale), bounty_cfg.font_weight);
        _ = win32.SelectObject(overlay.mem_dc, bf);
        const period_secs: f32 = if (bounty_cfg.isk_rate_unit == .hour) 3600.0 else 60.0;
        const unit_suffix: []const u8 = if (bounty_cfg.isk_rate_unit == .hour) "hr" else "min";
        if (thumbnail.last_bounty_isk_rate) |isk_rate| {
            var isk_buf: [16]u8 = undefined;
            const isk_abbrev = format.formatIskAbbrev(&isk_buf, isk_rate * period_secs);
            bounty_text = if (bounty_cfg.show_prefix)
                std.fmt.bufPrint(&bounty_buf, "ISK: {s} ISK/{s}", .{ isk_abbrev, unit_suffix }) catch "ISK: ---"
            else
                std.fmt.bufPrint(&bounty_buf, "{s} ISK/{s}", .{ isk_abbrev, unit_suffix }) catch "---";
        } else {
            bounty_text = if (bounty_cfg.show_prefix)
                std.fmt.bufPrint(&bounty_buf, "ISK: ?? ISK/{s}", .{unit_suffix}) catch "ISK: ---"
            else
                std.fmt.bufPrint(&bounty_buf, "?? ISK/{s}", .{unit_suffix}) catch "---";
        }
        bounty_dims = draw.measureText(overlay.mem_dc, bounty_text);
        bounty_pos = draw.calculateTextPosition(bounty_cfg.position, bounty_dims.width, bounty_dims.height, overlay.width, overlay.height, bounty_cfg.offset_x, bounty_cfg.offset_y);

        draw_lines[draw_line_count] = .{
            .font = bf,
            .text = bounty_text,
            .render_pos = bounty_pos,
            .bg_pos = bounty_pos,
            .bg_dims = bounty_dims,
            .color = config.bounty.color,
            .bg_color = settings.bounty_bg_color,
        };
        draw_line_count += 1;
        _ = win32.SelectObject(overlay.mem_dc, font);
    }

    // Resource-usage text runs are collected below and painted via the shared draw_lines loops after the border, one stacked line per enabled metric, same as the mining block above.
    var resources_line_bufs: [3][32]u8 = undefined;
    var resources_texts: [3][]const u8 = .{ "", "", "" };
    var resources_dims: [3]TextDimensions = .{TextDimensions{ .width = 0, .height = 0 }} ** 3;
    var resources_line_count: usize = 0;
    var resources_block_x: i32 = 0;
    var resources_block_width: usize = 0;
    if (config.resources.enabled and config.thumbnail.showText and thumbnail.has_resource_data) {
        const resources_cfg = &config.resources;
        const rf = try fonts.get(.resources, dpi, resources_cfg.font_name, scalePixels(resources_cfg.font_size, dpi_scale), resources_cfg.font_weight);
        _ = win32.SelectObject(overlay.mem_dc, rf);

        if (resources_cfg.show_cpu) {
            resources_texts[resources_line_count] = std.fmt.bufPrint(&resources_line_bufs[resources_line_count], "CPU: {d:.0}%", .{thumbnail.last_cpu_percent}) catch "";
            resources_dims[resources_line_count] = draw.measureText(overlay.mem_dc, resources_texts[resources_line_count]);
            resources_line_count += 1;
        }
        if (resources_cfg.show_ram) {
            resources_texts[resources_line_count] = std.fmt.bufPrint(&resources_line_bufs[resources_line_count], "RAM: {d:.0}MB", .{thumbnail.last_ram_mb}) catch "";
            resources_dims[resources_line_count] = draw.measureText(overlay.mem_dc, resources_texts[resources_line_count]);
            resources_line_count += 1;
        }
        if (resources_cfg.show_vram and thumbnail.has_vram_data) {
            resources_texts[resources_line_count] = std.fmt.bufPrint(&resources_line_bufs[resources_line_count], "VRAM: {d:.0}MB", .{thumbnail.last_vram_mb}) catch "";
            resources_dims[resources_line_count] = draw.measureText(overlay.mem_dc, resources_texts[resources_line_count]);
            resources_line_count += 1;
        }

        if (resources_line_count > 0) {
            var combined_height: usize = 0;
            var i: usize = 0;
            while (i < resources_line_count) : (i += 1) {
                resources_block_width = @max(resources_block_width, resources_dims[i].width);
                combined_height += resources_dims[i].height;
            }
            const anchor = draw.calculateTextPosition(resources_cfg.position, resources_block_width, combined_height, overlay.width, overlay.height, resources_cfg.offset_x, resources_cfg.offset_y);
            resources_block_x = anchor.x;
            const h_align = draw.horizontalAlignOf(resources_cfg.position);

            var y = anchor.y;
            i = 0;
            while (i < resources_line_count) : (i += 1) {
                draw_lines[draw_line_count] = .{
                    .font = rf,
                    .text = resources_texts[i],
                    .render_pos = .{ .x = draw.alignedLineX(anchor.x, resources_block_width, resources_dims[i].width, h_align), .y = y },
                    .bg_pos = .{ .x = resources_block_x, .y = y },
                    .bg_dims = .{ .width = resources_block_width, .height = resources_dims[i].height },
                    .color = config.resources.color,
                    .bg_color = settings.resources_bg_color,
                };
                draw_line_count += 1;
                y += @as(i32, @intCast(resources_dims[i].height));
            }
        }
        _ = win32.SelectObject(overlay.mem_dc, font);
    }

    // Background-fill for every collected single-rect run, before the border so the border renders on top.
    for (draw_lines[0..draw_line_count]) |line| {
        draw.fillTextBackground(overlay.pixels, overlay.width, overlay.height, line.bg_pos.x, line.bg_pos.y, line.bg_dims.width, line.bg_dims.height, line.bg_color);
    }
    // Notifications' background is filled last so it isn't covered by an overlapping element's background.
    if (settings.show_notifications and has_notification_text) {
        draw.fillTextBackground(
            overlay.pixels,
            overlay.width,
            overlay.height,
            notifications_text_pos.x,
            notifications_text_pos.y,
            notifications_text_dims.width,
            notifications_text_dims.height,
            settings.notifications_bg_color,
        );
    }

    if (settings.show_border) {
        draw.drawBorder(
            overlay.pixels,
            overlay.width,
            overlay.height,
            @intCast(settings.border_width),
            settings.border_color,
            settings.border_style,
        );
    }

    for (draw_lines[0..draw_line_count]) |line| {
        _ = win32.SelectObject(overlay.mem_dc, line.font);
        draw.renderText(overlay.mem_dc, line.text, line.render_pos.x, line.render_pos.y, line.color);
    }
    _ = win32.SelectObject(overlay.mem_dc, font);

    // Notifications render as several separately-colored lines under one shared fixup rect, so they
    // stay outside the loop above - see the note on DrawLine above. Rendered last so notification text
    // is never hidden behind an overlapping element.
    if (settings.show_notifications and has_notification_text) {
        const nf = notif_font.?;
        _ = win32.SelectObject(overlay.mem_dc, nf);
        var notif_line_y = notifications_text_pos.y;
        var idx: usize = 0;
        while (idx < settings.notification_line_count) : (idx += 1) {
            const line = settings.notification_lines[idx];
            draw.renderText(overlay.mem_dc, line.text, notifications_text_pos.x, notif_line_y, line.color);
            notif_line_y += @as(i32, @intCast(notif_line_dims[idx].height));
        }
        _ = win32.SelectObject(overlay.mem_dc, font);
    }

    // Bounded to the rects text/glyphs were actually drawn into instead of scanning the whole overlay.
    for (draw_lines[0..draw_line_count]) |line| {
        gdi_overlay.fixTextAlphaRect(overlay.pixels, overlay.width, overlay.height, line.bg_pos.x, line.bg_pos.y, line.bg_dims.width, line.bg_dims.height);
    }
    if (settings.show_notifications and has_notification_text) {
        gdi_overlay.fixTextAlphaRect(overlay.pixels, overlay.width, overlay.height, notifications_text_pos.x, notifications_text_pos.y, notifications_text_dims.width, notifications_text_dims.height);
    }

    const window_size = win32.SIZE{ .cx = width, .cy = height };
    const source_pos = win32.POINT{ .x = 0, .y = 0 };
    var blend = win32.BLENDFUNCTION{
        .BlendOp = win32.AC_SRC_OVER,
        .BlendFlags = 0,
        .SourceConstantAlpha = settings.overlay_alpha,
        .AlphaFormat = win32.AC_SRC_ALPHA,
    };

    // hdcDst=null is valid here: UpdateLayeredWindow uses the screen DC internally when hdcSrc is supplied, sparing a GetDC/ReleaseDC pair every repaint.
    _ = win32.UpdateLayeredWindow(
        hwnd,
        null,
        null,
        @constCast(&window_size),
        overlay.mem_dc,
        @constCast(&source_pos),
        0,
        &blend,
        win32.ULW_ALPHA,
    );
}

// Per-state override (if any) wins, then opacity is forced fully opaque when the window's own
// Opacity setting should apply instead, so it isn't compounded with this color's own alpha.
fn resolveTextBgColor(state_cfg: config_mod.StateVisualConfig, base_color: u32, force_opaque: bool) u32 {
    const resolved = state_cfg.textBgColor orelse base_color;
    return if (force_opaque) color_mod.withAlpha(resolved, 255) else resolved;
}

/// Builds RenderSettings from Painter config; the single point where a thumbnail's effective render state determines all visual properties.
pub fn createRenderSettings(cfg: *config_mod.Config, thumbnail: *const ThumbnailWindow, active_source_hwnd: ?win32.HWND) RenderSettings {
    const state = thumbnail.effectiveRenderState(active_source_hwnd);
    const character_name = thumbnail.character_name;
    const system_name = thumbnail.system_name;
    const cached_system_color = thumbnail.cached_system_color;
    const is_visible = thumbnail.visibility_state.isVisible();
    // Read live rather than cached, so fonts/geometry track whichever monitor this window is on right now.
    const dpi_scale = win32.dpiToScale(win32.GetDpiForWindow(thumbnail.hwnd));

    const state_cfg = cfg.thumbnail.getStateConfig(state);

    // Already resolved when system name was set.
    const system_color = cached_system_color;

    // Alert is treated like Active as a base (it's an attention event); StateVisualConfig for Alert, per-type overrides, and per-character overrides all layer on top of this.
    const is_alert_like = (state == .Active or state == .Alert);
    const base_border_width = if (is_alert_like) cfg.thumbnail.borderWidth else cfg.thumbnail.inactiveBorderWidth;
    const base_border_color = if (is_alert_like) cfg.thumbnail.borderColor else cfg.thumbnail.inactiveBorderColor;
    const base_border_style = if (is_alert_like) cfg.thumbnail.borderStyle else cfg.thumbnail.inactiveBorderStyle;
    const base_show_border = if (is_alert_like) cfg.thumbnail.showBorderWhenFocused else cfg.thumbnail.showBorderWhenInactive;

    // Per-character override: hides this thumbnail unconditionally, regardless of state.
    const char_hidden = thumbnail.cached_hide_thumbnail;

    // char_hidden is handled separately as an absolute override on the final show_thumbnail field below.
    const base_show_thumbnail = if (!is_visible)
        false
    else if (state == .Active)
        !cfg.thumbnail.activeThumbnailHidden
    else
        true;

    // If the thumbnail, active thumbnail, or this character specifically is hidden, don't show border or text either.
    const should_hide_all = !is_visible or char_hidden or (state == .Active and cfg.thumbnail.activeThumbnailHidden);

    // Whether this thumbnail belongs to the character focused when the notification fired; notification border effects must not fight with that character's always-on active border.
    const notif_on_focused_char = thumbnail.isFocused(active_source_hwnd);

    // Border color/flash effects are governed solely by the newest (index 0) stacked notification; older entries only add text lines.
    // Per-type "show_border: false" forces the border off during Alert, skipped for the focused character so it can't also hide that character's active border.
    const notif_hides_border = state == .Alert and !notif_on_focused_char and
        if (thumbnail.notifications.newest()) |notif| !notif.show_border else false;

    // Blinks the border off for alternating phases at Alert start (see ActiveNotification.isFlashOff), skipped for the focused character for the same reason as notif_hides_border.
    const notif_flash_hides_border = state == .Alert and !notif_on_focused_char and
        if (thumbnail.notifications.newest()) |notif| notif.isFlashOff(win32.Ticks.now()) else false;

    const effective_show_border = if (should_hide_all or notif_hides_border or notif_flash_hides_border)
        false
    else
        state_cfg.showBorder orelse base_show_border;

    const effective_show_text = if (should_hide_all)
        false
    else
        cfg.thumbnail.showText;

    const effective_show_character_name = if (should_hide_all)
        false
    else
        (cfg.thumbnail.showText and cfg.thumbnail.showCharacterName);

    const effective_show_system_name = if (should_hide_all)
        false
    else
        (cfg.thumbnail.showText and cfg.thumbnail.showSystemName and system_name.len > 0);

    const effective_show_notifications = if (should_hide_all)
        false
    else
        (cfg.thumbnail.showText and cfg.thumbnail.notifications.enabled);

    // Combat/Mining/Bounty are also gated by showText, but checked directly in the render function below,
    // since they already bypass RenderSettings entirely for their enabled-checks.
    const effective_show_group_badge = if (should_hide_all)
        false
    else
        (cfg.thumbnail.showText and cfg.thumbnail.showQuickGroupBadge);

    var final_border_color = state_cfg.borderColor orelse base_border_color;

    // When suppress_when_focused is true and the character is focused, the border falls back to normal Active appearance instead of the Alert override color.
    const is_suppressed_alert = if (state == .Alert) blk: {
        if (thumbnail.notifications.newest()) |notif| {
            const notif_is_focused = thumbnail.isFocused(active_source_hwnd);
            break :blk notif.suppress_when_focused and notif_is_focused;
        }
        break :blk false;
    } else false;

    // Per-type border color override sits above the Alert StateVisualConfig but below per-character overrides; skipped when the alert is suppressed.
    if (state == .Alert and !is_suppressed_alert) {
        if (thumbnail.notifications.newest()) |notif| {
            if (notif.border_color_override) |color| {
                final_border_color = color;
            }
        }
    }

    // Fallback color for stacked notification lines that don't carry their own text_color_override.
    const notification_base_text_color = state_cfg.textColor orelse cfg.thumbnail.characterNameColor;

    // Per-character border color has the highest precedence; a suppressed Alert is treated as Active for border purposes.
    if (thumbnail.cached_border_colors) |char_colors| {
        if (state == .Active or (state == .Alert and is_suppressed_alert)) {
            if (char_colors.activeBorderColor) |color| {
                final_border_color = color;
            }
        } else if (state == .Inactive or state == .Minimized) {
            if (char_colors.inactiveBorderColor) |color| {
                final_border_color = color;
            }
        }
    }

    // Unique Character Name Colors takes precedence over the per-state color, same as border color above.
    var final_text_color = state_cfg.textColor orelse cfg.thumbnail.characterNameColor;
    if (thumbnail.cached_character_color) |unique_color| {
        final_text_color = unique_color;
    }

    // Read the already-sized window back rather than duplicating the region-fit grid math here.
    var overlay_width: c_int = undefined;
    var overlay_height: c_int = undefined;
    var used_live_size = false;
    if (cfg.display.layoutMode == .RegionFit) {
        var client_rect: win32.RECT = undefined;
        if (win32.GetClientRect(thumbnail.hwnd, &client_rect) != 0 and client_rect.right > 0 and client_rect.bottom > 0) {
            overlay_width = @intCast(client_rect.right);
            overlay_height = @intCast(client_rect.bottom);
            used_live_size = true;
        }
    }
    if (!used_live_size) {
        const char_size = thumbnail.cached_thumbnail_size;
        const logical_width = if (char_size) |cs| cs.width orelse cfg.thumbnail.width else cfg.thumbnail.width;
        const logical_height = if (char_size) |cs| cs.height orelse cfg.thumbnail.height else cfg.thumbnail.height;
        overlay_width = scalePixels(logical_width, dpi_scale);
        overlay_height = scalePixels(logical_height, dpi_scale);
    }

    // Builds the visible stack, newest first: each entry keeps its own suppress_when_focused/text_color_override,
    // so different notification types can be filtered and colored independently within the same stack.
    var notification_lines: [notification_stack_mod.CAPACITY]NotificationLine = .{NotificationLine{}} ** notification_stack_mod.CAPACITY;
    var notification_line_count: usize = 0;
    if (effective_show_notifications) {
        const notif_is_focused = thumbnail.isFocused(active_source_hwnd);
        for (thumbnail.notifications.items()) |notif| {
            if (notif.suppress_when_focused and notif_is_focused) continue;
            notification_lines[notification_line_count] = .{
                .text = notif.text,
                .color = notif.text_color_override orelse notification_base_text_color,
            };
            notification_line_count += 1;
        }
    }

    return .{
        .show_text = effective_show_text,
        .show_character_name = effective_show_character_name,
        .character_name = character_name,
        .show_system_name = effective_show_system_name,
        .system_name = system_name,
        .character_name_color = final_text_color,
        .system_name_color = system_color,
        .character_name_bg_color = resolveTextBgColor(state_cfg, cfg.thumbnail.characterNameBgColor, cfg.thumbnail.applyOpacityToOverlayTexts),
        .system_name_bg_color = resolveTextBgColor(state_cfg, cfg.thumbnail.systemNameBgColor, cfg.thumbnail.applyOpacityToOverlayTexts),
        .group_badge_bg_color = resolveTextBgColor(state_cfg, cfg.thumbnail.quickGroupBadgeBgColor, cfg.thumbnail.applyOpacityToOverlayTexts),
        .notifications_bg_color = resolveTextBgColor(state_cfg, cfg.thumbnail.notifications.bg_color, cfg.thumbnail.applyOpacityToOverlayTexts),
        .combat_incoming_bg_color = resolveTextBgColor(state_cfg, cfg.combat.incoming_bg_color, cfg.thumbnail.applyOpacityToOverlayTexts),
        .combat_outgoing_bg_color = resolveTextBgColor(state_cfg, cfg.combat.outgoing_bg_color, cfg.thumbnail.applyOpacityToOverlayTexts),
        .mining_bg_color = resolveTextBgColor(state_cfg, cfg.mining.bg_color, cfg.thumbnail.applyOpacityToOverlayTexts),
        .bounty_bg_color = resolveTextBgColor(state_cfg, cfg.bounty.bg_color, cfg.thumbnail.applyOpacityToOverlayTexts),
        .resources_bg_color = resolveTextBgColor(state_cfg, cfg.resources.bg_color, cfg.thumbnail.applyOpacityToOverlayTexts),
        .character_name_font_name = cfg.thumbnail.characterNameFontName,
        .character_name_font_size = scalePixels(cfg.thumbnail.characterNameFontSize, dpi_scale),
        .character_name_font_weight = cfg.thumbnail.characterNameFontWeight,
        .character_name_position = cfg.thumbnail.characterNamePosition,
        .character_name_offset_x = cfg.thumbnail.characterNameOffsetX,
        .character_name_offset_y = cfg.thumbnail.characterNameOffsetY,
        .system_name_position = cfg.thumbnail.systemNamePosition,
        .system_name_offset_x = cfg.thumbnail.systemNameOffsetX,
        .system_name_offset_y = cfg.thumbnail.systemNameOffsetY,
        .system_name_font_name = cfg.thumbnail.systemNameFontName,
        .system_name_font_size = scalePixels(cfg.thumbnail.systemNameFontSize, dpi_scale),
        .system_name_font_weight = cfg.thumbnail.systemNameFontWeight,
        .show_notifications = effective_show_notifications,
        .notification_lines = notification_lines,
        .notification_line_count = notification_line_count,
        .notifications_position = cfg.thumbnail.notifications.position,
        .notifications_offset_x = cfg.thumbnail.notifications.offset_x,
        .notifications_offset_y = cfg.thumbnail.notifications.offset_y,
        .notifications_font_name = cfg.thumbnail.notifications.font_name,
        .notifications_font_size = scalePixels(cfg.thumbnail.notifications.font_size, dpi_scale),
        .notifications_font_weight = cfg.thumbnail.notifications.font_weight,
        .show_border = effective_show_border,
        .border_width = state_cfg.borderWidth orelse base_border_width,
        .border_color = final_border_color,
        .border_style = state_cfg.borderStyle orelse base_border_style,
        .show_exclusion_overlay = blk: {
            const show = thumbnail.is_excluded_from_cycle and is_visible;
            if (thumbnail.is_excluded_from_cycle) {
                slog.debug("Render settings for {s}: is_excluded={}, is_visible={}, show_overlay={}", .{ character_name, thumbnail.is_excluded_from_cycle, is_visible, show });
            }
            break :blk show;
        },
        .exclusion_overlay_style = cfg.thumbnail.exclusionOverlayStyle,
        .exclusion_overlay_color = cfg.thumbnail.exclusionOverlayColor,
        .show_group_badge = effective_show_group_badge and thumbnail.cached_group_badge_label.len > 0 and is_visible,
        .group_badge_text = thumbnail.cached_group_badge_label,
        .group_badge_color = cfg.thumbnail.quickGroupBadgeColor,
        .group_badge_position = cfg.thumbnail.quickGroupBadgePosition,
        .group_badge_offset_x = cfg.thumbnail.quickGroupBadgeOffsetX,
        .group_badge_offset_y = cfg.thumbnail.quickGroupBadgeOffsetY,
        .group_badge_font_name = cfg.thumbnail.quickGroupBadgeFontName,
        .group_badge_font_size = scalePixels(cfg.thumbnail.quickGroupBadgeFontSize, dpi_scale),
        .group_badge_font_weight = cfg.thumbnail.quickGroupBadgeFontWeight,
        // visibility_state and per-character hideThumbnail take absolute priority over per-state showThumbnail config.
        .show_thumbnail = if (!is_visible or char_hidden) false else state_cfg.showThumbnail orelse base_show_thumbnail,
        .overlay_alpha = if (cfg.thumbnail.applyOpacityToOverlayTexts) thumbnail.cached_opacity else OVERLAY_ALPHA,
        .overlay_width = overlay_width,
        .overlay_height = overlay_height,
        // -1.0 stands in for "calculating" (null) here — no real rate is negative, and this struct only needs
        // equality for cache invalidation, not the calculating/zero distinction the render code below cares about.
        .dps_incoming = if (cfg.combat.enabled) (thumbnail.last_incoming_dps orelse -1.0) else 0.0,
        .dps_outgoing = if (cfg.combat.enabled) (thumbnail.last_outgoing_dps orelse -1.0) else 0.0,
        .mining_rate = if (cfg.mining.enabled) (thumbnail.last_mining_rate orelse -1.0) else 0.0,
        .mining_isk_rate = if (cfg.mining.enabled and cfg.mining.show_isk_rate) (thumbnail.last_mining_isk_rate orelse -1.0) else 0.0,
        .bounty_isk_rate = if (cfg.bounty.enabled) (thumbnail.last_bounty_isk_rate orelse -1.0) else 0.0,
        .resource_cpu_percent = if (cfg.resources.enabled) thumbnail.last_cpu_percent else 0.0,
        .resource_ram_mb = if (cfg.resources.enabled) thumbnail.last_ram_mb else 0.0,
        .resource_vram_mb = if (cfg.resources.enabled) thumbnail.last_vram_mb else 0.0,
        .has_dps_data = thumbnail.has_dps_data,
        .has_mining_data = thumbnail.has_mining_data,
        .has_bounty_data = thumbnail.has_bounty_data,
        .has_resource_data = cfg.resources.enabled and thumbnail.has_resource_data,
        .has_vram_data = thumbnail.has_vram_data,
        .dps_incoming_color = cfg.combat.incoming_color,
        .dps_outgoing_color = cfg.combat.outgoing_color,
        .mining_color = cfg.mining.color,
        .bounty_color = cfg.bounty.color,
        .resources_color = cfg.resources.color,
    };
}
