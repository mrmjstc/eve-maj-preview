//! The History Panel: a draggable list of recent notifications, with category filter buttons.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const PanelWindow = @import("../platform/panel_window.zig").PanelWindow;
const config_mod = @import("../config.zig");
const list_look = @import("../thumbnail/list_look.zig");
const notification = @import("notification.zig");
const history = @import("history.zig");
const history_look = @import("history_look.zig");
const painter_mod = @import("../painter.zig");
const activation = @import("../clients/activation.zig");
const drag_panel = @import("../drag/panel.zig");
const log = @import("../log.zig");

const slog = log.scoped("history_panel");

const TEXT_BUF: usize = 160;

/// Granularity of the timestamp text baked into the render signature, so it doesn't redraw every scan tick.
const TIMESTAMP_BUCKET_MS: u64 = 15_000;

const HISTORY_PANEL_WINDOW_CLASS = "EVE_HISTORY_PANEL_CLASS";

/// The fonts the text draws with, and their line heights.
const PanelText = struct {
    name_font: win32.HFONT,
    small_font: win32.HFONT,
    name_height: i32,
    small_height: i32,
};

/// Owns the History Panel window and when it's on-screen: display.showNotifInfoPanel creates it, hideNotifInfoPanelWhenNoCharacters auto-hides it, and the tray toggle can force it visible.
pub const HistoryPanel = struct {
    window: ?HistoryPanelWindow = null,
    /// Tray-toggle override: forces the panel visible past hideNotifInfoPanelWhenNoCharacters until characters go logged-in -> logged-out again.
    force_visible: bool = false,
    /// Last-seen "any character logged in", used to detect the logged-in -> logged-out edge that clears force_visible.
    had_characters: bool = false,

    pub fn init(allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE) HistoryPanel {
        if (!store.live.display.showNotifInfoPanel) return .{};
        const window = HistoryPanelWindow.init(allocator, store, instance) catch |err| {
            slog.err("Failed to create History Panel window: {}", .{err});
            return .{};
        };
        return .{ .window = window };
    }

    pub fn deinit(self: *HistoryPanel) void {
        if (self.window) |*window| window.deinit();
        self.window = null;
    }

    /// Whether the panel is actually on-screen, accounting for hideNotifInfoPanelWhenNoCharacters and the tray-toggle override; drives both the render/hide gate and the tray menu's checked state.
    pub fn isVisible(self: *const HistoryPanel, config: *const config_mod.Config, any_character_logged_in: bool) bool {
        if (self.window == null) return false;
        if (!config.display.hideNotifInfoPanelWhenNoCharacters) return true;
        return any_character_logged_in or self.force_visible;
    }

    /// Keyed on isVisible() rather than window existence, so it turns fully off (not re-hidden) when toggled while visible, and forces it on immediately - even with no characters logged in - when toggled while off/auto-hidden.
    pub fn toggle(self: *HistoryPanel, allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE, any_character_logged_in: bool) void {
        if (self.isVisible(&store.live, any_character_logged_in)) {
            self.deinit();
            store.update(.{ .display = .{ .showNotifInfoPanel = false } });
            self.force_visible = false;
            return;
        }
        if (self.window == null) {
            self.window = HistoryPanelWindow.init(allocator, store, instance) catch |err| {
                slog.err("Failed to create History Panel window: {}", .{err});
                return;
            };
        }
        store.update(.{ .display = .{ .showNotifInfoPanel = true } });
        self.force_visible = true;
    }

    /// Matches the window to showNotifInfoPanel and its configured position, for a change made in the config dialog rather than by `toggle`.
    pub fn sync(self: *HistoryPanel, allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE) void {
        const wanted = store.live.display.showNotifInfoPanel;
        if (!wanted and self.window != null) {
            self.deinit();
            self.force_visible = false;
        } else if (wanted and self.window == null) {
            self.window = HistoryPanelWindow.init(allocator, store, instance) catch |err| {
                slog.err("Failed to create History Panel window: {}", .{err});
                return;
            };
        }
        if (self.window) |*window| window.panel.followPosition(store.live.display.notifInfoPanelX, store.live.display.notifInfoPanelY);
    }

    /// Per-tick: renders the panel from the painter's live history, or hides it.
    pub fn update(self: *HistoryPanel, painter: *const painter_mod.Painter, any_character_logged_in: bool) void {
        if (self.had_characters and !any_character_logged_in) self.force_visible = false;
        self.had_characters = any_character_logged_in;

        const window = if (self.window) |*w| w else return;
        if (self.isVisible(painter.config, any_character_logged_in)) {
            window.render(painter) catch |err| {
                slog.err("Failed to render History Panel window: {}", .{err});
            };
        } else {
            window.hide();
        }
    }
};

