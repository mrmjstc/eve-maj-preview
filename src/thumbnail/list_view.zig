//! The ClientList view mode: one compact panel with a row per client, in place of thumbnail windows.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const PanelWindow = @import("../platform/panel_window.zig").PanelWindow;
const config_mod = @import("../config.zig");
const color_mod = @import("../util/color.zig");
const format = @import("../util/format.zig");
const painter_mod = @import("../painter.zig");
const ThumbnailWindow = @import("window.zig").ThumbnailWindow;
const input = @import("input.zig");
const activation = @import("../clients/activation.zig");
const drag_panel = @import("../drag/panel.zig");
const template = @import("../notifications/template.zig");
const log = @import("../log.zig");

const slog = log.scoped("list_view");

pub const LIST_WIDTH: i32 = 230;
const HEADER_HEIGHT: i32 = 24;
const ROW_HEIGHT: i32 = 28;
const BADGE_LEFT: i32 = 8;
const BADGE_RADIUS: i32 = 5;
const TEXT_LEFT: i32 = BADGE_LEFT + BADGE_RADIUS * 2 + 7;
const TEXT_PAD_Y: i32 = 6;
const RIGHT_MARGIN: i32 = 8;
const TEXT_BUF: usize = 256;

// Pixel colours (0xAARRGGBB, non-pre-multiplied).
const RGB_HEADER: u32 = 0x001A1A1A;
const RGB_ROW_INACTIVE: u32 = 0x000F0F0F;
const RGB_ROW_ALERT: u32 = 0x002A1A1A;
const ARGB_SEPARATOR: u32 = 0xFF888888;
const ARGB_HDR_TEXT: u32 = 0xFFFFFFFF;
const ARGB_NAME_NORMAL: u32 = 0xFFFFFFFF;
const ARGB_NOTIF_TEXT: u32 = 0xFFFFAA00;
const ARGB_SYS_TEXT: u32 = 0xFFCCCCCC;
const RGB_FRAME: u32 = 0x00888888;
const BADGE_ALERT: u32 = 0xFFFF8833;
const BADGE_INACTIVE: u32 = 0xFF505050;
const BADGE_MINIMIZED: u32 = 0xFF303030;
const BADGE_DISABLED_BG: u32 = 0xFF3E3E3E;
const BADGE_DISABLED_X: u32 = 0xFFCC4444;

const LIST_WINDOW_CLASS = "EVE_LIST_CLASS";

/// `count` rows laid out row-major across `columns` columns.
const Grid = struct {
    count: i32,
    columns: i32,

    fn itemsIn(self: Grid, col: i32) i32 {
        return itemsInColumn(self.count, self.columns, col);
    }
};

