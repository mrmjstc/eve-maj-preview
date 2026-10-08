//! The ClientList view mode: one compact panel with a row per client, in place of thumbnail windows.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const fonts = @import("../platform/fonts.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const PanelWindow = @import("../platform/panel_window.zig").PanelWindow;
const config_mod = @import("../config.zig");
const types = @import("../config/types.zig");
const list_look = @import("list_look.zig");
const painter_mod = @import("../painter.zig");
const ThumbnailWindow = @import("window.zig").ThumbnailWindow;
const input = @import("input.zig");
const drag_panel = @import("../drag/panel.zig");
const template = @import("../notifications/template.zig");
const log = @import("../log.zig");

const slog = log.scoped("list_view");

const TEXT_BUF: usize = 256;
/// Kept clear for the right-hand slot when a long name is cut short.
const RIGHT_SLOT_MIN_WIDTH: i32 = 70;

const LIST_WINDOW_CLASS = "EVE_LIST_CLASS";

/// The fonts rows draw with, and their line heights.
const RowText = struct {
    name_font: win32.HFONT,
    small_font: win32.HFONT,
    name_height: i32,
    small_height: i32,
};

pub const ListWindow = struct {
    panel: PanelWindow,
    store: *config_mod.ProfileStore,
    config: *const config_mod.Config,
    /// Indices into the thumbnails render() was given, one per row in display order; hidden characters get none.
    rows: std.ArrayList(usize) = .empty,
    /// Each row's client, for clicks between renders.
    row_source_hwnds: std.ArrayList(win32.HWND) = .empty,
    /// The header's and right-hand slot's font.
    small_font: ?win32.HFONT = null,
    /// Owned; freed in deinit.
    small_font_name: []const u8 = "",
    small_font_size: i32 = 0,
    small_font_weight: fonts.FontWeight = .Regular,

    pub fn init(allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE) !ListWindow {
        const cfg = &store.live;
        try registerWindowClass(instance);
        const x = cfg.display.startX;
        const y = cfg.display.startY;
        const sizes = list_look.metrics(&cfg.display);
        const panel = try PanelWindow.create(allocator, instance, LIST_WINDOW_CLASS, "EVE Client List", .{ .left = x, .top = y, .right = x + sizes.column_width, .bottom = y + sizes.header_height });
        win32.setClickThroughStyle(panel.hwnd, cfg.interaction.clickThrough);
        return .{ .panel = panel, .store = store, .config = cfg };
    }

    pub fn deinit(self: *ListWindow) void {
        self.rows.deinit(self.panel.allocator);
        self.row_source_hwnds.deinit(self.panel.allocator);
        if (self.small_font) |font| _ = win32.DeleteObject(font);
        self.panel.allocator.free(self.small_font_name);
        self.panel.deinit();
    }

    /// Matches the panel to its configured position; whether it exists at all is the view mode's, which rebuilds the Painter.
    pub fn sync(self: *ListWindow) void {
        self.panel.followPosition(self.config.display.startX, self.config.display.startY);
        win32.setClickThroughStyle(self.panel.hwnd, self.config.interaction.clickThrough);
    }

    /// The client of the row at client point (`x`, `y`), from the last render; null over the header or an empty cell.
    fn rowSourceAt(self: *const ListWindow, x: i32, y: i32) ?win32.HWND {
        const sizes = list_look.metrics(&self.config.display);
        if (y < sizes.header_height) return null;
        const row: usize = @intCast(@divTrunc(y - sizes.header_height, sizes.row_height));
        const columns: i32 = list_look.effectiveColumns(self.config.display.listViewColumns, self.row_source_hwnds.items.len);
        const col: usize = @intCast(std.math.clamp(@divTrunc(x, sizes.column_width), 0, columns - 1));
        const index: usize = row * @as(usize, @intCast(columns)) + col;
        if (index >= self.row_source_hwnds.items.len) return null;
        return self.row_source_hwnds.items[index];
    }

    fn saveWindowPosition(self: *ListWindow) void {
        if (!self.config.display.rememberListViewPosition) return;
        const pos = self.panel.topLeft();
        self.store.update(.{ .display = .{ .startX = pos.x, .startY = pos.y } });
    }

    /// The list's active colour, or the character's own (or unique) active border colour.
    fn resolveActiveBadgeColor(self: *const ListWindow, thumb: *const ThumbnailWindow) u32 {
        if (thumb.cached_border_colors) |colors| {
            if (colors.activeBorderColor) |color| return color;
        }
        return self.config.display.listViewActiveColor;
    }

    /// Puts `rows` in the configured order and records each row's client.
    fn sortRows(self: *ListWindow, thumbnails: []const ThumbnailWindow) !void {
        const SortContext = struct {
            cfg: *const config_mod.Config,
            thumbnails: []const ThumbnailWindow,
            order_map: ?*const std.StringHashMap(usize),

            fn alphabeticalLessThan(a: *const ThumbnailWindow, b: *const ThumbnailWindow, a_index: usize, b_index: usize) bool {
                switch (std.ascii.orderIgnoreCase(a.cached_display_name, b.cached_display_name)) {
                    .lt => return true,
                    .gt => return false,
                    .eq => {},
                }
                switch (std.ascii.orderIgnoreCase(a.character_name, b.character_name)) {
                    .lt => return true,
                    .gt => return false,
                    .eq => return a_index < b_index,
                }
            }

            fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                const a = &ctx.thumbnails[a_index];
                const b = &ctx.thumbnails[b_index];
                return switch (ctx.cfg.display.listViewOrder) {
                    .Tracked => a_index < b_index,
                    .Alphabetical => alphabeticalLessThan(a, b, a_index, b_index),
                    .ConfiguredCharacters => config_mod.orderMapLessThan(ctx.order_map.?, a.character_name, b.character_name, a_index, b_index),
                };
            }
        };

        // Built once per sort instead of rescanning the configured characters in every comparison.
        var order_map: ?std.StringHashMap(usize) = null;
        defer if (order_map) |*m| m.deinit();
        if (self.config.display.listViewOrder == .ConfiguredCharacters) {
            order_map = try config_mod.buildCharacterOrderMap(self.config.characters.items, self.panel.allocator);
        }

        // Rows start in tracked order.
        if (self.config.display.listViewOrder != .Tracked) {
            std.sort.pdq(usize, self.rows.items, SortContext{
                .cfg = self.config,
                .thumbnails = thumbnails,
                .order_map = if (order_map) |*m| m else null,
            }, SortContext.lessThan);
        }

        try self.row_source_hwnds.resize(self.panel.allocator, self.rows.items.len);
        for (self.rows.items, self.row_source_hwnds.items) |thumb_index, *hwnd| hwnd.* = thumbnails[thumb_index].source_hwnd;
    }

    /// A hash of everything that affects the rendered pixels, to skip the redraw when nothing changed.
    fn computeRenderSignature(self: *const ListWindow, thumbnails: []const ThumbnailWindow, active_source_hwnd: ?win32.HWND) u64 {
        const display = &self.config.display;
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&self.rows.items.len));
        h.update(std.mem.asBytes(&display.listViewColumns));
        h.update(std.mem.asBytes(&display.listViewColumnWidth));
        h.update(std.mem.asBytes(&display.listViewOrder));
        h.update(std.mem.asBytes(&display.listViewOpacity));
        h.update(display.listViewFontName);
        h.update(std.mem.asBytes(&display.listViewFontSize));
        h.update(std.mem.asBytes(&display.listViewFontWeight));
        h.update(std.mem.asBytes(&display.listViewShowSystemName));
        h.update(std.mem.asBytes(&display.listViewIndicatorStyle));
        h.update(std.mem.asBytes(&display.listViewShowNotifications));
        h.update(std.mem.asBytes(&display.listViewShowIncomingDps));
        h.update(std.mem.asBytes(&display.listViewShowIncomingPrefix));
        h.update(std.mem.asBytes(&display.listViewIncomingDpsColor));
        h.update(std.mem.asBytes(&display.listViewShowOutgoingDps));
        h.update(std.mem.asBytes(&display.listViewShowOutgoingPrefix));
        h.update(std.mem.asBytes(&display.listViewOutgoingDpsColor));
        h.update(std.mem.asBytes(&display.listViewShowMiningRate));
        h.update(std.mem.asBytes(&display.listViewShowMiningPrefix));
        h.update(std.mem.asBytes(&display.listViewMiningRateColor));
        h.update(std.mem.asBytes(&display.listViewShowBountyRate));
        h.update(std.mem.asBytes(&display.listViewShowBountyPrefix));
        h.update(std.mem.asBytes(&display.listViewBountyRateColor));
        h.update(std.mem.asBytes(&self.config.combat.enabled));
        h.update(std.mem.asBytes(&self.config.mining.enabled));
        h.update(std.mem.asBytes(&self.config.bounty.enabled));
        h.update(std.mem.asBytes(&self.config.bounty.isk_rate_unit));
        // Rows are hashed before they're sorted, so the configured order has to be hashed itself.
        if (display.listViewOrder == .ConfiguredCharacters) {
            for (self.config.characters.items) |character| hashString(&h, character.name);
        }

        for (self.rows.items) |thumb_index| {
            const thumbnail = &thumbnails[thumb_index];
            const render_state = thumbnail.effectiveRenderState(active_source_hwnd);
            hashString(&h, thumbnail.character_name);
            hashString(&h, thumbnail.cached_display_name);
            hashString(&h, thumbnail.system_name);
            h.update(std.mem.asBytes(&render_state));
            h.update(std.mem.asBytes(&thumbnail.is_excluded_from_cycle));
            h.update(std.mem.asBytes(&thumbnail.stats.incoming_dps));
            h.update(std.mem.asBytes(&thumbnail.stats.outgoing_dps));
            h.update(std.mem.asBytes(&thumbnail.stats.mining_rate));
            h.update(std.mem.asBytes(&thumbnail.stats.bounty_isk_rate));
            h.update(std.mem.asBytes(&thumbnail.stats.has_dps));
            h.update(std.mem.asBytes(&thumbnail.stats.has_mining));
            h.update(std.mem.asBytes(&thumbnail.stats.has_bounty));
            if (thumbnail.system_name.len > 0) h.update(std.mem.asBytes(&thumbnail.cached_system_color));
            if (thumbnail.cached_character_color) |cc| h.update(std.mem.asBytes(&cc));
            if (render_state == .active) {
                const badge_color = self.resolveActiveBadgeColor(thumbnail);
                h.update(std.mem.asBytes(&badge_color));
            }
            for (thumbnail.notifications.items()) |notif| {
                hashString(&h, notif.text);
                h.update(std.mem.asBytes(&notif.border_color_override));
                h.update(std.mem.asBytes(&notif.text_color_override));
            }
        }

        return h.final();
    }

    /// The row's combat, mining and bounty rates the list shows, in writing order; empty when none is.
    fn statReadings(self: *const ListWindow, thumb: *const ThumbnailWindow, out: *[list_look.STAT_COUNT]list_look.StatReading) []const list_look.StatReading {
        const cfg = self.config;
        const settings: list_look.StatSettings = .{ .display = &cfg.display, .combat = &cfg.combat, .mining = &cfg.mining, .bounty = &cfg.bounty };
        const stats = &thumb.stats;
        const bounty_period_seconds: f32 = if (cfg.bounty.isk_rate_unit == .hour) 3600.0 else 60.0;
        var count: usize = 0;
        for (std.enums.values(list_look.Stat)) |stat| {
            if (!list_look.showsStat(settings, stat)) continue;
            const value: ?f32 = switch (stat) {
                .incoming_dps => if (stats.showsIncoming()) stats.incoming_dps else continue,
                .outgoing_dps => if (stats.showsOutgoing()) stats.outgoing_dps else continue,
                .mining_rate => if (stats.showsMining()) (if (stats.mining_rate) |rate| rate * 60.0 else null) else continue,
                .bounty_rate => if (stats.showsBounty()) (if (stats.bounty_isk_rate) |rate| rate * bounty_period_seconds else null) else continue,
            };
            out[count] = .{ .stat = stat, .value = value, .has_prefix = list_look.hasPrefix(&cfg.display, stat) };
            count += 1;
        }
        return out[0..count];
    }

    /// Called every painter tick; redraws only when the render signature changed.
    pub fn render(self: *ListWindow, thumbnails: []const ThumbnailWindow, active_source_hwnd: ?win32.HWND) !void {
        const display = &self.config.display;
        try self.panel.ensureFont("List View", display.listViewFontName, display.listViewFontSize, display.listViewFontWeight);
        try gdi_overlay.ensureFont(self.panel.allocator, "List View small", &self.small_font, &self.small_font_name, &self.small_font_size, &self.small_font_weight, display.listViewFontName, list_look.smallFontSize(display.listViewFontSize), display.listViewFontWeight);

        self.rows.clearRetainingCapacity();
        var any_visible = false;
        for (thumbnails, 0..) |*thumbnail, i| {
            if (thumbnail.cached_hide_thumbnail) continue;
            try self.rows.append(self.panel.allocator, i);
            if (thumbnail.visibility_state == .visible) any_visible = true;
        }
        // Also hidden once the visibility toggle or auto-hide has hidden every client.
        if (!any_visible) {
            self.panel.hide();
            return;
        }

        const signature = self.computeRenderSignature(thumbnails, active_source_hwnd);
        if (self.panel.isUnchanged(signature)) return;

        try self.sortRows(thumbnails);

        const count: i32 = @intCast(self.rows.items.len);
        const columns = list_look.effectiveColumns(display.listViewColumns, self.rows.items.len);
        const sizes = list_look.metrics(display);
        const rows_per_column: i32 = @divTrunc(count + columns - 1, columns);
        const bitmap = try self.panel.beginFrame(columns * sizes.column_width, sizes.header_height + rows_per_column * sizes.row_height + list_look.BOTTOM_PADDING);
        const width: usize = bitmap.width;
        const height: usize = bitmap.height;
        const dc = bitmap.mem_dc;

        gdi_overlay.fillRect(bitmap.pixels, width, height, 0, 0, width, height, list_look.PANEL);
        gdi_overlay.fillRect(bitmap.pixels, width, height, 0, @intCast(sizes.header_height - 1), width, 1, list_look.DIVIDER);

        var row_text: ?RowText = null;
        var old_font: ?win32.HANDLE = null;
        if (self.panel.font) |name_font| {
            if (self.small_font) |small_font| {
                old_font = win32.SelectObject(dc, small_font);
                const small_height = lineHeight(dc);
                var header_buf: [list_look.HEADER_TEXT_MAX]u8 = undefined;
                drawText(dc, list_look.headerText(&header_buf, self.rows.items.len), list_look.PADDING_X, @divTrunc(sizes.header_height - small_height, 2), list_look.MUTED);
                _ = win32.SelectObject(dc, name_font);
                row_text = .{ .name_font = name_font, .small_font = small_font, .name_height = lineHeight(dc), .small_height = small_height };
            }
        }
        // A font still selected into the DC can't be deleted when the settings change.
        defer if (old_font) |font| {
            _ = win32.SelectObject(dc, font);
        };

        for (self.rows.items, 0..) |thumb_index, i| self.drawRow(bitmap, &thumbnails[thumb_index], i, columns, sizes, row_text, active_source_hwnd);

        gdi_overlay.fixTextAlpha(bitmap.pixels, width, height);
        drawFrame(bitmap);

        self.panel.present(display.listViewOpacity, signature);
    }

    /// Row `i` in display order: its tint, status badge, name, and one right-hand slot for a notification, stats or system.
    fn drawRow(self: *const ListWindow, bitmap: *const gdi_overlay.OverlayBitmap, thumb: *const ThumbnailWindow, i: usize, columns: i32, sizes: list_look.Metrics, row_text: ?RowText, active_source_hwnd: ?win32.HWND) void {
        const display = &self.config.display;
        const width: usize = bitmap.width;
        const height: usize = bitmap.height;
        const columns_u: usize = @intCast(columns);
        const row: i32 = @intCast(i / columns_u);
        const col: i32 = @intCast(i % columns_u);
        const row_top: i32 = sizes.header_height + row * sizes.row_height;
        const col_left: i32 = col * sizes.column_width;
        const render_state = thumb.effectiveRenderState(active_source_hwnd);
        const is_active = render_state == .active;
        const is_alert = render_state == .alert;
        const is_excluded = thumb.is_excluded_from_cycle;
        const active_color = self.resolveActiveBadgeColor(thumb);

        const tint: ?u32 = if (is_alert)
            list_look.alertTint(alertColor(thumb))
        else if (is_active)
            list_look.activeTint(active_color)
        else
            null;
        if (tint) |row_bg| gdi_overlay.fillRect(bitmap.pixels, width, height, @intCast(col_left), @intCast(row_top), @intCast(sizes.column_width), @intCast(sizes.row_height), row_bg);

        const badge_color: u32 = if (is_excluded)
            list_look.BADGE_EXCLUDED
        else if (is_active)
            active_color
        else if (is_alert)
            list_look.BADGE_ALERT
        else if (render_state == .minimized)
            list_look.BADGE_MINIMIZED
        else
            list_look.BADGE_INACTIVE;
        const indicator_style = display.listViewIndicatorStyle;
        drawIndicator(bitmap, indicator_style, col_left, row_top, sizes.row_height, badge_color);

        const text = row_text orelse return;
        const dc = bitmap.mem_dc;
        const name_offset = list_look.textLeft(indicator_style);
        const text_left = col_left + name_offset;

        _ = win32.SelectObject(dc, text.name_font);
        const name_y = row_top + @divTrunc(sizes.row_height - text.name_height, 2);
        const name_color: u32 = if (is_excluded)
            list_look.MUTED
        else
            thumb.cached_character_color orelse if (is_active) list_look.activeNameColor(active_color) else list_look.NAME;
        const max_name_w: usize = @intCast(sizes.column_width - name_offset - list_look.PADDING_X - RIGHT_SLOT_MIN_WIDTH);
        if (measureTextWidth(dc, thumb.cached_display_name) <= max_name_w) {
            drawText(dc, thumb.cached_display_name, text_left, name_y, name_color);
        } else {
            drawTextTruncated(dc, thumb.cached_display_name, text_left, name_y, name_color, max_name_w);
        }

        var readings_buf: [list_look.STAT_COUNT]list_look.StatReading = undefined;
        const readings = self.statReadings(thumb, &readings_buf);

        _ = win32.SelectObject(dc, text.small_font);
        const small_y = row_top + @divTrunc(sizes.row_height - text.small_height, 2);
        const right_x = col_left + sizes.column_width - list_look.PADDING_X;

        // One slot only: the newest notification wins, then stats, then exclusion, then the system.
        var notif_buf: [TEXT_BUF]u8 = undefined;
        const newest = if (display.listViewShowNotifications) thumb.notifications.newest() else null;
        if (newest) |notif| {
            drawTextRight(dc, template.oneLine(notif.text, &notif_buf), right_x, small_y, notif.text_color_override orelse list_look.NOTIFICATION_TEXT, text_left);
        } else if (readings.len > 0) {
            drawStatsRight(dc, display, readings, right_x, small_y, text_left);
        } else if (is_excluded) {
            drawTextRight(dc, "Excluded", right_x, small_y, list_look.MUTED, text_left);
        } else if (display.listViewShowSystemName and thumb.system_name.len > 0) {
            drawTextRight(dc, thumb.system_name, right_x, small_y, thumb.cached_system_color, text_left);
        }
    }
};

