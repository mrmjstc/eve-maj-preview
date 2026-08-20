const std = @import("std");
const win32 = @import("win32.zig");
const config_mod = @import("config.zig");
const state_mod = @import("state.zig");
const types = @import("types.zig");
const gdi_overlay = @import("gdi_overlay.zig");
const log = @import("log.zig");
const slog = log.scoped("list_view");

// Only used by const-pointer/slice params so the painter ↔ list_view import cycle stays invisible at struct-size level; Zig's lazy type resolution handles it.
const ThumbnailWindow = @import("painter.zig").ThumbnailWindow;

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
const DEFAULT_ACTIVE_BORDER_COLOR: u32 = 0xFF606060;
const BADGE_ACTIVE: u32 = 0xFF44CC44;
const BADGE_ALERT: u32 = 0xFFFF8833;
const BADGE_INACTIVE: u32 = 0xFF505050;
const BADGE_MINIMIZED: u32 = 0xFF303030;
const BADGE_DISABLED_BG: u32 = 0xFF3E3E3E;
const BADGE_DISABLED_X: u32 = 0xFFCC4444;

// WM_NCHITTEST return values
const HTCAPTION: win32.LRESULT = 2;
const HTCLIENT: win32.LRESULT = 1;

var g_class_registered: bool = false;

// Anchors the drag to an absolute cursor position captured at WM_ENTERSIZEMOVE, since WM_MOVING's rect reflects our own prior snap overrides and re-deriving from it every message would prevent escaping an edge; mirrors input.zig's thumbnail dragging.
var g_drag_anchor_cursor: win32.POINT = .{ .x = 0, .y = 0 };
var g_drag_anchor_rect: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

/// Set by Painter.init() so the window proc can activate EVE clients without a direct list_view → input circular dependency.
pub var g_activate_fn: ?*const fn (win32.HWND) void = null;
pub var g_shift_click_fn: ?*const fn (win32.HWND) void = null;

const LIST_WINDOW_CLASS = "EVE_LIST_CLASS";

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

