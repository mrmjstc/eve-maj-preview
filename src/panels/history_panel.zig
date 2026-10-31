//! The History Panel: a draggable list of recent notifications, with category filter buttons.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const panel_window = @import("../platform/panel_window.zig");
const config_mod = @import("../config.zig");
const list_look = @import("list_look.zig");
const notification = @import("../notifications/notification.zig");
const history = @import("../notifications/history.zig");
const history_look = @import("history_look.zig");
const history_rows = @import("history_rows.zig");
const panel_chrome = @import("panel_chrome.zig");
const panel_look = @import("panel_look.zig");
const app = @import("../app.zig");
const activation = @import("../control/activation.zig");
const drag = @import("drag.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");
const log = @import("../log.zig");

const PanelWindow = panel_window.PanelWindow;
const slog = log.Scoped("history_panel");

const HISTORY_PANEL_WINDOW_CLASS = "EVE_HISTORY_PANEL_CLASS";

/// Owns the History Panel window and when it's on-screen: display.showNotifInfoPanel creates it, its auto-hide settings hide it, and the tray toggle can force it visible.
pub const HistoryPanel = struct {
    window: ?HistoryPanelWindow = null,
    visibility: panel_look.Visibility = .{},

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

    /// Accounts for the panel's auto-hide settings and the tray-toggle override.
    pub fn isVisible(self: *const HistoryPanel, config: *const config_mod.Config, any_character_logged_in: bool) bool {
        const display = &config.display;
        return self.window != null and self.visibility.allows(.{
            .hides_without_characters = display.hideNotifInfoPanelWhenNoCharacters,
            .any_character_logged_in = any_character_logged_in,
            .hides_without_focus = display.hideNotifInfoPanelWhenNoEveFocus,
            .hide_delay_ms = display.notifInfoPanelHideDebounceMs,
            .now_ms = win32.Ticks.now().ms,
        });
    }

    /// Keyed on isVisible(), not the window: a visible panel turns off, and a hidden one is forced on even with no character logged in.
    pub fn toggle(self: *HistoryPanel, allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE, any_character_logged_in: bool) void {
        if (self.isVisible(&store.live, any_character_logged_in)) {
            self.deinit();
            store.update(.{ .display = .{ .showNotifInfoPanel = false } });
            self.visibility.release();
            return;
        }
        if (self.window == null) {
            self.window = HistoryPanelWindow.init(allocator, store, instance) catch |err| {
                slog.err("Failed to create History Panel window: {}", .{err});
                return;
            };
        }
        store.update(.{ .display = .{ .showNotifInfoPanel = true } });
        self.visibility.force();
    }

    /// Matches the window to showNotifInfoPanel and its configured position, for a change made in the config dialog rather than by `toggle`.
    pub fn sync(self: *HistoryPanel, allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE) void {
        const is_wanted = store.live.display.showNotifInfoPanel;
        if (!is_wanted and self.window != null) {
            self.deinit();
            self.visibility.release();
        } else if (is_wanted and self.window == null) {
            self.window = HistoryPanelWindow.init(allocator, store, instance) catch |err| {
                slog.err("Failed to create History Panel window: {}", .{err});
                return;
            };
        }
        if (self.window) |*window| window.panel.followPosition(store.live.display.notifInfoPanelX, store.live.display.notifInfoPanelY);
    }

    /// Per-tick: renders the panel from `notifications`, or hides it.
    pub fn update(self: *HistoryPanel, notifications: *const history.NotificationHistory, config: *const config_mod.Config, presence: panel_look.Presence) void {
        self.visibility.note(presence, win32.Ticks.now().ms);

        const window = if (self.window) |*w| w else return;
        if (self.isVisible(config, presence.any_character_logged_in)) {
            window.render(notifications) catch |err| {
                slog.err("Failed to render History Panel window: {}", .{err});
            };
        } else {
            window.hide();
        }
    }
};