var g_class_registered: bool = false;

/// The newest notification's border colour, which tints an alerting row.
fn alertColor(thumb: *const ThumbnailWindow) u32 {
    const notif = thumb.notifications.newest() orelse return list_look.BADGE_ALERT;
    return notif.border_color_override orelse list_look.BADGE_ALERT;
}

/// A 1px border with rounded corners; outside them the pixels are cleared so the desktop shows through.
fn drawFrame(bitmap: *const gdi_overlay.OverlayBitmap) void {
    const width: usize = bitmap.width;
    const height: usize = bitmap.height;
    gdi_overlay.fillRect(bitmap.pixels, width, height, 0, 0, width, 1, list_look.BORDER);
    gdi_overlay.fillRect(bitmap.pixels, width, height, 0, height - 1, width, 1, list_look.BORDER);
    gdi_overlay.fillRect(bitmap.pixels, width, height, 0, 0, 1, height, list_look.BORDER);
    gdi_overlay.fillRect(bitmap.pixels, width, height, width - 1, 0, 1, height, list_look.BORDER);
    if (width < 2 * list_look.CORNER_RADIUS or height < 2 * list_look.CORNER_RADIUS) return;

    const radius: f32 = @floatFromInt(list_look.CORNER_RADIUS);
    for (0..list_look.CORNER_RADIUS) |dy| {
        for (0..list_look.CORNER_RADIUS) |dx| {
            // From the corner arc's centre to this pixel's centre.
            const fx = radius - @as(f32, @floatFromInt(dx)) - 0.5;
            const fy = radius - @as(f32, @floatFromInt(dy)) - 0.5;
            const distance = @sqrt(fx * fx + fy * fy);
            const pixel: u32 = if (distance > radius) 0 else if (distance > radius - 1) list_look.BORDER else continue;
            bitmap.pixels[dy * width + dx] = pixel;
            bitmap.pixels[dy * width + width - 1 - dx] = pixel;
            bitmap.pixels[(height - 1 - dy) * width + dx] = pixel;
            bitmap.pixels[(height - 1 - dy) * width + width - 1 - dx] = pixel;
        }
    }
}

