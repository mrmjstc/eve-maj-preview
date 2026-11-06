//! The History Panel: a draggable list of recent notifications, with category filter buttons.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const panel_window = @import("../platform/panel_window.zig");
const config_mod = @import("../config.zig");
const list_look = @import("list_look.zig");
const notification = @import("../notifications/notification.zig");
const history_mod = @import("../notifications/history.zig");
const history_look = @import("history_look.zig");
const history_rows = @import("history_rows.zig");
const panel_chrome = @import("panel_chrome.zig");
const panel_look = @import("panel_look.zig");
const header_panel = @import("header_panel.zig");
const panel_host = @import("panel_host.zig");
const panel_lifecycle = @import("panel_lifecycle.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");
const log = @import("../log.zig");

const PanelWindow = panel_window.PanelWindow;
const slog = log.Scoped("history_panel");

const HISTORY_PANEL_WINDOW_CLASS = "EVE_HISTORY_PANEL_CLASS";

const Class = header_panel.HeaderPanel(HistoryPanelWindow, HISTORY_PANEL_WINDOW_CLASS);

/// What the History Panel's window borrows from App.
pub const Links = struct {
    host: panel_host.Host,
    /// The history it lists, which a click on a merged row unmerges; outlives the panel.
    history: *history_mod.NotificationHistory,
};