pub const ListWindow = struct {
    panel: PanelWindow,
    store: *config_mod.ProfileStore,
    config: *const config_mod.Config,
    /// Indices into the thumbnails render() was given, one per row in display order; hidden characters get none.
    rows: std.ArrayList(usize) = .empty,
    /// Each row's client, for clicks between renders.
    row_source_hwnds: std.ArrayList(win32.HWND) = .empty,

    pub fn init(allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE) !ListWindow {
        const cfg = &store.live;
        try registerWindowClass(instance);
        const x = cfg.display.startX;
        const y = cfg.display.startY;
        const panel = try PanelWindow.create(allocator, instance, LIST_WINDOW_CLASS, "EVE Client List", .{ .left = x, .top = y, .right = x + LIST_WIDTH, .bottom = y + HEADER_HEIGHT });
        return .{ .panel = panel, .store = store, .config = cfg };
    }

    pub fn deinit(self: *ListWindow) void {
        self.rows.deinit(self.panel.allocator);
        self.row_source_hwnds.deinit(self.panel.allocator);
        self.panel.deinit();
    }

    /// Matches the panel to its configured position; whether it exists at all is the view mode's, which rebuilds the Painter.
    pub fn sync(self: *ListWindow) void {
        self.panel.followPosition(self.config.display.startX, self.config.display.startY);
    }

    fn saveWindowPosition(self: *ListWindow) void {
        if (!self.config.display.rememberListViewPosition) return;
        const pos = self.panel.topLeft();
        self.store.update(.{ .display = .{ .startX = pos.x, .startY = pos.y } });
    }

    /// The active border colour, including a per-character override.
    fn resolveActiveBadgeColor(self: *const ListWindow, thumb: *const ThumbnailWindow) u32 {
        if (thumb.cached_border_colors) |colors| {
            if (colors.activeBorderColor) |color| return color;
        }
        return self.config.thumbnail.active.borderColor orelse self.config.thumbnail.borderColor;
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
        h.update(std.mem.asBytes(&display.listViewOrder));
        h.update(std.mem.asBytes(&display.listViewOpacity));
        h.update(display.listViewFontName);
        h.update(std.mem.asBytes(&display.listViewFontSize));
        h.update(std.mem.asBytes(&display.listViewFontWeight));
        h.update(std.mem.asBytes(&self.config.thumbnail.showSystemName));
        h.update(std.mem.asBytes(&self.config.combat.enabled));
        h.update(std.mem.asBytes(&self.config.combat.show_incoming));
        h.update(std.mem.asBytes(&self.config.combat.show_outgoing));
        h.update(std.mem.asBytes(&self.config.combat.incoming_color));
        h.update(std.mem.asBytes(&self.config.combat.outgoing_color));
        h.update(std.mem.asBytes(&self.config.combat.incoming_show_prefix));
        h.update(std.mem.asBytes(&self.config.combat.outgoing_show_prefix));
        h.update(std.mem.asBytes(&self.config.mining.enabled));
        h.update(std.mem.asBytes(&self.config.mining.color));
        h.update(std.mem.asBytes(&self.config.mining.show_prefix));
        h.update(std.mem.asBytes(&self.config.bounty.enabled));
        h.update(std.mem.asBytes(&self.config.bounty.color));
        h.update(std.mem.asBytes(&self.config.bounty.show_prefix));
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

    /// Combat, mining and bounty rates for the row's right-hand slot, more compact than the thumbnail overlay's; empty when none is shown.
    fn buildStatText(self: *const ListWindow, buf: []u8, thumb: *const ThumbnailWindow) []const u8 {
        var writer: std.Io.Writer = .fixed(buf);
        const combat_cfg = &self.config.combat;
        const mining_cfg = &self.config.mining;
        const bounty_cfg = &self.config.bounty;
        const stats = &thumb.stats;
        var wrote = false;

        if (combat_cfg.enabled) {
            if (combat_cfg.show_incoming and stats.showsIncoming()) {
                const prefix: []const u8 = if (combat_cfg.incoming_show_prefix) "IN:" else "";
                if (stats.incoming_dps) |dps| writer.print("{s}{d:.0}", .{ prefix, dps }) catch {} else writer.print("{s}??", .{prefix}) catch {};
                wrote = true;
            }
            if (combat_cfg.show_outgoing and stats.showsOutgoing()) {
                if (wrote) writer.writeByte(' ') catch {};
                const prefix: []const u8 = if (combat_cfg.outgoing_show_prefix) "OUT:" else "";
                if (stats.outgoing_dps) |dps| writer.print("{s}{d:.0}", .{ prefix, dps }) catch {} else writer.print("{s}??", .{prefix}) catch {};
                wrote = true;
            }
        }

        if (mining_cfg.enabled and stats.showsMining()) {
            if (wrote) writer.writeByte(' ') catch {};
            const prefix: []const u8 = if (mining_cfg.show_prefix) "M:" else "";
            if (stats.mining_rate) |rate| {
                const rate_per_min = rate * 60.0;
                if (rate_per_min < 10.0) {
                    writer.print("{s}{d:.1}", .{ prefix, rate_per_min }) catch {};
                } else {
                    writer.print("{s}{d:.0}", .{ prefix, rate_per_min }) catch {};
                }
            } else {
                writer.print("{s}??", .{prefix}) catch {};
            }
            wrote = true;
        }

        if (bounty_cfg.enabled and stats.showsBounty()) {
            if (wrote) writer.writeByte(' ') catch {};
            const prefix: []const u8 = if (bounty_cfg.show_prefix) "ISK:" else "";
            if (stats.bounty_isk_rate) |isk_rate| {
                var isk_buf: [16]u8 = undefined;
                const period_secs: f32 = if (bounty_cfg.isk_rate_unit == .hour) 3600.0 else 60.0;
                writer.print("{s}{s}", .{ prefix, format.formatIskAbbrev(&isk_buf, isk_rate * period_secs) }) catch {};
            } else {
                writer.print("{s}??", .{prefix}) catch {};
            }
        }

        return writer.buffered();
    }

    /// Text color for buildStatText's output; incoming DPS takes priority (most urgent), then outgoing, then mining, then bounty.
    fn statColor(self: *const ListWindow, thumb: *const ThumbnailWindow) u32 {
        const combat_cfg = &self.config.combat;
        const stats = &thumb.stats;
        if (combat_cfg.enabled and combat_cfg.show_incoming and stats.showsIncoming()) return combat_cfg.incoming_color & 0xFFFFFF;
        if (combat_cfg.enabled and combat_cfg.show_outgoing and stats.showsOutgoing()) return combat_cfg.outgoing_color & 0xFFFFFF;
        if (self.config.mining.enabled and stats.showsMining()) return self.config.mining.color & 0xFFFFFF;
        if (self.config.bounty.enabled and stats.showsBounty()) return self.config.bounty.color & 0xFFFFFF;
        return ARGB_SYS_TEXT & 0xFFFFFF;
    }

    /// Called every painter tick; redraws only when the render signature changed.
    pub fn render(self: *ListWindow, thumbnails: []const ThumbnailWindow, active_source_hwnd: ?win32.HWND) !void {
        const display = &self.config.display;
        try self.panel.ensureFont("List View", display.listViewFontName, display.listViewFontSize, display.listViewFontWeight);

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
        const grid: Grid = .{ .count = count, .columns = effectiveColumns(display.listViewColumns, self.rows.items.len) };
        const rows_per_col: i32 = @divTrunc(count + grid.columns - 1, grid.columns);
        const bitmap = try self.panel.beginFrame(grid.columns * LIST_WIDTH, HEADER_HEIGHT + rows_per_col * ROW_HEIGHT);
        const width: usize = bitmap.width;
        const height: usize = bitmap.height;

        gdi_overlay.fillRect(bitmap.pixels, width, height, 0, 0, width, @intCast(HEADER_HEIGHT), color_mod.withAlpha(RGB_HEADER, 0xFF));

        const old_font = if (self.panel.font) |font| win32.SelectObject(bitmap.mem_dc, font) else null;
        defer if (old_font) |font| {
            _ = win32.SelectObject(bitmap.mem_dc, font);
        };

        if (self.panel.font != null) {
            var hdr_buf: [48]u8 = undefined;
            const hdr = std.fmt.bufPrint(&hdr_buf, "EVE-Maj Preview // {d}", .{count}) catch unreachable;
            drawText(bitmap.mem_dc, hdr, 8, 5, ARGB_HDR_TEXT & 0xFFFFFF);
        }
        gdi_overlay.fillRect(bitmap.pixels, width, height, 0, @intCast(HEADER_HEIGHT - 1), width, 1, ARGB_SEPARATOR);

        for (self.rows.items, 0..) |thumb_index, i| self.drawRow(bitmap, &thumbnails[thumb_index], i, grid, active_source_hwnd);

        drawColumnSeparators(bitmap, grid);
        drawFrame(bitmap, grid, color_mod.withAlpha(RGB_FRAME, 0xFF));

        gdi_overlay.fixTextAlpha(bitmap.pixels, width, height);
        applyScanlines(bitmap.pixels, width, height);
        applyVignette(bitmap.pixels, width, height);

        self.panel.present(display.listViewOpacity, signature);
    }

    /// Row `i` in display order: its background, status badge, name, and one right-hand slot for a notification, stats or system.
    fn drawRow(self: *const ListWindow, bitmap: *const gdi_overlay.OverlayBitmap, thumb: *const ThumbnailWindow, i: usize, grid: Grid, active_source_hwnd: ?win32.HWND) void {
        const width: usize = bitmap.width;
        const height: usize = bitmap.height;
        const columns_u: usize = @intCast(grid.columns);
        const row: i32 = @intCast(i / columns_u);
        const col: i32 = @intCast(i % columns_u);
        const row_top: i32 = HEADER_HEIGHT + row * ROW_HEIGHT;
        const col_left: i32 = col * LIST_WIDTH;
        const render_state = thumb.effectiveRenderState(active_source_hwnd);
        const is_active = render_state == .active;
        const is_alert = render_state == .alert;

        const row_bg: u32 = if (is_alert) blk: {
            // Tinted with the newest notification's border colour, if it has one.
            if (thumb.notifications.newest()) |notif| {
                if (notif.border_color_override) |nc| {
                    const r: u32 = (((nc >> 16) & 0xFF) * 35 / 255 + 0x1A) & 0xFF;
                    const g: u32 = (((nc >> 8) & 0xFF) * 35 / 255 + 0x1A) & 0xFF;
                    const b: u32 = ((nc & 0xFF) * 35 / 255 + 0x20) & 0xFF;
                    break :blk color_mod.withAlpha((r << 16) | (g << 8) | b, 0xFF);
                }
            }
            break :blk color_mod.withAlpha(RGB_ROW_ALERT, 0xFF);
        } else color_mod.withAlpha(RGB_ROW_INACTIVE, 0xFF);
        gdi_overlay.fillRect(bitmap.pixels, width, height, @intCast(col_left), @intCast(row_top), @intCast(LIST_WIDTH), @intCast(ROW_HEIGHT), row_bg);

        // Only when the next row has an item in this column, so it doesn't draw over an empty cell.
        if (row + 1 < grid.itemsIn(col)) {
            gdi_overlay.fillRect(bitmap.pixels, width, height, @intCast(col_left), @intCast(row_top + ROW_HEIGHT - 1), @intCast(LIST_WIDTH), 1, ARGB_SEPARATOR);
        }

        const badge_cx: i32 = col_left + BADGE_LEFT + BADGE_RADIUS;
        const badge_cy: i32 = row_top + @divTrunc(ROW_HEIGHT, 2);
        if (thumb.is_excluded_from_cycle) {
            drawDisabledBadge(bitmap.pixels, width, height, badge_cx, badge_cy, BADGE_RADIUS, BADGE_DISABLED_BG, BADGE_DISABLED_X);
        } else {
            const badge_col: u32 = if (is_active)
                self.resolveActiveBadgeColor(thumb)
            else if (is_alert)
                BADGE_ALERT
            else if (render_state == .minimized)
                BADGE_MINIMIZED
            else
                BADGE_INACTIVE;
            drawDot(bitmap.pixels, width, height, badge_cx, badge_cy, BADGE_RADIUS, badge_col);
        }

        if (self.panel.font == null) return;
        const dc = bitmap.mem_dc;
        const text_y = row_top + TEXT_PAD_Y;
        const text_left = col_left + TEXT_LEFT;

        const name_col: u32 = (thumb.cached_character_color orelse ARGB_NAME_NORMAL) & 0xFFFFFF;
        const max_name_w: usize = @intCast(LIST_WIDTH - TEXT_LEFT - RIGHT_MARGIN - 70);
        if (measureTextWidth(dc, thumb.cached_display_name) <= max_name_w) {
            drawText(dc, thumb.cached_display_name, text_left, text_y, name_col);
        } else {
            drawTextTruncated(dc, thumb.cached_display_name, text_left, text_y, name_col, max_name_w);
        }

        var stat_buf: [64]u8 = undefined;
        const stat_text = self.buildStatText(&stat_buf, thumb);

        // One slot only: the newest notification wins, then stats, then the system.
        var right_text: []const u8 = "";
        var right_col: u32 = ARGB_SYS_TEXT & 0xFFFFFF;
        var notif_buf: [TEXT_BUF]u8 = undefined;
        if (thumb.notifications.newest()) |notif| {
            right_text = template.oneLine(notif.text, &notif_buf);
            right_col = (notif.text_color_override orelse ARGB_NOTIF_TEXT) & 0xFFFFFF;
        } else if (stat_text.len > 0) {
            right_text = stat_text;
            right_col = self.statColor(thumb);
        } else if (self.config.thumbnail.showSystemName) {
            right_text = thumb.system_name;
            if (thumb.system_name.len > 0) right_col = thumb.cached_system_color & 0xFFFFFF;
        }

        if (right_text.len > 0) drawTextRight(dc, right_text, col_left + LIST_WIDTH - RIGHT_MARGIN, text_y, right_col, text_left);
    }
};

var g_class_registered: bool = false;

/// Number of columns needed to lay out `n` items (1-6 configured); never reserves width for trailing empty columns.
fn effectiveColumns(configured: u32, n: usize) i32 {
    const clamped: i32 = @max(1, @min(6, @as(i32, @intCast(configured))));
    if (n == 0) return clamped;
    return @min(clamped, @as(i32, @intCast(n)));
}

/// Number of items in column `col` when `n` items are laid out row-major across `columns` columns; earlier columns absorb the remainder from a partial last row.
fn itemsInColumn(n: i32, columns: i32, col: i32) i32 {
    const base = @divTrunc(n, columns);
    const remainder = @mod(n, columns);
    return if (col < remainder) base + 1 else base;
}

/// Between columns, only as tall as the taller neighbouring column, so they don't run alongside empty cells.
fn drawColumnSeparators(bitmap: *const gdi_overlay.OverlayBitmap, grid: Grid) void {
    var col: i32 = 1;
    while (col < grid.columns) : (col += 1) {
        const rows = @max(grid.itemsIn(col - 1), grid.itemsIn(col));
        gdi_overlay.fillRect(bitmap.pixels, bitmap.width, bitmap.height, @intCast(col * LIST_WIDTH), @intCast(HEADER_HEIGHT), 1, @intCast(rows * ROW_HEIGHT), ARGB_SEPARATOR);
    }
}

/// Stepped per column, so it hugs each column's rows instead of the full (possibly taller) window.
fn drawFrame(bitmap: *const gdi_overlay.OverlayBitmap, grid: Grid, color: u32) void {
    const width: usize = bitmap.width;
    const height: usize = bitmap.height;
    // The header always spans the full width, and column 0 is always the tallest.
    gdi_overlay.fillRect(bitmap.pixels, width, height, 0, 0, width, 1, color);
    gdi_overlay.fillRect(bitmap.pixels, width, height, 0, 0, 1, height, color);

    var col: i32 = 0;
    while (col < grid.columns) : (col += 1) {
        const bottom: usize = @intCast(HEADER_HEIGHT + grid.itemsIn(col) * ROW_HEIGHT - 1);
        gdi_overlay.fillRect(bitmap.pixels, width, height, @intCast(col * LIST_WIDTH), bottom, @intCast(LIST_WIDTH), 1, color);
    }

    const right_h: usize = @intCast(HEADER_HEIGHT + grid.itemsIn(grid.columns - 1) * ROW_HEIGHT);
    gdi_overlay.fillRect(bitmap.pixels, width, height, width - 1, 0, 1, right_h, color);
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
    if (drag_panel.handleMessage(hwnd, msg, lParam, HEADER_HEIGHT)) |result| return result;
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
            const cx = win32.lparamX(lParam);
            const cy = win32.lparamY(lParam);
            // The header is the drag handle (see drag_panel.handleMessage).
            if (cy < HEADER_HEIGHT) return 0;

            const list_window = listWindow() orelse return 0;
            const row: usize = @intCast(@divTrunc(cy - HEADER_HEIGHT, ROW_HEIGHT));
            const columns: i32 = effectiveColumns(list_window.config.display.listViewColumns, list_window.row_source_hwnds.items.len);
            const col: usize = @intCast(std.math.clamp(@divTrunc(cx, LIST_WIDTH), 0, columns - 1));
            const index: usize = row * @as(usize, @intCast(columns)) + col;
            if (index >= list_window.row_source_hwnds.items.len) return 0;

            const source_hwnd = list_window.row_source_hwnds.items[index];
            if (win32.isShiftPressed()) input.handleThumbnailShiftClick(source_hwnd) else activation.activate(source_hwnd);
            return 0;
        },
        else => return win32.DefWindowProcA(hwnd, msg, wParam, lParam),
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

fn drawDisabledBadge(pixels: [*]u32, width: usize, height: usize, cx: i32, cy: i32, r: i32, bg_argb: u32, x_argb: u32) void {
    drawDot(pixels, width, height, cx, cy, r, bg_argb);

    const arm: i32 = @max(@as(i32, 2), r - 1);
    var d: i32 = -arm;
    while (d <= arm) : (d += 1) {
        const x1 = cx + d;
        const y1 = cy + d;
        const x2 = cx + d;
        const y2 = cy - d;

        if (x1 >= 0 and y1 >= 0 and @as(usize, @intCast(x1)) < width and @as(usize, @intCast(y1)) < height) {
            pixels[@as(usize, @intCast(y1)) * width + @as(usize, @intCast(x1))] = x_argb;
        }
        if (x2 >= 0 and y2 >= 0 and @as(usize, @intCast(x2)) < width and @as(usize, @intCast(y2)) < height) {
            pixels[@as(usize, @intCast(y2)) * width + @as(usize, @intCast(x2))] = x_argb;
        }
    }
}

fn scaleRgb(rgb: u32, factor_255: u32) u32 {
    const r: u32 = ((rgb >> 16) & 0xFF) * factor_255 / 255;
    const g: u32 = ((rgb >> 8) & 0xFF) * factor_255 / 255;
    const b: u32 = (rgb & 0xFF) * factor_255 / 255;
    return (r << 16) | (g << 8) | b;
}

fn applyScanlines(pixels: [*]u32, width: usize, height: usize) void {
    var y: usize = 1;
    while (y < height) : (y += 2) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const idx = y * width + x;
            const p = pixels[idx];
            const a = p & 0xFF00_0000;
            if (a == 0) continue;
            pixels[idx] = a | scaleRgb(p & 0x00FF_FFFF, 228);
        }
    }
}

