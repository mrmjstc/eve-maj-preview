//! The Map Panel's window: its settings, the regions it shows, and drawing each frame.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const gdi_overlay = @import("../../platform/gdi_overlay.zig");
const panel_window = @import("../../platform/panel_window.zig");
const config_mod = @import("../../config.zig");
const history = @import("../../notifications/history.zig");
const history_rows = @import("../history_rows.zig");
const list_look = @import("../list_look.zig");
const look = @import("look.zig");
const menu_mod = @import("menu.zig");
const paint = @import("paint.zig");
const state_mod = @import("state.zig");
const text_mod = @import("text.zig");
const panel_chrome = @import("../panel_chrome.zig");
const panel_host = @import("../panel_host.zig");
const panel_lifecycle = @import("../panel_lifecycle.zig");
const panel_look = @import("../panel_look.zig");
const universe = @import("../../map/universe.zig");
const layout = @import("../../map/layout.zig");
const destinations_mod = @import("../../map/destinations.zig");
const scout = @import("../../clients/scout.zig");
const fixed_text = @import("../../util/fixed_text.zig");
const log = @import("../../log.zig");

const Destinations = destinations_mod.Destinations;
const FixedText = fixed_text.FixedText;
const GlobalConfig = config_mod.GlobalConfig;
const MapFonts = paint.MapFonts;
const MapState = state_mod.MapState;
const PanelWindow = panel_window.PanelWindow;
const Regions = layout.Regions;
const RegionIndex = universe.RegionIndex;
const Scene = paint.Scene;
const SystemIndex = universe.SystemIndex;
const slog = log.Scoped("map_panel");

/// Granularity of ages baked into the render signature, so they don't redraw every tick.
const AGE_BUCKET_MS: u64 = 15_000;
const DEFAULT_REGION_ID = 10000002;
/// When the screen's refresh rate can't be read.
const FALLBACK_REFRESH_HZ: u64 = 60;