fn registerWindowClass(instance: win32.HINSTANCE) !void {
    if (g_class_registered) return;
    try gdi_overlay.registerWindowClass(instance, listWindowProc, LIST_WINDOW_CLASS, null);
    g_class_registered = true;
}

fn listWindow() ?*ListWindow {
    const painter = painter_mod.g_painter_ptr orelse return null;
    return if (painter.list_window) |*list_window| list_window else null;
}

fn listWindowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    // The painter only holds the list once its window exists, so creation's messages go without a header.
    const header_height = if (listWindow()) |list_window| list_look.metrics(&list_window.config.display).header_height else 0;
    if (drag_panel.handleMessage(hwnd, msg, lParam, header_height)) |result| return result;
    switch (msg) {
        win32.WM_ENTERSIZEMOVE => {
            drag_panel.beginPanelDrag(hwnd);
            return 0;
        },
        win32.WM_EXITSIZEMOVE => {
            if (listWindow()) |list_window| list_window.saveWindowPosition();
            return 0;
        },
        win32.WM_LBUTTONDOWN => {
            const list_window = listWindow() orelse return 0;
            const source_hwnd = list_window.rowSourceAt(win32.lparamX(lParam), win32.lparamY(lParam)) orelse return 0;
            input.press(hwnd, source_hwnd);
            return 0;
        },
        win32.WM_LBUTTONUP => {
            input.release(hwnd);
            return 0;
        },
        win32.WM_SETCURSOR => {
            // Rows only: the header is the drag handle.
            const hit_test: win32.LRESULT = @as(u16, @truncate(@as(usize, @bitCast(lParam))));
            if (hit_test == win32.HTCLIENT and input.applyHoverCursor()) return 1;
            return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
        },
        else => return win32.DefWindowProcA(hwnd, msg, wParam, lParam),
    }
}