/// `first`/`last` are newest-first history indices, equal unless merged.
const HistoryRow = struct {
    hwnd: win32.HWND,
    count: usize,
    first: usize,
    last: usize,
};

pub const HistoryPanelWindow = struct {
    panel: PanelWindow,
    store: *config_mod.ProfileStore,
    config: *const config_mod.Config,
    history_rows: [history.CAPACITY]HistoryRow = undefined,
    history_row_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE) !HistoryPanelWindow {
        const display = &store.live.display;
        try registerWindowClass(instance);
        const panel = try PanelWindow.create(allocator, instance, HISTORY_PANEL_WINDOW_CLASS, "EVE Notification History", .{
            .left = display.notifInfoPanelX,
            .top = display.notifInfoPanelY,
            .right = display.notifInfoPanelX + display.notifInfoPanelWidth,
            .bottom = display.notifInfoPanelY + display.notifInfoPanelHeight,
        });
        return .{ .panel = panel, .store = store, .config = &store.live };
    }

    pub fn deinit(self: *HistoryPanelWindow) void {
        self.panel.deinit();
    }

    pub fn hide(self: *const HistoryPanelWindow) void {
        self.panel.hide();
    }

    fn saveWindowPosition(self: *HistoryPanelWindow) void {
        if (!self.config.display.rememberNotifInfoPanelPosition) return;
        const top_left = self.panel.topLeft();
        self.store.update(.{ .display = .{ .notifInfoPanelX = top_left.x, .notifInfoPanelY = top_left.y } });
    }

    fn messageColor(self: *const HistoryPanelWindow, notification_type: notification.NotificationType) u32 {
        return history_look.messageColor(&self.config.thumbnail.notifications, notification_type);
    }

    fn handleFooterClick(self: *HistoryPanelWindow, x: i32) void {
        const category = history_look.filterAt(self.panel.width, x) orelse return;
        setCategoryEnabled(self.store, category, !history_look.categoryEnabled(&self.config.display, category));
    }

    fn computeRenderSignature(self: *const HistoryPanelWindow, painter: *const painter_mod.Painter) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelWidth));
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelHeight));
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelOpacity));
        h.update(self.config.display.notifInfoPanelFontName);
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelFontSize));
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelFontWeight));
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelMaxRows));
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelShowTimestamp));
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelShowCategoryFilters));
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelMergeEnabled));
        h.update(std.mem.asBytes(&self.config.display.notifInfoPanelMergeWindowSec));
        for (history_look.CATEGORY_ORDER) |category| {
            const is_enabled = history_look.categoryEnabled(&self.config.display, category);
            h.update(std.mem.asBytes(&is_enabled));
        }
        h.update(std.mem.asBytes(&painter.notification_history.revision));

        const show_timestamp = self.config.display.notifInfoPanelShowTimestamp;
        const now = win32.Ticks.now();

        var entry_buf: [history.CAPACITY]history.Entry = undefined;
        const entries = painter.notification_history.snapshot(&entry_buf);
        for (entries) |*entry| {
            h.update(entry.characterName());
            h.update(entry.text());
            h.update(std.mem.asBytes(&entry.unmerged));
            const name_color = entry.character_color orelse list_look.NAME;
            const message_color = self.messageColor(entry.notification_type);
            h.update(std.mem.asBytes(&name_color));
            h.update(std.mem.asBytes(&message_color));
            if (show_timestamp) {
                const bucket = now.elapsedSince(entry.timestamp_ms) / TIMESTAMP_BUCKET_MS;
                h.update(std.mem.asBytes(&bucket));
            }
        }

        return h.final();
    }

    /// Fills history_rows from `entries`, skipping filtered categories and merging repeats, up to `capacity` rows.
    fn buildRows(self: *HistoryPanelWindow, entries: []const history.Entry, capacity: usize) void {
        const display = &self.config.display;
        const merge_window_ms: u64 = @as(u64, @intCast(@max(0, display.notifInfoPanelMergeWindowSec))) * 1000;
        const row_limit = @min(capacity, self.history_rows.len);
        var shown_count: usize = 0;
        for (entries, 0..) |*entry, i| {
            if (!history_look.showsCategory(display, notification.notificationCategory(entry.notification_type))) continue;

            if (display.notifInfoPanelMergeEnabled and shown_count > 0 and !entry.unmerged) {
                const row = &self.history_rows[shown_count - 1];
                const previous = &entries[row.last];
                if (!previous.unmerged and previous.notification_type == entry.notification_type and
                    std.mem.eql(u8, previous.text(), entry.text()) and
                    previous.timestamp_ms.elapsedSince(entry.timestamp_ms) <= merge_window_ms)
                {
                    row.count += 1;
                    row.last = i;
                    continue;
                }
            }

            if (shown_count >= row_limit) break;
            self.history_rows[shown_count] = .{ .hwnd = entry.source_hwnd, .count = 1, .first = i, .last = i };
            shown_count += 1;
        }
        self.history_row_count = shown_count;
    }

    /// Called every painter tick; redraws only when the render signature changed.
    pub fn render(self: *HistoryPanelWindow, painter: *const painter_mod.Painter) !void {
        const display = &self.config.display;
        try self.panel.ensureFont("History Panel", display.notifInfoPanelFontName, display.notifInfoPanelFontSize, display.notifInfoPanelFontWeight);
        try self.panel.ensureSmallFont("History Panel small", display.notifInfoPanelFontName, list_look.smallFontSize(display.notifInfoPanelFontSize), display.notifInfoPanelFontWeight);

        const signature = self.computeRenderSignature(painter);
        if (self.panel.isUnchanged(signature)) return;

        var entry_buf: [history.CAPACITY]history.Entry = undefined;
        const entries = painter.notification_history.snapshot(&entry_buf);
        const sizes = history_look.metrics(display);
        self.buildRows(entries, history_look.rowCapacity(display, sizes));

        const panel_width: i32 = @max(1, display.notifInfoPanelWidth);
        const panel_height: i32 = @max(1, display.notifInfoPanelHeight);
        const bitmap = try self.panel.beginFrame(panel_width, panel_height);
        const width: usize = bitmap.width;
        const height: usize = bitmap.height;
        const dc = bitmap.mem_dc;
        // A large font can leave no room below the header.
        const footer_top = @max(sizes.header_height, panel_height - sizes.footer_height);

        gdi_overlay.fillRect(bitmap.pixels, width, height, 0, 0, width, height, list_look.PANEL);
        gdi_overlay.fillRect(bitmap.pixels, width, height, 0, @intCast(sizes.header_height - 1), width, 1, list_look.DIVIDER);
        if (sizes.footer_height > 0) {
            gdi_overlay.fillRect(bitmap.pixels, width, height, 0, @intCast(footer_top), width, 1, list_look.DIVIDER);
            for (history_look.CATEGORY_ORDER, 0..) |category, index| {
                if (!history_look.categoryEnabled(display, category)) continue;
                const span = history_look.filterSpan(panel_width, index);
                gdi_overlay.fillRoundedRect(bitmap.pixels, width, height, @intCast(span.left), @intCast(footer_top + history_look.FILTER_GAP), @intCast(span.right - span.left), @intCast(sizes.header_height), history_look.FILTER_RADIUS, history_look.FILTER_ON);
            }
        }

        if (self.panel.font) |name_font| {
            if (self.panel.small_font) |small_font| {
                const old_font = win32.SelectObject(dc, small_font);
                // A font still selected into the DC can't be deleted when the settings change.
                defer if (old_font) |font| {
                    _ = win32.SelectObject(dc, font);
                };
                const small_height = lineHeight(dc);
                _ = win32.SelectObject(dc, name_font);
                const text: PanelText = .{ .name_font = name_font, .small_font = small_font, .name_height = lineHeight(dc), .small_height = small_height };
                self.drawText(dc, entries, sizes, panel_width, footer_top, text);
            }
        }

        gdi_overlay.fixTextAlpha(bitmap.pixels, width, height);
        gdi_overlay.drawRoundedFrame(bitmap, list_look.CORNER_RADIUS, list_look.BORDER);
        self.panel.present(display.notifInfoPanelOpacity, signature);
    }

    /// The header, the rows (or why there are none) and the filter buttons' labels.
    fn drawText(self: *const HistoryPanelWindow, dc: win32.HDC, entries: []const history.Entry, sizes: history_look.Metrics, panel_width: i32, footer_top: i32, text: PanelText) void {
        _ = win32.SelectObject(dc, text.small_font);
        drawLine(dc, history_look.HEADER_TEXT, list_look.PADDING_X, @divTrunc(sizes.header_height - text.small_height, 2), list_look.MUTED);
        if (sizes.footer_height > 0) self.drawFilterLabels(dc, panel_width, footer_top + history_look.FILTER_GAP + @divTrunc(sizes.header_height - text.small_height, 2));

        _ = win32.SelectObject(dc, text.name_font);
        if (self.history_row_count == 0) {
            const empty_text = if (entries.len == 0) "No notifications yet" else "All notifications filtered";
            drawLine(dc, empty_text, list_look.PADDING_X, sizes.header_height + @divTrunc(sizes.row_height - text.name_height, 2), list_look.MUTED);
            return;
        }
        const now = win32.Ticks.now();
        for (self.history_rows[0..self.history_row_count], 0..) |row, index| {
            const row_top = sizes.header_height + @as(i32, @intCast(index)) * sizes.row_height;
            self.drawRow(dc, entries, row, row_top, sizes.row_height, panel_width - list_look.PADDING_X, text, now);
        }
    }

    /// The name (or a merged row's count) then the message in the main font, and the timestamp right-aligned at `right` in the small one.
    fn drawRow(self: *const HistoryPanelWindow, dc: win32.HDC, entries: []const history.Entry, row: HistoryRow, row_top: i32, row_height: i32, right: i32, text: PanelText, now: win32.Ticks) void {
        const entry = &entries[row.first];
        const left = list_look.PADDING_X;
        var message_right = right;
        if (self.config.display.notifInfoPanelShowTimestamp) {
            var time_buf: [history_look.TIME_TEXT_MAX]u8 = undefined;
            const time_text = history_look.relativeTime(&time_buf, now.elapsedSince(entry.timestamp_ms));
            _ = win32.SelectObject(dc, text.small_font);
            const time_width: i32 = @intCast(measureTextWidth(dc, time_text));
            drawLine(dc, time_text, @max(left, right - time_width), row_top + @divTrunc(row_height - text.small_height, 2), list_look.MUTED);
            _ = win32.SelectObject(dc, text.name_font);
            message_right = right - time_width - history_look.TEXT_GAP;
        }

        const y = row_top + @divTrunc(row_height - text.name_height, 2);
        var count_buf: [history_look.COUNT_TEXT_MAX]u8 = undefined;
        const is_merged = row.count > 1;
        const name = if (is_merged) history_look.countText(&count_buf, row.count) else entry.characterName();
        const name_color = if (is_merged) list_look.MUTED else entry.character_color orelse list_look.NAME;
        const name_max = @divTrunc(@max(0, message_right - left) * history_look.NAME_MAX_PERCENT, 100);
        const message_x = left + drawFitted(dc, name, left, y, name_color, name_max) + history_look.TEXT_GAP;
        if (message_x >= message_right) return;
        _ = drawFitted(dc, entry.text(), message_x, y, self.messageColor(entry.notification_type), message_right - message_x);
    }

    /// Each filter button's label centred in it, brighter while its category shows.
    fn drawFilterLabels(self: *const HistoryPanelWindow, dc: win32.HDC, panel_width: i32, y: i32) void {
        for (history_look.CATEGORY_ORDER, 0..) |category, index| {
            const span = history_look.filterSpan(panel_width, index);
            const label = history_look.categoryLabel(category);
            const color = if (history_look.categoryEnabled(&self.config.display, category)) list_look.NAME else list_look.MUTED;
            const label_width: i32 = @intCast(measureTextWidth(dc, label));
            const span_width = span.right - span.left;
            if (label_width <= span_width) {
                drawLine(dc, label, span.left + @divTrunc(span_width - label_width, 2), y, color);
            } else {
                _ = drawFitted(dc, label, span.left, y, color, span_width);
            }
        }
    }
};

