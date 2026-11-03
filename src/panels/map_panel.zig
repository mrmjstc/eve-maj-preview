//! The Map Panel: a schematic of one region with live stats, where the clients are and chat intel, and New Eden for picking a region.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const panel_window = @import("../platform/panel_window.zig");
const config_mod = @import("../config.zig");
const types = @import("../config/types.zig");
const history = @import("../notifications/history.zig");
const history_look = @import("history_look.zig");
const history_rows = @import("history_rows.zig");
const list_look = @import("list_look.zig");
const map_look = @import("map_look.zig");
const panel_chrome = @import("panel_chrome.zig");
const panel_look = @import("panel_look.zig");
const popup_look = @import("popup_look.zig");
const popup_menu = @import("popup_menu.zig");
const universe = @import("../map/universe.zig");
const jump_range = @import("../map/jump_range.zig");
const layout_mod = @import("../map/layout.zig");
const overview_mod = @import("../map/overview.zig");
const search = @import("../map/search.zig");
const stats_mod = @import("../map/stats.zig");
const stats_feed = @import("../map/stats_feed.zig");
const storms_mod = @import("../map/storms.zig");
const incursions_mod = @import("../map/incursions.zig");
const intel_pins = @import("../map/intel_pins.zig");
const evestars = @import("../map/evestars.zig");
const destinations_mod = @import("../map/destinations.zig");
const system_links = @import("../map/system_links.zig");
const app = @import("../app.zig");
const activation = @import("../control/activation.zig");
const scout = @import("../clients/scout.zig");
const set = @import("../thumbnail/set.zig");
const window_mod = @import("../thumbnail/window.zig");
const drag = @import("drag.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");
const log = @import("../log.zig");

const Box = layout_mod.Box;
const Destinations = destinations_mod.Destinations;
const GlobalConfig = config_mod.GlobalConfig;
const Incursions = incursions_mod.Incursions;
const Layout = layout_mod.Layout;
const MapMetric = types.MapMetric;
const PanelWindow = panel_window.PanelWindow;
const PopupMenu = popup_menu.PopupMenu;
const PopupRow = popup_look.PopupRow;
const RegionIndex = universe.RegionIndex;
const Snapshot = stats_mod.Snapshot;
const Storms = storms_mod.Storms;
const SystemIndex = universe.SystemIndex;
const ThumbnailSet = set.ThumbnailSet;
const ThumbnailWindow = window_mod.ThumbnailWindow;
const slog = log.Scoped("map_panel");

const MAP_PANEL_WINDOW_CLASS = "EVE_MAP_PANEL_CLASS";
/// Granularity of ages baked into the render signature, so they don't redraw every tick.
const AGE_BUCKET_MS: u64 = 15_000;
/// More clients than this go unmarked.
const MAX_MARKS = 64;
const DEFAULT_REGION_ID = 10000002;
/// While a popup or an Eve Stars call is open, as the app's tick can be a second apart.
const PUMP_TIMER_ID: usize = 1;
const PUMP_INTERVAL_MS: win32.UINT = 100;
/// Shown instead of the real pins while mapPanelShowIntel is off.
const NO_PINS: intel_pins.IntelPins = .{};
/// Each wheel notch or zoom button press.
const ZOOM_STEP: f32 = 1.25;
/// How far the cursor must move before a press on empty map counts as a drag.
const PAN_START_DISTANCE: i32 = 3;
const MENU_ROWS = [_]MenuRow{ .heading, .set_destination, .open_site, .jump_range, .avoid_system, .copy_name };
/// With Eve Stars off or no token, nothing can be sent.
const MENU_ROWS_WITHOUT_EVE_STARS = [_]MenuRow{ .heading, .open_site, .jump_range, .copy_name };
/// The destination submenu's rows: the route's settings, "All", each group, then "Individual" for the characters.
const PREFERENCE_ROW = 0;
const ANSIBLEX_ROW = 1;
const WAYPOINTS_ROW = 2;
const ALL_ROW = 3;
const MAX_POPUP_ROWS = ALL_ROW + 1 + evestars.MAX_TARGETS;

/// A logged-in client on the map.
const Mark = struct {
    system: SystemIndex,
    source_hwnd: win32.HWND,
    /// Borrows from the thumbnail, so it's only good until the next tick; rebuilt each render.
    character_name: []const u8,
    color: u32,
    is_active: bool,
};

/// What the panel shows besides its own settings; borrowed for one render.
const Scene = struct {
    thumbnails: []const ThumbnailWindow = &.{},
    active_source_hwnd: ?win32.HWND = null,
    stats: ?*const Snapshot,
    pins: *const intel_pins.IntelPins,
    destinations: *const Destinations,
};

const Hover = struct {
    kind: Kind = .none,
    /// A `nodes` or `exits` place, a RegionIndex, a Button's or MapControl's value, an `intel_rows` place or a popup, submenu or nested row, by kind.
    index: u16 = 0,

    const Kind = enum { none, node, exit, region, button, intel_row, popup_row, submenu_row, nested_row, search_box, map_control };

    fn eql(self: Hover, other: Hover) bool {
        return self.kind == other.kind and self.index == other.index;
    }
};

const MenuRow = enum { heading, set_destination, open_site, jump_range, avoid_system, copy_name };

/// A left-button press on empty map, which a drag turns into panning.
const MapPan = struct {
    start_x: i32,
    start_y: i32,
    start_view: layout_mod.View,
    has_moved: bool = false,
};

/// What's measured once a frame for colouring the map.
const MapPaint = struct {
    metric: MapMetric,
    /// The region's busiest system by `metric`, which heat is measured against.
    peak: u32,
    holders: map_look.HolderRanks,
};

/// What follows a system's name.
const LabelSuffix = struct {
    /// Borrows from the buffer passed to labelSuffix.
    text: []const u8,
    color: u32,
};

/// A menu row's submenu.
const Branch = enum { destination, sites, jump_range };

/// Right-clicking a system opens this over the map.
const SystemMenu = struct {
    system: SystemIndex,
    anchor: win32.POINT,
    /// Null while no submenu is open.
    branch: ?Branch = null,
    /// The characters are open beside the destination submenu's "Individual".
    shows_characters: bool = false,
};

/// Which rows a popup's box shows.
const PopupRows = union(enum) { main, branch: Branch, characters };

/// Whether the search gives the keyboard back to what had it, or something else already took it.
const SearchEnding = enum { hand_back, keyboard_gone };

/// The shared fonts, and the map's own for the names on it.
const MapText = struct {
    chrome: panel_chrome.Text,
    label_font: win32.HFONT,
    label_height: i32,
    title_font: win32.HFONT,
    title_height: i32,
};

/// Owns the Map Panel window, its figures and its pins: display.showMapPanel creates the window, and the stats and pins outlive it.
pub const MapPanel = struct {
    window: ?MapPanelWindow = null,
    visibility: panel_look.Visibility = .{},
    feed: stats_feed.StatsFeed = .{},
    /// The newest figures; owned, freed in deinit.
    stats: ?*Snapshot = null,
    pins: intel_pins.IntelPins = .{},
    /// What the Intel Panel lists, drawn here while it's inside the map; borrowed, outlives the panel.
    intel_history: ?*const history.NotificationHistory = null,
    /// Holds the Eve Stars token; borrowed, outlives the panel.
    global: ?*const GlobalConfig = null,
    destinations: Destinations = .{},
    /// Hidden from its window's close button, the tray or the hotkey, which leave showMapPanel on; the tray or hotkey reopens it, as does turning the setting off and on.
    is_dismissed: bool = false,

    /// Creates the window if `store`'s profile shows it.
    pub fn start(self: *MapPanel, allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE, intel_history: *const history.NotificationHistory, global: *const GlobalConfig) void {
        self.intel_history = intel_history;
        self.global = global;
        if (store.live.display.showMapPanel) self.createWindow(allocator, store, instance);
    }

    /// Only once the feeds' threads have finished.
    pub fn deinit(self: *MapPanel) void {
        self.destroyWindow();
        self.feed.deinit();
        self.destinations.deinit();
        if (self.stats) |snapshot| stats_feed.destroySnapshot(snapshot);
        self.stats = null;
    }

    /// Accounts for the panel's auto-hide settings and the tray-toggle override.
    pub fn isVisible(self: *const MapPanel, config: *const config_mod.Config, any_character_logged_in: bool) bool {
        const display = &config.display;
        return self.window != null and self.visibility.allows(.{
            .hides_without_characters = display.hideMapPanelWhenNoCharacters,
            .any_character_logged_in = any_character_logged_in,
            .hides_without_focus = display.hideMapPanelWhenNoEveFocus,
            .hide_delay_ms = display.mapPanelHideDebounceMs,
            .now_ms = win32.Ticks.now().ms,
        });
    }

    /// Opens `system`'s region with it selected, for an Intel Panel row.
    pub fn showSystem(self: *MapPanel, system: SystemIndex, thumbnail_set: ?*const ThumbnailSet) void {
        const window = if (self.window) |*w| w else return;
        window.selectSystem(system);
        self.redraw(thumbnail_set);
    }

    /// Keyed on isVisible(), not the window: a visible panel hides, and a hidden one is forced on even with no character logged in.
    pub fn toggle(self: *MapPanel, allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE, any_character_logged_in: bool) void {
        if (self.isVisible(&store.live, any_character_logged_in)) {
            self.dismiss();
            return;
        }
        if (self.window == null) self.createWindow(allocator, store, instance);
        if (self.window == null) return;
        self.is_dismissed = false;
        store.update(.{ .display = .{ .showMapPanel = true } });
        self.visibility.force();
    }

    /// Destroys the window for now, leaving showMapPanel on.
    fn dismiss(self: *MapPanel) void {
        self.is_dismissed = true;
        self.destroyWindow();
        self.visibility.release();
    }

    /// Matches the window to showMapPanel, its position and region, for a change made in the config dialog or by a new profile.
    pub fn sync(self: *MapPanel, allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE) void {
        if (!store.live.display.showMapPanel) self.is_dismissed = false;
        const is_wanted = store.live.display.showMapPanel and !self.is_dismissed;
        if (!is_wanted and self.window != null) {
            self.destroyWindow();
            self.visibility.release();
        } else if (is_wanted and self.window == null) {
            self.createWindow(allocator, store, instance);
        }
        if (self.window) |*window| window.followSettings();
    }

    /// Per tick: takes any new figures, then renders the panel or hides it.
    pub fn update(self: *MapPanel, allocator: std.mem.Allocator, config: *const config_mod.Config, presence: panel_look.Presence, thumbnail_set: ?*const ThumbnailSet) void {
        self.visibility.note(presence, win32.Ticks.now().ms);

        if (self.feed.take()) |fresh| {
            if (self.stats) |old| stats_feed.destroySnapshot(old);
            self.stats = fresh;
        }
        self.pump(allocator);

        const window = if (self.window) |*w| w else return;
        if (!self.isVisible(config, presence.any_character_logged_in)) {
            window.hide();
            return;
        }
        if (config.display.mapPanelLiveStats) self.feed.poll(allocator, win32.Ticks.now());
        self.redraw(thumbnail_set);
    }

    /// Per tick, and on the pump timer: takes Eve Stars' replies and keeps an open menu's list fresh.
    fn pump(self: *MapPanel, allocator: std.mem.Allocator) void {
        const now_ms = win32.Ticks.now().ms;
        self.destinations.poll(now_ms);
        const window = if (self.window) |*w| w else return;
        if (window.menu != null and window.hasEveStars()) self.destinations.refreshTargets(allocator, tokenOf(self.global), now_ms);
    }

    /// Also from the window's own input, since the tick can be a second apart with no clients running.
    fn redraw(self: *MapPanel, thumbnail_set: ?*const ThumbnailSet) void {
        const window = if (self.window) |*w| w else return;
        window.setPumping(window.isPopupOpen() or self.destinations.isWaiting());
        var scene: Scene = .{ .stats = self.stats, .pins = if (window.config.display.mapPanelShowIntel) &self.pins else &NO_PINS, .destinations = &self.destinations };
        if (thumbnail_set) |active_set| {
            scene.thumbnails = active_set.thumbnails.items;
            scene.active_source_hwnd = active_set.active_source_hwnd;
        }
        window.render(scene) catch |err| {
            slog.err("Failed to render Map Panel window: {}", .{err});
        };
    }

    fn createWindow(self: *MapPanel, allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE) void {
        self.window = MapPanelWindow.init(allocator, store, instance, self.intel_history, self.global) catch |err| {
            slog.err("Failed to create Map Panel window: {}", .{err});
            return;
        };
    }

    fn destroyWindow(self: *MapPanel) void {
        if (self.window) |*window| {
            if (app.g_app) |running| window.closeSearch(running, .hand_back);
            window.deinit();
        }
        self.window = null;
    }
};

