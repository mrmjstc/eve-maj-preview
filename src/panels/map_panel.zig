//! The Map Panel: a schematic of one region or a few side by side, with live stats, where the clients are and chat intel, and New Eden for picking a region.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const panel_window = @import("../platform/panel_window.zig");
const config_mod = @import("../config.zig");
const history = @import("../notifications/history.zig");
const destinations_mod = @import("map/destinations.zig");
const input = @import("map/input.zig");
const paint = @import("map/paint.zig");
const window_mod = @import("map/window.zig");
const panel_host = @import("panel_host.zig");
const panel_lifecycle = @import("panel_lifecycle.zig");
const panel_look = @import("panel_look.zig");
const universe = @import("../map/universe.zig");
const stats_mod = @import("../map/stats.zig");
const campaigns_feed = @import("../map/campaigns_feed.zig");
const stats_feed = @import("../map/stats_feed.zig");
const holder_colors = @import("../map/holder_colors.zig");
const intel_pins = @import("../map/intel_pins.zig");
const zkill = @import("../map/zkill.zig");
const zkill_feed = @import("../map/zkill_feed.zig");
const set = @import("../thumbnail/set.zig");
const drag = @import("drag.zig");
const log = @import("../log.zig");

const Destinations = destinations_mod.Destinations;
const GlobalConfig = config_mod.GlobalConfig;
const LogoColors = holder_colors.LogoColors;
const MapPanelWindow = window_mod.MapPanelWindow;
const Scene = paint.Scene;
const Snapshot = stats_mod.Snapshot;
const SystemIndex = universe.SystemIndex;
const ThumbnailSet = set.ThumbnailSet;
const slog = log.Scoped("map_panel");

const MAP_PANEL_WINDOW_CLASS = "EVE_MAP_PANEL_CLASS";
/// While a popup or an Eve Stars call is open, or Ctrl-clicked regions wait for Ctrl's release, as the app's tick can be a second apart.
const PUMP_TIMER_ID: usize = 1;
const PUMP_INTERVAL_MS: win32.UINT = 100;
/// Re-armed by each frame a moving map skips, so where it stopped is still drawn.
const FRAME_TIMER_ID: usize = 2;
const FRAME_CATCH_UP_MS: win32.UINT = 50;
/// While a pin's, kill's or ping's ripple plays; about the shortest a timer goes.
const RIPPLE_TIMER_ID: usize = 3;
const RIPPLE_FRAME_MS: win32.UINT = 16;
/// Shown instead of the real pins while mapPanel.showIntel is off.
const NO_PINS: intel_pins.IntelPins = .{};

const Class = gdi_overlay.WindowClass(MAP_PANEL_WINDOW_CLASS, mapPanelWindowProc);