pub const ListWindow = struct {
    hwnd: win32.HWND,
    instance: win32.HINSTANCE,
    allocator: std.mem.Allocator,
    config: *config_mod.Config,
    font: ?win32.HFONT = null,
    // Tracks the settings `font` was created from so ensureFont() can detect a live-previewed change and recreate it.
    // cached_font_name aliases config.display.listViewFontName (no dupe) — safe since config always replaces the whole string rather than mutating in place.
    cached_font_name: []const u8 = "",
    cached_font_size: i32 = 0,
    cached_font_weight: types.FontWeight = .Regular,
    overlay: ?gdi_overlay.OverlayBitmap = null,
    row_source_hwnds: std.ArrayList(win32.HWND) = .empty,
    sort_indices: std.ArrayList(usize) = .empty,
    // Scratch buffer for the per-character-hidden filter applied at the top of render(); rebuilt every call, holds shallow copies (owned slices still belong to Painter).
    visible_thumbnails: std.ArrayList(ThumbnailWindow) = .empty,
    // -1 forces a resize on the first render.
    last_win_w: i32 = -1,
    last_win_h: i32 = -1,
    /// Hash of all render-affecting state from the previous completed render; lets render() skip the GDI redraw when nothing changed (mirrors Painter's renderSettingsEqual).
    last_render_signature: ?u64 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        cfg: *config_mod.Config,
        instance: win32.HINSTANCE,
    ) !ListWindow {
        try registerClass(instance);

        const hwnd = win32.CreateWindowExA(
            win32.WS_EX_TOPMOST | win32.WS_EX_TOOLWINDOW |
                win32.WS_EX_NOACTIVATE | win32.WS_EX_LAYERED,
            LIST_WINDOW_CLASS,
            "EVE Client List",
            win32.WS_POPUP,
            cfg.display.startX,
            cfg.display.startY,
            LIST_WIDTH,
            HEADER_HEIGHT,
            null,
            null,
            instance,
            null,
        ) orelse return error.CreateWindowFailed;
        errdefer _ = win32.DestroyWindow(hwnd);

        // Font is freed in deinit.
        const font_name_z = try allocator.dupeZ(u8, cfg.display.listViewFontName);
        defer allocator.free(font_name_z);

        const font = win32.CreateFontA(
            -cfg.display.listViewFontSize,
            0,
            0,
            0,
            cfg.display.listViewFontWeight.toWin32Weight(),
            if (cfg.display.listViewFontWeight.isItalic()) 1 else 0,
            0,
            0,
            win32.DEFAULT_CHARSET,
            win32.OUT_DEFAULT_PRECIS,
            win32.CLIP_DEFAULT_PRECIS,
            win32.CLEARTYPE_QUALITY,
            win32.DEFAULT_PITCH,
            font_name_z,
        );

        return .{
            .hwnd = hwnd,
            .instance = instance,
            .allocator = allocator,
            .config = cfg,
            .font = font,
            .cached_font_name = cfg.display.listViewFontName,
            .cached_font_size = cfg.display.listViewFontSize,
            .cached_font_weight = cfg.display.listViewFontWeight,
        };
    }

    pub fn deinit(self: *ListWindow) void {
        if (self.overlay) |o| o.destroy();
        self.row_source_hwnds.deinit(self.allocator);
        self.sort_indices.deinit(self.allocator);
        self.visible_thumbnails.deinit(self.allocator);
        if (self.font) |f| _ = win32.DeleteObject(f);
        _ = win32.DestroyWindow(self.hwnd);
    }

    /// Recreates `font` if name/size/weight changed since last built (e.g. a live-previewed edit, see PROTOCOL_PREVIEW_THUMBNAIL); mirrors Painter.getCachedFont's dirty-check for List View's single shared font.
    fn ensureFont(self: *ListWindow) void {
        const cfg = self.config.display;
        const unchanged = self.font != null and
            std.mem.eql(u8, self.cached_font_name, cfg.listViewFontName) and
            self.cached_font_size == cfg.listViewFontSize and
            self.cached_font_weight == cfg.listViewFontWeight;
        if (unchanged) return;

        if (self.font) |old| _ = win32.DeleteObject(old);
        self.font = null;

        const font_name_z = self.allocator.dupeZ(u8, cfg.listViewFontName) catch |err| {
            slog.err("Failed to allocate List View font name: {}", .{err});
            return;
        };
        defer self.allocator.free(font_name_z);

        self.font = win32.CreateFontA(
            -cfg.listViewFontSize,
            0,
            0,
            0,
            cfg.listViewFontWeight.toWin32Weight(),
            if (cfg.listViewFontWeight.isItalic()) 1 else 0,
            0,
            0,
            win32.DEFAULT_CHARSET,
            win32.OUT_DEFAULT_PRECIS,
            win32.CLIP_DEFAULT_PRECIS,
            win32.CLEARTYPE_QUALITY,
            win32.DEFAULT_PITCH,
            font_name_z,
        );
        self.cached_font_name = cfg.listViewFontName;
        self.cached_font_size = cfg.listViewFontSize;
        self.cached_font_weight = cfg.listViewFontWeight;
    }

    fn saveWindowPosition(self: *ListWindow) void {
        if (!self.config.display.rememberListViewPosition) return;

        var rect: win32.RECT = undefined;
        _ = win32.GetWindowRect(self.hwnd, &rect);

        const pos = config_mod.Position{
            .x = rect.left,
            .y = rect.top,
        };

        self.config.saveListViewPosition(self.allocator, pos) catch |err| {
            slog.err("Failed to save list view position: {}", .{err});
        };
    }

    fn resolveActiveBadgeColor(self: *const ListWindow, thumb: *const ThumbnailWindow) u32 {
        var color = self.config.thumbnail.active.getBorderColor(self.config.thumbnail.borderColor);

        // cached_active_border_override is kept in sync by painter.zig on name change; reuse it instead of re-scanning config.characters every tick (getCharacterBorderColors is a linear scan).
        if (thumb.cached_active_border_override) |override_color| {
            color = override_color;
        }

        return if (color == DEFAULT_ACTIVE_BORDER_COLOR) BADGE_ACTIVE else color;
    }

    fn withListAlpha(self: *const ListWindow, rgb: u32) u32 {
        const a: u32 = self.config.display.listViewOpacity;
        return (a << 24) | (rgb & 0x00FF_FFFF);
    }

    fn prepareRenderOrder(self: *ListWindow, thumbnails: []const ThumbnailWindow) ![]const usize {
        try self.sort_indices.resize(self.allocator, thumbnails.len);
        try self.row_source_hwnds.resize(self.allocator, thumbnails.len);

        for (self.sort_indices.items, 0..) |*slot, i| {
            slot.* = i;
        }

        const SortContext = struct {
            cfg: *const config_mod.Config,
            thumbnails: []const ThumbnailWindow,
            order_map: ?*const std.StringHashMap(usize),

            fn compareIgnoreCase(a: []const u8, b: []const u8) std.math.Order {
                const min_len = @min(a.len, b.len);
                var i: usize = 0;
                while (i < min_len) : (i += 1) {
                    const ca = std.ascii.toLower(a[i]);
                    const cb = std.ascii.toLower(b[i]);
                    if (ca < cb) return .lt;
                    if (ca > cb) return .gt;
                }
                if (a.len < b.len) return .lt;
                if (a.len > b.len) return .gt;
                return .eq;
            }

            fn alphabeticalLessThan(a: ThumbnailWindow, b: ThumbnailWindow, a_index: usize, b_index: usize) bool {
                const a_name = a.cached_display_name;
                const b_name = b.cached_display_name;

                switch (compareIgnoreCase(a_name, b_name)) {
                    .lt => return true,
                    .gt => return false,
                    .eq => {},
                }

                switch (compareIgnoreCase(a.character_name, b.character_name)) {
                    .lt => return true,
                    .gt => return false,
                    .eq => return a_index < b_index,
                }
            }

            fn configuredLessThan(order_map: *const std.StringHashMap(usize), a: ThumbnailWindow, b: ThumbnailWindow, a_index: usize, b_index: usize) bool {
                const a_order = order_map.get(a.character_name);
                const b_order = order_map.get(b.character_name);

                if (a_order) |ao| {
                    if (b_order) |bo| {
                        if (ao != bo) return ao < bo;
                    } else {
                        return true;
                    }
                } else if (b_order != null) {
                    return false;
                }

                return a_index < b_index;
            }

            fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                const a = ctx.thumbnails[a_index];
                const b = ctx.thumbnails[b_index];
                return switch (ctx.cfg.display.listViewOrder) {
                    .Tracked => a_index < b_index,
                    .Alphabetical => alphabeticalLessThan(a, b, a_index, b_index),
                    .ConfiguredCharacters => configuredLessThan(ctx.order_map.?, a, b, a_index, b_index),
                };
            }
        };

        // Precompute name -> configured-order index once per sort (first occurrence wins) instead of rescanning cfg.characters.items per comparator call.
        var order_map: ?std.StringHashMap(usize) = null;
        defer if (order_map) |*m| m.deinit();

        if (self.config.display.listViewOrder == .ConfiguredCharacters) {
            var map = std.StringHashMap(usize).init(self.allocator);
            errdefer map.deinit();
            for (self.config.characters.items, 0..) |char, i| {
                const gop = try map.getOrPut(char.name);
                if (!gop.found_existing) gop.value_ptr.* = i;
            }
            order_map = map;
        }

        if (self.config.display.listViewOrder != .Tracked) {
            std.sort.pdq(usize, self.sort_indices.items, SortContext{
                .cfg = self.config,
                .thumbnails = thumbnails,
                .order_map = if (order_map) |*m| m else null,
            }, SortContext.lessThan);
        }

        for (self.sort_indices.items, 0..) |thumb_index, row_index| {
            self.row_source_hwnds.items[row_index] = thumbnails[thumb_index].source_hwnd;
        }

        return self.sort_indices.items;
    }

    /// Cheap O(n) hash over everything that affects the rendered pixels (row-count/order settings plus each row's name/state/notification/system); used to skip the GDI redraw when nothing changed.
    fn computeRenderSignature(self: *const ListWindow, thumbnails: []const ThumbnailWindow) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&thumbnails.len));
        h.update(std.mem.asBytes(&self.config.display.listViewColumns));
        h.update(std.mem.asBytes(&self.config.display.listViewOrder));
        h.update(std.mem.asBytes(&self.config.display.listViewOpacity));
        h.update(self.config.display.listViewFontName);
        h.update(std.mem.asBytes(&self.config.display.listViewFontSize));
        h.update(std.mem.asBytes(&self.config.display.listViewFontWeight));
        h.update(std.mem.asBytes(&self.config.thumbnail.showSystemName));
        h.update(std.mem.asBytes(&self.config.combat.enabled));
        h.update(std.mem.asBytes(&self.config.combat.show_incoming));
        h.update(std.mem.asBytes(&self.config.combat.show_outgoing));
        h.update(std.mem.asBytes(&self.config.combat.incoming_color));
        h.update(std.mem.asBytes(&self.config.combat.outgoing_color));
        h.update(std.mem.asBytes(&self.config.mining.enabled));
        h.update(std.mem.asBytes(&self.config.mining.color));

        for (thumbnails) |*t| {
            h.update(t.character_name);
            // cached_display_name mirrors cached_system_color below — resolved by painter.zig on rename instead of re-scanning config.characters every tick.
            h.update(t.cached_display_name);
            h.update(t.system_name);
            h.update(std.mem.asBytes(&t.current_state));
            h.update(std.mem.asBytes(&t.is_excluded_from_cycle));
            h.update(std.mem.asBytes(&t.last_incoming_dps));
            h.update(std.mem.asBytes(&t.last_outgoing_dps));
            h.update(std.mem.asBytes(&t.last_mining_rate));
            if (t.system_name.len > 0) {
                // cached_system_color is kept in sync by painter.zig on system-name change; reuse it instead of re-resolving from config every tick (getSystemNameColor does a lookup per call).
                h.update(std.mem.asBytes(&t.cached_system_color));
            }
            if (t.cached_character_color) |cc| {
                h.update(std.mem.asBytes(&cc));
            }
            if (self.resolveActiveBadgeColorIfActive(t)) |badge_color| {
                h.update(std.mem.asBytes(&badge_color));
            }
            if (t.active_notification) |notif| {
                h.update(notif.text);
                h.update(std.mem.asBytes(&notif.border_color_override));
                h.update(std.mem.asBytes(&notif.text_color_override));
            }
        }

        return h.final();
    }

    fn resolveActiveBadgeColorIfActive(self: *const ListWindow, thumb: *const ThumbnailWindow) ?u32 {
        if (thumb.current_state != .Active) return null;
        return self.resolveActiveBadgeColor(thumb);
    }

    /// Compact combined DPS in/out + mining rate string for the list row's right-side slot; empty when neither stat is active. Mirrors the thumbnail overlay's own formatting (painter.renderThumbnail).
    fn buildStatText(self: *const ListWindow, buf: []u8, thumb: *const ThumbnailWindow) []const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();
        const combat_cfg = &self.config.combat;
        const mining_cfg = &self.config.mining;
        var wrote = false;

        if (combat_cfg.enabled) {
            if (combat_cfg.show_incoming and (thumb.last_incoming_dps == null or thumb.last_incoming_dps.? > 0)) {
                if (thumb.last_incoming_dps) |dps|
                    writer.print("IN:{d:.0}", .{dps}) catch {}
                else
                    writer.writeAll("IN:??") catch {};
                wrote = true;
            }
            if (combat_cfg.show_outgoing and (thumb.last_outgoing_dps == null or thumb.last_outgoing_dps.? > 0)) {
                if (wrote) writer.writeByte(' ') catch {};
                if (thumb.last_outgoing_dps) |dps|
                    writer.print("OUT:{d:.0}", .{dps}) catch {}
                else
                    writer.writeAll("OUT:??") catch {};
                wrote = true;
            }
        }

        if (mining_cfg.enabled and (thumb.last_mining_rate == null or thumb.last_mining_rate.? > 0)) {
            if (wrote) writer.writeByte(' ') catch {};
            if (thumb.last_mining_rate) |rate| {
                const rate_per_min = rate * 60.0;
                if (rate_per_min < 10.0) {
                    writer.print("M:{d:.1}", .{rate_per_min}) catch {};
                } else {
                    writer.print("M:{d:.0}", .{rate_per_min}) catch {};
                }
            } else {
                writer.writeAll("M:??") catch {};
            }
        }

        return stream.getWritten();
    }

    /// Text color for buildStatText's output; incoming DPS takes priority (most urgent), then outgoing, then mining.
    fn statColor(self: *const ListWindow, thumb: *const ThumbnailWindow) u32 {
        const combat_cfg = &self.config.combat;
        const mining_cfg = &self.config.mining;

        if (combat_cfg.enabled and combat_cfg.show_incoming and (thumb.last_incoming_dps == null or thumb.last_incoming_dps.? > 0)) return combat_cfg.incoming_color & 0xFFFFFF;
        if (combat_cfg.enabled and combat_cfg.show_outgoing and (thumb.last_outgoing_dps == null or thumb.last_outgoing_dps.? > 0)) return combat_cfg.outgoing_color & 0xFFFFFF;
        if (mining_cfg.enabled and (thumb.last_mining_rate == null or thumb.last_mining_rate.? > 0)) return mining_cfg.color & 0xFFFFFF;
        return ARGB_SYS_TEXT & 0xFFFFFF;
    }

    /// Re-render the list window with the current thumbnail state; called every painter update tick (~50 ms) and skips the GDI redraw when the render signature matches the previous tick's.
    pub fn render(self: *ListWindow, all_thumbnails: []const ThumbnailWindow) !void {
        self.ensureFont();

        // Drop per-character hidden entries entirely so they don't leave a blank row.
        self.visible_thumbnails.clearRetainingCapacity();
        for (all_thumbnails) |t| {
            if (!self.config.isThumbnailHidden(t.character_name)) {
                try self.visible_thumbnails.append(self.allocator, t);
            }
        }
        const thumbnails = self.visible_thumbnails.items;

        if (thumbnails.len == 0) {
            _ = win32.ShowWindow(self.hwnd, win32.SW_HIDE);
            return;
        }

        // Hide the entire panel when the visibility-toggle hotkey has hidden all thumbnails
        var all_hidden = true;
        for (thumbnails) |*t| {
            if (t.visibility_state == .Visible) {
                all_hidden = false;
                break;
            }
        }
        if (all_hidden) {
            _ = win32.ShowWindow(self.hwnd, win32.SW_HIDE);
            return;
        }

        const signature = self.computeRenderSignature(thumbnails);
        if (self.overlay != null and self.last_render_signature != null and self.last_render_signature.? == signature) {
            _ = win32.ShowWindow(self.hwnd, win32.SW_SHOWNOACTIVATE);
            return;
        }

        const render_order = try self.prepareRenderOrder(thumbnails);

        const n: i32 = @intCast(thumbnails.len);
        const columns: i32 = effectiveColumns(self.config.display.listViewColumns, thumbnails.len);
        const columns_u: usize = @intCast(columns);
        const rows_per_col: i32 = @divTrunc(n + columns - 1, columns);
        const win_h: i32 = HEADER_HEIGHT + rows_per_col * ROW_HEIGHT;
        const win_w: i32 = columns * LIST_WIDTH;

        if (win_w != self.last_win_w or win_h != self.last_win_h) {
            _ = win32.SetWindowPos(
                self.hwnd,
                win32.HWND_TOPMOST,
                0,
                0,
                win_w,
                win_h,
                win32.SWP_NOMOVE | win32.SWP_NOACTIVATE,
            );
            self.last_win_w = win_w;
            self.last_win_h = win_h;
        }

        const needs_bmp = if (self.overlay) |o|
            o.width != @as(usize, @intCast(win_w)) or
                o.height != @as(usize, @intCast(win_h))
        else
            true;

        if (needs_bmp) {
            if (self.overlay) |o| o.destroy();
            const sdc = win32.GetDC(null) orelse return error.GetDCFailed;
            defer _ = win32.ReleaseDC(null, sdc);
            self.overlay = try gdi_overlay.OverlayBitmap.create(sdc, win_w, win_h);
        }

        const ov = &self.overlay.?;
        const W: usize = @intCast(win_w);
        const H: usize = @intCast(win_h);

        // Clear to fully transparent
        @memset(ov.pixels[0 .. W * H], 0);

        fillRect(ov.pixels, W, 0, 0, W, @intCast(HEADER_HEIGHT), self.withListAlpha(RGB_HEADER));

        if (self.font) |f| {
            const old = win32.SelectObject(ov.mem_dc, f);
            defer {
                if (old) |o| _ = win32.SelectObject(ov.mem_dc, o);
            }

            var hdr_buf: [48:0]u8 = undefined;
            const hdr = std.fmt.bufPrintZ(
                &hdr_buf,
                "EVE-Maj Preview // {d}",
                .{thumbnails.len},
            ) catch "EVE-Maj Preview";
            drawText(ov.mem_dc, hdr, 8, 5, ARGB_HDR_TEXT & 0xFFFFFF);
        }

        fillRect(ov.pixels, W, 0, @intCast(HEADER_HEIGHT - 1), W, 1, ARGB_SEPARATOR);

        for (render_order, 0..) |thumb_index, i| {
            const thumb = &thumbnails[thumb_index];
            const row: i32 = @intCast(i / columns_u);
            const col: i32 = @intCast(i % columns_u);
            const row_top: i32 = HEADER_HEIGHT + row * ROW_HEIGHT;
            const row_top_u: usize = @intCast(row_top);
            const col_left: i32 = col * LIST_WIDTH;
            const col_left_u: usize = @intCast(col_left);
            const is_active = (thumb.current_state == .Active);
            const is_alert = (thumb.current_state == .Alert);

            const row_bg: u32 = if (is_active)
                self.withListAlpha(RGB_ROW_INACTIVE)
            else if (is_alert) blk: {
                // Tint row slightly with the notification border color if available
                if (thumb.active_notification) |notif| {
                    if (notif.border_color_override) |nc| {
                        const r: u32 = (((nc >> 16) & 0xFF) * 35 / 255 + 0x1A) & 0xFF;
                        const g: u32 = (((nc >> 8) & 0xFF) * 35 / 255 + 0x1A) & 0xFF;
                        const b: u32 = ((nc & 0xFF) * 35 / 255 + 0x20) & 0xFF;
                        break :blk self.withListAlpha((r << 16) | (g << 8) | b);
                    }
                }
                break :blk self.withListAlpha(RGB_ROW_ALERT);
            } else self.withListAlpha(RGB_ROW_INACTIVE);

            fillRect(ov.pixels, W, col_left_u, row_top_u, @intCast(LIST_WIDTH), @intCast(ROW_HEIGHT), row_bg);

            // Separator below this cell only when the next row has an item in this column (avoids drawing over an empty cell).
            if (row + 1 < itemsInColumn(n, columns, col)) {
                fillRect(ov.pixels, W, col_left_u, row_top_u + @as(usize, @intCast(ROW_HEIGHT)) - 1, @intCast(LIST_WIDTH), 1, ARGB_SEPARATOR);
            }

            const badge_cx: i32 = col_left + BADGE_LEFT + BADGE_RADIUS;
            const badge_cy: i32 = row_top + @divTrunc(ROW_HEIGHT, 2);
            if (thumb.is_excluded_from_cycle) {
                drawDisabledBadge(ov.pixels, W, H, badge_cx, badge_cy, BADGE_RADIUS, BADGE_DISABLED_BG, BADGE_DISABLED_X);
            } else {
                const badge_col: u32 = if (is_active)
                    self.resolveActiveBadgeColor(thumb)
                else if (is_alert)
                    BADGE_ALERT
                else if (thumb.current_state == .Minimized)
                    BADGE_MINIMIZED
                else
                    BADGE_INACTIVE;

                drawDot(ov.pixels, W, H, badge_cx, badge_cy, BADGE_RADIUS, badge_col);
            }

            if (self.font) |f| {
                const old = win32.SelectObject(ov.mem_dc, f);
                defer {
                    if (old) |o| _ = win32.SelectObject(ov.mem_dc, o);
                }

                const name_col: u32 = (thumb.cached_character_color orelse ARGB_NAME_NORMAL) & 0xFFFFFF;

                const display_name = thumb.cached_display_name;
                const text_y = row_top + TEXT_PAD_Y;
                const text_left = col_left + TEXT_LEFT;

                const name_w = measureTextWidth(ov.mem_dc, display_name);
                const max_name_w: usize = @intCast(LIST_WIDTH - TEXT_LEFT - RIGHT_MARGIN - 70);

                if (name_w <= max_name_w) {
                    drawText(ov.mem_dc, display_name, text_left, text_y, name_col);
                } else {
                    drawTextTruncated(ov.mem_dc, ov.pixels, W, H, display_name, text_left, text_y, name_col, max_name_w);
                }

                var stat_buf: [64]u8 = undefined;
                const stat_text = self.buildStatText(&stat_buf, thumb);

                const right_text: []const u8 = if (thumb.active_notification) |notif|
                    notif.text
                else if (stat_text.len > 0)
                    stat_text
                else if (self.config.thumbnail.showSystemName)
                    thumb.system_name
                else
                    "";

                const right_col: u32 = if (thumb.active_notification) |notif|
                    (notif.text_color_override orelse ARGB_NOTIF_TEXT) & 0xFFFFFF
                else if (stat_text.len > 0)
                    self.statColor(thumb)
                else blk: {
                    if (thumb.system_name.len > 0) {
                        break :blk thumb.cached_system_color & 0xFFFFFF;
                    }
                    break :blk ARGB_SYS_TEXT & 0xFFFFFF;
                };

                if (right_text.len > 0) {
                    drawTextRight(ov.mem_dc, right_text, col_left + LIST_WIDTH - RIGHT_MARGIN, text_y, right_col, text_left);
                }
            }
        }

        // Vertical separators between columns, clipped to the taller of the two neighbouring columns' content so they don't run alongside empty cells.
        var sep_col: i32 = 1;
        while (sep_col < columns) : (sep_col += 1) {
            const x: usize = @intCast(sep_col * LIST_WIDTH);
            const left_items = itemsInColumn(n, columns, sep_col - 1);
            const right_items = itemsInColumn(n, columns, sep_col);
            const sep_rows = @max(left_items, right_items);
            const sep_h: usize = @intCast(sep_rows * ROW_HEIGHT);
            fillRect(ov.pixels, W, x, @intCast(HEADER_HEIGHT), 1, sep_h, ARGB_SEPARATOR);
        }

        // Outer frame staircased per-column so it hugs each column's content instead of the full (possibly taller) window rect.
        {
            const frame_col = self.withListAlpha(RGB_FRAME);
            // Top spans the full width since the header always does.
            fillRect(ov.pixels, W, 0, 0, W, 1, frame_col);
            // Left spans the full height since column 0 is always the tallest.
            fillRect(ov.pixels, W, 0, 0, 1, H, frame_col);

            var frame_c: i32 = 0;
            while (frame_c < columns) : (frame_c += 1) {
                const items = itemsInColumn(n, columns, frame_c);
                const bottom_y: usize = @intCast(HEADER_HEIGHT + items * ROW_HEIGHT - 1);
                const seg_left: usize = @intCast(frame_c * LIST_WIDTH);
                fillRect(ov.pixels, W, seg_left, bottom_y, @intCast(LIST_WIDTH), 1, frame_col);
            }

            const last_items = itemsInColumn(n, columns, columns - 1);
            const right_h: usize = @intCast(HEADER_HEIGHT + last_items * ROW_HEIGHT);
            fillRect(ov.pixels, W, W - 1, 0, 1, right_h, frame_col);
        }

        gdi_overlay.fixTextAlpha(ov.pixels, W, H);
        applyScanlines(ov.pixels, W, H);
        applyVignette(ov.pixels, W, H);

        const sdc = win32.GetDC(null) orelse return error.GetDCFailed;
        defer _ = win32.ReleaseDC(null, sdc);

        const sz = win32.SIZE{ .cx = win_w, .cy = win_h };
        const pt = win32.POINT{ .x = 0, .y = 0 };
        var blend = win32.BLENDFUNCTION{
            .BlendOp = win32.AC_SRC_OVER,
            .BlendFlags = 0,
            .SourceConstantAlpha = self.config.display.listViewOpacity,
            .AlphaFormat = win32.AC_SRC_ALPHA,
        };

        _ = win32.UpdateLayeredWindow(
            self.hwnd,
            sdc,
            null,
            @constCast(&sz),
            ov.mem_dc,
            @constCast(&pt),
            0,
            &blend,
            win32.ULW_ALPHA,
        );

        _ = win32.ShowWindow(self.hwnd, win32.SW_SHOWNOACTIVATE);
        self.last_render_signature = signature;
    }
};