pub const MapPanelWindow = struct {
    panel: PanelWindow,
    /// For the names on the map, smaller than the panel's own fonts so more of them fit.
    label_font: gdi_overlay.CachedFont = .{},
    /// For the region's name over the map.
    title_font: gdi_overlay.CachedFont = .{},
    /// Borrowed; outlives the window.
    store: *config_mod.ProfileStore,
    /// Borrowed; outlives the window.
    config: *const config_mod.Config,
    region: RegionIndex,
    /// The mapPanelRegionId last read, so only a change to it moves the map; following a client doesn't touch it.
    settled_region_id: u32,
    /// The region the active client was last seen in; following acts when it changes, so a region picked by hand stays until then.
    followed_region: ?RegionIndex = null,
    layout: Layout = .{},
    /// What `layout` was built for.
    layout_signature: ?u64 = null,
    hover: Hover = .{},
    /// A leave is armed, to clear `hover`.
    is_tracking_mouse: bool = false,
    /// Null unless the left button is down on empty map.
    pan: ?MapPan = null,
    /// Shows New Eden in place of the map.
    is_picking_region: bool = false,
    overview: overview_mod.Overview = .{},
    /// What `overview` was built for.
    overview_signature: ?u64 = null,
    /// The selected system, ringed: one clicked, or arrived at through a gate or the Intel Panel.
    focus_system: ?SystemIndex = null,
    /// The jump range showing, kept across regions as it reaches past the one on screen.
    reach: ?jump_range.Reach = null,
    /// Rebuilt each render; borrows from the thumbnails.
    marks: [MAX_MARKS]Mark = undefined,
    mark_count: usize = 0,
    /// See MapPanel.intel_history.
    intel_history: ?*const history.NotificationHistory,
    /// The sidebar's rows, from the last render.
    intel_rows: [history.CAPACITY]history_rows.Row = undefined,
    intel_row_count: usize = 0,
    /// See MapPanel.global.
    global: ?*const GlobalConfig,
    /// Null while it's closed.
    menu: ?SystemMenu = null,
    /// The search box is open, and has the keyboard.
    is_searching: bool = false,
    search_buffer: [search.MAX_QUERY_LENGTH]u8 = undefined,
    search_length: usize = 0,
    hits: search.Hits = .{},
    /// The search's picked row, moved by the keys and the mouse: what's lit is what Enter opens.
    search_index: usize = 0,
    /// What had the keyboard before the search, to hand it back.
    search_return_hwnd: ?win32.HWND = null,
    popup: PopupMenu = .{},
    /// PUMP_TIMER_ID is running.
    is_pumping: bool = false,
    /// The title bar's text, to set it only when it changes.
    title_hash: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE, intel_history: ?*const history.NotificationHistory, global: ?*const GlobalConfig) !MapPanelWindow {
        const display = &store.live.display;
        try registerWindowClass(instance);
        const panel = try PanelWindow.initNative(allocator, instance, MAP_PANEL_WINDOW_CLASS, "EVE Map", .{
            .left = display.mapPanelX,
            .top = display.mapPanelY,
            .right = display.mapPanelX + display.mapPanelWidth + sidebarWidth(display, intel_history),
            .bottom = display.mapPanelY + display.mapPanelHeight,
        }, display.mapPanelAlwaysOnTop);
        return .{
            .panel = panel,
            .store = store,
            .config = &store.live,
            .region = regionFromSettings(display.mapPanelRegionId),
            .settled_region_id = display.mapPanelRegionId,
            .intel_history = intel_history,
            .global = global,
        };
    }

    pub fn deinit(self: *MapPanelWindow) void {
        self.label_font.deinit(self.panel.allocator);
        self.title_font.deinit(self.panel.allocator);
        self.panel.deinit();
    }

    pub fn hide(self: *const MapPanelWindow) void {
        self.panel.hide();
    }

    fn followSettings(self: *MapPanelWindow) void {
        const display = &self.config.display;
        self.panel.followPosition(display.mapPanelX, display.mapPanelY);
        if (display.mapPanelRegionId == self.settled_region_id) return;
        self.settled_region_id = display.mapPanelRegionId;
        self.showRegion(regionFromSettings(display.mapPanelRegionId));
    }

    /// A maximized window keeps the size it restores to.
    fn saveWindowPlacement(self: *const MapPanelWindow) void {
        const display = &self.config.display;
        if (win32.isWindowZoomed(self.panel.hwnd)) return;
        self.store.update(.{ .display = .{ .mapPanelWidth = self.panel.width - sidebarWidth(display, self.intel_history), .mapPanelHeight = self.panel.height } });
        if (!display.rememberMapPanelPosition) return;
        const top_left = self.panel.topLeft() orelse return;
        self.store.update(.{ .display = .{ .mapPanelX = top_left.x, .mapPanelY = top_left.y } });
    }

    fn showRegion(self: *MapPanelWindow, region: RegionIndex) void {
        self.region = region;
        self.layout.view = .{};
        self.focus_system = null;
        self.is_picking_region = false;
        self.hover = .{};
    }

    /// Picked by the user, so it's what the panel reopens on.
    fn chooseRegion(self: *MapPanelWindow, region: RegionIndex) void {
        self.showRegion(region);
        self.settled_region_id = universe.regionId(region);
        self.store.update(.{ .display = .{ .mapPanelRegionId = self.settled_region_id } });
    }

    fn selectSystem(self: *MapPanelWindow, system: SystemIndex) void {
        self.chooseRegion(universe.systemInfo(system).region);
        self.focus_system = system;
    }

    fn isIntelInside(self: *const MapPanelWindow) bool {
        return sidebarWidth(&self.config.display, self.intel_history) > 0;
    }

    /// Stops the window being dragged smaller than the settings allow, sidebar included.
    fn limitSize(self: *const MapPanelWindow, limits: *win32.MINMAXINFO) void {
        const min_width = config_mod.DisplayConfig.MAP_PANEL_MIN_WIDTH + sidebarWidth(&self.config.display, self.intel_history);
        const outer = PanelWindow.outerSize(min_width, config_mod.DisplayConfig.MAP_PANEL_MIN_HEIGHT);
        limits.ptMinTrackSize = .{ .x = outer.cx, .y = outer.cy };
    }

    /// Whether the size changed, and so the panel needs a redraw.
    fn onSize(self: *MapPanelWindow, width: i32, height: i32) bool {
        if (width == self.panel.width and height == self.panel.height) return false;
        self.panel.width = width;
        self.panel.height = height;
        return true;
    }

    /// Empty while the Intel Panel isn't inside the map.
    fn intelEntries(self: *const MapPanelWindow, buffer: []history.Entry) []const history.Entry {
        const intel_history = self.intel_history orelse return &.{};
        return if (self.isIntelInside()) intel_history.snapshot(buffer) else &.{};
    }

    /// Above the footer.
    fn innerArea(self: *const MapPanelWindow, sizes: map_look.Metrics) Box {
        return .{ .left = 0, .top = 0, .right = self.panel.width, .bottom = @max(0, self.panel.height - sizes.footer_height) };
    }

    /// Null while the Intel Panel isn't inside the map.
    fn intelSidebar(self: *const MapPanelWindow, sizes: map_look.Metrics) ?Box {
        if (!self.isIntelInside()) return null;
        const display = &self.config.display;
        const inner = self.innerArea(sizes);
        return switch (display.intelPanelSide) {
            .Left => .{ .left = inner.left, .top = inner.top, .right = inner.left + display.intelPanelWidth, .bottom = inner.bottom },
            .Right => .{ .left = inner.right - display.intelPanelWidth, .top = inner.top, .right = inner.right, .bottom = inner.bottom },
        };
    }

    /// The map's part of the panel, beside any sidebar, leaving a line for the divider.
    fn bodyArea(self: *const MapPanelWindow, sizes: map_look.Metrics) Box {
        var area = self.innerArea(sizes);
        const sidebar = self.intelSidebar(sizes) orelse return area;
        switch (self.config.display.intelPanelSide) {
            .Left => area.left = sidebar.right + 1,
            .Right => area.right = sidebar.left - 1,
        }
        return area;
    }

    /// What the map fits itself to, below the region's name.
    fn mapArea(self: *const MapPanelWindow, sizes: map_look.Metrics) Box {
        var area = self.bodyArea(sizes);
        area.top = @min(area.bottom, area.top + map_look.TITLE_BAND);
        return area;
    }

    fn hasEveStars(self: *const MapPanelWindow) bool {
        const settings = self.global orelse return false;
        return settings.evestarsEnabled and settings.evestarsToken.len > 0;
    }

    fn isPopupOpen(self: *const MapPanelWindow) bool {
        return self.menu != null or self.is_searching;
    }

    fn menuRows(self: *const MapPanelWindow) []const MenuRow {
        return if (self.hasEveStars()) &MENU_ROWS else &MENU_ROWS_WITHOUT_EVE_STARS;
    }

    /// The menu row `branch` hangs off.
    fn branchRowIndex(self: *const MapPanelWindow, branch: Branch) usize {
        const row: MenuRow = switch (branch) {
            .destination => .set_destination,
            .sites => .open_site,
            .jump_range => .jump_range,
        };
        // The token can go while the menu's open, taking its row along.
        return std.mem.indexOfScalar(MenuRow, self.menuRows(), row) orelse 0;
    }

    fn setPumping(self: *MapPanelWindow, is_wanted: bool) void {
        if (is_wanted == self.is_pumping) return;
        if (!is_wanted) {
            _ = win32.KillTimer(self.panel.hwnd, PUMP_TIMER_ID);
            self.is_pumping = false;
            return;
        }
        self.is_pumping = win32.SetTimer(self.panel.hwnd, PUMP_TIMER_ID, PUMP_INTERVAL_MS, null) != 0;
        if (!self.is_pumping) slog.warn("Failed to start the Map Panel's timer, so Eve Stars' replies wait for the tick", .{});
    }

    fn searchBox(self: *const MapPanelWindow, sizes: map_look.Metrics) Box {
        return map_look.searchBox(self.bodyArea(sizes));
    }

    fn isOverSearchBox(self: *const MapPanelWindow, x: i32, y: i32) bool {
        const box = self.searchBox(map_look.metrics(&self.config.display));
        return x >= box.left and x < box.right and y >= box.top and y < box.bottom;
    }

    /// While a popup is open, only it and the search box can be hit, the popup first as it can lie over the box.
    fn hitTest(self: *const MapPanelWindow, x: i32, y: i32) Hover {
        if (self.isPopupOpen()) {
            if (self.popup.hitAt(x, y)) |hit| return switch (hit) {
                .main => |row_index| .{ .kind = .popup_row, .index = @intCast(row_index) },
                .submenu => |row_index| .{ .kind = .submenu_row, .index = @intCast(row_index) },
                .nested => |row_index| .{ .kind = .nested_row, .index = @intCast(row_index) },
            };
        }
        if (self.isOverSearchBox(x, y)) return .{ .kind = .search_box };
        if (self.isPopupOpen()) return .{};
        const sizes = map_look.metrics(&self.config.display);
        if (y >= self.panel.height - sizes.footer_height) {
            const button = map_look.buttonAt(self.panel.width, x) orelse return .{};
            return .{ .kind = .button, .index = @backingInt(button) };
        }
        if (self.intelSidebar(sizes)) |sidebar| {
            if (x >= sidebar.left and x < sidebar.right and y >= sidebar.top and y < sidebar.bottom) {
                const row_index: usize = @intCast(@divTrunc(y - sidebar.top, history_rows.intelRowHeight(&self.config.display)));
                return if (row_index < self.intel_row_count) .{ .kind = .intel_row, .index = @intCast(row_index) } else .{};
            }
        }
        if (self.is_picking_region) {
            const region = self.overview.regionAt(x, y) orelse return .{};
            return .{ .kind = .region, .index = region };
        }
        if (map_look.mapControlAt(self.bodyArea(sizes), x, y)) |control| return .{ .kind = .map_control, .index = @backingInt(control) };
        // Chips lie over the map, so one beats a system just behind its edge.
        if (self.layout.exitLabelAt(x, y)) |exit| return .{ .kind = .exit, .index = exit };
        if (self.layout.nodeAt(x, y)) |node| return .{ .kind = .node, .index = node };
        if (self.layout.exitAt(x, y)) |exit| return .{ .kind = .exit, .index = exit };
        return .{};
    }

    /// Whether the hover changed, and so the panel needs a redraw.
    fn onMouseMove(self: *MapPanelWindow, running: *app.App, hwnd: win32.HWND, x: i32, y: i32) bool {
        if (!self.is_tracking_mouse) self.is_tracking_mouse = win32.trackMouseLeave(hwnd);
        if (self.pan) |*pan| return self.continuePan(pan, x, y);
        const hover = self.hitTest(x, y);
        if (hover.eql(self.hover)) return false;
        self.hover = hover;
        if (hover.kind == .popup_row and self.is_searching) self.search_index = hover.index;
        if (hover.kind == .popup_row) self.followMenuRow(hover.index);
        if (hover.kind == .submenu_row) self.followSubmenuRow(&running.map_panel.destinations, hover.index);
        return true;
    }

    /// Whether the map moved.
    fn continuePan(self: *MapPanelWindow, pan: *MapPan, x: i32, y: i32) bool {
        const delta_x = x - pan.start_x;
        const delta_y = y - pan.start_y;
        if (!pan.has_moved and @abs(delta_x) + @abs(delta_y) < PAN_START_DISTANCE) return false;
        pan.has_moved = true;
        const area = self.mapArea(map_look.metrics(&self.config.display));
        self.layout.view = pan.start_view.panned(area, @floatFromInt(delta_x), @floatFromInt(delta_y));
        return true;
    }

    fn beginPan(self: *MapPanelWindow, x: i32, y: i32) void {
        self.pan = .{ .start_x = x, .start_y = y, .start_view = self.layout.view };
        _ = win32.SetCapture(self.panel.hwnd);
    }

    /// A press that never moved is a click on empty map, which drops the selection.
    fn endPan(self: *MapPanelWindow) void {
        const pan = self.pan orelse return;
        self.pan = null;
        _ = win32.ReleaseCapture();
        if (!pan.has_moved) self.focus_system = null;
    }

    /// Whether the map zoomed; `wParam` and `lParam` are WM_MOUSEWHEEL's, whose position is on the screen.
    fn onWheel(self: *MapPanelWindow, wParam: win32.WPARAM, lParam: win32.LPARAM) bool {
        if (self.is_picking_region or self.isPopupOpen()) return false;
        var point: win32.POINT = .{ .x = win32.lparamX(lParam), .y = win32.lparamY(lParam) };
        _ = win32.ScreenToClient(self.panel.hwnd, &point);
        const area = self.mapArea(map_look.metrics(&self.config.display));
        if (point.x < area.left or point.x >= area.right or point.y >= area.bottom) return false;
        const notches = @as(f32, @floatFromInt(win32.getWheelDelta(@truncate(wParam)))) / win32.WHEEL_DELTA;
        self.layout.view = self.layout.view.zoomedAt(area, point.x, point.y, std.math.pow(f32, ZOOM_STEP, notches));
        return true;
    }

    fn pressMapControl(self: *MapPanelWindow, control: map_look.MapControl) void {
        const area = self.mapArea(map_look.metrics(&self.config.display));
        const x = @divTrunc(area.left + area.right, 2);
        const y = @divTrunc(area.top + area.bottom, 2);
        switch (control) {
            .zoom_in => self.layout.view = self.layout.view.zoomedAt(area, x, y, ZOOM_STEP),
            .zoom_out => self.layout.view = self.layout.view.zoomedAt(area, x, y, 1 / ZOOM_STEP),
            .fit => self.layout.view = .{},
            .always_on_top => self.store.update(.{ .display = .{ .mapPanelAlwaysOnTop = !self.config.display.mapPanelAlwaysOnTop } }),
        }
    }

    /// Opens the submenu of the menu row at `row_index`; the heading leaves what's open alone.
    fn followMenuRow(self: *MapPanelWindow, row_index: usize) void {
        const rows = self.menuRows();
        const menu = if (self.menu) |*open| open else return;
        if (row_index >= rows.len) return;
        switch (rows[row_index]) {
            .heading => {},
            .set_destination => menu.branch = .destination,
            .open_site => {
                menu.branch = .sites;
                menu.shows_characters = false;
            },
            .jump_range => {
                menu.branch = .jump_range;
                menu.shows_characters = false;
            },
            .avoid_system, .copy_name => {
                menu.branch = null;
                menu.shows_characters = false;
            },
        }
        if (menu.branch == null) self.popup.submenu = null;
        if (!menu.shows_characters) self.popup.nested = null;
    }

    /// Opens the characters for "Individual", and closes them for any other row.
    fn followSubmenuRow(self: *MapPanelWindow, destinations: *const Destinations, row_index: usize) void {
        const menu = if (self.menu) |*open| open else return;
        const branch = menu.branch orelse return;
        if (branch != .destination) return;
        menu.shows_characters = row_index == individualRow(&destinations.targets);
        if (!menu.shows_characters) self.popup.nested = null;
    }

    fn showsCharacters(self: *const MapPanelWindow) bool {
        return if (self.menu) |menu| menu.shows_characters else false;
    }

    fn onMouseLeave(self: *MapPanelWindow) void {
        self.is_tracking_mouse = false;
        self.hover = .{};
    }

    fn openIntelRow(self: *MapPanelWindow, row_index: usize) void {
        const intel_history = self.intel_history orelse return;
        const entry = intel_history.entryFromNewest(self.intel_rows[row_index].first_index) orelse return;
        if (entry.system) |system| self.selectSystem(system);
    }

    fn handleClick(self: *MapPanelWindow, running: *app.App, x: i32, y: i32) void {
        const hit = self.hitTest(x, y);
        switch (hit.kind) {
            .none => {
                if (self.isPopupOpen()) {
                    self.closePopup(running);
                    return;
                }
                if (self.is_picking_region) {
                    self.is_picking_region = false;
                    return;
                }
                self.beginPan(x, y);
            },
            .map_control => self.pressMapControl(@fromBackingInt(@intCast(hit.index))),
            .popup_row => self.pressPopupRow(running, hit.index),
            .submenu_row => self.pressSubmenuRow(running, hit.index),
            .nested_row => self.pressCharacterRow(running, hit.index),
            .search_box => self.openSearch(running),
            .button => self.pressButton(@fromBackingInt(@intCast(hit.index))),
            .region => self.chooseRegion(@intCast(hit.index)),
            .intel_row => self.openIntelRow(hit.index),
            .node => {
                const system = self.layout.nodes[hit.index].system;
                self.focus_system = if (self.focus_system == system) null else system;
                for (self.marks[0..self.mark_count]) |mark| {
                    if (mark.system != system) continue;
                    activation.activate(running, mark.source_hwnd);
                    return;
                }
            },
            .exit => {
                const exit = self.layout.exits[hit.index];
                self.chooseRegion(exit.region);
                self.focus_system = exit.destination;
            },
        }
    }

    fn handleRightClick(self: *MapPanelWindow, running: *app.App, x: i32, y: i32) void {
        const hit = self.hitTest(x, y);
        if (self.isPopupOpen()) {
            self.closePopup(running);
            return;
        }
        const node_index = self.nodeWithMenuAt(hit, x, y) orelse return;
        const node = self.layout.nodes[node_index];
        self.focus_system = node.system;
        self.menu = .{ .system = node.system, .anchor = .{ .x = node.x, .y = node.y } };
        self.hover = .{};
        if (self.hasEveStars()) running.map_panel.destinations.refreshTargets(running.allocator, tokenOf(self.global), win32.Ticks.now().ms);
    }

    /// A system's name counts as well as its marker, though only the marker takes a hover.
    fn nodeWithMenuAt(self: *const MapPanelWindow, hit: Hover, x: i32, y: i32) ?u16 {
        if (hit.kind == .node) return hit.index;
        if (hit.kind != .none or self.is_picking_region) return null;
        return self.layout.labelAt(x, y);
    }

    fn closePopup(self: *MapPanelWindow, running: *app.App) void {
        self.menu = null;
        self.popup.clear();
        self.closeSearch(running, .hand_back);
    }

    fn pressPopupRow(self: *MapPanelWindow, running: *app.App, row_index: usize) void {
        const menu = self.menu orelse return self.pickHit(running, row_index);
        self.followMenuRow(row_index);
        const rows = self.menuRows();
        if (row_index >= rows.len) return;
        switch (rows[row_index]) {
            .heading, .set_destination, .open_site, .jump_range => {},
            .avoid_system => {
                self.closePopup(running);
                self.toggleAvoided(&running.map_panel.destinations, menu.system);
            },
            .copy_name => {
                self.closePopup(running);
                copySystemName(&running.map_panel.destinations, menu.system);
            },
        }
    }

    fn isAvoided(self: *const MapPanelWindow, system: SystemIndex) bool {
        return self.config.avoidedSystemIndex(universe.systemInfo(system).id) != null;
    }

    fn toggleAvoided(self: *const MapPanelWindow, destinations: *Destinations, system: SystemIndex) void {
        const name = universe.systemName(system);
        const now_ms = win32.Ticks.now().ms;
        const is_avoided = self.store.toggleAvoidedSystem(universe.systemInfo(system).id) catch |err| {
            slog.warn("Failed to change whether routes avoid '{s}': {}", .{ name, err });
            destinations.showFailureText(.print("{s}", .{if (err == error.AvoidListFull) "The avoid list is full" else "Couldn't change the avoid list"}), now_ms);
            return;
        };
        destinations.showInfo(.print("Routes {s} {s}", .{ if (is_avoided) "avoid" else "no longer avoid", name }), now_ms);
    }

    fn pressSubmenuRow(self: *MapPanelWindow, running: *app.App, row_index: usize) void {
        self.followSubmenuRow(&running.map_panel.destinations, row_index);
        const menu = self.menu orelse return;
        const branch = menu.branch orelse return;
        switch (branch) {
            .destination => self.pressDestinationRow(running, menu.system, row_index),
            .sites => {
                if (row_index >= system_links.SITES.len) return;
                self.closePopup(running);
                openSite(&running.map_panel.destinations, system_links.SITES[row_index], menu.system);
            },
            .jump_range => {
                if (row_index >= self.rangeRowCount()) return;
                self.closePopup(running);
                self.reach = if (row_index < jump_range.SHIPS.len) .measure(menu.system, jump_range.SHIPS[row_index]) else null;
            },
        }
    }

    /// One a ship, then "Off" while a range shows.
    fn rangeRowCount(self: *const MapPanelWindow) usize {
        return jump_range.SHIPS.len + @intFromBool(self.reach != null);
    }

    /// The route's settings change in place, leaving the menu open for the send.
    fn pressDestinationRow(self: *MapPanelWindow, running: *app.App, system: SystemIndex, row_index: usize) void {
        const display = &self.config.display;
        switch (row_index) {
            PREFERENCE_ROW => return self.store.update(.{ .display = .{ .mapPanelRoutePreference = map_look.nextPreference(display.mapPanelRoutePreference) } }),
            ANSIBLEX_ROW => return self.store.update(.{ .display = .{ .mapPanelRouteAnsiblex = !display.mapPanelRouteAnsiblex } }),
            WAYPOINTS_ROW => return self.store.update(.{ .display = .{ .mapPanelRouteEveryWaypoint = !display.mapPanelRouteEveryWaypoint } }),
            else => {},
        }
        const destinations = &running.map_panel.destinations;
        const targets = destinations.targets.slice();
        const send_index = row_index - ALL_ROW;
        if (targets.len == 0 or send_index > destinations.targets.groupCount()) return;
        if (send_index > 0) return self.sendDestination(running, system, &targets[send_index - 1]);
        self.closePopup(running);
        const options = routeOptions(self.config);
        destinations.sendToAll(running.allocator, tokenOf(self.global), system, &options, win32.Ticks.now().ms);
    }

    fn pressCharacterRow(self: *MapPanelWindow, running: *app.App, row_index: usize) void {
        const menu = self.menu orelse return;
        const targets = &running.map_panel.destinations.targets;
        const characters = targets.slice()[targets.groupCount()..];
        if (row_index >= characters.len) return;
        self.sendDestination(running, menu.system, &characters[row_index]);
    }

    fn sendDestination(self: *MapPanelWindow, running: *app.App, system: SystemIndex, target: *const evestars.Target) void {
        self.closePopup(running);
        const options = routeOptions(self.config);
        running.map_panel.destinations.send(running.allocator, tokenOf(self.global), target, system, &options, win32.Ticks.now().ms);
    }

    /// A click doesn't activate the panel, so the keyboard has to be asked for; the hotkeys let go of it meanwhile.
    fn openSearch(self: *MapPanelWindow, running: *app.App) void {
        if (self.is_searching) return;
        self.menu = null;
        self.popup.clear();
        self.search_length = 0;
        self.hits = .{};
        self.search_index = 0;
        self.search_return_hwnd = win32.GetForegroundWindow();
        self.is_searching = true;
        if (running.hotkey_manager) |manager| manager.typingSuspendHotkeys();
        if (!win32.toBool(win32.SetForegroundWindow(self.panel.hwnd))) slog.warn("Failed to take the keyboard for the map's search", .{});
        _ = win32.SetFocus(self.panel.hwnd);
    }

    fn closeSearch(self: *MapPanelWindow, running: *app.App, ending: SearchEnding) void {
        if (!self.is_searching) return;
        self.is_searching = false;
        self.popup.clear();
        if (running.hotkey_manager) |manager| {
            if (running.timer_hwnd) |hwnd| manager.typingResumeHotkeys(hwnd);
        }
        switch (ending) {
            .keyboard_gone => {},
            .hand_back => if (self.search_return_hwnd) |hwnd| {
                _ = win32.SetForegroundWindow(hwnd);
            },
        }
    }

    /// Shows the hit on the map; a hit list that has since shrunk picks nothing.
    fn pickHit(self: *MapPanelWindow, running: *app.App, index: usize) void {
        const hits = self.hits.slice();
        if (index >= hits.len) return;
        const hit = hits[index];
        self.closePopup(running);
        switch (hit) {
            .system => |system| self.selectSystem(system),
            .region => |region| self.chooseRegion(region),
        }
    }

    fn searchQuery(self: *const MapPanelWindow) []const u8 {
        return self.search_buffer[0..self.search_length];
    }

    /// `wParam` is WM_CHAR's character; names are ASCII, so anything else is ignored, as is what would overrun the box.
    fn onSearchChar(self: *MapPanelWindow, wParam: win32.WPARAM) void {
        if (!self.is_searching) return;
        if (wParam == win32.VK_BACK) {
            self.search_length -|= 1;
        } else if (wParam >= ' ' and wParam < 0x7F and self.search_length < self.search_buffer.len) {
            self.search_buffer[self.search_length] = @intCast(wParam);
            self.search_length += 1;
        } else {
            return;
        }
        self.hits = search.find(self.searchQuery());
        self.search_index = 0;
    }

    fn onSearchKey(self: *MapPanelWindow, running: *app.App, wParam: win32.WPARAM) void {
        if (!self.is_searching) return;
        switch (wParam) {
            win32.VK_ESCAPE => self.closePopup(running),
            win32.VK_RETURN => self.pickHit(running, self.search_index),
            win32.VK_UP => self.search_index -|= 1,
            win32.VK_DOWN => self.search_index = @min(self.search_index + 1, self.hits.count -| 1),
            else => {},
        }
    }

    fn pressButton(self: *MapPanelWindow, button: map_look.Button) void {
        if (map_look.metricOf(button)) |metric| {
            self.store.update(.{ .display = .{ .mapPanelMetric = metric } });
            return;
        }
        switch (button) {
            .regions => self.is_picking_region = !self.is_picking_region,
            .follow => {
                self.store.update(.{ .display = .{ .mapPanelFollowActive = !self.config.display.mapPanelFollowActive } });
                self.followed_region = null;
            },
            .storms => self.store.update(.{ .display = .{ .mapPanelShowStorms = !self.config.display.mapPanelShowStorms } }),
            .incursions => self.store.update(.{ .display = .{ .mapPanelShowIncursions = !self.config.display.mapPanelShowIncursions } }),
            .security, .kills, .npc_kills, .jumps, .sovereignty => {},
        }
    }

    fn updateMarks(self: *MapPanelWindow, scene: Scene) void {
        self.mark_count = 0;
        for (scene.thumbnails) |*thumbnail| {
            if (self.mark_count == MAX_MARKS) break;
            if (scout.isGenericCharacterName(thumbnail.character_name)) continue;
            const system = universe.findSystem(thumbnail.system_name) orelse continue;
            self.marks[self.mark_count] = .{
                .system = system,
                .source_hwnd = thumbnail.source_hwnd,
                .character_name = thumbnail.character_name,
                .color = thumbnail.cached_character_color orelse list_look.NAME,
                .is_active = thumbnail.source_hwnd == scene.active_source_hwnd,
            };
            self.mark_count += 1;
        }
    }

    fn activeMark(self: *const MapPanelWindow) ?Mark {
        for (self.marks[0..self.mark_count]) |mark| {
            if (mark.is_active) return mark;
        }
        return null;
    }

    fn followActive(self: *MapPanelWindow) void {
        if (!self.config.display.mapPanelFollowActive) return;
        const active = self.activeMark() orelse return;
        const region = universe.systemInfo(active.system).region;
        if (self.followed_region == region) return;
        self.followed_region = region;
        if (region != self.region) self.showRegion(region);
    }

    fn computeRenderSignature(self: *const MapPanelWindow, scene: Scene, now_ms: u64, intel_entries: []const history.Entry) u64 {
        const display = &self.config.display;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&self.layoutSignature()));
        hasher.update(std.mem.asBytes(&display.mapPanelOpacity));
        hasher.update(std.mem.asBytes(&display.mapPanelMetric));
        hasher.update(std.mem.asBytes(&display.mapPanelFollowActive));
        hasher.update(std.mem.asBytes(&display.mapPanelShowStorms));
        hasher.update(std.mem.asBytes(&display.mapPanelShowIncursions));
        hasher.update(std.mem.asBytes(&display.mapPanelAlwaysOnTop));
        hasher.update(std.mem.asBytes(&display.mapPanelRoutePreference));
        hasher.update(std.mem.asBytes(&display.mapPanelRouteAnsiblex));
        hasher.update(std.mem.asBytes(&display.mapPanelRouteEveryWaypoint));
        hasher.update(std.mem.asBytes(&self.is_picking_region));
        hasher.update(std.mem.asBytes(&self.hover.kind));
        hasher.update(std.mem.asBytes(&self.hover.index));
        if (self.focus_system) |system| hasher.update(std.mem.asBytes(&system));
        if (self.reach) |*reach| {
            hasher.update(std.mem.asBytes(&reach.origin));
            hasher.update(std.mem.asBytes(&reach.ship));
        }
        hasher.update(std.mem.asBytes(&self.hasEveStars()));
        hasher.update(std.mem.asBytes(&self.is_searching));
        hasher.update(std.mem.asBytes(&self.search_index));
        hasher.update(self.searchQuery());
        hasher.update(std.mem.asBytes(&display.mapPanelShowCharacterNames));
        hasher.update(std.mem.asBytes(&scene.destinations.revision));
        if (self.menu) |menu| {
            hasher.update(std.mem.asBytes(&menu.system));
            hasher.update(std.mem.asBytes(&menu.anchor.x));
            hasher.update(std.mem.asBytes(&menu.anchor.y));
            if (menu.branch) |branch| hasher.update(std.mem.asBytes(&branch));
            hasher.update(std.mem.asBytes(&menu.shows_characters));
        }
        hasher.update(std.mem.sliceAsBytes(self.config.avoidedSystems.items));
        for (self.marks[0..self.mark_count]) |mark| {
            hasher.update(std.mem.asBytes(&mark.system));
            hasher.update(std.mem.asBytes(&mark.color));
            hasher.update(std.mem.asBytes(&mark.is_active));
            hasher.update(mark.character_name);
        }
        if (scene.stats) |stats| hasher.update(std.mem.asBytes(&stats.fetched_ms));
        hasher.update(std.mem.asBytes(&scene.pins.revision));
        // By whole pixels, so a shrinking halo redraws only when it can show.
        for (&scene.pins.pins) |*pin| {
            if (!pin.isLive(now_ms) or universe.systemInfo(pin.system).region != self.region) continue;
            const halo_radius: i32 = @intFromFloat(self.intelHaloRadius(pin, now_ms));
            hasher.update(std.mem.asBytes(&halo_radius));
        }
        if (self.intel_history) |intel_history| history_rows.hashIntel(&hasher, intel_history, intel_entries, display, &self.config.thumbnail.notifications);
        const age_bucket = now_ms / AGE_BUCKET_MS;
        hasher.update(std.mem.asBytes(&age_bucket));
        return hasher.final();
    }

    /// What `layout` depends on.
    fn layoutSignature(self: *const MapPanelWindow) u64 {
        var hasher = std.hash.Wyhash.init(1);
        hasher.update(std.mem.asBytes(&self.region));
        hasher.update(std.mem.asBytes(&self.layout.view));
        self.hashAreaAndFonts(&hasher);
        return hasher.final();
    }

    fn hashAreaAndFonts(self: *const MapPanelWindow, hasher: *std.hash.Wyhash) void {
        const display = &self.config.display;
        const area = self.mapArea(map_look.metrics(display));
        hasher.update(std.mem.asBytes(&area));
        panel_chrome.hashFonts(hasher, display);
        hasher.update(display.mapPanelFontName);
        hasher.update(std.mem.asBytes(&display.mapPanelFontSize));
        hasher.update(std.mem.asBytes(&display.mapPanelFontWeight));
    }

    /// The security once zoomed in enough; null before that.
    fn labelSuffix(self: *const MapPanelWindow, system: SystemIndex, buffer: *[map_look.SECURITY_TEXT_MAX]u8) ?LabelSuffix {
        if (!map_look.showsSecurityLabel(self.layout.view.zoom)) return null;
        const security_tenths = universe.systemInfo(system).security_tenths;
        return .{ .text = map_look.securityText(buffer, security_tenths), .color = map_look.securityTextColor(security_tenths) };
    }

    /// With `dc` holding the label font.
    fn labelWidth(self: *const MapPanelWindow, dc: win32.HDC, system: SystemIndex) i32 {
        const name_width = panel_chrome.textWidth(dc, universe.systemName(system));
        var buffer: [map_look.SECURITY_TEXT_MAX]u8 = undefined;
        const suffix = self.labelSuffix(system, &buffer) orelse return name_width;
        return name_width + map_look.LABEL_SUFFIX_GAP + panel_chrome.textWidth(dc, suffix.text);
    }

    fn ensureOverview(self: *MapPanelWindow, dc: win32.HDC, sizes: map_look.Metrics, text: ?MapText) void {
        var hasher = std.hash.Wyhash.init(3);
        self.hashAreaAndFonts(&hasher);
        const signature = hasher.final();
        if (self.overview_signature == signature) return;
        self.overview_signature = signature;
        self.overview.build(self.mapArea(sizes));

        const fonts = text orelse return;
        _ = win32.SelectObject(dc, fonts.label_font);
        var widths: [universe.REGION_COUNT]i32 = undefined;
        for (&widths, 0..) |*width, index| width.* = panel_chrome.textWidth(dc, universe.regionName(@intCast(index)));
        self.overview.placeLabels(&widths, fonts.label_height);
    }

    fn ensureLayout(self: *MapPanelWindow, dc: win32.HDC, sizes: map_look.Metrics, text: ?MapText) void {
        const signature = self.layoutSignature();
        if (self.layout_signature == signature) return;
        self.layout_signature = signature;
        self.layout.build(self.region, self.mapArea(sizes));

        const fonts = text orelse return;
        _ = win32.SelectObject(dc, fonts.label_font);
        var node_widths: [universe.MAX_REGION_SYSTEMS]i32 = undefined;
        for (self.layout.nodes[0..self.layout.node_count], node_widths[0..self.layout.node_count]) |node, *width| {
            width.* = self.labelWidth(dc, node.system);
        }
        var exit_widths: [layout_mod.MAX_EXITS]i32 = undefined;
        for (self.layout.exits[0..self.layout.exit_count], exit_widths[0..self.layout.exit_count]) |exit, *width| {
            width.* = panel_chrome.textWidth(dc, map_look.exitLabel(exit).slice());
        }
        self.layout.placeLabels(&node_widths, &exit_widths, fonts.label_height, map_look.labelClearance(self.layout.view.zoom));
    }

    /// Null if a font couldn't be created, which leaves the panel without text.
    fn mapText(self: *const MapPanelWindow, dc: win32.HDC) ?MapText {
        const chrome = panel_chrome.textOf(&self.panel, dc) orelse return null;
        const label_font = self.label_font.handle orelse return null;
        const title_font = self.title_font.handle orelse return null;
        _ = win32.SelectObject(dc, title_font);
        const title_height = panel_chrome.lineHeight(dc);
        _ = win32.SelectObject(dc, label_font);
        return .{ .chrome = chrome, .label_font = label_font, .label_height = panel_chrome.lineHeight(dc), .title_font = title_font, .title_height = title_height };
    }

    /// Called every tick, and on hover; redraws only when the render signature changed.
    pub fn render(self: *MapPanelWindow, scene: Scene) !void {
        const display = &self.config.display;
        self.panel.followSize(display.mapPanelWidth + sidebarWidth(display, self.intel_history), display.mapPanelHeight);
        self.panel.followTopmost(display.mapPanelAlwaysOnTop);
        try panel_chrome.ensureFonts(&self.panel, display);
        try self.label_font.ensure(self.panel.allocator, "Map Panel labels", display.mapPanelFontName, display.mapPanelFontSize, display.mapPanelFontWeight);
        try self.title_font.ensure(self.panel.allocator, "Map Panel title", display.mapPanelFontName, map_look.TITLE_FONT_SIZE, .Bold);

        self.updateMarks(scene);
        self.followActive();
        const now_ms = win32.Ticks.now().ms;
        var entry_buf: [history.CAPACITY]history.Entry = undefined;
        const intel_entries = self.intelEntries(&entry_buf);
        const signature = self.computeRenderSignature(scene, now_ms, intel_entries);
        if (self.panel.isUnchanged(signature)) return;

        const panel_width: i32 = @max(1, self.panel.width);
        const panel_height: i32 = @max(1, self.panel.height);
        const bitmap = try self.panel.beginFrame(panel_width, panel_height);
        const width: usize = bitmap.width;
        const height: usize = bitmap.height;
        const dc = bitmap.mem_dc;
        const canvas = bitmap.canvas();
        const sizes = map_look.metrics(display);
        const footer_top = panel_look.footerTop(panel_height, 0, sizes.footer_height);
        const buttons = self.footerButtons();

        const old_font = panel_chrome.selectFont(&self.panel, dc);
        defer panel_chrome.restoreFont(dc, old_font);
        const text = self.mapText(dc);
        self.ensureLayout(dc, sizes, text);
        if (self.is_picking_region) self.ensureOverview(dc, sizes, text);
        self.updateTitle(scene, now_ms);

        pixel_buffer.fillRect(canvas, 0, 0, width, height, map_look.BACKGROUND);
        map_look.drawGrid(canvas, self.bodyArea(sizes), if (self.is_picking_region) .{} else self.layout.view);
        const paint = self.mapPaint(scene);
        if (self.is_picking_region) {
            self.drawOverview(canvas, scene);
        } else {
            self.drawMap(canvas, scene, &paint, now_ms);
        }

        // After the map, which a new intel halo can reach past.
        const sidebar = self.intelSidebar(sizes);
        if (sidebar) |box| self.fillIntelSidebar(canvas, box);
        panel_chrome.fillFooter(canvas, footer_top);
        panel_chrome.fillButtons(canvas, &buttons, panel_width, footer_top, sizes.header_height);

        if (text) |fonts| {
            panel_chrome.drawButtonLabels(dc, fonts.chrome, &buttons, panel_width, footer_top, sizes.header_height);
            self.drawRegionTitle(dc, fonts, scene, sizes);
            if (self.is_picking_region) {
                self.drawOverviewLabels(dc, fonts.label_font);
            } else {
                self.drawLabels(dc, scene, fonts.label_font, now_ms);
                self.drawClientTags(bitmap, sizes, fonts.chrome);
                self.drawMapControls(bitmap, sizes);
                const legend = if (self.reach) |*reach| map_look.rangeLegend(reach) else legendFor(scene, &paint);
                var legend_top = self.drawLegend(bitmap, &legend, sizes, fonts.chrome, self.bodyArea(sizes).bottom);
                if (self.stormLegend(scene)) |*storm_legend| legend_top = self.drawLegend(bitmap, storm_legend, sizes, fonts.chrome, legend_top);
                if (self.incursionLegend(scene)) |*incursion_legend| _ = self.drawLegend(bitmap, incursion_legend, sizes, fonts.chrome, legend_top);
            }
            self.drawSearchBox(bitmap, sizes, fonts.chrome);
            self.drawTooltip(bitmap, scene, sizes, fonts.chrome, now_ms);
            if (sidebar) |box| self.drawIntelRows(dc, fonts.chrome, box, sizes, intel_entries);
            self.drawPopup(bitmap, scene.destinations, sizes, fonts.chrome);
            self.drawNotice(bitmap, scene.destinations, sizes, fonts.chrome);
        }

        self.panel.present(display.mapPanelOpacity, signature);
    }

    fn isButtonLit(self: *const MapPanelWindow, button: map_look.Button) bool {
        const display = &self.config.display;
        if (map_look.metricOf(button)) |metric| return display.mapPanelMetric == metric;
        return switch (button) {
            .regions => self.is_picking_region,
            .follow => display.mapPanelFollowActive,
            .storms => display.mapPanelShowStorms,
            .incursions => display.mapPanelShowIncursions,
            .security, .kills, .npc_kills, .jumps, .sovereignty => false,
        };
    }

    /// Null while they're hidden, or the last fetch didn't get them.
    fn shownStorms(self: *const MapPanelWindow, scene: Scene) ?*const Storms {
        const stats = scene.stats orelse return null;
        return if (self.config.display.mapPanelShowStorms and stats.has_storms) &stats.storms else null;
    }

    fn stormLegend(self: *const MapPanelWindow, scene: Scene) ?map_look.Legend {
        const storms = self.shownStorms(scene) orelse return null;
        return map_look.stormLegend(storms, self.layout.nodes[0..self.layout.node_count]);
    }

    /// Null while they're hidden, or the last fetch didn't get them.
    fn shownIncursions(self: *const MapPanelWindow, scene: Scene) ?*const Incursions {
        const stats = scene.stats orelse return null;
        return if (self.config.display.mapPanelShowIncursions and stats.has_incursions) &stats.incursions else null;
    }

    fn incursionLegend(self: *const MapPanelWindow, scene: Scene) ?map_look.Legend {
        const incursions = self.shownIncursions(scene) orelse return null;
        return map_look.incursionLegend(incursions, self.layout.nodes[0..self.layout.node_count]);
    }

    fn mapPaint(self: *const MapPanelWindow, scene: Scene) MapPaint {
        const metric = self.config.display.mapPanelMetric;
        const nodes = self.layout.nodes[0..self.layout.node_count];
        return .{
            .metric = metric,
            .peak = peakValue(&self.layout, scene, metric),
            .holders = if (scene.stats) |stats| .fromNodes(stats, nodes) else .{},
        };
    }

    /// Over any of the map that reached past its side, like a new intel halo.
    fn fillIntelSidebar(self: *const MapPanelWindow, canvas: pixel_buffer.Canvas, box: Box) void {
        pixel_buffer.fillRect(canvas, @intCast(box.left), @intCast(box.top), @intCast(box.right - box.left), @intCast(box.bottom - box.top), list_look.PANEL);
        const divider_x = switch (self.config.display.intelPanelSide) {
            .Left => box.right,
            .Right => box.left - 1,
        };
        pixel_buffer.fillRect(canvas, @intCast(divider_x), @intCast(box.top), 1, @intCast(box.bottom - box.top), list_look.DIVIDER);
    }

    fn drawIntelRows(self: *MapPanelWindow, dc: win32.HDC, text: panel_chrome.Text, box: Box, sizes: map_look.Metrics, entries: []const history.Entry) void {
        const display = &self.config.display;
        const row_sizes: history_look.Metrics = .{ .header_height = 0, .row_height = history_rows.intelRowHeight(display), .footer_height = sizes.footer_height };
        const capacity = history_look.rowsThatFit(self.panel.height, row_sizes, history.CAPACITY);
        self.intel_row_count = history_rows.build(&self.intel_rows, entries, capacity, history_rows.buildOptions(display, null));
        const area = history_rows.intelArea(display, box.left, box.top, box.right);
        history_rows.drawIntel(dc, text, self.intel_rows[0..self.intel_row_count], entries, &self.config.thumbnail.notifications, area);
    }

    fn footerButtons(self: *const MapPanelWindow) [map_look.BUTTON_ORDER.len]panel_chrome.Button {
        var buttons: [map_look.BUTTON_ORDER.len]panel_chrome.Button = undefined;
        for (map_look.BUTTON_ORDER, &buttons) |button, *shown| shown.* = .{ .label = map_look.buttonLabel(button), .is_lit = self.isButtonLit(button) };
        return buttons;
    }

    fn updateTitle(self: *MapPanelWindow, scene: Scene, now_ms: u64) void {
        var title_buf: [panel_chrome.MAX_TEXT_LENGTH]u8 = undefined;
        var age_buf: [panel_look.TIME_TEXT_MAX]u8 = undefined;
        const region = universe.regionName(self.region);
        const system_count = self.layout.node_count;
        // Region names are short, from the embedded map.
        const title = if (scene.stats) |stats|
            std.mem.printSentinel(&title_buf, "{s} - {d} systems - Stats {s}", .{ region, system_count, panel_look.relativeTime(&age_buf, now_ms -| stats.fetched_ms) }, 0) catch unreachable
        else
            std.mem.printSentinel(&title_buf, "{s} - {d} systems", .{ region, system_count }, 0) catch unreachable;
        const title_hash = std.hash.Wyhash.hash(0, title);
        if (title_hash == self.title_hash) return;
        self.title_hash = title_hash;
        _ = win32.SetWindowTextA(self.panel.hwnd, title);
    }

    /// Filled after the labels it covers, so GDI has to finish them first.
    fn drawSearchBox(self: *const MapPanelWindow, bitmap: *const gdi_overlay.OverlayBitmap, sizes: map_look.Metrics, text: panel_chrome.Text) void {
        const box = self.searchBox(sizes);
        const box_width = box.right - box.left;
        _ = win32.GdiFlush();
        // The cursor tends to stay on the box after the click that opens it.
        map_look.drawOverlayButton(bitmap.canvas(), box, self.hover.kind == .search_box and !self.is_searching);

        const dc = bitmap.mem_dc;
        _ = win32.SelectObject(dc, text.name_font);
        const label: evestars.Text = if (self.is_searching) .print("{s}_", .{self.searchQuery()}) else .print("Search map", .{});
        const label_color = if (self.is_searching) list_look.NAME else list_look.MUTED;
        const y = box.top + @divTrunc(box.bottom - box.top - text.name_height, 2);
        _ = panel_chrome.drawFitted(dc, label.slice(), box.left + panel_look.BUTTON_GAP, y, label_color, box_width - 2 * panel_look.BUTTON_GAP);
    }

    /// Bubbles coloured by the traffic the map shows, or by security when it shows neither.
    fn drawOverview(self: *const MapPanelWindow, canvas: pixel_buffer.Canvas, scene: Scene) void {
        const overview = &self.overview;
        const metric = self.config.display.mapPanelMetric;
        for (overview.links[0..overview.link_count]) |link| {
            const first = overview.bubbles[link.first];
            const second = overview.bubbles[link.second];
            pixel_buffer.drawLine(canvas, first.x, first.y, second.x, second.y, map_look.EDGE_LOCAL);
        }

        var totals: [universe.REGION_COUNT]u32 = @splat(0);
        var peak: u32 = 0;
        if (scene.stats) |stats| {
            for (stats.systems, 0..) |system_stats, index| {
                totals[universe.systemInfo(@intCast(index)).region] += map_look.metricValue(metric, system_stats);
            }
            peak = std.mem.max(u32, &totals);
        }
        for (overview.bubbles, totals, 0..) |bubble, total, index| {
            const region: RegionIndex = @intCast(index);
            const heat_color = if (peak > 0) map_look.heatColor(total, peak) else map_look.securityColor(bubble.security_tenths);
            const bubble_color = if (self.reach) |*reach| map_look.regionRangeColor(reach.region_counts[region]) else heat_color;
            map_look.drawMarker(canvas, bubble.x, bubble.y, bubble.radius, bubble_color);
            const is_hovered = self.hover.kind == .region and self.hover.index == region;
            if (is_hovered or region == self.region) pixel_buffer.drawRing(canvas, bubble.x, bubble.y, bubble.radius + map_look.RING_GAP, map_look.RING_THICKNESS, map_look.FOCUS);
            if (self.clientCountIn(region) > 0) pixel_buffer.drawRing(canvas, bubble.x, bubble.y, bubble.radius + 2 * map_look.RING_GAP, map_look.RING_THICKNESS, self.config.display.listViewActiveColor);
        }
        // Outside those rings, stepping out as a region can hold more than one storm or incursion.
        var ring_gaps: [universe.REGION_COUNT]f32 = @splat(3);
        if (self.shownStorms(scene)) |storms| {
            for (storms.slice()) |*storm| self.drawRegionRing(canvas, storm.center, map_look.stormColor(storm.kind), &ring_gaps);
        }
        if (self.shownIncursions(scene)) |incursions| {
            for (incursions.slice()) |*incursion| self.drawRegionRing(canvas, incursion.staging, map_look.INCURSION, &ring_gaps);
        }
    }

    /// Around the bubble of the region holding `system`, steps out from those drawn before it.
    fn drawRegionRing(self: *const MapPanelWindow, canvas: pixel_buffer.Canvas, system: SystemIndex, ring_color: u32, ring_gaps: *[universe.REGION_COUNT]f32) void {
        const region = universe.systemInfo(system).region;
        const bubble = self.overview.bubbles[region];
        pixel_buffer.drawRing(canvas, bubble.x, bubble.y, bubble.radius + ring_gaps[region] * map_look.RING_GAP, map_look.RING_THICKNESS, ring_color);
        ring_gaps[region] += 1;
    }

    /// A region with a client in it stands out, as the likely pick.
    fn drawOverviewLabels(self: *const MapPanelWindow, dc: win32.HDC, label_font: win32.HFONT) void {
        _ = win32.SelectObject(dc, label_font);
        for (self.overview.bubbles, 0..) |bubble, index| {
            const region: RegionIndex = @intCast(index);
            const label = bubble.label orelse continue;
            const is_hovered = self.hover.kind == .region and self.hover.index == region;
            const label_color = if (self.clientCountIn(region) > 0) self.config.display.listViewActiveColor else if (is_hovered or region == self.region) list_look.NAME else map_look.LABEL;
            drawHaloText(dc, universe.regionName(region), label.left, label.top, label_color);
        }
    }

    fn clientCountIn(self: *const MapPanelWindow, region: RegionIndex) usize {
        var count: usize = 0;
        for (self.marks[0..self.mark_count]) |mark| {
            if (universe.systemInfo(mark.system).region == region) count += 1;
        }
        return count;
    }

    /// The name of what's shown, and its figures for the last hour.
    fn drawRegionTitle(self: *const MapPanelWindow, dc: win32.HDC, fonts: MapText, scene: Scene, sizes: map_look.Metrics) void {
        const area = self.bodyArea(sizes);
        const x = area.left + map_look.OVERLAY_MARGIN;
        const y = area.top + 2;
        _ = win32.SelectObject(dc, fonts.title_font);
        panel_chrome.drawLine(dc, if (self.is_picking_region) "New Eden" else universe.regionName(self.region), x, y, map_look.TITLE);

        const nodes = self.layout.nodes[0..self.layout.node_count];
        const totals: ?map_look.RegionTotals = if (scene.stats) |stats| .fromNodes(stats, nodes) else null;
        const summary: evestars.Text = if (self.is_picking_region) .print("{d} regions, {d} systems. Click one to open it.", .{ universe.REGION_COUNT, universe.SYSTEM_COUNT }) else map_look.regionSummary(self.layout.node_count, totals);
        _ = win32.SelectObject(dc, fonts.chrome.small_font);
        _ = panel_chrome.drawFitted(dc, summary.slice(), x, y + fonts.title_height, list_look.MUTED, self.searchBox(sizes).left - x - map_look.OVERLAY_MARGIN);
    }

    /// One tag a system, naming the active client if it's there, as a stack of rings can't say who's where.
    fn drawClientTags(self: *const MapPanelWindow, bitmap: *const gdi_overlay.OverlayBitmap, sizes: map_look.Metrics, text: panel_chrome.Text) void {
        if (!self.config.display.mapPanelShowCharacterNames) return;
        const dc = bitmap.mem_dc;
        _ = win32.SelectObject(dc, text.small_font);
        _ = win32.GdiFlush();
        const canvas = bitmap.canvas();
        const area = self.bodyArea(sizes);
        var taken: [MAX_MARKS]Box = undefined;
        var taken_count: usize = 0;
        for (self.marks[0..self.mark_count], 0..) |mark, index| {
            if (!self.leadsSystem(mark, index)) continue;
            const node_index = self.layout.nodeOf(mark.system) orelse continue;
            const node = self.layout.nodes[node_index];
            const label = map_look.clientTagText(mark.character_name, self.clientCountAt(mark.system) - 1);
            const box_width = panel_chrome.wideTextWidth(dc, label.slice()) + 2 * map_look.CLIENT_TAG_PADDING;
            const box = map_look.clientTagBox(area, node.x, node.y, box_width, text.small_height, taken[0..taken_count]) orelse continue;
            taken[taken_count] = box;
            taken_count += 1;
            pixel_buffer.fillRect(canvas, @intCast(box.left), @intCast(box.top), @intCast(box_width), @intCast(text.small_height), popup_look.TOOLTIP_FILL);
            pixel_buffer.fillRect(canvas, @intCast(box.left), @intCast(box.top), @intCast(map_look.CLIENT_TAG_BAR), @intCast(text.small_height), if (mark.is_active) self.config.display.listViewActiveColor else mark.color);
            panel_chrome.drawWideLine(dc, label.slice(), box.left + map_look.CLIENT_TAG_PADDING, box.top, list_look.NAME);
        }
    }

    /// `mark`, at `index`, is the one its system's tag names: the active client, else the first.
    fn leadsSystem(self: *const MapPanelWindow, mark: Mark, index: usize) bool {
        for (self.marks[0..self.mark_count], 0..) |other, other_index| {
            if (other.system != mark.system or other_index == index) continue;
            if (other.is_active or (other_index < index and !mark.is_active)) return false;
        }
        return true;
    }

    fn clientCountAt(self: *const MapPanelWindow, system: SystemIndex) usize {
        var count: usize = 0;
        for (self.marks[0..self.mark_count]) |mark| {
            if (mark.system == system) count += 1;
        }
        return count;
    }

    /// Filled after the labels they cover, so GDI has to finish them first.
    fn drawMapControls(self: *const MapPanelWindow, bitmap: *const gdi_overlay.OverlayBitmap, sizes: map_look.Metrics) void {
        _ = win32.GdiFlush();
        const canvas = bitmap.canvas();
        const area = self.bodyArea(sizes);
        for (std.enums.values(map_look.MapControl)) |control| {
            const box = map_look.mapControlBox(area, control);
            if (box.left < 0) continue;
            const is_hovered = self.hover.kind == .map_control and self.hover.index == @backingInt(control);
            map_look.drawOverlayButton(canvas, box, is_hovered);
            map_look.drawMapControlGlyph(canvas, box, control, self.config.display.mapPanelAlwaysOnTop);
        }
    }

    /// In the map's left side above `bottom`, returning where the next one stacks; filled after the labels it covers, so GDI has to finish them first.
    fn drawLegend(self: *const MapPanelWindow, bitmap: *const gdi_overlay.OverlayBitmap, legend: *const map_look.Legend, sizes: map_look.Metrics, text: panel_chrome.Text, bottom: i32) i32 {
        const dc = bitmap.mem_dc;
        _ = win32.SelectObject(dc, text.small_font);
        const line_height = text.small_height;
        const has_ramp = legend.ramp.len > 0;
        const low_width = panel_chrome.textWidth(dc, legend.ramp_low.slice());
        const high_width = panel_chrome.textWidth(dc, legend.ramp_high.slice());
        const swatch_room = map_look.LEGEND_SWATCH_SIZE + map_look.OVERLAY_PADDING;

        var content_width = panel_chrome.wideTextWidth(dc, legend.title.slice());
        if (has_ramp) content_width = @max(content_width, low_width + high_width + map_look.LEGEND_RAMP_WIDTH + 2 * map_look.OVERLAY_PADDING);
        for (legend.rows[0..legend.row_count]) |row| content_width = @max(content_width, swatch_room + panel_chrome.wideTextWidth(dc, row.text.slice()));

        const area = self.bodyArea(sizes);
        const line_count: i32 = 1 + @as(i32, @intFromBool(has_ramp)) + @as(i32, @intCast(legend.row_count));
        const box_height = line_count * line_height + 2 * map_look.OVERLAY_PADDING;
        const box_width = content_width + 2 * map_look.OVERLAY_PADDING;
        const left = area.left + map_look.OVERLAY_MARGIN;
        const top = bottom - map_look.OVERLAY_MARGIN - box_height;
        // A window too small for it goes without.
        if (top < area.top or left + box_width > area.right) return bottom;

        _ = win32.GdiFlush();
        const canvas = bitmap.canvas();
        map_look.drawOverlayButton(canvas, .{ .left = left, .top = top, .right = left + box_width, .bottom = top + box_height }, false);

        const x = left + map_look.OVERLAY_PADDING;
        var y = top + map_look.OVERLAY_PADDING;
        panel_chrome.drawWideLine(dc, legend.title.slice(), x, y, list_look.NAME);
        y += line_height;
        if (has_ramp) {
            panel_chrome.drawLine(dc, legend.ramp_low.slice(), x, y, list_look.MUTED);
            map_look.drawRamp(canvas, x + low_width + map_look.OVERLAY_PADDING, y, line_height, legend.ramp);
            panel_chrome.drawLine(dc, legend.ramp_high.slice(), x + low_width + 2 * map_look.OVERLAY_PADDING + map_look.LEGEND_RAMP_WIDTH, y, list_look.MUTED);
            y += line_height;
        }
        for (legend.rows[0..legend.row_count]) |row| {
            const swatch_top = y + @divTrunc(line_height - map_look.LEGEND_SWATCH_SIZE, 2);
            pixel_buffer.fillRect(canvas, @intCast(x), @intCast(swatch_top), @intCast(map_look.LEGEND_SWATCH_SIZE), @intCast(map_look.LEGEND_SWATCH_SIZE), row.swatch);
            panel_chrome.drawWideLine(dc, row.text.slice(), x + swatch_room, y, list_look.MUTED);
            y += line_height;
        }
        return top;
    }

    fn intelHaloRadius(self: *const MapPanelWindow, pin: *const intel_pins.Pin, now_ms: u64) f32 {
        const shrink_ms: u64 = @as(u64, @intCast(@max(0, self.config.display.mapPanelIntelShrinkSec))) * std.time.ms_per_s;
        return map_look.intelHaloRadius(now_ms -| pin.seen_ms, shrink_ms);
    }

    fn drawMap(self: *const MapPanelWindow, canvas: pixel_buffer.Canvas, scene: Scene, paint: *const MapPaint, now_ms: u64) void {
        const layout = &self.layout;
        const scale = map_look.markerScale(layout.view.zoom);
        const hovered_node: ?u16 = if (self.hover.kind == .node) self.hover.index else null;
        // Under everything else, so a new halo doesn't hide the systems around it.
        for (layout.nodes[0..layout.node_count]) |node| {
            const pin = scene.pins.find(node.system, now_ms) orelse continue;
            map_look.drawIntelHalo(canvas, node.x, node.y, self.intelHaloRadius(pin, now_ms), pin.is_clear, pin.freshnessPercent(now_ms));
        }
        if (paint.metric == .Sovereignty) {
            for (layout.nodes[0..layout.node_count]) |node| {
                const stats = scene.stats orelse break;
                const holder = stats.systems[node.system].holder;
                if (holder != stats_mod.NO_HOLDER) map_look.drawHolderPatch(canvas, node.x, node.y, scale, paint.holders.colorOf(holder));
            }
        }
        const storms = self.shownStorms(scene);
        const incursions = self.shownIncursions(scene);
        self.drawAreas(canvas, scene, scale);
        const focus_node_index: ?u16 = if (self.focus_system) |system| layout.nodeOf(system) else null;
        for (layout.edges[0..layout.edge_count]) |edge| {
            const first = layout.nodes[edge.first_index];
            const second = layout.nodes[edge.second_index];
            const is_lit = hovered_node == edge.first_index or hovered_node == edge.second_index or focus_node_index == edge.first_index or focus_node_index == edge.second_index;
            const plain_color = if (edge.is_local) map_look.EDGE_LOCAL else map_look.EDGE_CROSS;
            const edge_color = if (is_lit) map_look.EDGE_HOVER else stormEdgeColor(storms, first.system, second.system) orelse incursionEdgeColor(incursions, first.system, second.system) orelse plain_color;
            pixel_buffer.drawLine(canvas, first.x, first.y, second.x, second.y, edge_color);
        }
        for (layout.exits[0..layout.exit_count], 0..) |exit, index| {
            const is_hovered = self.hover.kind == .exit and self.hover.index == index;
            map_look.drawExit(canvas, layout.nodes[exit.from_index], exit, if (is_hovered) map_look.EDGE_HOVER else map_look.EXIT);
            if (exit.label) |label| map_look.drawExitChip(canvas, label, is_hovered);
        }
        if (self.focusNode()) |node| {
            if (node.label) |label| map_look.drawFocusChip(canvas, label);
        }

        for (layout.nodes[0..layout.node_count], 0..) |node, index| {
            const value = if (scene.stats) |stats| map_look.metricValue(paint.metric, stats.systems[node.system]) else 0;
            const radius = map_look.markerRadius(value, paint.peak) * scale;
            const ring_radius = radius + map_look.RING_GAP;
            const is_focus = self.focus_system == node.system;
            // Filled, so it merges with the chip behind the name into one shape.
            if (is_focus) pixel_buffer.fillCircle(canvas, node.x, node.y, ring_radius + map_look.FOCUS_OUTLINE_THICKNESS, map_look.FOCUS_MARK);
            map_look.drawMarker(canvas, node.x, node.y, radius, if (self.isOutOfRange(node.system)) map_look.OUT_OF_RANGE else markerColor(scene, paint, node.system, value));
            const is_hovered = if (hovered_node) |hovered| hovered == index else false;
            if (is_hovered or is_focus) pixel_buffer.drawRing(canvas, node.x, node.y, ring_radius, if (is_focus) map_look.FOCUS_RING_THICKNESS else map_look.RING_THICKNESS, map_look.FOCUS);
        }

        const resting_radius = map_look.markerRadius(0, 0) * scale;
        for (self.marks[0..self.mark_count]) |mark| {
            const index = layout.nodeOf(mark.system) orelse continue;
            const node = layout.nodes[index];
            const ring_color = if (mark.is_active) self.config.display.listViewActiveColor else mark.color;
            pixel_buffer.drawRing(canvas, node.x, node.y, resting_radius + 2 * map_look.RING_GAP, map_look.RING_THICKNESS, ring_color);
        }
        if (self.reach) |*reach| {
            for (layout.nodes[0..layout.node_count]) |node| {
                if (reach.includes(node.system)) map_look.drawRangeMark(canvas, node.x, node.y, scale);
            }
            // Outside a client's ring, as the origin is often where one sits.
            if (layout.nodeOf(reach.origin)) |index| pixel_buffer.drawRing(canvas, layout.nodes[index].x, layout.nodes[index].y, resting_radius + 3 * map_look.RING_GAP, map_look.RING_THICKNESS, map_look.RANGE);
        }
        if (self.hasEveStars()) self.drawAvoidMarks(canvas);
    }

    /// Each storm and incursion as one shape following its systems and gates here, so an area that leaves the region stops at its edge.
    fn drawAreas(self: *const MapPanelWindow, canvas: pixel_buffer.Canvas, scene: Scene, scale: f32) void {
        // The legends list what reaches the map, and most regions have nothing to mask.
        if (self.stormLegend(scene) == null and self.incursionLegend(scene) == null) return;
        var mask = pixel_buffer.Mask.init(self.panel.allocator, canvas.width, canvas.height) catch |err| {
            slog.warn("Failed to draw storm and incursion areas: {}", .{err});
            return;
        };
        defer mask.deinit();
        const radius = map_look.areaRadius(scale);
        if (self.shownStorms(scene)) |storms| {
            for (storms.slice()) |*storm| {
                const shade = map_look.stormColor(storm.kind);
                self.fillMaskWith(&mask, &storm.covered, radius);
                map_look.drawArea(canvas, &mask, shade);
                self.fillMaskWith(&mask, &storm.core, radius);
                map_look.drawAreaCore(canvas, &mask, shade);
            }
        }
        if (self.shownIncursions(scene)) |incursions| {
            for (incursions.slice()) |*incursion| {
                self.fillMaskWith(&mask, &incursion.infested, radius);
                map_look.drawArea(canvas, &mask, map_look.INCURSION);
                mask.clear();
                const index = self.layout.nodeOf(incursion.staging) orelse continue;
                mask.addDisc(self.layout.nodes[index].x, self.layout.nodes[index].y, radius);
                map_look.drawAreaCore(canvas, &mask, map_look.INCURSION);
            }
        }
    }

    /// Replaces what `mask` held with `systems` here and the gates among them.
    fn fillMaskWith(self: *const MapPanelWindow, mask: *pixel_buffer.Mask, systems: *const universe.SystemSet, radius: f32) void {
        const layout = &self.layout;
        mask.clear();
        for (layout.nodes[0..layout.node_count]) |node| {
            if (systems.isSet(node.system)) mask.addDisc(node.x, node.y, radius);
        }
        for (layout.edges[0..layout.edge_count]) |edge| {
            const first = layout.nodes[edge.first_index];
            const second = layout.nodes[edge.second_index];
            if (systems.isSet(first.system) and systems.isSet(second.system)) mask.addBand(first.x, first.y, second.x, second.y, radius);
        }
    }

    /// A jump range is showing and doesn't take in `system`; its origin counts as taken in.
    fn isOutOfRange(self: *const MapPanelWindow, system: SystemIndex) bool {
        const reach = if (self.reach) |*shown| shown else return false;
        return system != reach.origin and !reach.includes(system);
    }

    /// Null with nothing selected.
    fn focusNode(self: *const MapPanelWindow) ?layout_mod.Node {
        const system = self.focus_system orelse return null;
        const index = self.layout.nodeOf(system) orelse return null;
        return self.layout.nodes[index];
    }

    /// Only with a token, as nothing else reads the list.
    fn drawAvoidMarks(self: *const MapPanelWindow, canvas: pixel_buffer.Canvas) void {
        for (self.config.avoidedSystems.items) |avoided| {
            const system = universe.findSystemById(avoided.systemId) orelse continue;
            const index = self.layout.nodeOf(system) orelse continue;
            const node = self.layout.nodes[index];
            map_look.drawAvoidMark(canvas, node.x, node.y);
        }
    }

    fn drawLabels(self: *const MapPanelWindow, dc: win32.HDC, scene: Scene, label_font: win32.HFONT, now_ms: u64) void {
        const layout = &self.layout;
        const storms = self.shownStorms(scene);
        const incursions = self.shownIncursions(scene);
        _ = win32.SelectObject(dc, label_font);
        for (layout.nodes[0..layout.node_count]) |node| {
            const label = node.label orelse continue;
            const name = universe.systemName(node.system);
            const plain_color = if (self.isNoteworthy(node.system)) list_look.NAME else map_look.LABEL;
            const label_color = if (scene.pins.find(node.system, now_ms)) |pin| map_look.intelColor(pin.is_clear) else stormCenterColor(storms, node.system) orelse incursionStagingColor(incursions, node.system) orelse plain_color;
            drawHaloText(dc, name, label.left, label.top, label_color);
            var suffix_buffer: [map_look.SECURITY_TEXT_MAX]u8 = undefined;
            const suffix = self.labelSuffix(node.system, &suffix_buffer) orelse continue;
            drawHaloText(dc, suffix.text, label.left + panel_chrome.textWidth(dc, name) + map_look.LABEL_SUFFIX_GAP, label.top, suffix.color);
        }
        for (layout.exits[0..layout.exit_count]) |exit| {
            const label = exit.label orelse continue;
            panel_chrome.drawLine(dc, map_look.exitLabel(exit).slice(), label.left, label.top, map_look.EXIT);
        }
    }

    /// Has something at it, so its name stands out from the quiet ones.
    fn isNoteworthy(self: *const MapPanelWindow, system: SystemIndex) bool {
        if (self.focus_system == system or self.clientCountAt(system) > 0) return true;
        if (self.reach != null and !self.isOutOfRange(system)) return true;
        return self.hover.kind == .node and self.layout.nodes[self.hover.index].system == system;
    }

    fn tooltipFor(self: *const MapPanelWindow, scene: Scene, now_ms: u64) ?map_look.Tooltip {
        const system: SystemIndex = switch (self.hover.kind) {
            .none, .button, .intel_row, .popup_row, .submenu_row, .nested_row, .search_box => return null,
            .map_control => return map_look.mapControlTooltip(@fromBackingInt(@intCast(self.hover.index)), self.config.display.mapPanelAlwaysOnTop),
            .region => {
                const region: RegionIndex = @intCast(self.hover.index);
                return map_look.regionTooltip(region, self.overview.bubbles[region].system_count, self.clientCountIn(region), if (self.reach) |*reach| reach else null, self.shownStorms(scene), self.shownIncursions(scene));
            },
            .exit => {
                const exit = self.layout.exits[self.hover.index];
                return map_look.exitTooltip(self.layout.nodes[exit.from_index].system, exit.destination);
            },
            .node => self.layout.nodes[self.hover.index].system,
        };
        var facts: map_look.SystemFacts = .{ .system = system, .stats = scene.stats, .is_avoided = self.hasEveStars() and self.isAvoided(system), .reach = if (self.reach) |*reach| reach else null, .storms = self.shownStorms(scene), .incursions = self.shownIncursions(scene) };
        var names: [MAX_MARKS][]const u8 = undefined;
        var name_count: usize = 0;
        for (self.marks[0..self.mark_count]) |mark| {
            if (mark.system != system) continue;
            names[name_count] = mark.character_name;
            name_count += 1;
        }
        facts.characters = names[0..name_count];
        if (scene.pins.find(system, now_ms)) |pin| {
            facts.intel_message = pin.message();
            facts.intel_age_ms = now_ms -| pin.seen_ms;
        }
        return map_look.systemTooltip(facts);
    }

    /// Filled after the labels it covers, so GDI has to finish them first.
    fn drawTooltip(self: *const MapPanelWindow, bitmap: *const gdi_overlay.OverlayBitmap, scene: Scene, sizes: map_look.Metrics, text: panel_chrome.Text, now_ms: u64) void {
        const tooltip = self.tooltipFor(scene, now_ms) orelse return;
        self.drawTextBox(bitmap, &tooltip, self.hoverAnchor(), sizes, text);
    }

    fn drawNotice(self: *const MapPanelWindow, bitmap: *const gdi_overlay.OverlayBitmap, destinations: *const Destinations, sizes: map_look.Metrics, text: panel_chrome.Text) void {
        const notice = if (destinations.notice) |*shown| shown else return;
        const area = self.bodyArea(sizes);
        const tooltip = map_look.noticeTooltip(notice);
        self.drawTextBox(bitmap, &tooltip, .{ .x = area.left, .y = area.bottom }, sizes, text);
    }

    fn drawTextBox(self: *const MapPanelWindow, bitmap: *const gdi_overlay.OverlayBitmap, tooltip: *const map_look.Tooltip, anchor: win32.POINT, sizes: map_look.Metrics, text: panel_chrome.Text) void {
        const dc = bitmap.mem_dc;
        _ = win32.SelectObject(dc, text.name_font);

        var box_width: i32 = 0;
        for (0..tooltip.line_count) |index| box_width = @max(box_width, panel_chrome.wideTextWidth(dc, tooltip.line(index)));
        box_width += 2 * popup_look.TOOLTIP_PADDING;
        const line_count: i32 = @intCast(tooltip.line_count);
        const box_height = line_count * text.name_height + 2 * popup_look.TOOLTIP_PADDING;

        const box = popup_look.tooltipBox(self.bodyArea(sizes), anchor.x, anchor.y, box_width, box_height);
        _ = win32.GdiFlush();
        const canvas = bitmap.canvas();
        pixel_buffer.fillRect(canvas, @intCast(box.left), @intCast(box.top), @intCast(box.right - box.left), @intCast(box.bottom - box.top), popup_look.TOOLTIP_FILL);
        pixel_buffer.drawRectOutline(canvas, box.left, box.top, @intCast(box.right - box.left), @intCast(box.bottom - box.top), 1, list_look.DIVIDER);

        for (0..tooltip.line_count) |index| {
            const offset: i32 = @intCast(index);
            const line_color = if (index == 0) tooltip.title_color else list_look.NAME;
            panel_chrome.drawWideLine(dc, tooltip.line(index), box.left + popup_look.TOOLTIP_PADDING, box.top + popup_look.TOOLTIP_PADDING + offset * text.name_height, line_color);
        }
    }

    fn popupRowCount(self: *const MapPanelWindow, destinations: *const Destinations, rows: PopupRows) usize {
        return switch (rows) {
            .main => if (self.menu != null) self.menuRows().len else @max(1, self.hits.count),
            .branch => |branch| switch (branch) {
                .destination => destinationRowCount(&destinations.targets),
                .sites => system_links.SITES.len,
                .jump_range => self.rangeRowCount(),
            },
            .characters => destinations.targets.count - destinations.targets.groupCount(),
        };
    }

    fn popupRow(self: *const MapPanelWindow, destinations: *const Destinations, rows: PopupRows, index: usize) PopupRow {
        switch (rows) {
            .main => {},
            .branch => |branch| return branchRow(destinations, &self.config.display, branch, index),
            .characters => return targetRow(&destinations.targets.slice()[destinations.targets.groupCount() + index]),
        }
        if (self.menu) |menu| return self.menuRow(menu.system, index);
        const hits = self.hits.slice();
        if (hits.len == 0) return .{ .text = .print("{s}", .{if (self.search_length == 0) "Type a name" else "Nothing found"}), .color = list_look.MUTED };
        const hit = map_look.hitLabel(hits[index]);
        return .{ .text = hit.text, .color = list_look.NAME, .accent = hit.security };
    }

    fn menuRow(self: *const MapPanelWindow, system: SystemIndex, index: usize) PopupRow {
        return switch (self.menuRows()[index]) {
            .heading => .{ .text = .print("{s}", .{universe.systemName(system)}), .color = list_look.MUTED, .has_rule_below = true },
            .set_destination => .{ .text = .print("Set Destination", .{}), .color = list_look.NAME, .has_submenu = true },
            .open_site => .{ .text = .print("Open", .{}), .color = list_look.NAME, .has_submenu = true },
            .jump_range => .{ .text = .print("Jump Range", .{}), .color = list_look.NAME, .has_submenu = true },
            .avoid_system => .{ .text = map_look.avoidLabel(self.isAvoided(system)), .color = list_look.NAME },
            .copy_name => .{ .text = .print("Copy Name", .{}), .color = list_look.NAME },
        };
    }

    /// The row that's lit, if any; the menu's heading and the search's status line never are, and an open submenu's row stays lit.
    fn litPopupRow(self: *const MapPanelWindow) ?usize {
        if (self.is_searching) return if (self.hits.count > 0) self.search_index else null;
        if (self.hover.kind == .popup_row and self.hover.index > 0) return self.hover.index;
        const menu = self.menu orelse return null;
        const branch = menu.branch orelse return null;
        return self.branchRowIndex(branch);
    }

    /// An open "Individual" stays lit while the cursor is among its characters.
    fn litSubmenuRow(self: *const MapPanelWindow, destinations: *const Destinations, branch: Branch) ?usize {
        if (self.hover.kind != .submenu_row) return if (self.showsCharacters()) individualRow(&destinations.targets) else null;
        if (branch == .destination and self.hover.index == ALL_ROW and destinations.targets.count == 0) return null;
        return self.hover.index;
    }

    /// `buffer` holds what's returned.
    fn fillPopupRows(self: *const MapPanelWindow, destinations: *const Destinations, rows: PopupRows, buffer: *[MAX_POPUP_ROWS]PopupRow) []const PopupRow {
        const row_count = self.popupRowCount(destinations, rows);
        for (buffer[0..row_count], 0..) |*row, index| row.* = self.popupRow(destinations, rows, index);
        return buffer[0..row_count];
    }

    fn drawPopup(self: *MapPanelWindow, bitmap: *const gdi_overlay.OverlayBitmap, destinations: *const Destinations, sizes: map_look.Metrics, text: panel_chrome.Text) void {
        if (!self.isPopupOpen()) return;
        const search_box = self.searchBox(sizes);
        var main_rows: [MAX_POPUP_ROWS]PopupRow = undefined;
        var options: popup_menu.DrawOptions = .{
            .rows = self.fillPopupRows(destinations, .main, &main_rows),
            .min_column_width = if (self.is_searching) map_look.SEARCH_WIDTH else 0,
            .lit_row = self.litPopupRow(),
            .flat_lit_color = if (self.is_searching) map_look.FOCUS_MARK else null,
            .row_height = if (self.is_searching) popup_look.rowHeightForBox(search_box.bottom - search_box.top) else null,
        };
        var submenu_rows: [MAX_POPUP_ROWS]PopupRow = undefined;
        if (self.menu) |menu| {
            if (menu.branch) |branch| options.submenu = .{
                .rows = self.fillPopupRows(destinations, .{ .branch = branch }, &submenu_rows),
                .parent_index = self.branchRowIndex(branch),
                .lit_row = self.litSubmenuRow(destinations, branch),
            };
        }
        var character_rows: [MAX_POPUP_ROWS]PopupRow = undefined;
        if (self.showsCharacters()) {
            // The list can lose its last character while they're open.
            if (individualRow(&destinations.targets)) |parent_index| options.nested = .{
                .rows = self.fillPopupRows(destinations, .characters, &character_rows),
                .parent_index = parent_index,
                .lit_row = if (self.hover.kind == .nested_row) self.hover.index else null,
            };
        }
        const area = self.bodyArea(sizes);
        // Offset by the gaps the grid leaves, so the results open flush with the box's right edge and the zoom-out button's top.
        const anchor: win32.POINT = if (self.menu) |menu| menu.anchor else .{
            .x = search_box.right + 2 * popup_look.TOOLTIP_PADDING,
            .y = map_look.mapControlBox(area, .zoom_out).top - popup_look.TOOLTIP_PADDING,
        };
        self.popup.draw(bitmap, text, area, anchor, options);
    }

    fn hoverAnchor(self: *const MapPanelWindow) win32.POINT {
        return switch (self.hover.kind) {
            .node => .{ .x = self.layout.nodes[self.hover.index].x, .y = self.layout.nodes[self.hover.index].y },
            .exit => .{ .x = self.layout.exits[self.hover.index].x, .y = self.layout.exits[self.hover.index].y },
            .region => .{ .x = self.overview.bubbles[self.hover.index].x, .y = self.overview.bubbles[self.hover.index].y },
            .map_control => blk: {
                const box = map_look.mapControlBox(self.bodyArea(map_look.metrics(&self.config.display)), @fromBackingInt(@intCast(self.hover.index)));
                // Up by the gap the grid leaves, so the tooltip sits level with the control.
                break :blk .{ .x = box.left, .y = box.top - popup_look.TOOLTIP_PADDING };
            },
            .none, .button, .intel_row, .popup_row, .submenu_row, .nested_row, .search_box => .{ .x = 0, .y = 0 },
        };
    }
};