/// The row's state marker in `style`, for the row whose top-left is `col_left`, `row_top`.
fn drawIndicator(bitmap: *const gdi_overlay.OverlayBitmap, style: types.ListIndicatorStyle, col_left: i32, row_top: i32, row_height: i32, argb: u32) void {
    const width: usize = bitmap.width;
    const height: usize = bitmap.height;
    const radius = list_look.BADGE_RADIUS;
    const cx = col_left + list_look.PADDING_X + radius;
    const cy = row_top + @divTrunc(row_height, 2);
    switch (style) {
        .Dot => drawDot(bitmap.pixels, width, height, cx, cy, radius, argb),
        .Square => gdi_overlay.fillRect(bitmap.pixels, width, height, @intCast(cx - radius), @intCast(cy - radius), @intCast(radius * 2), @intCast(radius * 2), argb),
        .Bar => gdi_overlay.fillRect(bitmap.pixels, width, height, @intCast(col_left + list_look.BORDER_WIDTH), @intCast(row_top), @intCast(list_look.BAR_WIDTH), @intCast(row_height), argb),
        .None => {},
    }
}

fn drawDot(pixels: [*]u32, width: usize, height: usize, cx: i32, cy: i32, r: i32, argb: u32) void {
    const r2 = r * r;
    var dy: i32 = -r;
    while (dy <= r) : (dy += 1) {
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            if (dx * dx + dy * dy <= r2) {
                const px: i32 = cx + dx;
                const py: i32 = cy + dy;
                if (px >= 0 and py >= 0 and @as(usize, @intCast(px)) < width and @as(usize, @intCast(py)) < height) {
                    pixels[@as(usize, @intCast(py)) * width + @as(usize, @intCast(px))] = argb;
                }
            }
        }
    }
}