var g_class_registered: bool = false;

fn setCategoryEnabled(store: *config_mod.ProfileStore, category: notification.NotificationCategory, value: bool) void {
    switch (category) {
        .Fleet => store.update(.{ .display = .{ .notifInfoPanelShowFleet = value } }),
        .Mining => store.update(.{ .display = .{ .notifInfoPanelShowMining = value } }),
        .Combat => store.update(.{ .display = .{ .notifInfoPanelShowCombat = value } }),
        .Navigation => store.update(.{ .display = .{ .notifInfoPanelShowNavigation = value } }),
        .General => store.update(.{ .display = .{ .notifInfoPanelShowGeneral = value } }),
    }
}

fn registerWindowClass(instance: win32.HINSTANCE) !void {
    if (g_class_registered) return;

    try gdi_overlay.registerWindowClass(instance, historyPanelWindowProc, HISTORY_PANEL_WINDOW_CLASS, null);

    g_class_registered = true;
}

fn historyWindow() ?*HistoryPanelWindow {
    const painter = painter_mod.g_painter_ptr orelse return null;
    return if (painter.history_panel.window) |*window| window else null;
}

fn historyPanelWindowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    // The painter only holds the panel once its window exists, so creation's messages go without a header.
    const header_height = if (historyWindow()) |window| history_look.metrics(&window.config.display).header_height else 0;
    if (drag_panel.handleMessage(hwnd, msg, lParam, header_height)) |result| return result;
    switch (msg) {
        win32.WM_ENTERSIZEMOVE => {
            drag_panel.beginPanelDrag(hwnd);
            // No single character owns this panel, so every saved position shows as a ghost.
            if (painter_mod.g_painter_ptr) |painter| painter.ghost_overlay.show(painter, "");
            return 0;
        },
        win32.WM_EXITSIZEMOVE => {
            const painter = painter_mod.g_painter_ptr orelse return 0;
            painter.ghost_overlay.hide();
            if (painter.history_panel.window) |*window| window.saveWindowPosition();
            return 0;
        },
        win32.WM_LBUTTONDOWN => {
            const painter = painter_mod.g_painter_ptr orelse return 0;
            const window = if (painter.history_panel.window) |*w| w else return 0;
            const sizes = history_look.metrics(&window.config.display);
            const y = win32.lparamY(lParam);
            if (y < sizes.header_height) return 0;
            if (sizes.footer_height > 0 and y >= window.panel.height - sizes.footer_height) {
                window.handleFooterClick(win32.lparamX(lParam));
                return 0;
            }

            const row: usize = @intCast(@divTrunc(y - sizes.header_height, sizes.row_height));
            if (row >= window.history_row_count) return 0;
            const history_row = window.history_rows[row];
            if (history_row.count > 1) {
                painter.notification_history.unmergeRange(history_row.first, history_row.last);
            } else {
                activation.activate(history_row.hwnd);
            }
            return 0;
        },
        else => return win32.DefWindowProcA(hwnd, msg, wParam, lParam),
    }
}

/// Ignores `color`'s alpha byte.
fn drawLine(dc: win32.HDC, text: []const u8, x: i32, y: i32, color: u32) void {
    gdi_overlay.drawText(TEXT_BUF, dc, x, y, text, color & 0x00FF_FFFF);
}

/// Cut short with "..." to fit `max_width` pixels; returns the width drawn.
fn drawFitted(dc: win32.HDC, text: []const u8, x: i32, y: i32, color: u32, max_width: i32) i32 {
    var out: [TEXT_BUF:0]u8 = undefined;
    const fitted = gdi_overlay.truncateTextToFit(TEXT_BUF, dc, &out, text, @intCast(@max(0, max_width)));
    drawLine(dc, fitted, x, y, color);
    return @intCast(measureTextWidth(dc, fitted));
}

/// The selected font's line height.
fn lineHeight(dc: win32.HDC) i32 {
    return gdi_overlay.measureTextSize(TEXT_BUF, dc, "Ag").cy;
}

fn measureTextWidth(dc: win32.HDC, text: []const u8) usize {
    return gdi_overlay.measureTextWidth(TEXT_BUF, dc, text);
}