/// Owns the History Panel window and when it's on-screen: historyPanel.show creates it, its auto-hide settings hide it, and the tray toggle can force it visible.
pub const HistoryPanel = struct {
    window: ?HistoryPanelWindow = null,
    visibility: panel_look.Visibility = .{},
    /// Null until start.
    links: ?Links = null,

    /// Creates the window if the context's profile shows it; in place, as the window is linked to where it's stored.
    pub fn start(self: *HistoryPanel, context: panel_host.Context, links: Links) void {
        self.links = links;
        panel_lifecycle.sync(self, context);
    }

    pub fn deinit(self: *HistoryPanel) void {
        self.destroyWindow();
    }

    /// Accounts for the panel's auto-hide settings and the tray-toggle override.
    pub fn isVisible(self: *const HistoryPanel, config: *const config_mod.Config, any_character_logged_in: bool) bool {
        return self.window != null and self.visibility.allowsFor(&config.historyPanel, any_character_logged_in, win32.Ticks.now().ms);
    }

    /// Keyed on isVisible(), not the window: a visible panel turns off, and a hidden one is forced on even with no character logged in.
    pub fn toggle(self: *HistoryPanel, context: panel_host.Context, any_character_logged_in: bool) void {
        panel_lifecycle.toggle(self, context, self.isVisible(&context.store.live, any_character_logged_in));
    }

    /// Matches the window to historyPanel.show and its configured position, for a change made in the config dialog rather than by `toggle`.
    pub fn sync(self: *HistoryPanel, context: panel_host.Context) void {
        panel_lifecycle.sync(self, context);
        const history_settings = &context.store.live.historyPanel;
        if (self.window) |*window| window.panel.followPosition(history_settings.x, history_settings.y);
    }

    /// For panel_lifecycle.
    pub fn wantsWindow(_: *const HistoryPanel, config: *const config_mod.Config) bool {
        return config.historyPanel.show;
    }

    /// For panel_lifecycle.
    pub fn setShown(_: *const HistoryPanel, store: *config_mod.ProfileStore, is_shown: bool) void {
        store.update(.{ .historyPanel = .{ .show = is_shown } });
    }

    /// Per-tick: renders the panel from `notifications`, or hides it.
    pub fn update(self: *HistoryPanel, notifications: *const history_mod.NotificationHistory, config: *const config_mod.Config, presence: panel_look.Presence) void {
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

    /// For panel_lifecycle.
    pub fn createWindow(self: *HistoryPanel, context: panel_host.Context) void {
        const links = self.links orelse {
            slog.err("Failed to create History Panel window: the panel wasn't started", .{});
            return;
        };
        panel_lifecycle.install(HistoryPanelWindow, &self.window, HistoryPanelWindow.init(context, links), null, "History Panel");
    }

    /// For panel_lifecycle.
    pub fn destroyWindow(self: *HistoryPanel) void {
        if (self.window) |*window| window.deinit();
        self.window = null;
    }
};

pub const HistoryPanelWindow = struct {
    panel: PanelWindow,
    /// Borrowed; outlives the window.
    store: *config_mod.ProfileStore,
    /// Borrowed; outlives the window.
    config: *const config_mod.Config,
    host: panel_host.Host,
    /// Borrowed; outlives the window.
    history: *history_mod.NotificationHistory,
    rows: [history_mod.CAPACITY]history_rows.Row = undefined,
    row_count: usize = 0,

    pub fn init(context: panel_host.Context, links: Links) !HistoryPanelWindow {
        const history_settings = &context.store.live.historyPanel;
        try Class.register(context.instance);
        const panel = try PanelWindow.init(context.allocator, context.instance, HISTORY_PANEL_WINDOW_CLASS, "EVE Notification History", panel_lifecycle.windowRect(history_settings), history_settings.alwaysOnTop);
        return .{ .panel = panel, .store = context.store, .config = &context.store.live, .host = links.host, .history = links.history };
    }

    pub fn deinit(self: *HistoryPanelWindow) void {
        self.panel.deinit();
    }

    pub fn hide(self: *const HistoryPanelWindow) void {
        self.panel.hide();
    }

    pub fn headerHeight(self: *const HistoryPanelWindow) i32 {
        return history_look.metrics(&self.config.historyPanel).header_height;
    }

    pub fn saveWindowPosition(self: *const HistoryPanelWindow) void {
        if (!self.config.historyPanel.rememberPosition) return;
        const top_left = self.panel.topLeft() orelse return;
        self.store.update(.{ .historyPanel = .{ .x = top_left.x, .y = top_left.y } });
    }

    pub fn onLeftClick(self: *HistoryPanelWindow, x: i32, y: i32) void {
        const sizes = history_look.metrics(&self.config.historyPanel);
        if (y < sizes.header_height) return;
        if (sizes.footer_height > 0 and y >= self.panel.height - sizes.footer_height) {
            self.handleFooterClick(x);
            return;
        }

        const row_index = panel_look.rowAt(y, sizes.header_height, sizes.row_height, self.row_count) orelse return;
        const history_row = self.rows[row_index];
        if (history_row.count > 1) {
            self.history.unmergeRange(history_row.first_index, history_row.last_index);
        } else {
            self.host.run(.{ .activate = history_row.hwnd });
        }
    }

    fn handleFooterClick(self: *HistoryPanelWindow, x: i32) void {
        const category = history_look.filterAt(self.panel.width, x) orelse return;
        setCategoryEnabled(self.store, category, !history_look.isCategoryEnabled(&self.config.historyPanel, category));
    }

    fn computeRenderSignature(self: *const HistoryPanelWindow, notifications: *const history_mod.NotificationHistory) u64 {
        const history_settings = &self.config.historyPanel;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&history_settings.width));
        hasher.update(std.mem.asBytes(&history_settings.height));
        hasher.update(std.mem.asBytes(&history_settings.opacity));
        panel_chrome.hashFonts(&hasher, history_settings);
        hasher.update(std.mem.asBytes(&history_settings.maxRows));
        hasher.update(std.mem.asBytes(&history_settings.showTimestamp));
        hasher.update(std.mem.asBytes(&history_settings.showCategoryFilters));
        hasher.update(std.mem.asBytes(&history_settings.mergeEnabled));
        hasher.update(std.mem.asBytes(&history_settings.mergeWindowSec));
        for (history_look.CATEGORY_ORDER) |category| {
            const is_enabled = history_look.isCategoryEnabled(history_settings, category);
            hasher.update(std.mem.asBytes(&is_enabled));
        }
        hasher.update(std.mem.asBytes(&notifications.revision));

        var entry_buf: [history_mod.CAPACITY]history_mod.Entry = undefined;
        history_rows.hashEntries(&hasher, notifications.snapshot(&entry_buf), &self.config.thumbnail.notifications, history_settings.showTimestamp);
        return hasher.final();
    }

    fn filterButtons(self: *const HistoryPanelWindow) [history_look.CATEGORY_ORDER.len]panel_chrome.Button {
        var buttons: [history_look.CATEGORY_ORDER.len]panel_chrome.Button = undefined;
        for (history_look.CATEGORY_ORDER, &buttons) |category, *button| {
            button.* = .{ .label = history_look.categoryLabel(category), .is_lit = history_look.isCategoryEnabled(&self.config.historyPanel, category) };
        }
        return buttons;
    }

    /// Called every tick; redraws only when the render signature changed.
    pub fn render(self: *HistoryPanelWindow, notifications: *const history_mod.NotificationHistory) !void {
        const history_settings = &self.config.historyPanel;
        self.panel.followTopmost(history_settings.alwaysOnTop);
        try panel_chrome.ensureFonts(&self.panel, history_settings);

        const signature = self.computeRenderSignature(notifications);
        if (self.panel.isUnchanged(signature)) return;

        var entry_buf: [history_mod.CAPACITY]history_mod.Entry = undefined;
        const entries = notifications.snapshot(&entry_buf);
        const sizes = history_look.metrics(history_settings);
        self.row_count = history_rows.build(&self.rows, entries, history_look.rowCapacity(history_settings, sizes), history_rows.buildOptions(history_settings, history_settings));

        const panel_width: i32 = @max(1, history_settings.width);
        const panel_height: i32 = @max(1, history_settings.height);
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
        self.panel.present(history_settings.opacity, signature);
    }

    fn drawRows(self: *const HistoryPanelWindow, dc: win32.HDC, entries: []const history_mod.Entry, sizes: history_look.Metrics, panel_width: i32, text: panel_chrome.Text) void {
        const history_settings = &self.config.historyPanel;
        const area: history_rows.Area = .{ .top = sizes.header_height, .row_height = sizes.row_height, .right = panel_width - list_look.PADDING_X, .shows_timestamp = history_settings.showTimestamp };
        if (self.row_count == 0) {
            history_rows.drawEmpty(dc, text, if (entries.len == 0) "No notifications yet" else "All notifications filtered", area);
            return;
        }
        history_rows.draw(dc, text, self.rows[0..self.row_count], entries, &self.config.thumbnail.notifications, area);
    }
};

fn setCategoryEnabled(store: *config_mod.ProfileStore, category: notification.NotificationCategory, is_enabled: bool) void {
    switch (category) {
        .Fleet => store.update(.{ .historyPanel = .{ .showFleet = is_enabled } }),
        .Mining => store.update(.{ .historyPanel = .{ .showMining = is_enabled } }),
        .Combat => store.update(.{ .historyPanel = .{ .showCombat = is_enabled } }),
        .Navigation => store.update(.{ .historyPanel = .{ .showNavigation = is_enabled } }),
        .Chat => store.update(.{ .historyPanel = .{ .showChat = is_enabled } }),
        .General => store.update(.{ .historyPanel = .{ .showGeneral = is_enabled } }),
    }
}
