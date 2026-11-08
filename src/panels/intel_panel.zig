//! The Intel Panel's own window, for when it's detached from the Map Panel, which otherwise draws the same reports in a card.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const panel_window = @import("../platform/panel_window.zig");
const config_mod = @import("../config.zig");
const history = @import("../notifications/history.zig");
const history_look = @import("history_look.zig");
const history_rows = @import("history_rows.zig");
const list_look = @import("list_look.zig");
const panel_chrome = @import("panel_chrome.zig");
const panel_look = @import("panel_look.zig");
const header_panel = @import("header_panel.zig");
const panel_host = @import("panel_host.zig");
const panel_lifecycle = @import("panel_lifecycle.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");
const log = @import("../log.zig");

const PanelWindow = panel_window.PanelWindow;
const slog = log.Scoped("intel_panel");

const HEADER_TEXT = "Intel";
const INTEL_PANEL_WINDOW_CLASS = "EVE_INTEL_PANEL_CLASS";

const Class = header_panel.HeaderPanel(IntelPanelWindow, INTEL_PANEL_WINDOW_CLASS);

/// What the Intel Panel's window borrows from App.
pub const Links = struct {
    host: panel_host.Host,
    /// The reports it lists, which a row click looks its system up in; outlives the panel.
    intel_history: *const history.NotificationHistory,
};