var g_is_class_registered: bool = false;

/// ALL_ROW is a status line while there are no targets.
fn branchRow(destinations: *const Destinations, display: *const config_mod.DisplayConfig, branch: Branch, index: usize) PopupRow {
    switch (branch) {
        .sites => return .{ .text = .print("{s}", .{system_links.siteName(system_links.SITES[index])}), .color = list_look.NAME },
        .jump_range => return rangeRow(index),
        .destination => {},
    }
    switch (index) {
        PREFERENCE_ROW => return .{ .text = map_look.preferenceLabel(display.mapPanelRoutePreference), .color = list_look.NAME },
        ANSIBLEX_ROW => return .{ .text = map_look.ansiblexLabel(display.mapPanelRouteAnsiblex), .color = list_look.NAME },
        WAYPOINTS_ROW => return .{ .text = map_look.waypointsLabel(display.mapPanelRouteEveryWaypoint), .color = list_look.NAME, .has_rule_below = true },
        else => {},
    }
    const targets = destinations.targets.slice();
    if (targets.len == 0) return .{ .text = .print("{s}", .{if (destinations.feed.characters.isBusy()) "Loading..." else "No characters"}), .color = list_look.MUTED };
    if (index == ALL_ROW) {
        const character_count = destinations.targets.sendableCharacterCount();
        return .{ .text = map_look.allLabel(character_count), .color = if (character_count > 0) list_look.NAME else list_look.MUTED };
    }
    if (index == individualRow(&destinations.targets)) return .{ .text = .print("Individual", .{}), .color = list_look.NAME, .has_submenu = true };
    return targetRow(&targets[index - ALL_ROW - 1]);
}