/// Owns the Map Panel window, its figures and its pins: mapPanel.show creates the window, and the stats and pins outlive it.
pub const MapPanel = struct {
    /// App's PANEL_HOST.
    host: panel_host.Host,
    window: ?MapPanelWindow = null,
    visibility: panel_look.Visibility = .{},
    feed: stats_feed.StatsFeed = .{},
    /// Between the stats' fetches, while a running timer shows.
    campaign_feed: campaigns_feed.CampaignsFeed = .{},
    /// The newest figures; owned, freed in deinit.
    stats: ?*Snapshot = null,
    /// The newest alliance logo colours; owned, freed in deinit.
    logo_colors: ?*LogoColors = null,
    /// Changes with each new logo_colors.
    logo_revision: u64 = 0,
    pins: intel_pins.IntelPins = .{},
    /// What the Intel Panel lists, drawn here while it's inside the map; borrowed, outlives the panel.
    intel_history: ?*const history.NotificationHistory = null,
    /// Holds the Eve Stars token; borrowed, outlives the panel.
    global: ?*const GlobalConfig = null,
    destinations: Destinations = .{},
    kill_feed: zkill_feed.ZkillFeed = .{},
    /// zKillboard's kills within their lifetime.
    kills: zkill.Kills = .{},
    /// What the kills' ships and victims are called; freed in deinit.
    kill_names: zkill.Names = .{},

    /// Creates the window if the context's profile shows it.
    pub fn start(self: *MapPanel, context: panel_host.Context, intel_history: *const history.NotificationHistory, global: *const GlobalConfig) void {
        self.intel_history = intel_history;
        self.global = global;
        panel_lifecycle.sync(self, context);
    }

    /// Only once the feeds' threads have finished; `allocator` is the one update was given.
    pub fn deinit(self: *MapPanel, allocator: std.mem.Allocator) void {
        self.destroyWindow();
        self.feed.deinit(allocator);
        self.campaign_feed.deinit(allocator);
        self.kill_feed.deinit(allocator);
        self.kill_names.deinit(allocator);
        self.destinations.deinit();
        if (self.stats) |snapshot| stats_feed.destroySnapshot(snapshot);
        self.stats = null;
        if (self.logo_colors) |colors| allocator.destroy(colors);
        self.logo_colors = null;
    }

    /// Accounts for the panel's auto-hide settings and the tray-toggle override.
    pub fn isVisible(self: *const MapPanel, config: *const config_mod.Config, any_character_logged_in: bool) bool {
        return self.window != null and self.visibility.allowsFor(&config.mapPanel, any_character_logged_in, win32.Ticks.now().ms);
    }

    /// Selects and ripples `system`, opening its region unless that's shown, for an Intel Panel row.
    pub fn showSystem(self: *MapPanel, system: SystemIndex, thumbnail_set: ?*const ThumbnailSet) void {
        const window = if (self.window) |*w| w else return;
        window.pingSystem(system);
        self.redraw(thumbnail_set);
    }

    /// Keyed on isVisible(), not the window: a visible panel turns off, and a hidden one is forced on even with no character logged in.
    pub fn toggle(self: *MapPanel, context: panel_host.Context, any_character_logged_in: bool) void {
        panel_lifecycle.toggle(self, context, self.isVisible(&context.store.live, any_character_logged_in));
    }

    /// Matches the window to mapPanel.show, its position and regions, for a change made in the config dialog or by a new profile.
    pub fn sync(self: *MapPanel, context: panel_host.Context) void {
        panel_lifecycle.sync(self, context);
        if (self.window) |*window| window.followSettings();
    }

    /// For panel_lifecycle.
    pub fn wantsWindow(_: *const MapPanel, config: *const config_mod.Config) bool {
        return config.mapPanel.show;
    }

    /// For panel_lifecycle.
    pub fn setShown(_: *const MapPanel, store: *config_mod.ProfileStore, is_shown: bool) void {
        store.update(.{ .mapPanel = .{ .show = is_shown } });
    }

    /// Per tick: takes any new figures, then renders the panel or hides it.
    pub fn update(self: *MapPanel, allocator: std.mem.Allocator, io: std.Io, config: *const config_mod.Config, presence: panel_look.Presence, thumbnail_set: ?*const ThumbnailSet) void {
        self.visibility.note(presence, win32.Ticks.now().ms);

        if (self.feed.take()) |fresh| {
            if (self.stats) |old| {
                fresh.carryNpcDelta(old);
                stats_feed.destroySnapshot(old);
            }
            self.stats = fresh;
        }
        if (self.campaign_feed.take()) |fresh| {
            defer allocator.destroy(fresh);
            if (self.stats) |snapshot| snapshot.applyLiveCampaigns(fresh);
        }
        if (self.feed.takeColors()) |fresh| {
            if (self.logo_colors) |old| allocator.destroy(old);
            self.logo_colors = fresh;
            self.logo_revision +%= 1;
        }
        self.takeKills(config);
        self.pump(allocator);

        const window = if (self.window) |*w| w else return;
        if (!self.isVisible(config, presence.any_character_logged_in)) {
            window.hide();
            return;
        }
        if (config.mapPanel.liveStats) self.feed.poll(allocator, io, win32.Ticks.now());
        if (config.mapPanel.showKills) self.kill_feed.poll(allocator, win32.Ticks.now().ms);
        if (self.stats) |snapshot| {
            if (config.mapPanel.liveStats and config.mapPanel.showSovTimers and window.listsRunningTimer(&snapshot.campaigns, win32.unixSecondsNow())) self.campaign_feed.poll(allocator, win32.Ticks.now().ms);
        }
        if (config.mapPanel.showAnsiblex and window.hasEveStars()) self.destinations.refreshBridges(allocator, window.evestarsToken(), win32.Ticks.now().ms);
        self.redraw(thumbnail_set);
    }

    /// Adds the newest run's kills and names, and drops kills past their lifetime.
    fn takeKills(self: *MapPanel, config: *const config_mod.Config) void {
        const now_ms = win32.Ticks.now().ms;
        if (self.kill_feed.takeBatch(now_ms)) |batch| {
            defer batch.destroy();
            batch.takeNames(&self.kill_names);
            for (batch.kills.items) |kill| {
                var arrived = kill;
                arrived.seen_ms = now_ms;
                self.kills.add(arrived);
            }
        }
        self.kills.prune(win32.unixSecondsNow(), config.mapPanel.killLifetimeSeconds());
    }

    /// For panel_lifecycle.
    pub fn createWindow(self: *MapPanel, context: panel_host.Context) void {
        // Linked to the panel rather than the window, as the window's input reaches the panel's feeds.
        panel_lifecycle.install(MapPanelWindow, &self.window, initWindow(context, self.intel_history, self.global), self, "Map Panel");
    }

    /// For panel_lifecycle.
    pub fn destroyWindow(self: *MapPanel) void {
        if (self.window) |*window| {
            input.closeSearch(window, self.inputContext(), .hand_back);
            window.deinit();
        }
        self.window = null;
    }

    /// Per tick, and on the pump timer: takes Eve Stars' replies, keeps an open menu's list fresh and closes New Eden once Ctrl is let go.
    fn pump(self: *MapPanel, allocator: std.mem.Allocator) void {
        const now_ms = win32.Ticks.now().ms;
        self.destinations.poll(now_ms);
        const window = if (self.window) |*w| w else return;
        input.finishChoosingRegions(window);
        if (window.state.menu != null and window.hasEveStars()) self.destinations.refreshTargets(allocator, window.evestarsToken(), now_ms);
    }

    /// Also from the window's own input, since the tick can be a second apart with no clients running.
    fn redraw(self: *MapPanel, thumbnail_set: ?*const ThumbnailSet) void {
        const window = if (self.window) |*w| w else return;
        setPumping(window, window.state.isPopupOpen() or self.destinations.isWaiting() or window.state.is_choosing_regions);
        var scene: Scene = .{ .stats = self.stats, .logo_colors = self.logo_colors, .logo_revision = self.logo_revision, .pins = if (window.config.mapPanel.showIntel) &self.pins else &NO_PINS, .destinations = &self.destinations, .now_seconds = win32.unixSecondsNow() };
        if (window.config.mapPanel.showKills) {
            scene.kills = &self.kills;
            scene.kill_names = &self.kill_names;
        }
        if (thumbnail_set) |active_set| {
            scene.thumbnails = active_set.thumbnails.items;
            scene.active_source_hwnd = active_set.active_source_hwnd;
        }
        window.render(scene) catch |err| {
            slog.err("Failed to render Map Panel window: {}", .{err});
        };
        setRippling(window, window.hasRipple(scene, win32.Ticks.now().ms));
    }

    fn redrawAfterInput(self: *MapPanel) void {
        self.redraw(self.host.thumbnail_set());
    }

    /// For input that can come faster than the screen refreshes; a skipped frame waits for FRAME_TIMER_ID.
    fn redrawPaced(self: *MapPanel) void {
        const window = if (self.window) |*w| w else return;
        if (win32.microsecondsNow() -| window.last_frame_us >= window.frame_interval_us) return self.redrawAfterInput();
        if (win32.SetTimer(window.panel.hwnd, FRAME_TIMER_ID, FRAME_CATCH_UP_MS, null) != 0) return;
        slog.warn("Failed to start the Map Panel's frame timer, so the map draws on every move", .{});
        self.redrawAfterInput();
    }

    fn respond(self: *MapPanel, response: input.Response) void {
        switch (response) {
            .none => {},
            .redraw => self.redrawAfterInput(),
            .redraw_paced => self.redrawPaced(),
        }
    }

    fn inputContext(self: *MapPanel) input.Context {
        return .{ .destinations = &self.destinations, .host = self.host };
    }
};

