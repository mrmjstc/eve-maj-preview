//! The Intel Panel's own window, for when it's detached from the Map Panel, which otherwise draws the same rows in a sidebar.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const panel_window = @import("../platform/panel_window.zig");
const config_mod = @import("../config.zig");
const history = @import("../notifications/history.zig");
const history_look = @import("history_look.zig");
const history_rows = @import("history_rows.zig");
const list_look = @import("list_look.zig");
const panel_chrome = @import("panel_chrome.zig");
const panel_look = @import("panel_look.zig");
const app = @import("../app.zig");
const drag = @import("drag.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");
const log = @import("../log.zig");

const PanelWindow = panel_window.PanelWindow;
const slog = log.Scoped("intel_panel");

const HEADER_TEXT = "Intel";
const INTEL_PANEL_WINDOW_CLASS = "EVE_INTEL_PANEL_CLASS";

/// Owns whether the Intel Panel shows: inside the map it shows with the map, and alone it has this window and its own settings.
pub const IntelPanel = struct {
    window: ?IntelPanelWindow = null,
    visibility: panel_look.Visibility = .{},

    pub fn init(allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE) IntelPanel {
        var panel: IntelPanel = .{};
        if (wantsWindow(&store.live)) panel.createWindow(allocator, store, instance);
        return panel;
    }

    pub fn deinit(self: *IntelPanel) void {
        if (self.window) |*window| window.deinit();
        self.window = null;
    }

    /// `is_map_shown` decides it while the panel is inside the map.
    pub fn isVisible(self: *const IntelPanel, config: *const config_mod.Config, presence: panel_look.Presence, is_map_shown: bool) bool {
        const display = &config.display;
        if (!display.showIntelPanel) return false;
        if (display.intelPanelAttached) return is_map_shown;
        return self.window != null and self.visibility.allows(.{
            .hides_without_characters = display.hideIntelPanelWhenNoCharacters,
            .any_character_logged_in = presence.any_character_logged_in,
            .hides_without_focus = display.hideIntelPanelWhenNoEveFocus,
            .hide_delay_ms = display.intelPanelHideDebounceMs,
            .now_ms = win32.Ticks.now().ms,
        });
    }

    /// Keyed on isVisible(), not the window: a visible panel turns off, and a hidden one is forced on.
    pub fn toggle(self: *IntelPanel, allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE, presence: panel_look.Presence, is_map_shown: bool) void {
        if (self.isVisible(&store.live, presence, is_map_shown)) {
            self.deinit();
            store.update(.{ .display = .{ .showIntelPanel = false } });
            self.visibility.release();
            return;
        }
        store.update(.{ .display = .{ .showIntelPanel = true } });
        self.visibility.force();
        self.sync(allocator, store, instance);
    }

    /// Matches the window to the settings, for a change made in the config dialog or by a new profile.
    pub fn sync(self: *IntelPanel, allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE) void {
        const is_wanted = wantsWindow(&store.live);
        if (!is_wanted and self.window != null) {
            self.deinit();
            self.visibility.release();
        } else if (is_wanted and self.window == null) {
            self.createWindow(allocator, store, instance);
        }
        if (self.window) |*window| window.panel.followPosition(store.live.display.intelPanelX, store.live.display.intelPanelY);
    }

    /// Per tick: renders the window from `notifications`, or hides it.
    pub fn update(self: *IntelPanel, notifications: *const history.NotificationHistory, config: *const config_mod.Config, presence: panel_look.Presence) void {
        self.visibility.note(presence, win32.Ticks.now().ms);
        const window = if (self.window) |*w| w else return;
        if (!self.isVisible(config, presence, false)) {
            window.hide();
            return;
        }
        window.render(notifications) catch |err| {
            slog.err("Failed to render Intel Panel window: {}", .{err});
        };
    }

    fn createWindow(self: *IntelPanel, allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE) void {
        self.window = IntelPanelWindow.init(allocator, store, instance) catch |err| {
            slog.err("Failed to create Intel Panel window: {}", .{err});
            return;
        };
    }
};