fn applyVignette(pixels: [*]u32, width: usize, height: usize) void {
    if (width < 2 or height < 2) return;

    const cx: usize = width / 2;
    const cy: usize = height / 2;
    const max_dx: usize = @max(@as(usize, 1), cx);
    const max_dy: usize = @max(@as(usize, 1), cy);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const idx = y * width + x;
            const p = pixels[idx];
            const a = p & 0xFF00_0000;
            if (a == 0) continue;

            const dx: usize = if (x >= cx) x - cx else cx - x;
            const dy: usize = if (y >= cy) y - cy else cy - y;

            const edge_x: u32 = if (dx * 2 > max_dx) @intCast((((dx * 2) - max_dx) * 255) / max_dx) else 0;
            const edge_y: u32 = if (dy * 2 > max_dy) @intCast((((dy * 2) - max_dy) * 255) / max_dy) else 0;
            const edge = @max(edge_x, edge_y);

            if (edge > 0) {
                const darken: u32 = 255 - (edge * 80 / 255);
                pixels[idx] = a | scaleRgb(p & 0x00FF_FFFF, darken);
            }
        }
    }
}

/// With a faint glow offset down and right.
fn drawText(dc: win32.HDC, text: []const u8, x: i32, y: i32, rgb: u32) void {
    _ = win32.SetBkMode(dc, win32.TRANSPARENT);
    const buf = gdi_overlay.toBufZ(TEXT_BUF, text);
    const n = @min(text.len, TEXT_BUF - 1);

    const base = rgb & 0x00FF_FFFF;
    _ = win32.SetTextColor(dc, gdi_overlay.toColorRef(scaleRgb(base, 108)));
    _ = win32.TextOutA(dc, x + 1, y, &buf, @intCast(n));
    _ = win32.TextOutA(dc, x, y + 1, &buf, @intCast(n));
    _ = win32.SetTextColor(dc, gdi_overlay.toColorRef(base));
    _ = win32.TextOutA(dc, x, y, &buf, @intCast(n));
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