fn registerClass(instance: win32.HINSTANCE) !void {
    if (g_class_registered) return;

    const cursor = win32.LoadCursorA(null, win32.IDC_ARROW);
    const wc = win32.WNDCLASSEXA{
        .cbSize = @sizeOf(win32.WNDCLASSEXA),
        .style = 0,
        .lpfnWndProc = listWindowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = cursor,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = LIST_WINDOW_CLASS,
        .hIconSm = null,
    };

    if (win32.RegisterClassExA(&wc) == 0) {
        return error.RegisterClassFailed;
    }

    g_class_registered = true;
}

fn listWindowProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wParam: win32.WPARAM,
    lParam: win32.LPARAM,
) callconv(.c) win32.LRESULT {
    switch (msg) {
        win32.WM_NCHITTEST => {
            const sy: i32 = @as(i32, @intCast(@as(i16, @truncate(lParam >> 16))));
            _ = @as(i32, @intCast(@as(i16, @truncate(lParam))));

            var wr: win32.RECT = undefined;
            _ = win32.GetWindowRect(hwnd, &wr);
            const cy = sy - wr.top;

            const painter_mod = @import("painter.zig");
            const dragging_enabled = if (painter_mod.g_painter_ptr) |p| p.config.interaction.enableDragging else true;

            if (dragging_enabled and cy < HEADER_HEIGHT) return HTCAPTION;
            return HTCLIENT;
        },

        win32.WM_ENTERSIZEMOVE => {
            _ = win32.GetCursorPos(&g_drag_anchor_cursor);
            _ = win32.GetWindowRect(hwnd, &g_drag_anchor_rect);
            return 0;
        },

        win32.WM_MOVING => {
            const rect: *win32.RECT = @ptrFromInt(@as(usize, @intCast(lParam)));
            const width = rect.right - rect.left;
            const height = rect.bottom - rect.top;

            // Compute the truly-intended position from the absolute cursor delta since drag start, ignoring Windows' possibly already-snapped rect (see g_drag_anchor_cursor above).
            var cursor: win32.POINT = undefined;
            _ = win32.GetCursorPos(&cursor);
            const intended_x = g_drag_anchor_rect.left + (cursor.x - g_drag_anchor_cursor.x);
            const intended_y = g_drag_anchor_rect.top + (cursor.y - g_drag_anchor_cursor.y);

            const input_mod = @import("input.zig");
            const snapped = input_mod.applySnapping(intended_x, intended_y, width, height, hwnd);

            rect.left = snapped.x;
            rect.top = snapped.y;
            rect.right = snapped.x + width;
            rect.bottom = snapped.y + height;
            return win32.TRUE;
        },

        win32.WM_EXITSIZEMOVE => {
            const painter_mod = @import("painter.zig");
            if (painter_mod.g_painter_ptr) |p| {
                if (p.list_window) |*lv| {
                    lv.saveWindowPosition();
                }
            }
            return 0;
        },

        win32.WM_LBUTTONDOWN => {
            const cx: i32 = @as(i32, @intCast(@as(i16, @truncate(lParam))));
            const cy: i32 = @as(i32, @intCast(@as(i16, @truncate(lParam >> 16))));
            // Header clicks are handled by WM_NCHITTEST.
            if (cy < HEADER_HEIGHT) return 0;

            const row: usize = @intCast(@divTrunc(cy - HEADER_HEIGHT, ROW_HEIGHT));
            const vkeys = @import("virtual_keys.zig");
            const shift_pressed = (win32.GetAsyncKeyState(@intCast(vkeys.VK_SHIFT)) & @as(c_short, @bitCast(@as(c_ushort, 0x8000)))) != 0;

            const painter_mod = @import("painter.zig");
            if (painter_mod.g_painter_ptr) |p| {
                if (p.list_window) |*lv| {
                    const columns: i32 = effectiveColumns(lv.config.display.listViewColumns, lv.row_source_hwnds.items.len);
                    const col: usize = @intCast(std.math.clamp(@divTrunc(cx, LIST_WIDTH), 0, columns - 1));
                    const index: usize = row * @as(usize, @intCast(columns)) + col;
                    if (index < lv.row_source_hwnds.items.len) {
                        const source_hwnd = lv.row_source_hwnds.items[index];
                        if (shift_pressed) {
                            if (g_shift_click_fn) |toggle_exclusion| {
                                toggle_exclusion(source_hwnd);
                            }
                        } else if (g_activate_fn) |activate| {
                            activate(source_hwnd);
                        } else {
                            // Fallback: basic foreground activation
                            _ = win32.ShowWindow(source_hwnd, win32.SW_RESTORE);
                            _ = win32.SetForegroundWindow(source_hwnd);
                        }
                    }
                }
            }
            return 0;
        },

        // Suppress background erase: this is a layered window.
        win32.WM_ERASEBKGND => return 1,

        else => return win32.DefWindowProcA(hwnd, msg, wParam, lParam),
    }
}