pub const HistoryPanelWindow = struct {
    panel: PanelWindow,
    /// Borrowed; outlives the window.
    store: *config_mod.ProfileStore,
    /// Borrowed; outlives the window.
    config: *const config_mod.Config,
    rows: [history.CAPACITY]history_rows.Row = undefined,
    row_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE) !HistoryPanelWindow {
        const display = &store.live.display;
        try registerWindowClass(instance);
        const panel = try PanelWindow.init(allocator, instance, HISTORY_PANEL_WINDOW_CLASS, "EVE Notification History", .{
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

    fn saveWindowPosition(self: *const HistoryPanelWindow) void {
        if (!self.config.display.rememberNotifInfoPanelPosition) return;
        const top_left = self.panel.topLeft() orelse return;
        self.store.update(.{ .display = .{ .notifInfoPanelX = top_left.x, .notifInfoPanelY = top_left.y } });
    }

    fn handleFooterClick(self: *HistoryPanelWindow, x: i32) void {
        const category = history_look.filterAt(self.panel.width, x) orelse return;
        setCategoryEnabled(self.store, category, !history_look.isCategoryEnabled(&self.config.display, category));
    }

    fn computeRenderSignature(self: *const HistoryPanelWindow, notifications: *const history.NotificationHistory) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&self.config.display.notifInfoPanelWidth));
        hasher.update(std.mem.asBytes(&self.config.display.notifInfoPanelHeight));
        hasher.update(std.mem.asBytes(&self.config.display.notifInfoPanelOpacity));
        panel_chrome.hashFonts(&hasher, &self.config.display);
        hasher.update(std.mem.asBytes(&self.config.display.notifInfoPanelMaxRows));
        hasher.update(std.mem.asBytes(&self.config.display.notifInfoPanelShowTimestamp));
        hasher.update(std.mem.asBytes(&self.config.display.notifInfoPanelShowCategoryFilters));
        hasher.update(std.mem.asBytes(&self.config.display.notifInfoPanelMergeEnabled));
        hasher.update(std.mem.asBytes(&self.config.display.notifInfoPanelMergeWindowSec));
        for (history_look.CATEGORY_ORDER) |category| {
            const is_enabled = history_look.isCategoryEnabled(&self.config.display, category);
            hasher.update(std.mem.asBytes(&is_enabled));
        }
        hasher.update(std.mem.asBytes(&notifications.revision));

        var entry_buf: [history.CAPACITY]history.Entry = undefined;
        history_rows.hashEntries(&hasher, notifications.snapshot(&entry_buf), &self.config.thumbnail.notifications, self.config.display.notifInfoPanelShowTimestamp);
        return hasher.final();
    }

    fn filterButtons(self: *const HistoryPanelWindow) [history_look.CATEGORY_ORDER.len]panel_chrome.Button {
        var buttons: [history_look.CATEGORY_ORDER.len]panel_chrome.Button = undefined;
        for (history_look.CATEGORY_ORDER, &buttons) |category, *button| {
            button.* = .{ .label = history_look.categoryLabel(category), .is_lit = history_look.isCategoryEnabled(&self.config.display, category) };
        }
        return buttons;
    }

    /// Called every tick; redraws only when the render signature changed.
    pub fn render(self: *HistoryPanelWindow, notifications: *const history.NotificationHistory) !void {
        const display = &self.config.display;
        try panel_chrome.ensureFonts(&self.panel, display);

        const signature = self.computeRenderSignature(notifications);
        if (self.panel.isUnchanged(signature)) return;

        var entry_buf: [history.CAPACITY]history.Entry = undefined;
        const entries = notifications.snapshot(&entry_buf);
        const sizes = history_look.metrics(display);
        self.row_count = history_rows.build(&self.rows, entries, history_look.rowCapacity(display, sizes), history_rows.buildOptions(display, display));

        const panel_width: i32 = @max(1, display.notifInfoPanelWidth);
        const panel_height: i32 = @max(1, display.notifInfoPanelHeight);
        const bitmap = try self.panel.beginFrame(panel_width, panel_height);
        const width: usize = bitmap.width;
        const height: usize = bitmap.height;
        const dc = bitmap.mem_dc;
        const canvas = bitmap.canvas();
        const footer_top = panel_look.footerTop(panel_height, sizes.header_height, sizes.footer_height);
        const buttons = self.filterButtons();

        pixel_buffer.fillRect(canvas, 0, 0, width, height, list_look.PANEL);
        panel_chrome.fillBars(canvas, sizes.header_height, if (sizes.footer_height > 0) footer_top else null);
        if (sizes.footer_height > 0) panel_chrome.fillButtons(canvas, &buttons, panel_width, footer_top, sizes.header_height);

        const old_font = panel_chrome.selectFont(&self.panel, dc);
        defer panel_chrome.restoreFont(dc, old_font);
        if (panel_chrome.textOf(&self.panel, dc)) |text| {
            panel_chrome.drawHeader(dc, text, sizes.header_height, panel_width, history_look.HEADER_TEXT, null);
            if (sizes.footer_height > 0) panel_chrome.drawButtonLabels(dc, text, &buttons, panel_width, footer_top, sizes.header_height);
            self.drawRows(dc, entries, sizes, panel_width, text);
        }

        panel_chrome.finish(canvas);
        self.panel.present(display.notifInfoPanelOpacity, signature);
    }

    fn drawRows(self: *const HistoryPanelWindow, dc: win32.HDC, entries: []const history.Entry, sizes: history_look.Metrics, panel_width: i32, text: panel_chrome.Text) void {
        const display = &self.config.display;
        const area: history_rows.Area = .{ .top = sizes.header_height, .row_height = sizes.row_height, .right = panel_width - list_look.PADDING_X, .shows_timestamp = display.notifInfoPanelShowTimestamp };
        if (self.row_count == 0) {
            history_rows.drawEmpty(dc, text, if (entries.len == 0) "No notifications yet" else "All notifications filtered", area);
            return;
        }
        history_rows.draw(dc, text, self.rows[0..self.row_count], entries, &self.config.thumbnail.notifications, area);
    }
};