fn initWindow(context: panel_host.Context, intel_history: ?*const history.NotificationHistory, global: ?*const GlobalConfig) !MapPanelWindow {
    try Class.register(context.instance);
    return MapPanelWindow.init(context, MAP_PANEL_WINDOW_CLASS, intel_history, global);
}

fn setPumping(window: *MapPanelWindow, is_wanted: bool) void {
    if (!setTimerRunning(window.panel.hwnd, &window.is_pumping, PUMP_TIMER_ID, PUMP_INTERVAL_MS, is_wanted)) slog.warn("Failed to start the Map Panel's timer, so Eve Stars' replies wait for the tick", .{});
}

fn setRippling(window: *MapPanelWindow, is_wanted: bool) void {
    if (!setTimerRunning(window.panel.hwnd, &window.is_rippling, RIPPLE_TIMER_ID, RIPPLE_FRAME_MS, is_wanted)) slog.warn("Failed to start the Map Panel's ripple timer, so ripples play only on the tick", .{});
}

/// Starts or stops timer `id`, with `is_running` tracking it; false only when it was wanted and wouldn't start.
fn setTimerRunning(hwnd: win32.HWND, is_running: *bool, id: usize, interval_ms: win32.UINT, is_wanted: bool) bool {
    if (is_wanted == is_running.*) return true;
    if (!is_wanted) {
        _ = win32.KillTimer(hwnd, id);
        is_running.* = false;
        return true;
    }
    is_running.* = win32.SetTimer(hwnd, id, interval_ms, null) != 0;
    return is_running.*;
}