fn fillRect(pixels: [*]u32, stride: usize, x: usize, y: usize, w: usize, h: usize, argb: u32) void {
    const end_y = y + h;
    const end_x = x + w;
    if (end_x > stride) return;
    var py = y;
    while (py < end_y) : (py += 1) {
        @memset(pixels[py * stride + x .. py * stride + end_x], argb);
    }
}

fn drawDot(pixels: [*]u32, W: usize, H: usize, cx: i32, cy: i32, r: i32, argb: u32) void {
    const r2 = r * r;
    var dy: i32 = -r;
    while (dy <= r) : (dy += 1) {
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            if (dx * dx + dy * dy <= r2) {
                const px: i32 = cx + dx;
                const py: i32 = cy + dy;
                if (px >= 0 and py >= 0 and @as(usize, @intCast(px)) < W and @as(usize, @intCast(py)) < H) {
                    pixels[@as(usize, @intCast(py)) * W + @as(usize, @intCast(px))] = argb;
                }
            }
        }
    }
}

fn drawDisabledBadge(
    pixels: [*]u32,
    W: usize,
    H: usize,
    cx: i32,
    cy: i32,
    r: i32,
    bg_argb: u32,
    x_argb: u32,
) void {
    drawDot(pixels, W, H, cx, cy, r, bg_argb);

    const arm: i32 = @max(@as(i32, 2), r - 1);
    var d: i32 = -arm;
    while (d <= arm) : (d += 1) {
        const x1 = cx + d;
        const y1 = cy + d;
        const x2 = cx + d;
        const y2 = cy - d;

        if (x1 >= 0 and y1 >= 0 and @as(usize, @intCast(x1)) < W and @as(usize, @intCast(y1)) < H) {
            pixels[@as(usize, @intCast(y1)) * W + @as(usize, @intCast(x1))] = x_argb;
        }
        if (x2 >= 0 and y2 >= 0 and @as(usize, @intCast(x2)) < W and @as(usize, @intCast(y2)) < H) {
            pixels[@as(usize, @intCast(y2)) * W + @as(usize, @intCast(x2))] = x_argb;
        }
    }
}