/// Past the ships is the "Off" row.
fn rangeRow(index: usize) PopupRow {
    if (index == jump_range.SHIPS.len) return .{ .text = .print("Off", .{}), .color = list_look.NAME };
    return .{ .text = map_look.rangeLabel(jump_range.SHIPS[index]), .color = list_look.NAME };
}

fn targetRow(target: *const evestars.Target) PopupRow {
    return .{ .text = map_look.targetLabel(target), .color = map_look.targetColor(target) };
}

/// Null with no characters to list.
fn individualRow(targets: *const evestars.Targets) ?usize {
    const group_count = targets.groupCount();
    return if (targets.count > group_count) ALL_ROW + 1 + group_count else null;
}

fn destinationRowCount(targets: *const evestars.Targets) usize {
    if (individualRow(targets)) |row_index| return row_index + 1;
    return ALL_ROW + 1 + targets.count;
}

/// Zero while the Intel Panel isn't inside the map.
fn sidebarWidth(display: *const config_mod.DisplayConfig, intel_history: ?*const history.NotificationHistory) i32 {
    const is_inside = display.showIntelPanel and display.intelPanelAttached and intel_history != null;
    return if (is_inside) display.intelPanelWidth else 0;
}

fn routeOptions(config: *const config_mod.Config) evestars.RouteOptions {
    const display = &config.display;
    var options: evestars.RouteOptions = .{
        .preference = display.mapPanelRoutePreference,
        .uses_ansiblex = display.mapPanelRouteAnsiblex,
        .sets_every_waypoint = display.mapPanelRouteEveryWaypoint,
        .avoids_zone = .{ display.mapPanelRouteAvoidZone1, display.mapPanelRouteAvoidZone2, display.mapPanelRouteAvoidZone3, display.mapPanelRouteAvoidZone4, display.mapPanelRouteAvoidZone5 },
    };
    for (config.avoidedSystems.items) |avoided| options.avoid(avoided.systemId);
    return options;
}