pub const MapPanelWindow = struct {
    panel: PanelWindow,
    /// For the names on the map, smaller than the panel's own fonts so more of them fit.
    label_font: gdi_overlay.CachedFont = .{},
    /// For the regions' names, over the map and beside each region on it.
    title_font: gdi_overlay.CachedFont = .{},
    /// Borrowed; outlives the window.
    store: *config_mod.ProfileStore,
    /// Borrowed; outlives the window.
    config: *const config_mod.Config,
    state: MapState,
    /// The region IDs last read from the settings, so only a change to them moves the map; following a client doesn't touch them.
    settled_region_ids: [layout.MAX_REGIONS]u32,
    /// A leave is armed, to clear the hover.
    is_tracking_mouse: bool = false,
    /// See MapPanel.intel_history.
    intel_history: ?*const history.NotificationHistory,
    /// See MapPanel.global.
    global: ?*const GlobalConfig,
    /// What had the keyboard before the search, to hand it back.
    search_return_hwnd: ?win32.HWND = null,
    /// The panel's pump timer is running.
    is_pumping: bool = false,
    /// The title bar's text, to set it only when it changes.
    title_hash: u64 = 0,
    /// One refresh of the screen the window is on; a moving map draws no more often, as the screen can't show it.
    frame_interval_us: u64,
    /// When the last frame started drawing.
    last_frame_us: u64 = 0,

    /// `class_name` must already be registered.
    pub fn init(context: panel_host.Context, class_name: [*:0]const u8, intel_history: ?*const history.NotificationHistory, global: ?*const GlobalConfig) !MapPanelWindow {
        const map_settings = &context.store.live.mapPanel;
        var rect = panel_lifecycle.windowRect(map_settings);
        rect.right += sidebarWidth(&context.store.live.intelPanel, intel_history);
        const panel = try PanelWindow.initNative(context.allocator, context.instance, class_name, "EVE Map", rect, map_settings.alwaysOnTop);
        return .{
            .panel = panel,
            .store = context.store,
            .config = &context.store.live,
            .state = .{ .regions = regionsFromSettings(map_settings) },
            .settled_region_ids = savedRegionIds(map_settings),
            .intel_history = intel_history,
            .global = global,
            .frame_interval_us = frameIntervalOf(panel.hwnd),
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

    pub fn followSettings(self: *MapPanelWindow) void {
        const map_settings = &self.config.mapPanel;
        self.panel.followPosition(map_settings.x, map_settings.y);
        const saved = savedRegionIds(map_settings);
        if (std.mem.eql(u32, &saved, &self.settled_region_ids)) return;
        self.settled_region_ids = saved;
        self.state.showRegions(regionsFromSettings(map_settings));
    }

    /// Once a move or resize by hand ends.
    pub fn afterSizeMove(self: *MapPanelWindow) void {
        self.saveWindowPlacement();
        // It may have moved to a screen with another refresh rate.
        self.frame_interval_us = frameIntervalOf(self.panel.hwnd);
    }

    /// A maximized window keeps the size it restores to.
    fn saveWindowPlacement(self: *const MapPanelWindow) void {
        const map_settings = &self.config.mapPanel;
        if (win32.isWindowZoomed(self.panel.hwnd)) return;
        self.store.update(.{ .mapPanel = .{ .width = self.panel.width - sidebarWidth(&self.config.intelPanel, self.intel_history), .height = self.panel.height } });
        if (!map_settings.rememberPosition) return;
        const top_left = self.panel.topLeft() orelse return;
        self.store.update(.{ .mapPanel = .{ .x = top_left.x, .y = top_left.y } });
    }

    /// Picked by the user, so it's what the panel reopens on.
    pub fn chooseRegion(self: *MapPanelWindow, region: RegionIndex) void {
        self.state.showRegions(.one(region));
        self.saveRegions();
    }

    /// Adds `region` beside those shown, or takes it out, staying in New Eden if that's open; whether the map changed.
    pub fn toggleRegion(self: *MapPanelWindow, destinations: *Destinations, region: RegionIndex) bool {
        var regions = self.state.regions;
        switch (regions.toggle(region)) {
            .added, .removed => {},
            .replaced => |dropped| destinations.showInfo(.print("Dropped {s}: the map shows {d} regions at most", .{ universe.regionName(dropped), layout.MAX_REGIONS }), win32.Ticks.now().ms),
            .last => return false,
        }
        self.state.regions = regions;
        self.state.layout.view = .{};
        // A hovered exit's place can be gone once the layout is rebuilt.
        self.state.hover = .{};
        if (self.state.focus_system) |system| {
            if (!regions.contains(universe.systemInfo(system).region)) self.state.focus_system = null;
        }
        self.saveRegions();
        return true;
    }

    fn saveRegions(self: *MapPanelWindow) void {
        self.settled_region_ids = regionIds(&self.state.regions);
        const ids = self.settled_region_ids;
        self.store.update(.{ .mapPanel = .{ .regionId = ids[0], .extraRegionId1 = ids[1], .extraRegionId2 = ids[2], .extraRegionId3 = ids[3] } });
    }

    /// Keeps the regions shown when they hold `system`.
    pub fn selectSystem(self: *MapPanelWindow, system: SystemIndex) void {
        const region = universe.systemInfo(system).region;
        if (self.state.regions.contains(region)) self.state.is_picking_region = false else self.chooseRegion(region);
        self.state.focus_system = system;
    }

    fn isIntelInside(self: *const MapPanelWindow) bool {
        return sidebarWidth(&self.config.intelPanel, self.intel_history) > 0;
    }

    /// Stops the window being dragged smaller than the settings allow, sidebar included.
    pub fn limitSize(self: *const MapPanelWindow, limits: *win32.MINMAXINFO) void {
        const min_width = config_mod.MapPanelConfig.MIN_WIDTH + sidebarWidth(&self.config.intelPanel, self.intel_history);
        const outer = PanelWindow.outerSize(min_width, config_mod.MapPanelConfig.MIN_HEIGHT);
        limits.ptMinTrackSize = .{ .x = outer.cx, .y = outer.cy };
    }

    /// Whether the size changed, and so the panel needs a redraw.
    pub fn onSize(self: *MapPanelWindow, width: i32, height: i32) bool {
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

    pub fn currentAreas(self: *const MapPanelWindow) look.Areas {
        const intel_settings = &self.config.intelPanel;
        return .init(self.panel.width, self.panel.height, look.metrics(&self.config.historyPanel).footer_height, sidebarWidth(intel_settings, self.intel_history), intel_settings.side);
    }

    pub fn hasEveStars(self: *const MapPanelWindow) bool {
        const settings = self.global orelse return false;
        return settings.evestarsEnabled and settings.evestarsToken.len > 0;
    }

    /// Empty without global settings.
    pub fn evestarsToken(self: *const MapPanelWindow) []const u8 {
        const settings = self.global orelse return "";
        return settings.evestarsToken;
    }

    pub fn menuContext(self: *const MapPanelWindow, destinations: *const Destinations, system: SystemIndex) menu_mod.Context {
        const map_settings = &self.config.mapPanel;
        return .{
            .has_eve_stars = self.hasEveStars(),
            .targets = &destinations.targets,
            .is_loading = destinations.feed.characters.isBusy(),
            .has_reach = self.state.reach != null,
            .is_avoided = self.isAvoided(system),
            .preference = map_settings.routePreference,
            .uses_ansiblex = map_settings.routeAnsiblex,
            .sets_every_waypoint = map_settings.routeEveryWaypoint,
        };
    }

    fn isAvoided(self: *const MapPanelWindow, system: SystemIndex) bool {
        return self.config.avoidedSystemIndex(universe.systemInfo(system).id) != null;
    }

    fn updateMarks(self: *MapPanelWindow, scene: Scene) void {
        self.state.marks.clear();
        for (scene.thumbnails) |*thumbnail| {
            if (scout.isGenericCharacterName(thumbnail.character_name)) continue;
            const system = universe.findSystem(thumbnail.system_name) orelse continue;
            const is_added = self.state.marks.add(.{
                .system = system,
                .source_hwnd = thumbnail.source_hwnd,
                .character_name = thumbnail.character_name,
                .color = thumbnail.cached_character_color orelse list_look.NAME,
                .is_active = thumbnail.source_hwnd == scene.active_source_hwnd,
            });
            if (!is_added) break;
        }
    }

    fn followActive(self: *MapPanelWindow) void {
        if (!self.config.mapPanel.followActive) return;
        const active = self.state.marks.active() orelse return;
        const region = universe.systemInfo(active.system).region;
        if (self.state.followed_region == region) return;
        self.state.followed_region = region;
        if (!self.state.regions.contains(region)) self.state.showRegions(.one(region));
    }

    fn computeRenderSignature(self: *const MapPanelWindow, scene: Scene, now_ms: u64, intel_entries: []const history.Entry) u64 {
        const map_settings = &self.config.mapPanel;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&self.layoutSignature()));
        hasher.update(std.mem.asBytes(&map_settings.opacity));
        hasher.update(std.mem.asBytes(&map_settings.metric));
        hasher.update(std.mem.asBytes(&map_settings.followActive));
        hasher.update(std.mem.asBytes(&map_settings.showStorms));
        hasher.update(std.mem.asBytes(&map_settings.showIncursions));
        hasher.update(std.mem.asBytes(&map_settings.alwaysOnTop));
        hasher.update(std.mem.asBytes(&map_settings.routePreference));
        hasher.update(std.mem.asBytes(&map_settings.routeAnsiblex));
        hasher.update(std.mem.asBytes(&map_settings.routeEveryWaypoint));
        self.state.hash(&hasher);
        hasher.update(std.mem.asBytes(&self.hasEveStars()));
        hasher.update(std.mem.asBytes(&map_settings.showCharacterNames));
        hasher.update(std.mem.asBytes(&scene.destinations.revision));
        hasher.update(std.mem.sliceAsBytes(self.config.avoidedSystems.items));
        if (scene.stats) |stats| hasher.update(std.mem.asBytes(&stats.fetched_ms));
        hasher.update(std.mem.asBytes(&scene.logo_revision));
        hasher.update(std.mem.asBytes(&scene.pins.revision));
        const lifetime_ms = map_settings.intelShrinkMs();
        const halo_scale = look.markerScale(self.state.layout.view.zoom);
        // By whole pixels, so a shrinking halo redraws only when it can show.
        for (&scene.pins.pins) |*pin| {
            if (!pin.isLive(lifetime_ms, now_ms) or !self.state.regions.contains(universe.systemInfo(pin.system).region)) continue;
            const halo_radius: i32 = @intFromFloat(paint.intelHaloRadius(map_settings, pin, halo_scale, now_ms));
            hasher.update(std.mem.asBytes(&halo_radius));
        }
        if (self.intel_history) |intel_history| history_rows.hashIntel(&hasher, intel_history, intel_entries, &self.config.historyPanel, &self.config.intelPanel, &self.config.thumbnail.notifications);
        const age_bucket = now_ms / AGE_BUCKET_MS;
        hasher.update(std.mem.asBytes(&age_bucket));
        return hasher.final();
    }

    /// What `layout` depends on.
    fn layoutSignature(self: *const MapPanelWindow) u64 {
        var hasher = std.hash.Wyhash.init(1);
        hasher.update(std.mem.sliceAsBytes(self.state.regions.slice()));
        hasher.update(std.mem.asBytes(&self.state.layout.view));
        self.hashAreaAndFonts(&hasher);
        return hasher.final();
    }

    fn hashAreaAndFonts(self: *const MapPanelWindow, hasher: *std.hash.Wyhash) void {
        const area = self.currentAreas().map;
        hasher.update(std.mem.asBytes(&area));
        self.hashFonts(hasher);
    }

    fn hashFonts(self: *const MapPanelWindow, hasher: *std.hash.Wyhash) void {
        const map_settings = &self.config.mapPanel;
        panel_chrome.hashFonts(hasher, &self.config.historyPanel);
        hasher.update(map_settings.fontName);
        hasher.update(std.mem.asBytes(&map_settings.fontSize));
        hasher.update(std.mem.asBytes(&map_settings.fontWeight));
    }

    /// The label width of the node at `index` in `layout`, with its security once zoomed in enough.
    fn labelWidthAt(self: *const MapPanelWindow, index: usize) i32 {
        const name_width = self.state.label_widths.names[index];
        if (!look.showsSecurityLabel(self.state.layout.view.zoom)) return name_width;
        return name_width + look.LABEL_SUFFIX_GAP + self.state.label_widths.securities[index];
    }

    /// Only when the regions or fonts change, as a pan or zoom keeps every label's width; with `dc` holding the label font, after `layout` is built.
    fn measureLabels(self: *MapPanelWindow, dc: win32.HDC) void {
        var hasher = std.hash.Wyhash.init(4);
        hasher.update(std.mem.sliceAsBytes(self.state.regions.slice()));
        self.hashFonts(&hasher);
        const signature = hasher.final();
        if (self.state.label_widths_signature == signature) return;
        self.state.label_widths_signature = signature;

        const widths = &self.state.label_widths;
        for (self.state.layout.nodes[0..self.state.layout.node_count], 0..) |node, index| {
            widths.names[index] = panel_chrome.textWidth(dc, universe.systemName(node.system));
            var buffer: [text_mod.SECURITY_TEXT_MAX]u8 = undefined;
            widths.securities[index] = panel_chrome.textWidth(dc, text_mod.securityText(&buffer, universe.systemInfo(node.system).security_tenths));
        }
        for (self.state.layout.exits[0..self.state.layout.exit_count], widths.exits[0..self.state.layout.exit_count]) |exit, *width| {
            width.* = panel_chrome.textWidth(dc, text_mod.exitLabel(exit).slice());
        }
    }

    fn ensureOverview(self: *MapPanelWindow, dc: win32.HDC, areas: look.Areas, fonts: ?MapFonts) void {
        var hasher = std.hash.Wyhash.init(3);
        self.hashAreaAndFonts(&hasher);
        const signature = hasher.final();
        if (self.state.overview_signature == signature) return;
        self.state.overview_signature = signature;
        self.state.overview.build(areas.map);

        const loaded = fonts orelse return;
        _ = win32.SelectObject(dc, loaded.label_font);
        var widths: [universe.REGION_COUNT]i32 = undefined;
        for (&widths, 0..) |*width, index| width.* = panel_chrome.textWidth(dc, universe.regionName(@intCast(index)));
        self.state.overview.placeLabels(&widths, loaded.label_height);
    }

    fn ensureLayout(self: *MapPanelWindow, dc: win32.HDC, areas: look.Areas, fonts: ?MapFonts) void {
        const signature = self.layoutSignature();
        if (self.state.layout_signature == signature) return;
        self.state.layout_signature = signature;
        self.state.layout.build(self.state.regions, areas.map);

        const loaded = fonts orelse return;
        _ = win32.SelectObject(dc, loaded.label_font);
        self.measureLabels(dc);
        var node_widths: [layout.MAX_NODES]i32 = undefined;
        for (node_widths[0..self.state.layout.node_count], 0..) |*width, index| width.* = self.labelWidthAt(index);
        self.state.layout.placeLabels(&node_widths, &self.state.label_widths.exits, loaded.label_height, look.labelClearance(self.state.layout.view.zoom));

        _ = win32.SelectObject(dc, loaded.title_font);
        var region_widths: [layout.MAX_REGIONS]i32 = undefined;
        for (self.state.layout.regions.slice(), region_widths[0..self.state.layout.regions.count]) |region, *width| width.* = panel_chrome.textWidth(dc, universe.regionName(region));
        self.state.layout.placeRegionLabels(&region_widths, loaded.title_height);
    }

    /// Null if a font couldn't be created, which leaves the panel without text.
    fn mapFonts(self: *const MapPanelWindow, dc: win32.HDC) ?MapFonts {
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
        const map_settings = &self.config.mapPanel;
        self.panel.followSize(map_settings.width + sidebarWidth(&self.config.intelPanel, self.intel_history), map_settings.height);
        self.panel.followTopmost(map_settings.alwaysOnTop);
        try panel_chrome.ensureFonts(&self.panel, &self.config.historyPanel);
        try self.label_font.ensure(self.panel.allocator, "Map Panel labels", map_settings.fontName, map_settings.fontSize, map_settings.fontWeight);
        try self.title_font.ensure(self.panel.allocator, "Map Panel title", map_settings.fontName, look.TITLE_FONT_SIZE, .Bold);

        self.updateMarks(scene);
        self.followActive();
        const now_ms = win32.Ticks.now().ms;
        var entry_buf: [history.CAPACITY]history.Entry = undefined;
        const intel_entries = self.intelEntries(&entry_buf);
        const signature = self.computeRenderSignature(scene, now_ms, intel_entries);
        if (self.panel.isUnchanged(signature)) return;

        self.last_frame_us = win32.microsecondsNow();
        const panel_width: i32 = @max(1, self.panel.width);
        const panel_height: i32 = @max(1, self.panel.height);
        const bitmap = try self.panel.beginFrameFilled(panel_width, panel_height, look.BACKGROUND);
        const dc = bitmap.mem_dc;
        const sizes = look.metrics(&self.config.historyPanel);
        const areas = self.currentAreas();

        const old_font = panel_chrome.selectFont(&self.panel, dc);
        defer panel_chrome.restoreFont(dc, old_font);
        const fonts = self.mapFonts(dc);
        self.ensureLayout(dc, areas, fonts);
        if (self.state.is_picking_region) self.ensureOverview(dc, areas, fonts);
        self.updateTitle(scene, now_ms);

        const painter: paint.Painter = .{
            .state = &self.state,
            .config = self.config,
            .areas = areas,
            .sizes = sizes,
            .has_eve_stars = self.hasEveStars(),
            .menu = if (self.state.menu) |*menu| .{ .menu = menu, .context = self.menuContext(scene.destinations, menu.system) } else null,
            .panel_height = self.panel.height,
            .allocator = self.panel.allocator,
        };
        painter.draw(bitmap, scene, fonts, intel_entries, now_ms, .{ .intel_rows = &self.state.intel_rows, .intel_row_count = &self.state.intel_row_count, .popup = &self.state.popup });

        self.panel.present(map_settings.opacity, signature);
    }

    fn updateTitle(self: *MapPanelWindow, scene: Scene, now_ms: u64) void {
        var age_buf: [panel_look.TIME_TEXT_MAX]u8 = undefined;
        const regions = text_mod.regionsTitle(self.state.regions.slice());
        const system_count = self.state.layout.node_count;
        const text: FixedText = if (scene.stats) |stats|
            .print("{s} - {d} systems - Stats {s}", .{ regions.slice(), system_count, panel_look.relativeTime(&age_buf, now_ms -| stats.fetched_ms) })
        else
            .print("{s} - {d} systems", .{ regions.slice(), system_count });
        var title_buf: [panel_chrome.MAX_TEXT_LENGTH:0]u8 = undefined;
        @memcpy(title_buf[0..text.length], text.slice());
        title_buf[text.length] = 0;
        const title = title_buf[0..text.length :0];
        const title_hash = std.hash.Wyhash.hash(0, title);
        if (title_hash == self.title_hash) return;
        self.title_hash = title_hash;
        _ = win32.SetWindowTextA(self.panel.hwnd, title);
    }
};

/// Zero while the Intel Panel isn't inside the map.
fn sidebarWidth(intel_settings: *const config_mod.IntelPanelConfig, intel_history: ?*const history.NotificationHistory) i32 {
    const is_inside = intel_settings.show and intel_settings.attached and intel_history != null;
    return if (is_inside) intel_settings.width else 0;
}

fn regionFromSettings(region_id: u32) RegionIndex {
    return universe.findRegionById(region_id) orelse universe.findRegionById(DEFAULT_REGION_ID) orelse 0;
}

/// A saved region the map no longer has is left out, and a lost first one becomes The Forge.
fn regionsFromSettings(map_settings: *const config_mod.MapPanelConfig) Regions {
    const ids = savedRegionIds(map_settings);
    var regions: Regions = .one(regionFromSettings(ids[0]));
    for (ids[1..]) |id| {
        const region = universe.findRegionById(id) orelse continue;
        // A duplicate is dropped.
        _ = regions.add(region);
    }
    return regions;
}

fn savedRegionIds(map_settings: *const config_mod.MapPanelConfig) [layout.MAX_REGIONS]u32 {
    comptime std.debug.assert(layout.MAX_REGIONS == 4);
    return .{ map_settings.regionId, map_settings.extraRegionId1, map_settings.extraRegionId2, map_settings.extraRegionId3 };
}

/// 0 past the regions shown, as the settings save it.
fn regionIds(regions: *const Regions) [layout.MAX_REGIONS]u32 {
    var ids: [layout.MAX_REGIONS]u32 = @splat(0);
    for (regions.slice(), ids[0..regions.count]) |region, *id| id.* = universe.regionId(region);
    return ids;
}

/// One refresh of the screen `hwnd` is on.
fn frameIntervalOf(hwnd: win32.HWND) u64 {
    const dc = win32.GetDC(hwnd) orelse {
        slog.warn("Failed to read the screen's refresh rate, so the map assumes {d} Hz", .{FALLBACK_REFRESH_HZ});
        return std.time.us_per_s / FALLBACK_REFRESH_HZ;
    };
    defer _ = win32.ReleaseDC(hwnd, dc);
    const rate = win32.GetDeviceCaps(dc, win32.VREFRESH);
    // 0 and 1 stand for the hardware's default rate.
    const hz: u64 = if (rate > 1) @intCast(rate) else FALLBACK_REFRESH_HZ;
    return std.time.us_per_s / hz;
}
