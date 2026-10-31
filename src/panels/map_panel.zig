//! The Map Panel: a schematic of one region with live stats, where the clients are, and chat intel.
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
const universe = @import("../map/universe.zig");
const layout_mod = @import("../map/layout.zig");
const stats_mod = @import("../map/stats.zig");
const stats_feed = @import("../map/stats_feed.zig");
const intel_pins = @import("../map/intel_pins.zig");
const app = @import("../app.zig");
const activation = @import("../control/activation.zig");
const scout = @import("../clients/scout.zig");
const set = @import("../thumbnail/set.zig");
const window_mod = @import("../thumbnail/window.zig");
const drag = @import("drag.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");
const log = @import("../log.zig");

const Box = layout_mod.Box;
const Layout = layout_mod.Layout;
const MapMetric = types.MapMetric;
const PanelWindow = panel_window.PanelWindow;
const RegionIndex = universe.RegionIndex;
const Snapshot = stats_mod.Snapshot;
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
/// Around a client's or the hovered system's marker.
const RING_GAP: f32 = 3;
const RING_THICKNESS: f32 = 1.5;
const EXIT_RADIUS: f32 = 2;
/// Shown instead of the real pins while mapPanelShowIntel is off.
const NO_PINS: intel_pins.IntelPins = .{};

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
};

const Hover = struct {
    kind: Kind = .none,
    /// A `nodes` or `exits` place, a RegionIndex, a Button's value or an `intel_rows` place, by kind.
    index: u16 = 0,

    const Kind = enum { none, node, exit, region, button, intel_row };

    fn eql(self: Hover, other: Hover) bool {
        return self.kind == other.kind and self.index == other.index;
    }
};

