//! The Map Panel's window: its settings, the regions it shows, and drawing each frame.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const gdi_overlay = @import("../../platform/gdi_overlay.zig");
const panel_window = @import("../../platform/panel_window.zig");
const config_mod = @import("../../config.zig");
const history = @import("../../notifications/history.zig");
const history_rows = @import("../history_rows.zig");
const list_look = @import("../list_look.zig");
const destinations_mod = @import("destinations.zig");
const look = @import("look.zig");
const menu_mod = @import("menu.zig");
const paint = @import("paint.zig");
const state_mod = @import("state.zig");
const text_mod = @import("text.zig");
const panel_chrome = @import("../panel_chrome.zig");
const panel_host = @import("../panel_host.zig");
const panel_lifecycle = @import("../panel_lifecycle.zig");
const panel_look = @import("../panel_look.zig");
const palette = @import("../palette.zig");
const universe = @import("../../map/universe.zig");
const layout = @import("../../map/layout.zig");
const campaigns_mod = @import("../../map/campaigns.zig");
const timer_list = @import("timer_list.zig");
const wormhole_list = @import("wormhole_list.zig");
const wormholes = @import("../../map/wormholes.zig");
const scout = @import("../../clients/scout.zig");
const fixed_text = @import("../../util/fixed_text.zig");
const log = @import("../../log.zig");