fn scaleRgb(rgb: u32, factor_255: u32) u32 {
    const r: u32 = ((rgb >> 16) & 0xFF) * factor_255 / 255;
    const g: u32 = ((rgb >> 8) & 0xFF) * factor_255 / 255;
    const b: u32 = (rgb & 0xFF) * factor_255 / 255;
    return (r << 16) | (g << 8) | b;
}

fn applyScanlines(pixels: [*]u32, W: usize, H: usize) void {
    var y: usize = 1;
    while (y < H) : (y += 2) {
        var x: usize = 0;
        while (x < W) : (x += 1) {
            const idx = y * W + x;
            const p = pixels[idx];
            const a = p & 0xFF00_0000;
            if (a == 0) continue;
            const rgb = p & 0x00FF_FFFF;
            pixels[idx] = a | scaleRgb(rgb, 228);
        }
    }
}

fn applyVignette(pixels: [*]u32, W: usize, H: usize) void {
    if (W < 2 or H < 2) return;

    const cx: usize = W / 2;
    const cy: usize = H / 2;
    const max_dx: usize = @max(@as(usize, 1), cx);
    const max_dy: usize = @max(@as(usize, 1), cy);

    var y: usize = 0;
    while (y < H) : (y += 1) {
        var x: usize = 0;
        while (x < W) : (x += 1) {
            const idx = y * W + x;
            const p = pixels[idx];
            const a = p & 0xFF00_0000;
            if (a == 0) continue;

            const dx: usize = if (x >= cx) x - cx else cx - x;
            const dy: usize = if (y >= cy) y - cy else cy - y;

            const edge_x: u32 = if (dx * 2 > max_dx)
                @intCast((((dx * 2) - max_dx) * 255) / max_dx)
            else
                0;
            const edge_y: u32 = if (dy * 2 > max_dy)
                @intCast((((dy * 2) - max_dy) * 255) / max_dy)
            else
                0;
            const edge = @max(edge_x, edge_y);

            if (edge > 0) {
                const darken: u32 = 255 - (edge * 80 / 255);
                pixels[idx] = a | scaleRgb(p & 0x00FF_FFFF, darken);
            }
        }
    }
}

