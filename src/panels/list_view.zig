//! The client list: one compact panel with a row per client, in place of or beside the thumbnail windows.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const panel_window = @import("../platform/panel_window.zig");
const config_mod = @import("../config.zig");
const types = @import("../config/types.zig");
const list_look = @import("list_look.zig");
const window = @import("../thumbnail/window.zig");
const header_panel = @import("header_panel.zig");
const panel_host = @import("panel_host.zig");
const template = @import("../notifications/template.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");

const PanelWindow = panel_window.PanelWindow;
const ThumbnailWindow = window.ThumbnailWindow;

const TEXT_BUFFER_SIZE: usize = 256;
/// Kept clear for the right-hand slot when a long name is cut short.
const RIGHT_SLOT_MIN_WIDTH: i32 = 70;

const LIST_WINDOW_CLASS = "EVE_LIST_CLASS";

const Class = header_panel.HeaderPanel(ListWindow, LIST_WINDOW_CLASS);

/// thumbnail_input's, passed in by App, so rows click like thumbnails without panels/ importing input code.
pub const RowInput = struct {
    press: *const fn (hwnd: win32.HWND, source_hwnd: win32.HWND) void,
    release: *const fn (hwnd: win32.HWND) void,
    /// False when Windows should set the class cursor.
    apply_hover_cursor: *const fn () bool,
};

const RowText = struct {
    name_font: win32.HFONT,
    small_font: win32.HFONT,
    name_height: i32,
    small_height: i32,
};

