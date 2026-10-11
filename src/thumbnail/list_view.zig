//! The ClientList view mode: one compact panel with a row per client, in place of thumbnail windows.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const panel_window = @import("../platform/panel_window.zig");
const config_mod = @import("../config.zig");
const types = @import("../config/types.zig");
const list_look = @import("list_look.zig");
const painter_mod = @import("../painter.zig");
const window = @import("window.zig");
const input = @import("input.zig");
const drag_panel = @import("../drag/panel.zig");
const template = @import("../notifications/template.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");

const PanelWindow = panel_window.PanelWindow;
const ThumbnailWindow = window.ThumbnailWindow;

const TEXT_BUFFER_SIZE: usize = 256;
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
    /// Borrows store.live.
    config: *const config_mod.Config,
    /// Indices into the thumbnails render() was given, one per row in display order; hidden characters get none.
    rows: std.ArrayList(usize) = .empty,
    /// Each row's client, for clicks between renders.
    row_source_hwnds: std.ArrayList(win32.HWND) = .empty,

    pub fn init(allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE) !ListWindow {
        const config = &store.live;
        try registerWindowClass(instance);
        const x = config.display.startX;
        const y = config.display.startY;
        const sizes = list_look.metrics(&config.display);
        const panel = try PanelWindow.init(allocator, instance, LIST_WINDOW_CLASS, "EVE Client List", .{ .left = x, .top = y, .right = x + sizes.column_width, .bottom = y + sizes.header_height });
        win32.setClickThroughStyle(panel.hwnd, config.interaction.clickThrough);
        return .{ .panel = panel, .store = store, .config = config };
    }

    pub fn deinit(self: *ListWindow) void {
        self.rows.deinit(self.panel.allocator);
        self.row_source_hwnds.deinit(self.panel.allocator);
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
        const column: usize = @intCast(std.math.clamp(@divTrunc(x, sizes.column_width), 0, columns - 1));
        const index: usize = row * @as(usize, @intCast(columns)) + column;
        if (index >= self.row_source_hwnds.items.len) return null;
        return self.row_source_hwnds.items[index];
    }

    fn saveWindowPosition(self: *const ListWindow) void {
        if (!self.config.display.rememberListViewPosition) return;
        const top_left = self.panel.topLeft();
        self.store.update(.{ .display = .{ .startX = top_left.x, .startY = top_left.y } });
    }

    /// The list's active colour, or the character's own (or unique) active border colour.
    fn resolveActiveBadgeColor(self: *const ListWindow, thumbnail: *const ThumbnailWindow) u32 {
        if (thumbnail.cached_border_colors) |colors| {
            if (colors.activeBorderColor) |color| return color;
        }
        return self.config.display.listViewActiveColor;
    }

    /// Puts `rows` in the configured order and records each row's client.
    fn sortRows(self: *ListWindow, thumbnails: []const ThumbnailWindow) !void {
        const SortContext = struct {
            config: *const config_mod.Config,
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

            fn lessThan(context: @This(), a_index: usize, b_index: usize) bool {
                const a = &context.thumbnails[a_index];
                const b = &context.thumbnails[b_index];
                return switch (context.config.display.listViewOrder) {
                    .Tracked => a_index < b_index,
                    .Alphabetical => alphabeticalLessThan(a, b, a_index, b_index),
                    .ConfiguredCharacters => config_mod.orderMapLessThan(context.order_map.?, a.character_name, b.character_name, a_index, b_index),
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
                .config = self.config,
                .thumbnails = thumbnails,
                .order_map = if (order_map) |*m| m else null,
            }, SortContext.lessThan);
        }

        try self.row_source_hwnds.resize(self.panel.allocator, self.rows.items.len);
        for (self.rows.items, self.row_source_hwnds.items) |thumbnail_index, *hwnd| hwnd.* = thumbnails[thumbnail_index].source_hwnd;
    }

    /// A hash of everything that affects the rendered pixels, to skip the redraw when nothing changed.
    fn computeRenderSignature(self: *const ListWindow, thumbnails: []const ThumbnailWindow, active_source_hwnd: ?win32.HWND) u64 {
        const display = &self.config.display;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&self.rows.items.len));
        hasher.update(std.mem.asBytes(&display.listViewColumns));
        hasher.update(std.mem.asBytes(&display.listViewColumnWidth));
        hasher.update(std.mem.asBytes(&display.listViewOrder));
        hasher.update(std.mem.asBytes(&display.listViewOpacity));
        hasher.update(display.listViewFontName);
        hasher.update(std.mem.asBytes(&display.listViewFontSize));
        hasher.update(std.mem.asBytes(&display.listViewFontWeight));
        hasher.update(std.mem.asBytes(&display.listViewShowSystemName));
        hasher.update(std.mem.asBytes(&display.listViewIndicatorStyle));
        hasher.update(std.mem.asBytes(&display.listViewShowNotifications));
        hasher.update(std.mem.asBytes(&display.listViewNotificationColor));
        hasher.update(std.mem.asBytes(&display.listViewShowIncomingDps));
        hasher.update(std.mem.asBytes(&display.listViewShowIncomingPrefix));
        hasher.update(std.mem.asBytes(&display.listViewIncomingDpsColor));
        hasher.update(std.mem.asBytes(&display.listViewShowOutgoingDps));
        hasher.update(std.mem.asBytes(&display.listViewShowOutgoingPrefix));
        hasher.update(std.mem.asBytes(&display.listViewOutgoingDpsColor));
        hasher.update(std.mem.asBytes(&display.listViewShowMiningRate));
        hasher.update(std.mem.asBytes(&display.listViewShowMiningPrefix));
        hasher.update(std.mem.asBytes(&display.listViewMiningRateColor));
        hasher.update(std.mem.asBytes(&display.listViewShowBountyRate));
        hasher.update(std.mem.asBytes(&display.listViewShowBountyPrefix));
        hasher.update(std.mem.asBytes(&display.listViewBountyRateColor));
        hasher.update(std.mem.asBytes(&self.config.combat.enabled));
        hasher.update(std.mem.asBytes(&self.config.mining.enabled));
        hasher.update(std.mem.asBytes(&self.config.bounty.enabled));
        hasher.update(std.mem.asBytes(&self.config.bounty.isk_rate_unit));
        // Rows are hashed before they're sorted, so the configured order has to be hashed itself.
        if (display.listViewOrder == .ConfiguredCharacters) {
            for (self.config.characters.items) |character| hashString(&hasher, character.name);
        }

        for (self.rows.items) |thumbnail_index| {
            const thumbnail = &thumbnails[thumbnail_index];
            const render_state = thumbnail.effectiveRenderState(active_source_hwnd);
            hashString(&hasher, thumbnail.character_name);
            hashString(&hasher, thumbnail.cached_display_name);
            hashString(&hasher, thumbnail.system_name);
            hasher.update(std.mem.asBytes(&render_state));
            hasher.update(std.mem.asBytes(&thumbnail.is_excluded_from_cycle));
            hasher.update(std.mem.asBytes(&thumbnail.stats.incoming_dps));
            hasher.update(std.mem.asBytes(&thumbnail.stats.outgoing_dps));
            hasher.update(std.mem.asBytes(&thumbnail.stats.mining_rate));
            hasher.update(std.mem.asBytes(&thumbnail.stats.bounty_isk_rate));
            hasher.update(std.mem.asBytes(&thumbnail.stats.has_dps));
            hasher.update(std.mem.asBytes(&thumbnail.stats.has_mining));
            hasher.update(std.mem.asBytes(&thumbnail.stats.has_bounty));
            if (thumbnail.system_name.len > 0) hasher.update(std.mem.asBytes(&thumbnail.cached_system_color));
            if (thumbnail.cached_character_color) |cc| hasher.update(std.mem.asBytes(&cc));
            if (render_state == .active) {
                const badge_color = self.resolveActiveBadgeColor(thumbnail);
                hasher.update(std.mem.asBytes(&badge_color));
            }
            for (thumbnail.notifications.items()) |notification| {
                hashString(&hasher, notification.text);
                hasher.update(std.mem.asBytes(&notification.border_color_override));
                hasher.update(std.mem.asBytes(&notification.text_color_override));
            }
        }

        return hasher.final();
    }

    /// The row's combat, mining and bounty rates the list shows, in writing order; empty when none is.
    fn statReadings(self: *const ListWindow, thumbnail: *const ThumbnailWindow, out: *[list_look.STAT_COUNT]list_look.StatReading) []const list_look.StatReading {
        const config = self.config;
        const settings: list_look.StatSettings = .{ .display = &config.display, .combat = &config.combat, .mining = &config.mining, .bounty = &config.bounty };
        const stats = &thumbnail.stats;
        const bounty_period_seconds = config.bounty.isk_rate_unit.seconds();
        var count: usize = 0;
        for (std.enums.values(list_look.Stat)) |stat| {
            if (!list_look.showsStat(settings, stat)) continue;
            const value: ?f32 = switch (stat) {
                .incoming_dps => if (stats.showsIncoming()) stats.incoming_dps else continue,
                .outgoing_dps => if (stats.showsOutgoing()) stats.outgoing_dps else continue,
                .mining_rate => if (stats.showsMining()) (if (stats.mining_rate) |rate| rate * 60.0 else null) else continue,
                .bounty_rate => if (stats.showsBounty()) (if (stats.bounty_isk_rate) |rate| rate * bounty_period_seconds else null) else continue,
            };
            out[count] = .{ .stat = stat, .value = value, .has_prefix = list_look.hasPrefix(&config.display, stat) };
            count += 1;
        }
        return out[0..count];
    }

    /// Called every painter tick; redraws only when the render signature changed.
    pub fn render(self: *ListWindow, thumbnails: []const ThumbnailWindow, active_source_hwnd: ?win32.HWND) !void {
        const display = &self.config.display;
        try self.panel.ensureFont("List View", display.listViewFontName, display.listViewFontSize, display.listViewFontWeight);
        try self.panel.ensureSmallFont("List View small", display.listViewFontName, list_look.smallFontSize(display.listViewFontSize), display.listViewFontWeight);

        self.rows.clearRetainingCapacity();
        var has_visible_row = false;
        for (thumbnails, 0..) |*thumbnail, i| {
            if (thumbnail.cached_hide_thumbnail) continue;
            try self.rows.append(self.panel.allocator, i);
            if (thumbnail.visibility_state == .visible) has_visible_row = true;
        }
        // Also hidden once the visibility toggle or auto-hide has hidden every client.
        if (!has_visible_row) {
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

        pixel_buffer.fillRect(bitmap.pixels, width, height, 0, 0, width, height, list_look.PANEL);
        pixel_buffer.fillRect(bitmap.pixels, width, height, 0, @intCast(sizes.header_height - 1), width, 1, list_look.DIVIDER);

        var row_text: ?RowText = null;
        var old_font: ?win32.HANDLE = null;
        if (self.panel.font) |name_font| {
            if (self.panel.small_font) |small_font| {
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

        for (self.rows.items, 0..) |thumbnail_index, row_index| self.drawRow(bitmap, &thumbnails[thumbnail_index], row_index, columns, sizes, row_text, active_source_hwnd);

        pixel_buffer.fixTextAlpha(bitmap.pixels, width, height);
        pixel_buffer.drawRoundedFrame(bitmap.pixels, bitmap.width, bitmap.height, list_look.CORNER_RADIUS, list_look.BORDER);

        self.panel.present(display.listViewOpacity, signature);
    }

    /// Row `row_index` in display order: its tint, status badge, name, and one right-hand slot for a notification, stats or system.
    fn drawRow(self: *const ListWindow, bitmap: *const gdi_overlay.OverlayBitmap, thumbnail: *const ThumbnailWindow, row_index: usize, columns: i32, sizes: list_look.Metrics, row_text: ?RowText, active_source_hwnd: ?win32.HWND) void {
        const display = &self.config.display;
        const width: usize = bitmap.width;
        const height: usize = bitmap.height;
        const columns_u: usize = @intCast(columns);
        const row: i32 = @intCast(row_index / columns_u);
        const column: i32 = @intCast(row_index % columns_u);
        const row_top: i32 = sizes.header_height + row * sizes.row_height;
        const column_left: i32 = column * sizes.column_width;
        const render_state = thumbnail.effectiveRenderState(active_source_hwnd);
        const is_active = render_state == .active;
        const is_alert = render_state == .alert;
        const is_excluded = thumbnail.is_excluded_from_cycle;
        const active_color = self.resolveActiveBadgeColor(thumbnail);

        const tint: ?u32 = if (is_alert)
            list_look.alertTint(alertColor(thumbnail))
        else if (is_active)
            list_look.activeTint(active_color)
        else
            null;
        if (tint) |row_bg| pixel_buffer.fillRect(bitmap.pixels, width, height, @intCast(column_left), @intCast(row_top), @intCast(sizes.column_width), @intCast(sizes.row_height), row_bg);

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
        drawIndicator(bitmap, indicator_style, column_left, row_top, sizes.row_height, badge_color);

        const text = row_text orelse return;
        const dc = bitmap.mem_dc;
        const name_offset = list_look.textLeft(indicator_style);
        const text_left = column_left + name_offset;

        _ = win32.SelectObject(dc, text.name_font);
        const name_y = row_top + @divTrunc(sizes.row_height - text.name_height, 2);
        const name_color: u32 = if (is_excluded)
            list_look.MUTED
        else
            thumbnail.cached_character_color orelse if (is_active) list_look.activeNameColor(active_color) else list_look.NAME;
        const max_name_width: usize = @intCast(sizes.column_width - name_offset - list_look.PADDING_X - RIGHT_SLOT_MIN_WIDTH);
        if (measureTextWidth(dc, thumbnail.cached_display_name) <= max_name_width) {
            drawText(dc, thumbnail.cached_display_name, text_left, name_y, name_color);
        } else {
            drawTextTruncated(dc, thumbnail.cached_display_name, text_left, name_y, name_color, max_name_width);
        }

        var readings_buf: [list_look.STAT_COUNT]list_look.StatReading = undefined;
        const readings = self.statReadings(thumbnail, &readings_buf);

        _ = win32.SelectObject(dc, text.small_font);
        const small_y = row_top + @divTrunc(sizes.row_height - text.small_height, 2);
        const right_x = column_left + sizes.column_width - list_look.PADDING_X;

        // One slot only: the newest notification wins, then stats, then exclusion, then the system.
        var notification_buffer: [TEXT_BUFFER_SIZE]u8 = undefined;
        const newest = if (display.listViewShowNotifications) thumbnail.notifications.newest() else null;
        if (newest) |notification| {
            drawTextRight(dc, template.oneLine(notification.text, &notification_buffer), right_x, small_y, notification.text_color_override orelse display.listViewNotificationColor, text_left);
        } else if (readings.len > 0) {
            drawStatsRight(dc, display, readings, right_x, small_y, text_left);
        } else if (is_excluded) {
            drawTextRight(dc, "Excluded", right_x, small_y, list_look.MUTED, text_left);
        } else if (display.listViewShowSystemName and thumbnail.system_name.len > 0) {
            drawTextRight(dc, thumbnail.system_name, right_x, small_y, thumbnail.cached_system_color, text_left);
        }
    }
};

var g_class_registered: bool = false;

/// The newest notification's border colour, which tints an alerting row.
fn alertColor(thumbnail: *const ThumbnailWindow) u32 {
    const notification = thumbnail.notifications.newest() orelse return list_look.BADGE_ALERT;
    return notification.border_color_override orelse list_look.BADGE_ALERT;
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

/// The row's state marker in `style`, for the row whose top-left is `column_left`, `row_top`.
fn drawIndicator(bitmap: *const gdi_overlay.OverlayBitmap, style: types.ListIndicatorStyle, column_left: i32, row_top: i32, row_height: i32, argb: u32) void {
    const width: usize = bitmap.width;
    const height: usize = bitmap.height;
    const radius = list_look.BADGE_RADIUS;
    const center_x = column_left + list_look.PADDING_X + radius;
    const center_y = row_top + @divTrunc(row_height, 2);
    switch (style) {
        .Dot => drawDot(bitmap.pixels, width, height, center_x, center_y, radius, argb),
        .Square => pixel_buffer.fillRect(bitmap.pixels, width, height, @intCast(center_x - radius), @intCast(center_y - radius), @intCast(radius * 2), @intCast(radius * 2), argb),
        .None => {},
    }
}

fn drawDot(pixels: [*]u32, width: usize, height: usize, center_x: i32, center_y: i32, radius: i32, argb: u32) void {
    const radius_squared = radius * radius;
    var dy: i32 = -radius;
    while (dy <= radius) : (dy += 1) {
        var dx: i32 = -radius;
        while (dx <= radius) : (dx += 1) {
            if (dx * dx + dy * dy <= radius_squared) {
                const x: i32 = center_x + dx;
                const y: i32 = center_y + dy;
                if (x >= 0 and y >= 0 and @as(usize, @intCast(x)) < width and @as(usize, @intCast(y)) < height) {
                    pixels[@as(usize, @intCast(y)) * width + @as(usize, @intCast(x))] = argb;
                }
            }
        }
    }
}

/// Ignores `color`'s alpha byte.
fn drawText(dc: win32.HDC, text: []const u8, x: i32, y: i32, color: u32) void {
    _ = win32.SetBkMode(dc, win32.TRANSPARENT);
    const text_z = gdi_overlay.toBufZ(TEXT_BUFFER_SIZE, text);
    const length = @min(text.len, TEXT_BUFFER_SIZE - 1);
    _ = win32.SetTextColor(dc, gdi_overlay.toColorRef(color & 0x00FF_FFFF));
    _ = win32.TextOutA(dc, x, y, &text_z, @intCast(length));
}

/// The selected font's line height.
fn lineHeight(dc: win32.HDC) i32 {
    return gdi_overlay.measureTextSize(TEXT_BUFFER_SIZE, dc, "Ag").cy;
}

fn measureTextWidth(dc: win32.HDC, text: []const u8) usize {
    return gdi_overlay.measureTextWidth(TEXT_BUFFER_SIZE, dc, text);
}

/// Right edge at `right_x`; skipped rather than drawn left of `min_x`, where it would overlap the name.
fn drawTextRight(dc: win32.HDC, text: []const u8, right_x: i32, y: i32, rgb: u32, min_x: i32) void {
    const length = @min(text.len, TEXT_BUFFER_SIZE - 1);
    const x = right_x - @as(i32, @intCast(measureTextWidth(dc, text[0..length])));
    if (x < min_x) return;
    drawText(dc, text[0..length], x, y, rgb);
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

/// Truncated with "..." to fit `max_width` pixels.
fn drawTextTruncated(dc: win32.HDC, text: []const u8, x: i32, y: i32, rgb: u32, max_width: usize) void {
    var out: [TEXT_BUFFER_SIZE:0]u8 = undefined;
    const truncated = gdi_overlay.truncateTextToFit(TEXT_BUFFER_SIZE, dc, &out, text, max_width);
    drawText(dc, truncated, x, y, rgb);
}

/// Length-prefixed, so swapping "Bob" and "BobBob" can't leave the hashed byte stream unchanged.
fn hashString(hasher: *std.hash.Wyhash, text: []const u8) void {
    hasher.update(std.mem.asBytes(&text.len));
    hasher.update(text);
}