fn copySystemName(destinations: *Destinations, system: SystemIndex) void {
    const name = universe.systemName(system);
    const now_ms = win32.Ticks.now().ms;
    if (win32.setClipboardText(name)) {
        destinations.showInfo(.print("Copied {s}", .{name}), now_ms);
        return;
    }
    slog.warn("Failed to copy '{s}' to the clipboard", .{name});
    destinations.showFailureText(.print("Couldn't copy {s}", .{name}), now_ms);
}

fn openSite(destinations: *Destinations, site: system_links.Site, system: SystemIndex) void {
    const url = system_links.siteUrl(site, system);
    if (win32.shellOpenUrl(url.slice())) return;
    slog.warn("Failed to open '{s}'", .{url.slice()});
    destinations.showFailureText(.print("Couldn't open {s}", .{system_links.siteName(site)}), win32.Ticks.now().ms);
}

fn tokenOf(global: ?*const GlobalConfig) []const u8 {
    return if (global) |settings| settings.evestarsToken else "";
}

/// A dark outline, so a name stays readable across the gates running behind it.
fn drawHaloText(dc: win32.HDC, text: []const u8, x: i32, y: i32, text_color: u32) void {
    inline for (.{ [2]i32{ -1, 0 }, [2]i32{ 1, 0 }, [2]i32{ 0, -1 }, [2]i32{ 0, 1 } }) |offset| {
        panel_chrome.drawLine(dc, text, x + offset[0], y + offset[1], map_look.BACKGROUND);
    }
    panel_chrome.drawLine(dc, text, x, y, text_color);
}