var g_is_class_registered: bool = false;

fn setCategoryEnabled(store: *config_mod.ProfileStore, category: notification.NotificationCategory, is_enabled: bool) void {
    switch (category) {
        .Fleet => store.update(.{ .display = .{ .notifInfoPanelShowFleet = is_enabled } }),
        .Mining => store.update(.{ .display = .{ .notifInfoPanelShowMining = is_enabled } }),
        .Combat => store.update(.{ .display = .{ .notifInfoPanelShowCombat = is_enabled } }),
        .Navigation => store.update(.{ .display = .{ .notifInfoPanelShowNavigation = is_enabled } }),
        .Chat => store.update(.{ .display = .{ .notifInfoPanelShowChat = is_enabled } }),
        .General => store.update(.{ .display = .{ .notifInfoPanelShowGeneral = is_enabled } }),
    }
}

fn registerWindowClass(instance: win32.HINSTANCE) !void {
    if (g_is_class_registered) return;

    try gdi_overlay.registerWindowClass(instance, historyPanelWindowProc, HISTORY_PANEL_WINDOW_CLASS, null);

    g_is_class_registered = true;
}

fn historyWindow() ?*HistoryPanelWindow {
    const running = app.g_app orelse return null;
    return if (running.notifications.panel.window) |*window| window else null;
}

fn historyPanelWindowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    // The notification center only holds the panel once its window exists, so creation's messages go without a header.
    const header_height = if (historyWindow()) |window| history_look.metrics(&window.config.display).header_height else 0;
    if (drag.handleSharedMessage(app.currentThumbnailSet(), hwnd, msg, lParam, header_height)) |result| return result;
    switch (msg) {
        win32.WM_EXITSIZEMOVE => {
            if (historyWindow()) |window| window.saveWindowPosition();
            return 0;
        },
        win32.WM_LBUTTONDOWN => {
            const running = app.g_app orelse return 0;
            const window = historyWindow() orelse return 0;
            const sizes = history_look.metrics(&window.config.display);
            const y = win32.lparamY(lParam);
            if (y < sizes.header_height) return 0;
            if (sizes.footer_height > 0 and y >= window.panel.height - sizes.footer_height) {
                window.handleFooterClick(win32.lparamX(lParam));
                return 0;
            }

            const row_index: usize = @intCast(@divTrunc(y - sizes.header_height, sizes.row_height));
            if (row_index >= window.row_count) return 0;
            const history_row = window.rows[row_index];
            if (history_row.count > 1) {
                running.notifications.history.unmergeRange(history_row.first, history_row.last);
            } else {
                activation.activate(running, history_row.hwnd);
            }
            return 0;
        },
        else => return win32.DefWindowProcA(hwnd, msg, wParam, lParam),
    }
}