fn mapPanelWindowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    // Messages sent while the window is created come before it's attached.
    const owner = panel_window.ownerOf(MapPanel, hwnd);
    // The frame's edges and title bar are Windows' own to hit test.
    if (msg != win32.WM_NCHITTEST) {
        const thumbnail_set = if (owner) |map_panel| map_panel.host.thumbnail_set() else null;
        if (drag.handleMessage(thumbnail_set, hwnd, msg, lParam, 0)) |result| return result;
    }
    switch (msg) {
        win32.WM_CLOSE => {
            const map_panel = owner orelse return 0;
            const window = if (map_panel.window) |*open| open else return 0;
            panel_lifecycle.close(map_panel, window.store);
            return 0;
        },
        else => {},
    }
    const map_panel = owner orelse return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
    const window = if (map_panel.window) |*open| open else return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
    switch (msg) {
        win32.WM_EXITSIZEMOVE => window.afterSizeMove(),
        win32.WM_SYSCOMMAND => {
            // A title bar drag asks to move by this, so a locked map stays put; sizing still works.
            if (wParam & 0xFFF0 == win32.SC_MOVE and window.config.mapPanel.lockPosition) return 0;
            return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
        },
        win32.WM_PAINT => window.panel.paint(),
        win32.WM_SIZE => {
            if (wParam == win32.SIZE_MINIMIZED) return 0;
            if (window.onSize(win32.lparamX(lParam), win32.lparamY(lParam))) map_panel.redrawAfterInput();
        },
        win32.WM_GETMINMAXINFO => window.limitSize(win32.lparamToPtr(win32.MINMAXINFO, lParam)),
        win32.WM_TIMER => {
            switch (wParam) {
                FRAME_TIMER_ID => _ = win32.KillTimer(hwnd, FRAME_TIMER_ID),
                PUMP_TIMER_ID => map_panel.pump(window.panel.allocator),
                else => {},
            }
            map_panel.redrawAfterInput();
        },
        else => {
            const response = input.handleMessage(window, map_panel.inputContext(), msg, wParam, lParam) orelse return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
            map_panel.respond(response);
        },
    }
    return 0;
}