fn legendFor(scene: Scene, paint: *const MapPaint) map_look.Legend {
    return switch (paint.metric) {
        .Security => map_look.securityLegend(),
        .ShipKills, .NpcKills, .Jumps => map_look.heatLegend(paint.metric, paint.peak, scene.stats != null),
        .Sovereignty => map_look.sovereigntyLegend(&paint.holders, scene.stats),
    };
}

/// Null where no storm covers the gate between them, or `storms` is.
fn stormEdgeColor(storms: ?*const Storms, first: SystemIndex, second: SystemIndex) ?u32 {
    const shown = storms orelse return null;
    const mark = shown.edgeMark(first, second) orelse return null;
    return map_look.stormEdgeColor(mark);
}

/// Null unless a storm is centred on `system`.
fn stormCenterColor(storms: ?*const Storms, system: SystemIndex) ?u32 {
    const shown = storms orelse return null;
    const storm = shown.centeredOn(system) orelse return null;
    return map_look.stormColor(storm.kind);
}

/// Null where no incursion covers the gate between them, or `incursions` is.
fn incursionEdgeColor(incursions: ?*const Incursions, first: SystemIndex, second: SystemIndex) ?u32 {
    const shown = incursions orelse return null;
    return if (shown.coversGate(first, second)) map_look.INCURSION else null;
}