/// Owns whether the Intel Panel shows: inside the map it shows with the map, and alone it has this window and its own settings.
pub const IntelPanel = struct {
    window: ?IntelPanelWindow = null,
    visibility: panel_look.Visibility = .{},
    /// Last sync's intelPanel.attached, to catch the panel leaving the map.
    was_attached: bool = false,
    /// Null until start.
    links: ?Links = null,

    /// Creates the window if the context's profile shows it alone; in place, as the window is linked to where it's stored.
    pub fn start(self: *IntelPanel, context: panel_host.Context, links: Links) void {
        self.links = links;
        self.was_attached = context.store.live.intelPanel.attached;
        panel_lifecycle.sync(self, context);
    }

    pub fn deinit(self: *IntelPanel) void {
        self.destroyWindow();
    }

    /// `is_map_shown` decides it while the panel is inside the map.
    pub fn isVisible(self: *const IntelPanel, config: *const config_mod.Config, presence: panel_look.Presence, is_map_shown: bool) bool {
        const intel_settings = &config.intelPanel;
        if (!intel_settings.show) return false;
        if (intel_settings.attached) return is_map_shown;
        return self.window != null and self.visibility.allowsFor(intel_settings, presence.any_character_logged_in, win32.Ticks.now().ms);
    }

    /// Keyed on isVisible(), not the window: a visible panel turns off, and a hidden one is forced on.
    pub fn toggle(self: *IntelPanel, context: panel_host.Context, presence: panel_look.Presence, is_map_shown: bool) void {
        panel_lifecycle.toggle(self, context, self.isVisible(&context.store.live, presence, is_map_shown));
    }

    /// Matches the window to the settings, for a change made in the config dialog or by a new profile.
    pub fn sync(self: *IntelPanel, context: panel_host.Context) void {
        const intel_settings = &context.store.live.intelPanel;
        const has_left_map = self.was_attached and !intel_settings.attached;
        self.was_attached = intel_settings.attached;
        panel_lifecycle.sync(self, context);
        // Its auto-hide never applied inside the map, so detaching mustn't make it vanish.
        if (has_left_map and self.window != null) self.visibility.force();
        if (self.window) |*window| window.panel.followPosition(intel_settings.x, intel_settings.y);
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

    /// For panel_lifecycle: only while it's out of the map.
    pub fn wantsWindow(_: *const IntelPanel, config: *const config_mod.Config) bool {
        return config.intelPanel.show and !config.intelPanel.attached;
    }

    /// For panel_lifecycle.
    pub fn setShown(_: *const IntelPanel, store: *config_mod.ProfileStore, is_shown: bool) void {
        store.update(.{ .intelPanel = .{ .show = is_shown } });
    }

    /// For panel_lifecycle.
    pub fn createWindow(self: *IntelPanel, context: panel_host.Context) void {
        const links = self.links orelse {
            slog.err("Failed to create Intel Panel window: the panel wasn't started", .{});
            return;
        };
        panel_lifecycle.install(IntelPanelWindow, &self.window, IntelPanelWindow.init(context, links), null, "Intel Panel");
    }

    /// For panel_lifecycle.
    pub fn destroyWindow(self: *IntelPanel) void {
        if (self.window) |*window| window.deinit();
        self.window = null;
    }
};

pub const IntelPanelWindow = struct {
    panel: PanelWindow,
    /// Borrowed; outlives the window.
    store: *config_mod.ProfileStore,
    /// Borrowed; outlives the window.
    config: *const config_mod.Config,
    host: panel_host.Host,
    /// Borrowed; outlives the window.
    intel_history: *const history.NotificationHistory,
    rows: [history.CAPACITY]history_rows.Row = undefined,
    row_count: usize = 0,

    pub fn init(context: panel_host.Context, links: Links) !IntelPanelWindow {
        const intel_settings = &context.store.live.intelPanel;
        try Class.register(context.instance);
        const panel = try PanelWindow.init(context.allocator, context.instance, INTEL_PANEL_WINDOW_CLASS, "EVE Intel", panel_lifecycle.windowRect(intel_settings), intel_settings.alwaysOnTop);
        return .{ .panel = panel, .store = context.store, .config = &context.store.live, .host = links.host, .intel_history = links.intel_history };
    }

    pub fn deinit(self: *IntelPanelWindow) void {
        self.panel.deinit();
    }

    pub fn hide(self: *const IntelPanelWindow) void {
        self.panel.hide();
    }

    fn panelSizes(self: *const IntelPanelWindow) history_look.Metrics {
        const history_settings = &self.config.historyPanel;
        return .{ .header_height = panel_look.headerHeight(history_settings), .row_height = history_rows.intelRowHeight(history_settings), .footer_height = 0 };
    }

    pub fn headerHeight(self: *const IntelPanelWindow) i32 {
        return self.panelSizes().header_height;
    }

    pub fn saveWindowPosition(self: *const IntelPanelWindow) void {
        const intel_settings = &self.config.intelPanel;
        if (!intel_settings.rememberPosition) return;
        const top_left = self.panel.topLeft() orelse return;
        self.store.update(.{ .intelPanel = .{ .x = top_left.x, .y = top_left.y } });
    }

    pub fn onLeftClick(self: *IntelPanelWindow, x: i32, y: i32) void {
        _ = x;
        const sizes = self.panelSizes();
        const row_index = panel_look.rowAt(y, sizes.header_height, sizes.row_height, self.row_count) orelse return;
        const entry = self.intel_history.entryFromNewest(self.rows[row_index].first_index) orelse return;
        if (entry.system) |system| self.host.run(.{ .show_system = system });
    }

    fn computeRenderSignature(self: *const IntelPanelWindow, notifications: *const history.NotificationHistory, entries: []const history.Entry) u64 {
        const intel_settings = &self.config.intelPanel;
        const history_settings = &self.config.historyPanel;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&intel_settings.width));
        hasher.update(std.mem.asBytes(&intel_settings.height));
        hasher.update(std.mem.asBytes(&intel_settings.opacity));
        panel_chrome.hashFonts(&hasher, history_settings);
        history_rows.hashIntel(&hasher, notifications, entries, history_settings, intel_settings, &self.config.thumbnail.notifications);
        return hasher.final();
    }

    /// Called every tick; redraws only when the render signature changed.
    pub fn render(self: *IntelPanelWindow, notifications: *const history.NotificationHistory) !void {
        const intel_settings = &self.config.intelPanel;
        const history_settings = &self.config.historyPanel;
        self.panel.followTopmost(intel_settings.alwaysOnTop);
        try panel_chrome.ensureFonts(&self.panel, history_settings);

        const panel_width: i32 = @max(1, intel_settings.width);
        const panel_height: i32 = @max(1, intel_settings.height);
        var entry_buf: [history.CAPACITY]history.Entry = undefined;
        const entries = notifications.snapshot(&entry_buf);
        const signature = self.computeRenderSignature(notifications, entries);
        if (self.panel.isUnchanged(signature)) return;

        const sizes = self.panelSizes();
        const capacity = history_look.rowsThatFit(panel_height, sizes, history.CAPACITY);
        self.row_count = history_rows.build(&self.rows, entries, capacity, history_rows.buildOptions(history_settings, null));

        const bitmap = try self.panel.beginFrame(panel_width, panel_height);
        const dc = bitmap.mem_dc;
        const canvas = bitmap.canvas();
        pixel_buffer.fillRect(canvas, 0, 0, bitmap.width, bitmap.height, list_look.PANEL);
        panel_chrome.fillBars(canvas, sizes.header_height, null);

        const old_font = panel_chrome.selectFont(&self.panel, dc);
        defer panel_chrome.restoreFont(dc, old_font);
        if (panel_chrome.textOf(&self.panel, dc)) |text| {
            panel_chrome.drawHeader(dc, text, sizes.header_height, panel_width, HEADER_TEXT, null);
            const area = history_rows.intelArea(history_settings, intel_settings, 0, sizes.header_height, panel_width);
            history_rows.drawIntel(dc, text, self.rows[0..self.row_count], entries, &self.config.thumbnail.notifications, area);
        }

        panel_chrome.finish(canvas);
        self.panel.present(intel_settings.opacity, signature);
    }
};