pub const IntelPanelWindow = struct {
    panel: PanelWindow,
    /// Borrowed; outlives the window.
    store: *config_mod.ProfileStore,
    /// Borrowed; outlives the window.
    config: *const config_mod.Config,
    rows: [history.CAPACITY]history_rows.Row = undefined,
    row_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE) !IntelPanelWindow {
        const display = &store.live.display;
        try registerWindowClass(instance);
        const panel = try PanelWindow.init(allocator, instance, INTEL_PANEL_WINDOW_CLASS, "EVE Intel", .{
            .left = display.intelPanelX,
            .top = display.intelPanelY,
            .right = display.intelPanelX + display.intelPanelWidth,
            .bottom = display.intelPanelY + display.intelPanelHeight,
        });
        return .{ .panel = panel, .store = store, .config = &store.live };
    }

    pub fn deinit(self: *IntelPanelWindow) void {
        self.panel.deinit();
    }

    pub fn hide(self: *const IntelPanelWindow) void {
        self.panel.hide();
    }

    fn sizes(self: *const IntelPanelWindow) history_look.Metrics {
        const display = &self.config.display;
        return .{ .header_height = panel_look.headerHeight(display), .row_height = history_rows.intelRowHeight(display), .footer_height = 0 };
    }

    fn saveWindowPosition(self: *const IntelPanelWindow) void {
        const display = &self.config.display;
        if (!display.rememberIntelPanelPosition) return;
        const top_left = self.panel.topLeft() orelse return;
        self.store.update(.{ .display = .{ .intelPanelX = top_left.x, .intelPanelY = top_left.y } });
    }

    fn computeRenderSignature(self: *const IntelPanelWindow, notifications: *const history.NotificationHistory, entries: []const history.Entry) u64 {
        const display = &self.config.display;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&display.intelPanelWidth));
        hasher.update(std.mem.asBytes(&display.intelPanelHeight));
        hasher.update(std.mem.asBytes(&display.intelPanelOpacity));
        panel_chrome.hashFonts(&hasher, display);
        history_rows.hashIntel(&hasher, notifications, entries, display, &self.config.thumbnail.notifications);
        return hasher.final();
    }

    /// Called every tick; redraws only when the render signature changed.
    pub fn render(self: *IntelPanelWindow, notifications: *const history.NotificationHistory) !void {
        const display = &self.config.display;
        try panel_chrome.ensureFonts(&self.panel, display);

        const panel_width: i32 = @max(1, display.intelPanelWidth);
        const panel_height: i32 = @max(1, display.intelPanelHeight);
        var entry_buf: [history.CAPACITY]history.Entry = undefined;
        const entries = notifications.snapshot(&entry_buf);
        const signature = self.computeRenderSignature(notifications, entries);
        if (self.panel.isUnchanged(signature)) return;

        const panel_sizes = self.sizes();
        const capacity = history_look.rowsThatFit(panel_height, panel_sizes, history.CAPACITY);
        self.row_count = history_rows.build(&self.rows, entries, capacity, history_rows.buildOptions(display, null));

        const bitmap = try self.panel.beginFrame(panel_width, panel_height);
        const dc = bitmap.mem_dc;
        const canvas = bitmap.canvas();
        pixel_buffer.fillRect(canvas, 0, 0, bitmap.width, bitmap.height, list_look.PANEL);
        panel_chrome.fillBars(canvas, panel_sizes.header_height, null);

        const old_font = panel_chrome.selectFont(&self.panel, dc);
        defer panel_chrome.restoreFont(dc, old_font);
        if (panel_chrome.textOf(&self.panel, dc)) |text| {
            panel_chrome.drawHeader(dc, text, panel_sizes.header_height, panel_width, HEADER_TEXT, null);
            const area = history_rows.intelArea(display, 0, panel_sizes.header_height, panel_width);
            history_rows.drawIntel(dc, text, self.rows[0..self.row_count], entries, &self.config.thumbnail.notifications, area);
        }

        panel_chrome.finish(canvas);
        self.panel.present(display.intelPanelOpacity, signature);
    }
};

var g_is_class_registered: bool = false;

fn wantsWindow(config: *const config_mod.Config) bool {
    return config.display.showIntelPanel and !config.display.intelPanelAttached;
}

fn registerWindowClass(instance: win32.HINSTANCE) !void {
    if (g_is_class_registered) return;
    try gdi_overlay.registerWindowClass(instance, intelPanelWindowProc, INTEL_PANEL_WINDOW_CLASS, null);
    g_is_class_registered = true;
}

fn intelWindow() ?*IntelPanelWindow {
    const running = app.g_app orelse return null;
    return if (running.notifications.intel_panel.window) |*window| window else null;
}

fn intelPanelWindowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    // The notification center only holds the panel once its window exists, so creation's messages go without a header.
    const header_height = if (intelWindow()) |window| window.sizes().header_height else 0;
    if (drag.handleSharedMessage(app.currentThumbnailSet(), hwnd, msg, lParam, header_height)) |result| return result;
    switch (msg) {
        win32.WM_EXITSIZEMOVE => {
            if (intelWindow()) |window| window.saveWindowPosition();
            return 0;
        },
        win32.WM_LBUTTONDOWN => {
            const running = app.g_app orelse return 0;
            const window = intelWindow() orelse return 0;
            const panel_sizes = window.sizes();
            const y = win32.lparamY(lParam);
            if (y < panel_sizes.header_height) return 0;

            const row_index: usize = @intCast(@divTrunc(y - panel_sizes.header_height, panel_sizes.row_height));
            if (row_index >= window.row_count) return 0;
            const entry = running.notifications.intel_history.entryFromNewest(window.rows[row_index].first) orelse return 0;
            if (entry.system) |system| running.map_panel.showSystem(system, running.thumbnail_set);
            return 0;
        },
        else => return win32.DefWindowProcA(hwnd, msg, wParam, lParam),
    }
}