const Box = layout.Box;
const Campaigns = campaigns_mod.Campaigns;
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
    /// For the regions' names beside each region on the map.
    title_font: gdi_overlay.CachedFont = .{},
    /// The cards' and controls' text, in the configuration window's font so they match it.
    ui_font: gdi_overlay.CachedFont = .{},
    ui_small_font: gdi_overlay.CachedFont = .{},
    /// A picked segment's label and the cards' headings.
    ui_semibold_font: gdi_overlay.CachedFont = .{},
    /// The title card's heading.
    ui_heading_font: gdi_overlay.CachedFont = .{},
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
    /// The panel's ripple timer is running.
    is_rippling: bool = false,
    /// The title bar's text, to set it only when it changes.
    title_hash: u64 = 0,
    /// One refresh of the screen the window is on; a moving map draws no more often, as the screen can't show it.
    frame_interval_us: u64,
    /// When the last frame started drawing.
    last_frame_us: u64 = 0,

    /// `class_name` must already be registered.
    pub fn init(context: panel_host.Context, class_name: [*:0]const u8, intel_history: ?*const history.NotificationHistory, global: ?*const GlobalConfig) !MapPanelWindow {
        const map_settings = &context.store.live.mapPanel;
        const panel = try PanelWindow.initNative(context.allocator, context.instance, class_name, "EVE Map", panel_lifecycle.windowRect(map_settings), map_settings.alwaysOnTop);
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
        self.ui_font.deinit(self.panel.allocator);
        self.ui_small_font.deinit(self.panel.allocator);
        self.ui_semibold_font.deinit(self.panel.allocator);
        self.ui_heading_font.deinit(self.panel.allocator);
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
        self.store.update(.{ .mapPanel = .{ .width = self.panel.width, .height = self.panel.height } });
        if (!map_settings.rememberPosition) return;
        const top_left = self.panel.topLeft() orelse return;
        self.store.update(.{ .mapPanel = .{ .x = top_left.x, .y = top_left.y } });
    }

    /// Picked by the user, so it's what the panel reopens on.
    pub fn chooseRegion(self: *MapPanelWindow, region: RegionIndex) void {
        self.chooseRegions(.one(region));
    }

    /// Picked by the user, so they're what the panel reopens on.
    pub fn chooseRegions(self: *MapPanelWindow, regions: Regions) void {
        self.state.showRegions(regions);
        self.saveRegions();
    }

    /// Ctrl-clicked in New Eden: adds `region` to what it will show, or takes it out, down to none.
    pub fn toggleChosenRegion(self: *MapPanelWindow, destinations: *Destinations, region: RegionIndex) void {
        var chosen = self.state.chosen_regions orelse self.state.regions;
        switch (chosen.toggle(region)) {
            .added, .removed => {},
            .replaced => |dropped| showDropped(destinations, dropped),
            .last => chosen = .{},
        }
        self.state.chosen_regions = chosen;
        self.state.is_choosing_regions = true;
    }

    /// Adds `region` beside those shown, or takes it out; whether the map changed.
    pub fn toggleRegion(self: *MapPanelWindow, destinations: *Destinations, region: RegionIndex) bool {
        var regions = self.state.regions;
        switch (regions.toggle(region)) {
            .added, .removed => {},
            .replaced => |dropped| showDropped(destinations, dropped),
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
        const intel_settings = &self.config.intelPanel;
        return intel_settings.show and intel_settings.attached and self.intel_history != null;
    }

    /// The Intel card shows intel inside the map, kills, or both under tabs.
    fn hasSideCard(self: *const MapPanelWindow) bool {
        return self.isIntelInside() or self.config.mapPanel.showKills;
    }

    /// The tab picked, or the only one that can show.
    fn shownTab(self: *const MapPanelWindow) look.CardTab {
        if (!self.isIntelInside()) return .kills;
        if (!self.config.mapPanel.showKills) return .intel;
        return self.state.card_tab;
    }

    /// Stops the window being dragged smaller than the settings allow.
    pub fn limitSize(_: *const MapPanelWindow, limits: *win32.MINMAXINFO) void {
        const outer = PanelWindow.outerSize(config_mod.MapPanelConfig.MIN_WIDTH, config_mod.MapPanelConfig.MIN_HEIGHT);
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

    /// Lists the rows that fit into the state's intel_rows or kill_rows, once this render has measured the chrome; null with nothing to list; leaves `dc` holding the chrome's name font.
    fn placeIntelCard(self: *MapPanelWindow, dc: win32.HDC, areas: look.Areas, fonts: MapFonts, entries: []const history.Entry, scene: Scene) ?look.IntelCard {
        if (!self.hasSideCard()) return null;
        const header_height = look.intelHeaderHeight(areas.card_height);
        const row_height = look.intelRowHeight(fonts.chrome.name_height);
        const top = areas.intelTop();
        const column_bottom = self.timerColumnBottom(areas, fonts);
        // Half the column while the wormhole card shares it.
        const bottom = if (self.showsWormholeCard()) top + @divTrunc(column_bottom - top, 2) else column_bottom;
        const capacity = look.IntelCard.capacity(top, bottom, header_height, row_height);
        const tab = self.shownTab();
        const row_count = switch (tab) {
            .intel => blk: {
                self.state.intel_row_count = history_rows.build(&self.state.intel_rows, entries, capacity, history_rows.buildOptions(&self.config.historyPanel, null));
                break :blk self.state.intel_row_count;
            },
            .kills => self.listKills(scene, capacity),
        };
        var card: look.IntelCard = .init(areas, top, header_height, row_height, row_count, self.state.is_intel_collapsed);
        card.tab = tab;
        if (self.isIntelInside() and self.config.mapPanel.showKills) {
            var left = card.header.left + look.INTEL_PADDING_X;
            for (std.enums.values(look.CardTab), &card.tabs) |each, *box| {
                _ = win32.SelectObject(dc, if (each == tab) fonts.semibold_font else fonts.chrome.name_font);
                const width = panel_chrome.textWidth(dc, paint.cardTabName(each));
                box.* = .{ .left = left, .top = card.header.top, .right = left + width, .bottom = card.header.bottom };
                left += width + look.CARD_TAB_GAP;
            }
            _ = win32.SelectObject(dc, fonts.chrome.name_font);
        }
        return card;
    }

    /// Below the Intel card, or in its place, down to the sov timer card or the map controls; lists the picked hub's connections, kept scrolled inside the list; leaves `dc` holding the chrome's name font.
    fn placeWormholeCard(self: *MapPanelWindow, dc: win32.HDC, areas: look.Areas, fonts: MapFonts, scene: Scene) ?look.ListCard {
        if (!self.showsWormholeCard()) return null;
        const hub = self.state.wormhole_hub;
        self.state.wormhole_entry_count = if (paint.shownWormholes(self.config, scene)) |connections| wormhole_list.build(connections, hub, &self.state.wormhole_entries).len else 0;
        const top = if (self.state.intel_card) |*intel| intel.box.bottom + look.CARD_GAP else areas.intelTop();
        const row_height = look.listRowHeight(fonts.chrome.name_height);
        const bottom = self.timerColumnBottom(areas, fonts);
        const probe: look.ListCard = .init(areas, top, bottom, look.intelHeaderHeight(areas.card_height), row_height, 0, true);
        self.state.wormhole_scroll = @min(self.state.wormhole_scroll, wormhole_list.maxScroll(self.state.wormhole_entry_count, probe.visible_count));
        const shown_count = self.state.wormhole_entry_count - self.state.wormhole_scroll;
        var card: look.ListCard = .init(areas, top, bottom, look.intelHeaderHeight(areas.card_height), row_height, shown_count, self.state.is_wormholes_collapsed);
        var left = card.header.left + look.INTEL_PADDING_X;
        for (std.enums.values(wormholes.Hub), &card.tabs) |each, *box| {
            _ = win32.SelectObject(dc, if (each == hub) fonts.semibold_font else fonts.chrome.name_font);
            const width = panel_chrome.textWidth(dc, text_mod.hubName(each));
            box.* = .{ .left = left, .top = card.header.top, .right = left + width, .bottom = card.header.bottom };
            left += width + look.CARD_TAB_GAP;
        }
        _ = win32.SelectObject(dc, fonts.chrome.name_font);
        return card;
    }

    /// While Thera and Turnur show and are fetched.
    pub fn showsWormholeCard(self: *const MapPanelWindow) bool {
        return self.config.mapPanel.showWormholes and self.config.mapPanel.liveStats;
    }

    /// A running sov timer is listed, so its scores are worth fetching live; from the last render's list.
    pub fn listsRunningTimer(self: *const MapPanelWindow, campaigns: *const Campaigns, now_seconds: i64) bool {
        for (self.state.timer_entries[0..self.state.timer_entry_count]) |entry| {
            if (entry.index < campaigns.count and campaigns.campaigns[entry.index].hasStarted(now_seconds)) return true;
        }
        return false;
    }

    /// While a region shown has a sov timer, after listTimers.
    fn showsTimerCard(self: *const MapPanelWindow) bool {
        return self.state.timer_entry_count > 0;
    }

    /// The shown regions' sov timers into timer_entries, none over New Eden; before the areas are measured, as the card shows only with one.
    fn listTimers(self: *MapPanelWindow, scene: Scene) void {
        const campaigns = if (self.state.is_picking_region) null else paint.shownCampaigns(self.config, scene);
        const shown = campaigns orelse {
            self.state.timer_entry_count = 0;
            return;
        };
        self.state.timer_entry_count = timer_list.build(shown, self.state.regions, &self.state.timer_entries).len;
    }

    /// Where the cards above the sov timer card end, leaving it its rows, up to half the column.
    fn timerColumnBottom(self: *const MapPanelWindow, areas: look.Areas, fonts: MapFonts) i32 {
        if (!self.showsTimerCard()) return areas.sideBottom();
        const header_height = look.intelHeaderHeight(areas.card_height);
        const row_height = look.listRowHeight(fonts.chrome.name_height);
        const half_rows: usize = @intCast(@max(1, @divTrunc(@divTrunc(areas.sideBottom() - areas.intelTop(), 2) - header_height, row_height)));
        const row_count: i32 = if (self.state.is_timers_collapsed) 0 else @intCast(@min(self.state.timer_entry_count, half_rows));
        return areas.sideBottom() - header_height - row_count * row_height - look.CARD_GAP;
    }

    /// At the foot of the right column, under the other cards.
    fn placeTimerCard(self: *const MapPanelWindow, areas: look.Areas, fonts: MapFonts) ?look.ListCard {
        if (!self.showsTimerCard()) return null;
        const above = if (self.state.wormhole_card) |*card| card.box else if (self.state.intel_card) |*card| card.box else null;
        const top = if (above) |box| box.bottom + look.CARD_GAP else areas.intelTop();
        return .init(areas, top, areas.sideBottom(), look.intelHeaderHeight(areas.card_height), look.listRowHeight(fonts.chrome.name_height), self.state.timer_entry_count, self.state.is_timers_collapsed);
    }

    /// The newest kills in the regions shown, up to `capacity`, into kill_rows; returns how many.
    fn listKills(self: *MapPanelWindow, scene: Scene, capacity: usize) usize {
        const kills = scene.kills orelse return 0;
        var count: usize = 0;
        for (0..kills.count) |index| {
            if (count == capacity) break;
            const kill = kills.fromNewest(index);
            if (!self.state.regions.contains(universe.systemInfo(kill.system).region)) continue;
            self.state.kill_rows[count] = kill.*;
            count += 1;
        }
        self.state.kill_row_count = count;
        return count;
    }

    pub fn currentAreas(self: *const MapPanelWindow) look.Areas {
        return .init(self.panel.width, self.panel.height, palette.CONTROL_HEIGHT, self.hasSideCard() or self.showsWormholeCard() or self.showsTimerCard());
    }

    /// A new pin's ripple is playing in a shown region, or a search ping's, which wants frames faster than the tick.
    pub fn hasRipple(self: *const MapPanelWindow, scene: paint.Scene, now_ms: u64) bool {
        if (self.state.ping) |ping| {
            if (look.rippleAt(now_ms -| ping.started_ms) != null) return true;
        }
        for (&scene.pins.pins) |*pin| {
            if (pin.seen_ms == 0 or look.rippleAt(now_ms -| pin.seen_ms) == null) continue;
            if (self.state.regions.contains(universe.systemInfo(pin.system).region)) return true;
        }
        const kills = scene.kills orelse return false;
        // Newest first, so the first too old to ripple ends the search.
        for (0..kills.count) |index| {
            const kill = kills.fromNewest(index);
            if (look.rippleAt(now_ms -| kill.seen_ms) == null) break;
            if (self.state.regions.contains(universe.systemInfo(kill.system).region)) return true;
        }
        return false;
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
        for (look.LAYER_ORDER) |layer| hasher.update(std.mem.asBytes(&look.isLayerShown(map_settings, layer)));
        // An empty Intel card changes nothing else, so it would wait for the age bucket.
        hasher.update(std.mem.asBytes(&self.isIntelInside()));
        hasher.update(std.mem.asBytes(&self.hasSideCard()));
        if (scene.kills) |kills| hasher.update(std.mem.asBytes(&kills.revision));
        hasher.update(std.mem.asBytes(&self.config.accentColor));
        hasher.update(std.mem.asBytes(&self.config.listView.activeColor));
        hasher.update(std.mem.asBytes(&map_settings.alwaysOnTop));
        hasher.update(std.mem.asBytes(&map_settings.routePreference));
        hasher.update(std.mem.asBytes(&map_settings.routeAnsiblex));
        hasher.update(std.mem.asBytes(&map_settings.routeEveryWaypoint));
        self.state.hash(&hasher);
        hasher.update(std.mem.asBytes(&self.hasEveStars()));
        hasher.update(std.mem.asBytes(&scene.destinations.revision));
        hasher.update(std.mem.sliceAsBytes(self.config.avoidedSystems.items));
        if (scene.stats) |stats| {
            hasher.update(std.mem.asBytes(&stats.fetched_ms));
            hasher.update(std.mem.asBytes(&stats.campaigns_revision));
        }
        hasher.update(std.mem.asBytes(&scene.logo_revision));
        hasher.update(std.mem.asBytes(&scene.pins.revision));
        // Each minute while timers or kills show, for their countdowns, ages and fading.
        if (paint.shownCampaigns(self.config, scene) != null or scene.kills != null) hasher.update(std.mem.asBytes(&@divFloor(scene.now_seconds, std.time.s_per_min)));
        const lifetime_ms = map_settings.intelShrinkMs();
        const halo_scale = look.markerScale(self.state.layout.view.zoom);
        // By whole pixels, so a shrinking halo redraws only when it can show.
        for (&scene.pins.pins) |*pin| {
            if (!pin.isLive(lifetime_ms, now_ms) or !self.state.regions.contains(universe.systemInfo(pin.system).region)) continue;
            const halo_radius: i32 = @intFromFloat(paint.intelHaloRadius(map_settings, pin, halo_scale, now_ms));
            hasher.update(std.mem.asBytes(&halo_radius));
            if (look.rippleAt(now_ms -| pin.seen_ms)) |ripple| hashRipple(&hasher, ripple, halo_scale);
        }
        if (self.state.ping) |ping| {
            if (look.rippleAt(now_ms -| ping.started_ms)) |ripple| hashRipple(&hasher, ripple, halo_scale);
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
        hasher.update(map_settings.fontName);
        hasher.update(std.mem.asBytes(&map_settings.fontSize));
        hasher.update(std.mem.asBytes(&map_settings.fontWeight));
    }

    /// The label width of the node at `index` in `layout`, with its security once zoomed in enough; a sov timer goes on the line below.
    fn labelWidthAt(self: *const MapPanelWindow, index: usize, has_timer: bool) i32 {
        const widths = &self.state.label_widths;
        var width = widths.names[index];
        if (look.showsSecurityLabel(self.state.layout.view.zoom)) width += look.LABEL_SUFFIX_GAP + widths.securities[index];
        return if (has_timer) @max(width, widths.timer) else width;
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
        widths.timer = 0;
        for (text_mod.TIMER_TEXT_SAMPLES) |sample| widths.timer = @max(widths.timer, panel_chrome.textWidth(dc, sample));
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

    fn ensureLayout(self: *MapPanelWindow, areas: look.Areas) void {
        const signature = self.layoutSignature();
        if (self.state.layout_signature == signature) return;
        self.state.layout_signature = signature;
        self.state.layout.build(self.state.regions, areas.map);
        self.state.labels_signature = null;
    }

    /// After `layout` is built, as a build drops them; only when it or the connections shown change, as setting them drops their names; an Ansiblex gate with both ends shown is drawn across the map instead.
    fn ensurePortals(self: *MapPanelWindow, scene: Scene) void {
        const map_layout = &self.state.layout;
        var ends: [layout.MAX_PORTALS]layout.PortalEnd = undefined;
        var end_count: usize = 0;
        if (paint.shownWormholes(self.config, scene)) |connections| {
            for (connections.slice()) |connection| {
                if (end_count == ends.len) break;
                if (map_layout.nodeOf(connection.system) == null) continue;
                ends[end_count] = .{ .system = connection.system, .target = .{ .hub = connection.hub } };
                end_count += 1;
            }
        }
        if (paint.shownBridges(self.config, self.hasEveStars(), scene)) |bridges| {
            for (bridges.slice()) |bridge| {
                if (end_count == ends.len) break;
                if (map_layout.nodeOf(bridge.from) == null or map_layout.nodeOf(bridge.to) != null) continue;
                ends[end_count] = .{ .system = bridge.from, .target = .{ .system = bridge.to } };
                end_count += 1;
            }
        }
        var hasher = std.hash.Wyhash.init(6);
        hasher.update(std.mem.asBytes(&self.state.layout_signature));
        for (ends[0..end_count]) |end| {
            hasher.update(std.mem.asBytes(&end.system));
            hasher.update(std.mem.asBytes(&end.target.key()));
        }
        const signature = hasher.final();
        if (self.state.portals_signature == signature) return;
        self.state.portals_signature = signature;
        self.state.layout.setPortals(ends[0..end_count]);
        self.state.labels_signature = null;
    }

    /// After `layout` is built and what floats over the map is measured, as the names keep clear of `covered`; a name makes room for its sov timer while `campaigns` show.
    fn ensureLabels(self: *MapPanelWindow, dc: win32.HDC, areas: look.Areas, fonts: ?MapFonts, covered: []const Box, campaigns: ?*const Campaigns) void {
        const loaded = fonts orelse return;
        const node_count = self.state.layout.node_count;
        var has_timer: [layout.MAX_NODES]bool = @splat(false);
        if (campaigns) |shown| {
            for (self.state.layout.nodes[0..node_count], has_timer[0..node_count]) |node, *is_timed| is_timed.* = shown.soonestIn(node.system) != null;
        }
        var hasher = std.hash.Wyhash.init(5);
        hasher.update(std.mem.asBytes(&self.state.layout_signature));
        hasher.update(std.mem.sliceAsBytes(covered));
        hasher.update(std.mem.sliceAsBytes(has_timer[0..node_count]));
        const signature = hasher.final();
        if (self.state.labels_signature == signature) return;
        self.state.labels_signature = signature;

        const old_font = win32.SelectObject(dc, loaded.label_font);
        defer if (old_font) |font| {
            _ = win32.SelectObject(dc, font);
        };
        self.measureLabels(dc);
        var node_widths: [layout.MAX_NODES]i32 = undefined;
        for (node_widths[0..node_count], has_timer[0..node_count], 0..) |*width, is_timed, index| width.* = self.labelWidthAt(index, is_timed);
        var node_shapes: [layout.MAX_NODES]layout.LabelShape = @splat(.{});
        const timer_shape: layout.LabelShape = .{ .line_count = 2, .clearance = look.timerLabelClearance(self.state.layout.view.zoom) };
        for (node_shapes[0..node_count], has_timer[0..node_count]) |*shape, is_timed| {
            if (is_timed) shape.* = timer_shape;
        }
        var portal_widths: [layout.MAX_PORTALS]i32 = undefined;
        for (self.state.layout.portals[0..self.state.layout.portal_count], portal_widths[0..self.state.layout.portal_count]) |portal, *width| width.* = panel_chrome.textWidth(dc, text_mod.portalLabel(portal.target));
        self.state.layout.placeLabels(areas.body, covered, &node_widths, node_shapes[0..node_count], &self.state.label_widths.exits, &portal_widths, loaded.label_height, look.labelClearance(self.state.layout.view.zoom));

        _ = win32.SelectObject(dc, loaded.title_font);
        var region_widths: [layout.MAX_REGIONS]i32 = undefined;
        for (self.state.layout.regions.slice(), region_widths[0..self.state.layout.regions.count]) |region, *width| width.* = panel_chrome.textWidth(dc, universe.regionName(region));
        self.state.layout.placeRegionLabels(areas.body, covered, &region_widths, loaded.title_height);
    }

    /// The cards, bars and controls over the map, once this render has measured them; `buffer` holds what's returned.
    fn coveredBoxes(self: *const MapPanelWindow, painter: *const paint.Painter, dc: win32.HDC, scene: Scene, fonts: ?MapFonts, buffer: *[layout.MAX_COVERED]Box) []const Box {
        const chrome = &self.state.chrome;
        const areas = painter.areas;
        const fixed = [_]Box{ chrome.title, chrome.metric_bar, chrome.toggle_bar, areas.search_box, areas.mapControlBox(.always_on_top), areas.zoomStack() };
        // The Intel card, the wormhole card, the sov timer card and the legends' card come after these.
        comptime std.debug.assert(fixed.len + 4 <= layout.MAX_COVERED);
        @memcpy(buffer[0..fixed.len], &fixed);
        var count: usize = fixed.len;
        if (self.state.intel_card) |*card| {
            buffer[count] = card.box;
            count += 1;
        }
        if (self.state.wormhole_card) |*card| {
            buffer[count] = card.box;
            count += 1;
        }
        if (self.state.timer_card) |*card| {
            buffer[count] = card.box;
            count += 1;
        }
        const loaded = fonts orelse return buffer[0..count];
        if (painter.legendCard(dc, scene, loaded.chrome)) |card| {
            buffer[count] = card;
            count += 1;
        }
        return buffer[0..count];
    }

    /// Null if a font couldn't be created, which leaves the panel without text.
    fn mapFonts(self: *const MapPanelWindow, dc: win32.HDC) ?MapFonts {
        const name_font = self.ui_font.handle orelse return null;
        const small_font = self.ui_small_font.handle orelse return null;
        const semibold_font = self.ui_semibold_font.handle orelse return null;
        const heading_font = self.ui_heading_font.handle orelse return null;
        const label_font = self.label_font.handle orelse return null;
        const title_font = self.title_font.handle orelse return null;
        _ = win32.SelectObject(dc, small_font);
        const small_height = panel_chrome.lineHeight(dc);
        _ = win32.SelectObject(dc, heading_font);
        const heading_height = panel_chrome.lineHeight(dc);
        _ = win32.SelectObject(dc, title_font);
        const title_height = panel_chrome.lineHeight(dc);
        _ = win32.SelectObject(dc, name_font);
        const chrome: panel_chrome.Text = .{ .name_font = name_font, .small_font = small_font, .name_height = panel_chrome.lineHeight(dc), .small_height = small_height };
        _ = win32.SelectObject(dc, label_font);
        return .{
            .chrome = chrome,
            .semibold_font = semibold_font,
            .heading_font = heading_font,
            .heading_height = heading_height,
            .label_font = label_font,
            .label_height = panel_chrome.lineHeight(dc),
            .title_font = title_font,
            .title_height = title_height,
        };
    }

    /// Called every tick, and on hover; redraws only when the render signature changed.
    pub fn render(self: *MapPanelWindow, scene: Scene) !void {
        const map_settings = &self.config.mapPanel;
        self.panel.followSize(map_settings.width, map_settings.height);
        self.panel.followTopmost(map_settings.alwaysOnTop);
        try panel_chrome.ensureFonts(&self.panel, &self.config.historyPanel);
        try self.label_font.ensure(self.panel.allocator, "Map Panel labels", map_settings.fontName, map_settings.fontSize, map_settings.fontWeight);
        try self.title_font.ensure(self.panel.allocator, "Map Panel title", map_settings.fontName, look.TITLE_FONT_SIZE, .Bold);
        try self.ui_font.ensure(self.panel.allocator, "Map Panel text", palette.FACE, palette.FONT_SIZE, .Regular);
        try self.ui_small_font.ensure(self.panel.allocator, "Map Panel small text", palette.FACE, palette.SMALL_FONT_SIZE, .Regular);
        try self.ui_semibold_font.ensure(self.panel.allocator, "Map Panel semibold text", palette.SEMIBOLD_FACE, palette.FONT_SIZE, .Regular);
        try self.ui_heading_font.ensure(self.panel.allocator, "Map Panel heading", palette.SEMIBOLD_FACE, look.TITLE_FONT_SIZE, .Regular);

        self.updateMarks(scene);
        self.followActive();
        self.listTimers(scene);
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
        const areas = self.currentAreas();

        const old_font = panel_chrome.selectFont(&self.panel, dc);
        defer panel_chrome.restoreFont(dc, old_font);
        const fonts = self.mapFonts(dc);
        self.ensureLayout(areas);
        self.ensurePortals(scene);
        if (self.state.is_picking_region) self.ensureOverview(dc, areas, fonts);
        self.updateTitle(scene, now_ms);
        const painter: paint.Painter = .{
            .state = &self.state,
            .config = self.config,
            .areas = areas,
            .has_eve_stars = self.hasEveStars(),
            .menu = if (self.state.menu) |*menu| .{ .menu = menu, .context = self.menuContext(scene.destinations, menu.system) } else null,
            .allocator = self.panel.allocator,
        };
        const title = paint.titleText(&self.state);
        if (fonts) |loaded| self.state.chrome = measureChrome(dc, loaded, areas, title.slice(), painter.legendCardWidth(dc, scene, loaded.chrome));
        self.state.intel_card = if (fonts) |loaded| self.placeIntelCard(dc, areas, loaded, intel_entries, scene) else null;
        self.state.wormhole_card = if (fonts) |loaded| self.placeWormholeCard(dc, areas, loaded, scene) else null;
        self.state.timer_card = if (fonts) |loaded| self.placeTimerCard(areas, loaded) else null;
        var covered_buffer: [layout.MAX_COVERED]Box = undefined;
        self.ensureLabels(dc, areas, fonts, self.coveredBoxes(&painter, dc, scene, fonts, &covered_buffer), paint.shownCampaigns(self.config, scene));
        painter.draw(bitmap, scene, fonts, intel_entries, now_ms, .{ .popup = &self.state.popup, .search_stops = &self.state.search_stops });

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

/// By whole pixels, so a ripple redraws only when it can show.
fn hashRipple(hasher: *std.hash.Wyhash, ripple: look.Ripple, scale: f32) void {
    const ripple_radius: i32 = @intFromFloat(ripple.radius * scale);
    hasher.update(std.mem.asBytes(&ripple_radius));
    hasher.update(std.mem.asBytes(&ripple.alpha));
}

/// `legend_width` is the legends' card's, so the toggle bar can keep clear of it; leaves `dc` holding the chrome's name font.
fn measureChrome(dc: win32.HDC, fonts: MapFonts, areas: look.Areas, title: []const u8, legend_width: i32) look.Chrome {
    var text: look.ChromeText = undefined;
    text.legend_width = legend_width;
    _ = win32.SelectObject(dc, fonts.heading_font);
    text.title_width = panel_chrome.textWidth(dc, title);
    text.title_height = fonts.heading_height;
    // Semibold, the picked segment's font and the wider of the two, and each segment's widest label, so picking one doesn't resize the bar.
    _ = win32.SelectObject(dc, fonts.semibold_font);
    for (look.SEGMENT_ORDER, &text.metric_widths) |segment, *width| {
        width.* = 0;
        for (look.segmentMetrics(segment)) |metric| width.* = @max(width.*, panel_chrome.textWidth(dc, text_mod.metricLabel(metric)));
    }
    _ = win32.SelectObject(dc, fonts.chrome.name_font);
    for (look.TOGGLE_ORDER, &text.toggle_widths) |toggle, *width| width.* = panel_chrome.textWidth(dc, text_mod.toggleLabel(toggle));
    return .init(areas, text);
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

fn showDropped(destinations: *Destinations, dropped: RegionIndex) void {
    destinations.showInfo(.print("Dropped {s}: the map shows {d} regions at most", .{ universe.regionName(dropped), layout.MAX_REGIONS }), win32.Ticks.now().ms);
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