/// Ignores `color`'s alpha byte.
fn drawText(dc: win32.HDC, text: []const u8, x: i32, y: i32, color: u32) void {
    _ = win32.SetBkMode(dc, win32.TRANSPARENT);
    const buf = gdi_overlay.toBufZ(TEXT_BUF, text);
    const n = @min(text.len, TEXT_BUF - 1);
    _ = win32.SetTextColor(dc, gdi_overlay.toColorRef(color & 0x00FF_FFFF));
    _ = win32.TextOutA(dc, x, y, &buf, @intCast(n));
}

/// The selected font's line height.
fn lineHeight(dc: win32.HDC) i32 {
    return gdi_overlay.measureTextSize(TEXT_BUF, dc, "Ag").cy;
}

fn measureTextWidth(dc: win32.HDC, text: []const u8) usize {
    return gdi_overlay.measureTextWidth(TEXT_BUF, dc, text);
}

/// Right edge at `right_x`; skipped rather than drawn left of `min_x`, where it would overlap the name.
fn drawTextRight(dc: win32.HDC, text: []const u8, right_x: i32, y: i32, rgb: u32, min_x: i32) void {
    const n = @min(text.len, TEXT_BUF - 1);
    const x = right_x - @as(i32, @intCast(measureTextWidth(dc, text[0..n])));
    if (x < min_x) return;
    drawText(dc, text[0..n], x, y, rgb);
}