/// Draw text at (x, y) in client coordinates of the mem_dc.
fn drawText(dc: win32.HDC, text: []const u8, x: i32, y: i32, rgb: u32) void {
    _ = win32.SetBkMode(dc, win32.TRANSPARENT);
    var buf: [TEXT_BUF:0]u8 = undefined;
    const n = @min(text.len, TEXT_BUF - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;

    const base = rgb & 0x00FF_FFFF;
    const glow = scaleRgb(base, 108);
    _ = win32.SetTextColor(dc, gdi_overlay.toColorRef(glow));
    _ = win32.TextOutA(dc, x + 1, y, &buf, @intCast(n));
    _ = win32.TextOutA(dc, x, y + 1, &buf, @intCast(n));
    _ = win32.SetTextColor(dc, gdi_overlay.toColorRef(base));
    _ = win32.TextOutA(dc, x, y, &buf, @intCast(n));
}

/// Measure text width in pixels using the currently selected font.
fn measureTextWidth(dc: win32.HDC, text: []const u8) usize {
    var buf: [TEXT_BUF:0]u8 = undefined;
    const n = @min(text.len, TEXT_BUF - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    var sz: win32.SIZE = undefined;
    _ = win32.GetTextExtentPoint32A(dc, &buf, @intCast(n), &sz);
    return @intCast(@max(0, sz.cx));
}

/// Draw text right-aligned so its right edge is at pixel `right_x`.
/// `min_x` is the leftmost pixel the text may start at (to avoid overlapping the name text).
fn drawTextRight(dc: win32.HDC, text: []const u8, right_x: i32, y: i32, rgb: u32, min_x: i32) void {
    var buf: [TEXT_BUF:0]u8 = undefined;
    const n = @min(text.len, TEXT_BUF - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    var sz: win32.SIZE = undefined;
    _ = win32.GetTextExtentPoint32A(dc, &buf, @intCast(n), &sz);
    const x = right_x - sz.cx;
    if (x < min_x) return;
    drawText(dc, text[0..n], x, y, rgb);
}

/// Draw text truncated with "..." so it fits within max_w pixels.
fn drawTextTruncated(
    dc: win32.HDC,
    pixels: [*]u32,
    W: usize,
    H: usize,
    text: []const u8,
    x: i32,
    y: i32,
    rgb: u32,
    max_w: usize,
) void {
    _ = pixels;
    _ = W;
    _ = H;
    var buf: [TEXT_BUF:0]u8 = undefined;
    // -4 leaves room for the "..." suffix.
    const orig_n = @min(text.len, TEXT_BUF - 4);
    var lo: usize = 0;
    var hi: usize = orig_n;
    @memcpy(buf[0..orig_n], text[0..orig_n]);
    buf[orig_n] = 0;
    var sz: win32.SIZE = undefined;
    _ = win32.GetTextExtentPoint32A(dc, &buf, @intCast(orig_n), &sz);
    if (@as(usize, @intCast(@max(0, sz.cx))) <= max_w) {
        drawText(dc, text[0..orig_n], x, y, rgb);
        return;
    }
    // Find longest prefix that fits with "..."
    const ellipsis = "...";
    var ellipsis_w: win32.SIZE = undefined;
    _ = win32.GetTextExtentPoint32A(dc, ellipsis, 3, &ellipsis_w);
    const budget: i32 = @as(i32, @intCast(max_w)) - ellipsis_w.cx;
    if (budget <= 0) return;

    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        @memcpy(buf[0..mid], text[0..mid]);
        buf[mid] = 0;
        _ = win32.GetTextExtentPoint32A(dc, &buf, @intCast(mid), &sz);
        if (sz.cx <= budget) {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }

    var out: [TEXT_BUF:0]u8 = undefined;
    @memcpy(out[0..lo], text[0..lo]);
    @memcpy(out[lo .. lo + 3], ellipsis);
    out[lo + 3] = 0;
    drawText(dc, out[0 .. lo + 3], x, y, rgb);
}