/// The shared fonts, and the map's own for the names on it.
const MapText = struct {
    chrome: panel_chrome.Text,
    label_font: win32.HFONT,
    label_height: i32,
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

    /// Creates the window if `store`'s profile shows it.
    pub fn start(self: *MapPanel, allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE, intel_history: *const history.NotificationHistory) void {
        self.intel_history = intel_history;
        if (store.live.display.showMapPanel) self.createWindow(allocator, store, instance);
    }

    /// Only once the feed's thread has finished.
    pub fn deinit(self: *MapPanel) void {
        self.destroyWindow();
        self.feed.deinit();
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

    /// Keyed on isVisible(), not the window: a visible panel turns off, and a hidden one is forced on even with no character logged in.
    pub fn toggle(self: *MapPanel, allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE, any_character_logged_in: bool) void {
        if (self.isVisible(&store.live, any_character_logged_in)) {
            self.destroyWindow();
            store.update(.{ .display = .{ .showMapPanel = false } });
            self.visibility.release();
            return;
        }
        if (self.window == null) self.createWindow(allocator, store, instance);
        if (self.window == null) return;
        store.update(.{ .display = .{ .showMapPanel = true } });
        self.visibility.force();
    }

    /// Matches the window to showMapPanel, its position and region, for a change made in the config dialog or by a new profile.
    pub fn sync(self: *MapPanel, allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE) void {
        const is_wanted = store.live.display.showMapPanel;
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

        const window = if (self.window) |*w| w else return;
        if (!self.isVisible(config, presence.any_character_logged_in)) {
            window.hide();
            return;
        }
        if (config.display.mapPanelLiveStats) self.feed.poll(allocator, win32.Ticks.now());
        self.redraw(thumbnail_set);
    }

    /// Also from the window's own input, since the tick can be a second apart with no clients running.
    fn redraw(self: *MapPanel, thumbnail_set: ?*const ThumbnailSet) void {
        const window = if (self.window) |*w| w else return;
        var scene: Scene = .{ .stats = self.stats, .pins = if (window.config.display.mapPanelShowIntel) &self.pins else &NO_PINS };
        if (thumbnail_set) |active_set| {
            scene.thumbnails = active_set.thumbnails.items;
            scene.active_source_hwnd = active_set.active_source_hwnd;
        }
        window.render(scene) catch |err| {
            slog.err("Failed to render Map Panel window: {}", .{err});
        };
    }

    fn createWindow(self: *MapPanel, allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE) void {
        self.window = MapPanelWindow.init(allocator, store, instance, self.intel_history) catch |err| {
            slog.err("Failed to create Map Panel window: {}", .{err});
            return;
        };
    }

    fn destroyWindow(self: *MapPanel) void {
        if (self.window) |*window| window.deinit();
        self.window = null;
    }
};

pub const MapPanelWindow = struct {
    panel: PanelWindow,
    /// For the names on the map, smaller than the panel's own fonts so more of them fit.
    label_font: gdi_overlay.CachedFont = .{},
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
    /// Shows the region grid in place of the map.
    is_picking_region: bool = false,
    /// The selected system, ringed: one clicked, or arrived at through a gate or the Intel Panel.
    focus_system: ?SystemIndex = null,
    /// Rebuilt each render; borrows from the thumbnails.
    marks: [MAX_MARKS]Mark = undefined,
    mark_count: usize = 0,
    /// See MapPanel.intel_history.
    intel_history: ?*const history.NotificationHistory,
    /// The sidebar's rows, from the last render.
    intel_rows: [history.CAPACITY]history_rows.Row = undefined,
    intel_row_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, store: *config_mod.ProfileStore, instance: win32.HINSTANCE, intel_history: ?*const history.NotificationHistory) !MapPanelWindow {
        const display = &store.live.display;
        try registerWindowClass(instance);
        const panel = try PanelWindow.init(allocator, instance, MAP_PANEL_WINDOW_CLASS, "EVE Map", .{
            .left = display.mapPanelX,
            .top = display.mapPanelY,
            .right = display.mapPanelX + display.mapPanelWidth,
            .bottom = display.mapPanelY + display.mapPanelHeight,
        });
        return .{
            .panel = panel,
            .store = store,
            .config = &store.live,
            .region = regionFromSettings(display.mapPanelRegionId),
            .settled_region_id = display.mapPanelRegionId,
            .intel_history = intel_history,
        };
    }

    pub fn deinit(self: *MapPanelWindow) void {
        self.label_font.deinit(self.panel.allocator);
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

    fn saveWindowPosition(self: *const MapPanelWindow) void {
        if (!self.config.display.rememberMapPanelPosition) return;
        const top_left = self.panel.topLeft() orelse return;
        self.store.update(.{ .display = .{ .mapPanelX = top_left.x, .mapPanelY = top_left.y } });
    }

    fn showRegion(self: *MapPanelWindow, region: RegionIndex) void {
        self.region = region;
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
        const display = &self.config.display;
        return display.showIntelPanel and display.intelPanelAttached and self.intel_history != null;
    }

    /// The map keeps its configured width, and the window grows around it for the sidebar.
    fn panelWidth(self: *const MapPanelWindow) i32 {
        const display = &self.config.display;
        return display.mapPanelWidth + if (self.isIntelInside()) display.intelPanelWidth else 0;
    }

    /// Empty while the Intel Panel isn't inside the map.
    fn intelEntries(self: *const MapPanelWindow, buffer: []history.Entry) []const history.Entry {
        const intel_history = self.intel_history orelse return &.{};
        return if (self.isIntelInside()) intel_history.snapshot(buffer) else &.{};
    }

    /// Between the header and footer, inside the frame.
    fn innerArea(self: *const MapPanelWindow, sizes: map_look.Metrics) Box {
        const top = sizes.header_height;
        return .{ .left = 1, .top = top, .right = self.panelWidth() - 1, .bottom = @max(top, self.config.display.mapPanelHeight - sizes.footer_height) };
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

    fn pickerGrid(self: *const MapPanelWindow, sizes: map_look.Metrics) map_look.PickerGrid {
        return .init(self.bodyArea(sizes), sizes.header_height);
    }

    fn hitTest(self: *const MapPanelWindow, x: i32, y: i32) Hover {
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
            const region = self.pickerGrid(sizes).regionAt(x, y) orelse return .{};
            return .{ .kind = .region, .index = region };
        }
        if (self.layout.nodeAt(x, y)) |node| return .{ .kind = .node, .index = node };
        if (self.layout.exitAt(x, y)) |exit| return .{ .kind = .exit, .index = exit };
        return .{};
    }

    /// Whether the hover changed, and so the panel needs a redraw.
    fn onMouseMove(self: *MapPanelWindow, hwnd: win32.HWND, x: i32, y: i32) bool {
        if (!self.is_tracking_mouse) self.is_tracking_mouse = win32.trackMouseLeave(hwnd);
        const hover = self.hitTest(x, y);
        if (hover.eql(self.hover)) return false;
        self.hover = hover;
        return true;
    }

    fn onMouseLeave(self: *MapPanelWindow) void {
        self.is_tracking_mouse = false;
        self.hover = .{};
    }

    fn openIntelRow(self: *MapPanelWindow, row_index: usize) void {
        const intel_history = self.intel_history orelse return;
        const entry = intel_history.entryFromNewest(self.intel_rows[row_index].first) orelse return;
        if (entry.system) |system| self.selectSystem(system);
    }

    fn handleClick(self: *MapPanelWindow, running: *app.App, x: i32, y: i32) void {
        const hit = self.hitTest(x, y);
        switch (hit.kind) {
            .none => {
                self.is_picking_region = false;
                self.focus_system = null;
            },
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
            .security, .kills, .npc_kills, .jumps => {},
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
        hasher.update(std.mem.asBytes(&self.is_picking_region));
        hasher.update(std.mem.asBytes(&self.hover.kind));
        hasher.update(std.mem.asBytes(&self.hover.index));
        if (self.focus_system) |system| hasher.update(std.mem.asBytes(&system));
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
        const display = &self.config.display;
        var hasher = std.hash.Wyhash.init(1);
        hasher.update(std.mem.asBytes(&self.region));
        hasher.update(std.mem.asBytes(&display.mapPanelWidth));
        hasher.update(std.mem.asBytes(&display.mapPanelHeight));
        const area = self.bodyArea(map_look.metrics(display));
        hasher.update(std.mem.asBytes(&area));
        panel_chrome.hashFonts(&hasher, display);
        hasher.update(display.mapPanelFontName);
        hasher.update(std.mem.asBytes(&display.mapPanelFontSize));
        hasher.update(std.mem.asBytes(&display.mapPanelFontWeight));
        return hasher.final();
    }

    fn ensureLayout(self: *MapPanelWindow, dc: win32.HDC, sizes: map_look.Metrics, text: ?MapText) void {
        const signature = self.layoutSignature();
        if (self.layout_signature == signature) return;
        self.layout_signature = signature;
        self.layout.build(self.region, self.bodyArea(sizes));

        const fonts = text orelse return;
        _ = win32.SelectObject(dc, fonts.label_font);
        var node_widths: [universe.MAX_REGION_SYSTEMS]i32 = undefined;
        for (self.layout.nodes[0..self.layout.node_count], node_widths[0..self.layout.node_count]) |node, *width| {
            width.* = panel_chrome.textWidth(dc, universe.systemName(node.system));
        }
        var exit_widths: [layout_mod.MAX_EXITS]i32 = undefined;
        for (self.layout.exits[0..self.layout.exit_count], exit_widths[0..self.layout.exit_count]) |exit, *width| {
            width.* = panel_chrome.textWidth(dc, universe.regionName(exit.region));
        }
        self.layout.placeLabels(&node_widths, &exit_widths, fonts.label_height);
    }

    /// Null if a font couldn't be created, which leaves the panel without text.
    fn mapText(self: *const MapPanelWindow, dc: win32.HDC) ?MapText {
        const chrome = panel_chrome.textOf(&self.panel, dc) orelse return null;
        const label_font = self.label_font.handle orelse return null;
        _ = win32.SelectObject(dc, label_font);
        return .{ .chrome = chrome, .label_font = label_font, .label_height = panel_chrome.lineHeight(dc) };
    }

    /// Called every tick, and on hover; redraws only when the render signature changed.
    pub fn render(self: *MapPanelWindow, scene: Scene) !void {
        const display = &self.config.display;
        try panel_chrome.ensureFonts(&self.panel, display);
        try self.label_font.ensure(self.panel.allocator, "Map Panel labels", display.mapPanelFontName, display.mapPanelFontSize, display.mapPanelFontWeight);

        self.updateMarks(scene);
        self.followActive();
        const now_ms = win32.Ticks.now().ms;
        var entry_buf: [history.CAPACITY]history.Entry = undefined;
        const intel_entries = self.intelEntries(&entry_buf);
        const signature = self.computeRenderSignature(scene, now_ms, intel_entries);
        if (self.panel.isUnchanged(signature)) return;

        const panel_width: i32 = @max(1, self.panelWidth());
        const panel_height: i32 = @max(1, display.mapPanelHeight);
        const bitmap = try self.panel.beginFrame(panel_width, panel_height);
        const width: usize = bitmap.width;
        const height: usize = bitmap.height;
        const dc = bitmap.mem_dc;
        const canvas = bitmap.canvas();
        const sizes = map_look.metrics(display);
        const footer_top = panel_look.footerTop(panel_height, sizes.header_height, sizes.footer_height);
        const buttons = self.footerButtons();

        const old_font = panel_chrome.selectFont(&self.panel, dc);
        defer panel_chrome.restoreFont(dc, old_font);
        const text = self.mapText(dc);
        self.ensureLayout(dc, sizes, text);

        pixel_buffer.fillRect(canvas, 0, 0, width, height, list_look.PANEL);
        if (self.is_picking_region) {
            self.drawPickerFills(canvas, sizes);
        } else {
            self.drawMap(canvas, scene, now_ms);
        }

        // After the map, which a new intel halo can reach past.
        const sidebar = self.intelSidebar(sizes);
        if (sidebar) |box| self.fillIntelSidebar(canvas, box);
        panel_chrome.fillBars(canvas, sizes.header_height, footer_top);
        panel_chrome.fillButtons(canvas, &buttons, panel_width, footer_top, sizes.header_height);

        if (text) |fonts| {
            self.drawHeader(dc, scene, sizes, fonts.chrome, panel_width, now_ms);
            panel_chrome.drawButtonLabels(dc, fonts.chrome, &buttons, panel_width, footer_top, sizes.header_height);
            if (self.is_picking_region) {
                self.drawPickerLabels(dc, sizes, fonts.chrome);
            } else {
                self.drawLabels(dc, scene, fonts.label_font, now_ms);
                self.drawTooltip(bitmap, scene, sizes, fonts.chrome, now_ms);
            }
            if (sidebar) |box| self.drawIntelRows(dc, fonts.chrome, box, sizes, intel_entries);
        }

        panel_chrome.finish(canvas);
        self.panel.present(display.mapPanelOpacity, signature);
    }

    fn isButtonLit(self: *const MapPanelWindow, button: map_look.Button) bool {
        const display = &self.config.display;
        if (map_look.metricOf(button)) |metric| return display.mapPanelMetric == metric;
        return switch (button) {
            .regions => self.is_picking_region,
            .follow => display.mapPanelFollowActive,
            .security, .kills, .npc_kills, .jumps => false,
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
        const row_sizes: history_look.Metrics = .{ .header_height = sizes.header_height, .row_height = history_rows.intelRowHeight(display), .footer_height = sizes.footer_height };
        const capacity = history_look.rowsThatFit(display.mapPanelHeight, row_sizes, history.CAPACITY);
        self.intel_row_count = history_rows.build(&self.intel_rows, entries, capacity, history_rows.buildOptions(display, null));
        const area = history_rows.intelArea(display, box.left, box.top, box.right);
        history_rows.drawIntel(dc, text, self.intel_rows[0..self.intel_row_count], entries, &self.config.thumbnail.notifications, area);
    }

    fn footerButtons(self: *const MapPanelWindow) [map_look.BUTTON_ORDER.len]panel_chrome.Button {
        var buttons: [map_look.BUTTON_ORDER.len]panel_chrome.Button = undefined;
        for (map_look.BUTTON_ORDER, &buttons) |button, *shown| shown.* = .{ .label = map_look.buttonLabel(button), .is_lit = self.isButtonLit(button) };
        return buttons;
    }

    fn drawHeader(self: *const MapPanelWindow, dc: win32.HDC, scene: Scene, sizes: map_look.Metrics, text: panel_chrome.Text, panel_width: i32, now_ms: u64) void {
        var title_buf: [panel_chrome.MAX_TEXT_LENGTH]u8 = undefined;
        // Region names are short, from the embedded map.
        const title = std.fmt.bufPrint(&title_buf, "{s} - {d} systems", .{ universe.regionName(self.region), self.layout.node_count }) catch unreachable;
        var age_buf: [panel_look.TIME_TEXT_MAX]u8 = undefined;
        var status_buf: [panel_look.TIME_TEXT_MAX + 8]u8 = undefined;
        const status: ?[]const u8 = if (scene.stats) |stats|
            std.fmt.bufPrint(&status_buf, "Stats {s}", .{panel_look.relativeTime(&age_buf, now_ms -| stats.fetched_ms)}) catch unreachable
        else
            null;
        panel_chrome.drawHeader(dc, text, sizes.header_height, panel_width, title, status);
    }

    fn drawPickerFills(self: *const MapPanelWindow, canvas: pixel_buffer.Canvas, sizes: map_look.Metrics) void {
        const grid = self.pickerGrid(sizes);
        for (0..universe.REGION_COUNT) |index| {
            const region: RegionIndex = @intCast(index);
            const is_hovered = self.hover.kind == .region and self.hover.index == region;
            if (region != self.region and !is_hovered) continue;
            const cell = grid.cell(region);
            pixel_buffer.fillRect(canvas, @intCast(cell.left), @intCast(cell.top), @intCast(cell.right - cell.left), @intCast(cell.bottom - cell.top), panel_look.BUTTON_ON);
        }
    }

    /// A region with a client in it stands out, as the likely pick.
    fn drawPickerLabels(self: *const MapPanelWindow, dc: win32.HDC, sizes: map_look.Metrics, text: panel_chrome.Text) void {
        _ = win32.SelectObject(dc, text.name_font);
        const grid = self.pickerGrid(sizes);
        for (0..universe.REGION_COUNT) |index| {
            const region: RegionIndex = @intCast(index);
            const cell = grid.cell(region);
            const label_color = if (self.hasClientIn(region)) self.config.display.listViewActiveColor else list_look.NAME;
            const y = cell.top + @divTrunc(cell.bottom - cell.top - text.name_height, 2);
            _ = panel_chrome.drawFitted(dc, universe.regionName(region), cell.left + panel_look.BUTTON_GAP, y, label_color, cell.right - cell.left - 2 * panel_look.BUTTON_GAP);
        }
    }

    fn hasClientIn(self: *const MapPanelWindow, region: RegionIndex) bool {
        for (self.marks[0..self.mark_count]) |mark| {
            if (universe.systemInfo(mark.system).region == region) return true;
        }
        return false;
    }

    fn intelHaloRadius(self: *const MapPanelWindow, pin: *const intel_pins.Pin, now_ms: u64) f32 {
        const shrink_ms: u64 = @as(u64, @intCast(@max(0, self.config.display.mapPanelIntelShrinkSec))) * std.time.ms_per_s;
        return map_look.intelHaloRadius(now_ms -| pin.seen_ms, shrink_ms);
    }

    fn drawMap(self: *const MapPanelWindow, canvas: pixel_buffer.Canvas, scene: Scene, now_ms: u64) void {
        const layout = &self.layout;
        const hovered_node: ?u16 = if (self.hover.kind == .node) self.hover.index else null;
        // Under everything else, so a new halo doesn't hide the systems around it.
        for (layout.nodes[0..layout.node_count]) |node| {
            const pin = scene.pins.find(node.system, now_ms) orelse continue;
            const halo_radius = self.intelHaloRadius(pin, now_ms);
            const freshness = pin.freshnessPercent(now_ms);
            pixel_buffer.fillCircle(canvas, node.x, node.y, halo_radius, map_look.intelHaloColor(pin.is_clear, freshness));
            pixel_buffer.drawRing(canvas, node.x, node.y, halo_radius, RING_THICKNESS, map_look.intelRimColor(pin.is_clear, freshness));
        }
        for (layout.edges[0..layout.edge_count]) |edge| {
            const first = layout.nodes[edge.first];
            const second = layout.nodes[edge.second];
            const is_hovered = hovered_node == edge.first or hovered_node == edge.second;
            const edge_color = if (is_hovered) map_look.EDGE_HOVER else if (edge.is_local) map_look.EDGE_LOCAL else map_look.EDGE_CROSS;
            pixel_buffer.drawLine(canvas, first.x, first.y, second.x, second.y, edge_color);
        }
        for (layout.exits[0..layout.exit_count], 0..) |exit, index| {
            const node = layout.nodes[exit.from];
            const is_hovered = self.hover.kind == .exit and self.hover.index == index;
            const exit_color = if (is_hovered) map_look.EDGE_HOVER else map_look.EXIT;
            pixel_buffer.drawLine(canvas, node.x, node.y, exit.x, exit.y, exit_color);
            pixel_buffer.fillCircle(canvas, exit.x, exit.y, EXIT_RADIUS, exit_color);
        }

        const metric = self.config.display.mapPanelMetric;
        const peak = peakValue(layout, scene, metric);
        for (layout.nodes[0..layout.node_count], 0..) |node, index| {
            const value = if (scene.stats) |stats| map_look.metricValue(metric, stats.systems[node.system]) else 0;
            const radius = map_look.markerRadius(value, peak);
            const marker_color = if (metric == .Security) map_look.securityColor(universe.systemInfo(node.system).security_tenths) else map_look.heatColor(value, peak);
            pixel_buffer.fillCircle(canvas, node.x, node.y, radius, marker_color);
            const is_hovered = if (hovered_node) |hovered| hovered == index else false;
            if (is_hovered or self.focus_system == node.system) pixel_buffer.drawRing(canvas, node.x, node.y, radius + RING_GAP, RING_THICKNESS, map_look.FOCUS);
        }

        for (self.marks[0..self.mark_count]) |mark| {
            const index = layout.nodeOf(mark.system) orelse continue;
            const node = layout.nodes[index];
            const ring_color = if (mark.is_active) self.config.display.listViewActiveColor else mark.color;
            pixel_buffer.drawRing(canvas, node.x, node.y, map_look.markerRadius(0, 0) + 2 * RING_GAP, RING_THICKNESS, ring_color);
        }
    }

    fn drawLabels(self: *const MapPanelWindow, dc: win32.HDC, scene: Scene, label_font: win32.HFONT, now_ms: u64) void {
        const layout = &self.layout;
        _ = win32.SelectObject(dc, label_font);
        for (layout.nodes[0..layout.node_count]) |node| {
            const label = node.label orelse continue;
            const label_color = if (scene.pins.find(node.system, now_ms)) |pin| map_look.intelColor(pin.is_clear) else list_look.NAME;
            panel_chrome.drawLine(dc, universe.systemName(node.system), label.left, label.top, label_color);
        }
        for (layout.exits[0..layout.exit_count]) |exit| {
            const label = exit.label orelse continue;
            panel_chrome.drawLine(dc, universe.regionName(exit.region), label.left, label.top, map_look.EXIT);
        }
    }

    fn tooltipFor(self: *const MapPanelWindow, scene: Scene, now_ms: u64) ?map_look.Tooltip {
        switch (self.hover.kind) {
            .none, .region, .button, .intel_row => return null,
            .exit => {
                const exit = self.layout.exits[self.hover.index];
                return map_look.exitTooltip(self.layout.nodes[exit.from].system, exit.destination);
            },
            .node => {},
        }

        const system = self.layout.nodes[self.hover.index].system;
        var facts: map_look.SystemFacts = .{ .system = system, .stats = scene.stats };
        var distances: universe.Distances = undefined;
        if (self.activeMark()) |active| {
            universe.measureDistances(active.system, universe.UNREACHED - 1, &distances);
            facts.active_character = active.character_name;
            if (distances[system] != universe.UNREACHED) facts.jumps_from_active = distances[system];
        }
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
        const dc = bitmap.mem_dc;
        _ = win32.SelectObject(dc, text.name_font);

        var box_width: i32 = 0;
        for (0..tooltip.line_count) |index| box_width = @max(box_width, wideTextWidth(dc, tooltip.line(index)));
        box_width += 2 * map_look.TOOLTIP_PADDING;
        const line_count: i32 = @intCast(tooltip.line_count);
        const box_height = line_count * text.name_height + 2 * map_look.TOOLTIP_PADDING;

        const anchor = self.hoverAnchor();
        const box = map_look.tooltipBox(self.bodyArea(sizes), anchor.x, anchor.y, box_width, box_height);
        _ = win32.GdiFlush();
        const canvas = bitmap.canvas();
        pixel_buffer.fillRect(canvas, @intCast(box.left), @intCast(box.top), @intCast(box.right - box.left), @intCast(box.bottom - box.top), map_look.TOOLTIP_FILL);
        pixel_buffer.drawRectOutline(canvas, box.left, box.top, @intCast(box.right - box.left), @intCast(box.bottom - box.top), 1, list_look.DIVIDER);

        for (0..tooltip.line_count) |index| {
            const offset: i32 = @intCast(index);
            const line_color = if (index == 0) tooltip.title_color else list_look.NAME;
            gdi_overlay.drawTextUtf8(panel_chrome.MAX_TEXT_LENGTH, dc, box.left + map_look.TOOLTIP_PADDING, box.top + map_look.TOOLTIP_PADDING + offset * text.name_height, tooltip.line(index), line_color & 0x00FF_FFFF);
        }
    }

    fn hoverAnchor(self: *const MapPanelWindow) win32.POINT {
        return switch (self.hover.kind) {
            .node => .{ .x = self.layout.nodes[self.hover.index].x, .y = self.layout.nodes[self.hover.index].y },
            .exit => .{ .x = self.layout.exits[self.hover.index].x, .y = self.layout.exits[self.hover.index].y },
            .none, .region, .button, .intel_row => .{ .x = 0, .y = 0 },
        };
    }
};

var g_is_class_registered: bool = false;

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
    // The app only holds the panel once its window exists, so creation's messages go without a header.
    const header_height = if (mapWindow()) |window| map_look.metrics(&window.config.display).header_height else 0;
    if (drag.handleSharedMessage(app.currentThumbnailSet(), hwnd, msg, lParam, header_height)) |result| return result;
    switch (msg) {
        win32.WM_EXITSIZEMOVE => {
            if (mapWindow()) |window| window.saveWindowPosition();
            return 0;
        },
        win32.WM_MOUSEMOVE => {
            const running = app.g_app orelse return 0;
            const window = mapWindow() orelse return 0;
            if (window.onMouseMove(hwnd, win32.lparamX(lParam), win32.lparamY(lParam))) redrawAfterInput(running);
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
        else => return win32.DefWindowProcA(hwnd, msg, wParam, lParam),
    }
}

/// Like panel_chrome.textWidth, for text that may not be ASCII, as intel and alliance names can be.
fn wideTextWidth(dc: win32.HDC, text: []const u8) i32 {
    return gdi_overlay.measureTextSizeUtf8(panel_chrome.MAX_TEXT_LENGTH, dc, text).cx;
}