/// Null unless an incursion stages from `system`.
fn incursionStagingColor(incursions: ?*const Incursions, system: SystemIndex) ?u32 {
    const shown = incursions orelse return null;
    return if (shown.stagedAt(system) != null) map_look.INCURSION else null;
}

fn markerColor(scene: Scene, paint: *const MapPaint, system: SystemIndex, value: u32) u32 {
    return switch (paint.metric) {
        .Security => map_look.securityColor(universe.systemInfo(system).security_tenths),
        .ShipKills, .NpcKills, .Jumps => map_look.heatColor(value, paint.peak),
        .Sovereignty => paint.holders.colorOf(if (scene.stats) |stats| stats.systems[system].holder else stats_mod.NO_HOLDER),
    };
}

fn regionFromSettings(region_id: u32) RegionIndex {
    return universe.findRegionById(region_id) orelse universe.findRegionById(DEFAULT_REGION_ID) orelse 0;
}

/// The region's busiest system by `metric`, which heat is measured against.
fn peakValue(layout: *const Layout, scene: Scene, metric: MapMetric) u32 {
    const stats = scene.stats orelse return 0;
    var peak: u32 = 0;
    for (layout.nodes[0..layout.node_count]) |node| peak = @max(peak, map_look.metricValue(metric, stats.systems[node.system]));
    return peak;
}