/// Right-aligned at `right_x`, each reading in its own colour a space apart; skipped like drawTextRight rather than drawn left of `min_x`.
fn drawStatsRight(dc: win32.HDC, display: *const config_mod.DisplayConfig, readings: []const list_look.StatReading, right_x: i32, y: i32, min_x: i32) void {
    var texts: [list_look.STAT_COUNT][list_look.STAT_TEXT_MAX]u8 = undefined;
    var lengths: [list_look.STAT_COUNT]usize = undefined;
    var widths: [list_look.STAT_COUNT]i32 = undefined;
    const gap: i32 = @intCast(measureTextWidth(dc, " "));
    var total: i32 = 0;
    for (readings, 0..) |reading, index| {
        var writer: std.Io.Writer = .fixed(&texts[index]);
        list_look.writeStat(&writer, reading);
        lengths[index] = writer.buffered().len;
        widths[index] = @intCast(measureTextWidth(dc, texts[index][0..lengths[index]]));
        total += widths[index];
        if (index > 0) total += gap;
    }
    var x = right_x - total;
    if (x < min_x) return;
    for (readings, 0..) |reading, index| {
        drawText(dc, texts[index][0..lengths[index]], x, y, list_look.statColor(display, reading.stat));
        x += widths[index] + gap;
    }
}

/// Truncated with "..." to fit `max_w` pixels.
fn drawTextTruncated(dc: win32.HDC, text: []const u8, x: i32, y: i32, rgb: u32, max_w: usize) void {
    var out: [TEXT_BUF:0]u8 = undefined;
    const truncated = gdi_overlay.truncateTextToFit(TEXT_BUF, dc, &out, text, max_w);
    drawText(dc, truncated, x, y, rgb);
}

/// Length-prefixed, so swapping "Bob" and "BobBob" can't leave the hashed byte stream unchanged.
fn hashString(h: *std.hash.Wyhash, text: []const u8) void {
    h.update(std.mem.asBytes(&text.len));
    h.update(text);
}