pub const ListWindow = struct {
    panel: PanelWindow,
    /// Borrowed; outlives the window.
    store: *config_mod.ProfileStore,
    /// Borrows store.live.
    config: *const config_mod.Config,
    /// For drag snapping to the thumbnails.
    host: panel_host.Host,
    row_input: RowInput,
    /// Indices into the thumbnails render() was given, one per row in display order; hidden characters get none.
    rows: std.ArrayList(usize) = .empty,
    /// Each row's client, for clicks between renders.
    row_source_hwnds: std.ArrayList(win32.HWND) = .empty,

    pub fn init(context: panel_host.Context, host: panel_host.Host, row_input: RowInput) !ListWindow {
        const config = &context.store.live;
        try Class.register(context.instance);
        const x = config.display.startX;
        const y = config.display.startY;
        const sizes = list_look.metrics(&config.listView);
        const panel = try PanelWindow.init(context.allocator, context.instance, LIST_WINDOW_CLASS, "EVE Client List", .{ .left = x, .top = y, .right = x + sizes.column_width, .bottom = y + sizes.header_height }, config.listView.alwaysOnTop);
        win32.setClickThroughStyle(panel.hwnd, config.interaction.clickThrough);
        return .{ .panel = panel, .store = context.store, .config = config, .host = host, .row_input = row_input };
    }

    pub fn deinit(self: *ListWindow) void {
        self.rows.deinit(self.panel.allocator);
        self.row_source_hwnds.deinit(self.panel.allocator);
        self.panel.deinit();
    }

    /// Matches the panel to its configured position.
    pub fn sync(self: *ListWindow) void {
        self.panel.followPosition(self.config.display.startX, self.config.display.startY);
        win32.setClickThroughStyle(self.panel.hwnd, self.config.interaction.clickThrough);
    }

    /// From the last render; null over the header or an empty cell.
    fn rowSourceAt(self: *const ListWindow, x: i32, y: i32) ?win32.HWND {
        const sizes = list_look.metrics(&self.config.listView);
        if (y < sizes.header_height) return null;
        const row: usize = @intCast(@divTrunc(y - sizes.header_height, sizes.row_height));
        const columns: i32 = list_look.effectiveColumns(self.config.listView.columns, self.row_source_hwnds.items.len);
        const column: usize = @intCast(std.math.clamp(@divTrunc(x, sizes.column_width), 0, columns - 1));
        const index: usize = row * @as(usize, @intCast(columns)) + column;
        if (index >= self.row_source_hwnds.items.len) return null;
        return self.row_source_hwnds.items[index];
    }

    pub fn headerHeight(self: *const ListWindow) i32 {
        return list_look.metrics(&self.config.listView).header_height;
    }

    pub fn saveWindowPosition(self: *const ListWindow) void {
        if (!self.config.listView.rememberPosition) return;
        const top_left = self.panel.topLeft() orelse return;
        self.store.update(.{ .display = .{ .startX = top_left.x, .startY = top_left.y } });
    }

    /// Null for a message left to Windows.
    pub fn handleMessage(self: *ListWindow, hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) ?win32.LRESULT {
        _ = wParam;
        switch (msg) {
            win32.WM_LBUTTONDOWN => {
                const source_hwnd = self.rowSourceAt(win32.lparamX(lParam), win32.lparamY(lParam)) orelse return 0;
                self.row_input.press(hwnd, source_hwnd);
                return 0;
            },
            win32.WM_LBUTTONUP => {
                self.row_input.release(hwnd);
                return 0;
            },
            win32.WM_SETCURSOR => {
                // Rows only: the header is the drag handle.
                const hit_test: win32.LRESULT = @as(u16, @truncate(@as(usize, @bitCast(lParam))));
                if (hit_test == win32.HTCLIENT and self.row_input.apply_hover_cursor()) return 1;
                return null;
            },
            else => return null,
        }
    }

    /// The shown active colour, or the character's own (or unique) active border colour.
    fn resolveActiveBadgeColor(self: *const ListWindow, thumbnail: *const ThumbnailWindow) u32 {
        if (thumbnail.cached_border_colors) |colors| {
            if (colors.activeBorderColor) |color| return color;
        }
        return self.config.shownColors().active_color;
    }

    /// Puts `rows` in the configured order and records each row's client.
    fn sortRows(self: *ListWindow, thumbnails: []const ThumbnailWindow) !void {
        const AlphabeticalContext = struct {
            thumbnails: []const ThumbnailWindow,

            fn lessThan(context: @This(), first_index: usize, second_index: usize) bool {
                const first = &context.thumbnails[first_index];
                const second = &context.thumbnails[second_index];
                switch (std.ascii.orderIgnoreCase(first.cached_display_name, second.cached_display_name)) {
                    .lt => return true,
                    .gt => return false,
                    .eq => {},
                }
                switch (std.ascii.orderIgnoreCase(first.character_name, second.character_name)) {
                    .lt => return true,
                    .gt => return false,
                    .eq => return first_index < second_index,
                }
            }
        };
        const ConfiguredContext = struct {
            thumbnails: []const ThumbnailWindow,
            order_map: *const std.StringHashMap(usize),

            fn lessThan(context: @This(), first_index: usize, second_index: usize) bool {
                return config_mod.orderMapLessThan(context.order_map, context.thumbnails[first_index].character_name, context.thumbnails[second_index].character_name, first_index, second_index);
            }
        };

        // Rows start in tracked order.
        switch (self.config.listView.order) {
            .Tracked => {},
            .Alphabetical => std.sort.pdq(usize, self.rows.items, AlphabeticalContext{ .thumbnails = thumbnails }, AlphabeticalContext.lessThan),
            .ConfiguredCharacters => {
                // Built once per sort, not per comparison.
                var order_map = try config_mod.buildCharacterOrderMap(self.config.characters.items, self.panel.allocator);
                defer order_map.deinit();
                std.sort.pdq(usize, self.rows.items, ConfiguredContext{ .thumbnails = thumbnails, .order_map = &order_map }, ConfiguredContext.lessThan);
            },
        }

        try self.row_source_hwnds.resize(self.panel.allocator, self.rows.items.len);
        for (self.rows.items, self.row_source_hwnds.items) |thumbnail_index, *hwnd| hwnd.* = thumbnails[thumbnail_index].source_hwnd;
    }

    /// A hash of everything that affects the rendered pixels, to skip the redraw when nothing changed.
    fn computeRenderSignature(self: *const ListWindow, thumbnails: []const ThumbnailWindow, active_source_hwnd: ?win32.HWND) u64 {
        const list_settings = &self.config.listView;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&self.rows.items.len));
        hasher.update(std.mem.asBytes(&list_settings.columns));
        hasher.update(std.mem.asBytes(&list_settings.columnWidth));
        hasher.update(std.mem.asBytes(&list_settings.order));
        hasher.update(std.mem.asBytes(&list_settings.opacity));
        hasher.update(list_settings.fontName);
        hasher.update(std.mem.asBytes(&list_settings.fontSize));
        hasher.update(std.mem.asBytes(&list_settings.fontWeight));
        hasher.update(std.mem.asBytes(&list_settings.showSystemName));
        hasher.update(std.mem.asBytes(&list_settings.indicatorStyle));
        hasher.update(std.mem.asBytes(&list_settings.showNotifications));
        hasher.update(std.mem.asBytes(&list_settings.notificationColor));
        hasher.update(std.mem.asBytes(&list_settings.showIncomingDps));
        hasher.update(std.mem.asBytes(&list_settings.showIncomingPrefix));
        hasher.update(std.mem.asBytes(&list_settings.incomingDpsColor));
        hasher.update(std.mem.asBytes(&list_settings.showOutgoingDps));
        hasher.update(std.mem.asBytes(&list_settings.showOutgoingPrefix));
        hasher.update(std.mem.asBytes(&list_settings.outgoingDpsColor));
        hasher.update(std.mem.asBytes(&list_settings.showMiningRate));
        hasher.update(std.mem.asBytes(&list_settings.showMiningPrefix));
        hasher.update(std.mem.asBytes(&list_settings.miningRateColor));
        hasher.update(std.mem.asBytes(&list_settings.showBountyRate));
        hasher.update(std.mem.asBytes(&list_settings.showBountyPrefix));
        hasher.update(std.mem.asBytes(&list_settings.bountyRateColor));
        hasher.update(std.mem.asBytes(&self.config.combat.enabled));
        hasher.update(std.mem.asBytes(&self.config.mining.enabled));
        hasher.update(std.mem.asBytes(&self.config.bounty.enabled));
        hasher.update(std.mem.asBytes(&self.config.bounty.isk_rate_unit));
        // Rows are hashed before they're sorted, so the configured order has to be hashed itself.
        if (list_settings.order == .ConfiguredCharacters) {
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
            if (thumbnail.cached_character_color) |character_color| hasher.update(std.mem.asBytes(&character_color));
            if (render_state == .active) {
                const badge_color = self.resolveActiveBadgeColor(thumbnail);
                hasher.update(std.mem.asBytes(&badge_color));
            }
            for (thumbnail.notifications.items()) |notification| {
                hashString(&hasher, notification.text);
                hasher.update(std.mem.asBytes(&notification.border_color_override));
                hasher.update(std.mem.asBytes(&notification.text_color_override));
                hasher.update(std.mem.asBytes(&notification.shows_text));
                if (notification.lead) |lead| hasher.update(std.mem.asBytes(&lead.color));
            }
        }

        return hasher.final();
    }

    /// In writing order; empty when the list shows none.
    fn statReadings(self: *const ListWindow, thumbnail: *const ThumbnailWindow, out: *[list_look.STAT_COUNT]list_look.StatReading) []const list_look.StatReading {
        const config = self.config;
        const settings: list_look.StatSettings = .{ .list_settings = &config.listView, .combat = &config.combat, .mining = &config.mining, .bounty = &config.bounty };
        const stats = &thumbnail.stats;
        const bounty_period_seconds = config.bounty.isk_rate_unit.seconds();
        var reading_count: usize = 0;
        for (std.enums.values(list_look.Stat)) |stat| {
            if (!list_look.showsStat(settings, stat)) continue;
            const value: ?f32 = switch (stat) {
                .incoming_dps => if (stats.showsIncoming()) stats.incoming_dps else continue,
                .outgoing_dps => if (stats.showsOutgoing()) stats.outgoing_dps else continue,
                .mining_rate => if (stats.showsMining()) (if (stats.mining_rate) |rate| rate * 60.0 else null) else continue,
                .bounty_rate => if (stats.showsBounty()) (if (stats.bounty_isk_rate) |rate| rate * bounty_period_seconds else null) else continue,
            };
            out[reading_count] = .{ .stat = stat, .value = value, .has_prefix = list_look.hasPrefix(&config.listView, stat) };
            reading_count += 1;
        }
        return out[0..reading_count];
    }

    /// Called every tick; redraws only when the render signature changed.
    pub fn render(self: *ListWindow, thumbnails: []const ThumbnailWindow, active_source_hwnd: ?win32.HWND) !void {
        const list_settings = &self.config.listView;
        self.panel.followTopmost(list_settings.alwaysOnTop);
        try self.panel.ensureFont("List View", list_settings.fontName, list_settings.fontSize, list_settings.fontWeight);
        try self.panel.ensureSmallFont("List View small", list_settings.fontName, list_look.smallFontSize(list_settings.fontSize), list_settings.fontWeight);

        self.rows.clearRetainingCapacity();
        var has_visible_row = false;
        for (thumbnails, 0..) |*thumbnail, i| {
            if (thumbnail.cached_hide_thumbnail) continue;
            try self.rows.append(self.panel.allocator, i);
            if (thumbnail.isShown()) has_visible_row = true;
        }
        // Also hidden once the visibility toggle or auto-hide has hidden every client.
        if (!has_visible_row) {
            self.panel.hide();
            return;
        }

        const signature = self.computeRenderSignature(thumbnails, active_source_hwnd);
        if (self.panel.isUnchanged(signature)) return;

        try self.sortRows(thumbnails);

        const row_count: i32 = @intCast(self.rows.items.len);
        const columns = list_look.effectiveColumns(list_settings.columns, self.rows.items.len);
        const sizes = list_look.metrics(list_settings);
        const rows_per_column: i32 = @divTrunc(row_count + columns - 1, columns);
        const bitmap = try self.panel.beginFrame(columns * sizes.column_width, sizes.header_height + rows_per_column * sizes.row_height + list_look.BOTTOM_PADDING);
        const width: usize = bitmap.width;
        const height: usize = bitmap.height;
        const dc = bitmap.mem_dc;

        pixel_buffer.fillRect(bitmap.canvas(), 0, 0, width, height, list_look.PANEL);
        pixel_buffer.fillRect(bitmap.canvas(), 0, @intCast(sizes.header_height - 1), width, 1, list_look.DIVIDER);

        var row_text: ?RowText = null;
        var old_font: ?win32.HANDLE = null;
        if (self.panel.font.handle) |name_font| {
            if (self.panel.small_font.handle) |small_font| {
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

        pixel_buffer.fixTextAlpha(bitmap.canvas());
        pixel_buffer.drawRoundedFrame(bitmap.canvas(), list_look.CORNER_RADIUS, list_look.BORDER);

        self.panel.present(list_settings.opacity, signature);
    }

    /// `row_index` is in display order.
    fn drawRow(self: *const ListWindow, bitmap: *const gdi_overlay.OverlayBitmap, thumbnail: *const ThumbnailWindow, row_index: usize, columns: i32, sizes: list_look.Metrics, row_text: ?RowText, active_source_hwnd: ?win32.HWND) void {
        const list_settings = &self.config.listView;
        const column_count: usize = @intCast(columns);
        const row: i32 = @intCast(row_index / column_count);
        const column: i32 = @intCast(row_index % column_count);
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
        if (tint) |row_color| pixel_buffer.fillRect(bitmap.canvas(), @intCast(column_left), @intCast(row_top), @intCast(sizes.column_width), @intCast(sizes.row_height), row_color);

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
        const indicator_style = list_settings.indicatorStyle;
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

        // One slot only: the newest notification with text wins, then stats, then exclusion, then the system.
        var notification_buffer: [TEXT_BUFFER_SIZE]u8 = undefined;
        const newest = if (list_settings.showNotifications) thumbnail.notifications.newestWithText() else null;
        if (newest) |notification| {
            const line = template.oneLine(notification.text, &notification_buffer);
            const line_color = notification.text_color_override orelse list_settings.notificationColor;
            if (notification.lead) |lead| {
                drawTextWithLeadRight(dc, line, lead.length, lead.color, right_x, small_y, line_color, text_left);
            } else {
                drawTextRight(dc, line, right_x, small_y, line_color, text_left);
            }
        } else if (readings.len > 0) {
            drawStatsRight(dc, list_settings, readings, right_x, small_y, text_left);
        } else if (is_excluded) {
            drawTextRight(dc, "Excluded", right_x, small_y, list_look.MUTED, text_left);
        } else if (list_settings.showSystemName and thumbnail.system_name.len > 0) {
            drawTextRight(dc, thumbnail.system_name, right_x, small_y, thumbnail.cached_system_color, text_left);
        }
    }
};

/// The newest notification's border colour, which tints an alerting row.
fn alertColor(thumbnail: *const ThumbnailWindow) u32 {
    const notification = thumbnail.notifications.newest() orelse return list_look.BADGE_ALERT;
    return notification.border_color_override orelse list_look.BADGE_ALERT;
}

fn drawIndicator(bitmap: *const gdi_overlay.OverlayBitmap, style: types.ListIndicatorStyle, column_left: i32, row_top: i32, row_height: i32, argb: u32) void {
    const canvas = bitmap.canvas();
    const radius = list_look.BADGE_RADIUS;
    const center_x = column_left + list_look.PADDING_X + radius;
    const center_y = row_top + @divTrunc(row_height, 2);
    switch (style) {
        .Dot => drawDot(canvas, center_x, center_y, radius, argb),
        .Square => pixel_buffer.fillRect(canvas, @intCast(center_x - radius), @intCast(center_y - radius), @intCast(radius * 2), @intCast(radius * 2), argb),
        .None => {},
    }
}

fn drawDot(canvas: pixel_buffer.Canvas, center_x: i32, center_y: i32, radius: i32, argb: u32) void {
    const width = canvas.width;
    const radius_squared = radius * radius;
    var delta_y: i32 = -radius;
    while (delta_y <= radius) : (delta_y += 1) {
        var delta_x: i32 = -radius;
        while (delta_x <= radius) : (delta_x += 1) {
            if (delta_x * delta_x + delta_y * delta_y <= radius_squared) {
                const x: i32 = center_x + delta_x;
                const y: i32 = center_y + delta_y;
                if (x >= 0 and y >= 0 and @as(usize, @intCast(x)) < width and @as(usize, @intCast(y)) < canvas.height) {
                    canvas.pixels[@as(usize, @intCast(y)) * width + @as(usize, @intCast(x))] = argb;
                }
            }
        }
    }
}

/// Ignores `argb`'s alpha byte.
fn drawText(dc: win32.HDC, text: []const u8, x: i32, y: i32, argb: u32) void {
    _ = win32.SetBkMode(dc, win32.TRANSPARENT);
    const terminated_text = gdi_overlay.terminatedCopy(TEXT_BUFFER_SIZE, text);
    const length = @min(text.len, TEXT_BUFFER_SIZE - 1);
    _ = win32.SetTextColor(dc, gdi_overlay.toColorRef(argb & 0x00FF_FFFF));
    _ = win32.TextOutA(dc, x, y, &terminated_text, @intCast(length));
}

fn lineHeight(dc: win32.HDC) i32 {
    return gdi_overlay.measureTextSize(TEXT_BUFFER_SIZE, dc, "Ag").cy;
}

fn measureTextWidth(dc: win32.HDC, text: []const u8) usize {
    return gdi_overlay.measureTextWidth(TEXT_BUFFER_SIZE, dc, text);
}

/// Right edge at `right_x`; skipped rather than drawn left of `min_x`, where it would overlap the name.
fn drawTextRight(dc: win32.HDC, text: []const u8, right_x: i32, y: i32, argb: u32, min_x: i32) void {
    drawTextWithLeadRight(dc, text, 0, argb, right_x, y, argb, min_x);
}

/// Like drawTextRight, with the first `lead_length` bytes in `lead_color`.
fn drawTextWithLeadRight(dc: win32.HDC, text: []const u8, lead_length: usize, lead_color: u32, right_x: i32, y: i32, argb: u32, min_x: i32) void {
    const length = @min(text.len, TEXT_BUFFER_SIZE - 1);
    const x = right_x - @as(i32, @intCast(measureTextWidth(dc, text[0..length])));
    if (x < min_x) return;
    const lead_end = @min(lead_length, length);
    drawText(dc, text[0..lead_end], x, y, lead_color);
    drawText(dc, text[lead_end..length], x + @as(i32, @intCast(measureTextWidth(dc, text[0..lead_end]))), y, argb);
}

/// Each reading in its own colour, a space apart; skipped like drawTextRight past `min_x`.
fn drawStatsRight(dc: win32.HDC, list_settings: *const config_mod.ListViewConfig, readings: []const list_look.StatReading, right_x: i32, y: i32, min_x: i32) void {
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
        drawText(dc, texts[index][0..lengths[index]], x, y, list_look.statColor(list_settings, reading.stat));
        x += widths[index] + gap;
    }
}

fn drawTextTruncated(dc: win32.HDC, text: []const u8, x: i32, y: i32, argb: u32, max_width: usize) void {
    var out: [TEXT_BUFFER_SIZE:0]u8 = undefined;
    const truncated = gdi_overlay.truncateTextToFit(TEXT_BUFFER_SIZE, dc, &out, text, max_width);
    drawText(dc, truncated, x, y, argb);
}

/// Length-prefixed, so swapping "Bob" and "BobBob" can't leave the hashed byte stream unchanged.
fn hashString(hasher: *std.hash.Wyhash, text: []const u8) void {
    hasher.update(std.mem.asBytes(&text.len));
    hasher.update(text);
}