fn registerWindowClass(instance: win32.HINSTANCE) !void {
    if (g_is_class_registered) return;
    try gdi_overlay.registerWindowClass(instance, mapPanelWindowProc, MAP_PANEL_WINDOW_CLASS, null);
    g_is_class_registered = true;
}

fn mapWindow() ?*MapPanelWindow {
    const running = app.g_app orelse return null;
    return if (running.map_panel.window) |*window| window else null;
}

fn redrawAfterInput(running: *app.App) void {
    running.map_panel.redraw(running.thumbnail_set);
}

fn mapPanelWindowProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    // The frame's edges and title bar are Windows' own to hit test.
    if (msg != win32.WM_NCHITTEST) {
        if (drag.handleSharedMessage(app.currentThumbnailSet(), hwnd, msg, lParam, 0)) |result| return result;
    }
    switch (msg) {
        win32.WM_EXITSIZEMOVE => {
            if (mapWindow()) |window| window.saveWindowPlacement();
            return 0;
        },
        win32.WM_PAINT => {
            const window = mapWindow() orelse return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
            window.panel.paint();
            return 0;
        },
        win32.WM_SIZE => {
            const running = app.g_app orelse return 0;
            const window = mapWindow() orelse return 0;
            if (wParam == win32.SIZE_MINIMIZED) return 0;
            if (window.onSize(win32.lparamX(lParam), win32.lparamY(lParam))) redrawAfterInput(running);
            return 0;
        },
        win32.WM_GETMINMAXINFO => {
            const window = mapWindow() orelse return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
            window.limitSize(win32.lparamToPtr(win32.MINMAXINFO, lParam));
            return 0;
        },
        win32.WM_MOUSEACTIVATE => {
            // So clicking the map leaves the game with the keyboard, while the title bar activates as usual.
            if (lParam & 0xFFFF == win32.HTCLIENT) return win32.MA_NOACTIVATE;
            return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
        },
        win32.WM_CLOSE => {
            const running = app.g_app orelse return 0;
            running.map_panel.dismiss();
            return 0;
        },
        win32.WM_MOUSEMOVE => {
            const running = app.g_app orelse return 0;
            const window = mapWindow() orelse return 0;
            if (window.onMouseMove(running, hwnd, win32.lparamX(lParam), win32.lparamY(lParam))) redrawAfterInput(running);
            return 0;
        },
        win32.WM_MOUSELEAVE => {
            const running = app.g_app orelse return 0;
            const window = mapWindow() orelse return 0;
            window.onMouseLeave();
            redrawAfterInput(running);
            return 0;
        },
        win32.WM_LBUTTONDOWN => {
            const running = app.g_app orelse return 0;
            const window = mapWindow() orelse return 0;
            window.handleClick(running, win32.lparamX(lParam), win32.lparamY(lParam));
            redrawAfterInput(running);
            return 0;
        },
        win32.WM_LBUTTONUP => {
            const running = app.g_app orelse return 0;
            const window = mapWindow() orelse return 0;
            window.endPan();
            redrawAfterInput(running);
            return 0;
        },
        win32.WM_CAPTURECHANGED => {
            // A pan ended by Windows rather than the button keeps the view it reached.
            const window = mapWindow() orelse return 0;
            window.pan = null;
            return 0;
        },
        win32.WM_MOUSEWHEEL => {
            const running = app.g_app orelse return 0;
            const window = mapWindow() orelse return 0;
            if (window.onWheel(wParam, lParam)) redrawAfterInput(running);
            return 0;
        },
        win32.WM_RBUTTONDOWN => {
            const running = app.g_app orelse return 0;
            const window = mapWindow() orelse return 0;
            window.handleRightClick(running, win32.lparamX(lParam), win32.lparamY(lParam));
            redrawAfterInput(running);
            return 0;
        },
        win32.WM_CHAR => {
            const running = app.g_app orelse return 0;
            const window = mapWindow() orelse return 0;
            window.onSearchChar(wParam);
            redrawAfterInput(running);
            return 0;
        },
        win32.WM_KEYDOWN => {
            const running = app.g_app orelse return 0;
            const window = mapWindow() orelse return 0;
            window.onSearchKey(running, wParam);
            redrawAfterInput(running);
            return 0;
        },
        win32.WM_KILLFOCUS => {
            const running = app.g_app orelse return 0;
            const window = mapWindow() orelse return 0;
            // Also sent as the window is destroyed, when its bitmap has gone; closing it ends any search first.
            if (!window.is_searching) return 0;
            window.closeSearch(running, .keyboard_gone);
            redrawAfterInput(running);
            return 0;
        },
        win32.WM_TIMER => {
            const running = app.g_app orelse return 0;
            running.map_panel.pump(running.allocator);
            redrawAfterInput(running);
            return 0;
        },
        else => return win32.DefWindowProcA(hwnd, msg, wParam, lParam),
    }
}
