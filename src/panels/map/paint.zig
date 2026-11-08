//! Draws the Map Panel's frame from what it shows; nothing here changes the map's state.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const gdi_overlay = @import("../../platform/gdi_overlay.zig");
const config_mod = @import("../../config.zig");
const types = @import("../../config/types.zig");
const history = @import("../../notifications/history.zig");
const history_rows = @import("../history_rows.zig");
const list_look = @import("../list_look.zig");
const destinations_mod = @import("destinations.zig");
const look = @import("look.zig");
const marks = @import("marks.zig");
const menu_mod = @import("menu.zig");
const search = @import("search.zig");
const state_mod = @import("state.zig");
const text_mod = @import("text.zig");
const panel_chrome = @import("../panel_chrome.zig");
const panel_look = @import("../panel_look.zig");
const popup_look = @import("../popup_look.zig");
const popup_menu = @import("../popup_menu.zig");
const universe = @import("../../map/universe.zig");
const layout_mod = @import("../../map/layout.zig");
const stats_mod = @import("../../map/stats.zig");
const holder_colors = @import("../../map/holder_colors.zig");
const storms_mod = @import("../../map/storms.zig");
const incursions_mod = @import("../../map/incursions.zig");
const campaigns_mod = @import("../../map/campaigns.zig");
const wormholes = @import("../../map/wormholes.zig");
const faction_warfare = @import("../../map/faction_warfare.zig");
const evestars = @import("../../map/evestars.zig");
const zkill = @import("../../map/zkill.zig");
const intel_pins = @import("../../map/intel_pins.zig");
const window = @import("../../thumbnail/window.zig");
const color_mod = @import("../../util/color.zig");
const fixed_text = @import("../../util/fixed_text.zig");
const pixel_buffer = @import("../../util/pixel_buffer.zig");
const log = @import("../../log.zig");

const Box = layout_mod.Box;
const Campaigns = campaigns_mod.Campaigns;
const Bridges = evestars.Bridges;
const KillNames = zkill.Names;
const Kills = zkill.Kills;
const Connections = wormholes.Connections;
const Destinations = destinations_mod.Destinations;
const FixedText = fixed_text.FixedText;
const Incursions = incursions_mod.Incursions;
const Layout = layout_mod.Layout;
const LogoColors = holder_colors.LogoColors;
const MapMetric = types.MapMetric;
const MapState = state_mod.MapState;
const PopupRow = popup_look.PopupRow;
const RegionIndex = universe.RegionIndex;
const Snapshot = stats_mod.Snapshot;
const Storms = storms_mod.Storms;
const SystemIndex = universe.SystemIndex;
const ThumbnailWindow = window.ThumbnailWindow;
const slog = log.Scoped("map_panel");

/// The metric's or the jump range's, the storms' and the incursions'.
const MAX_LEGENDS = 3;

/// What the panel shows besides its own settings.
pub const Scene = struct {
    /// Borrowed for one render.
    thumbnails: []const ThumbnailWindow = &.{},
    active_source_hwnd: ?win32.HWND = null,
    /// Borrowed for one render.
    stats: ?*const Snapshot,
    /// Borrowed for one render; null until the first arrive.
    logo_colors: ?*const LogoColors = null,
    /// Changes with each new logo_colors, for the redraw check.
    logo_revision: u64 = 0,
    /// Borrowed for one render.
    pins: *const intel_pins.IntelPins,
    /// Borrowed for one render.
    destinations: *const Destinations,
    /// Seconds since 1970, UTC, for the sov timers' countdowns and the kills' ages.
    now_seconds: i64 = 0,
    /// Borrowed for one render; null while kills are hidden.
    kills: ?*const Kills = null,
    /// Borrowed for one render; null while kills are hidden.
    kill_names: ?*const KillNames = null,
};

/// The configuration window's fonts for the cards and controls, and the map's own for the names on it.
pub const MapFonts = struct {
    chrome: panel_chrome.Text,
    /// A picked segment's label and the cards' headings.
    semibold_font: win32.HFONT,
    /// The title card's heading.
    heading_font: win32.HFONT,
    heading_height: i32,
    label_font: win32.HFONT,
    label_height: i32,
    title_font: win32.HFONT,
    title_height: i32,
};

/// Where a tooltip's parts go, measured once so sizing and drawing agree; offsets are from its box's corner.
const TooltipShape = struct {
    size: win32.POINT,
    padding: win32.POINT,
    rows_top: i32,
    row_height: i32,
    /// From a labelled line's left to its text; 0 without labels.
    label_column: i32,
};

/// The menu, while it's open, and what its rows show.
pub const OpenMenu = struct {
    /// Borrowed for one render.
    menu: *const menu_mod.Menu,
    context: menu_mod.Context,
};

/// What a render measures for the next hit test.
pub const Measured = struct {
    /// Borrowed for one render.
    popup: *popup_menu.PopupMenu,
    /// Borrowed for one render.
    search_stops: *search.Stops,
};

/// What's measured once a frame for colouring the map.
const MapPaint = struct {
    metric: MapMetric,
    /// The busiest system shown by `metric`, which heat is measured against.
    peak: u32,
    holders: look.HolderRanks,
};

/// What follows a system's name.
const LabelSuffix = struct {
    /// Borrows from the buffer passed to labelSuffix.
    text: []const u8,
    color: u32,
};

/// How a name is lifted off the gates behind it.
const Outline = enum {
    full,
    /// Down and right only, for a drag's frames: two text calls rather than five.
    shadow,
};

/// One render's drawing.
pub const Painter = struct {
    /// Borrowed for one render.
    state: *const MapState,
    /// Borrowed for one render.
    config: *const config_mod.Config,
    areas: look.Areas,
    has_eve_stars: bool,
    /// Null while the menu's closed.
    menu: ?OpenMenu,
    /// For the storm and incursion areas' mask, freed before draw returns.
    allocator: std.mem.Allocator,

    /// With `bitmap` begun and the panel's font selected.
    pub fn draw(self: *const Painter, bitmap: *const gdi_overlay.OverlayBitmap, scene: Scene, fonts: ?MapFonts, intel_entries: []const history.Entry, now_ms: u64, measured: Measured) void {
        const dc = bitmap.mem_dc;
        const canvas = bitmap.canvas();
        const areas = self.areas;

        look.drawGrid(canvas, areas.body, if (self.state.is_picking_region) .{} else self.state.layout.view);
        const paint = self.mapPaint(scene);
        if (self.state.is_picking_region) {
            self.drawOverview(canvas, scene);
        } else {
            self.drawMap(canvas, scene, &paint, now_ms);
        }

        const loaded = fonts orelse return;
        if (self.state.is_picking_region) {
            self.drawOverviewLabels(dc, loaded.label_font);
        } else {
            self.drawRegionLabels(dc, loaded.title_font);
            self.drawLabels(dc, scene, loaded.label_font, now_ms);
            self.drawClientTags(bitmap, loaded.chrome, scene, &paint);
        }
        self.drawChrome(bitmap, loaded);
        if (self.state.intel_card) |*card| self.drawIntelCard(bitmap, loaded, card, intel_entries, scene);
        if (self.state.wormhole_card) |*card| self.drawWormholeCard(bitmap, loaded, card, scene);
        if (self.state.timer_card) |*card| self.drawTimerCard(bitmap, loaded, card, scene);
        if (!self.state.is_picking_region) {
            var legend_buffer: [MAX_LEGENDS]text_mod.Legend = undefined;
            drawLegends(bitmap, self.legends(scene, &paint, &legend_buffer), areas, loaded.chrome, self.state.chrome.bottomBars());
        }
        self.drawSearchBox(bitmap, loaded.chrome, measured.search_stops);
        self.drawTooltip(bitmap, scene, loaded, now_ms);
        self.drawPopup(bitmap, .{ .chrome = loaded.chrome, .title = loaded.semibold_font }, measured.popup);
        drawNotice(bitmap, scene.destinations, areas, self.state.chrome.toggle_bar, loaded);
    }

    /// Where the legends' card will go, so names can keep clear of it; null without one.
    pub fn legendCard(self: *const Painter, dc: win32.HDC, scene: Scene, text: panel_chrome.Text) ?Box {
        if (self.state.is_picking_region) return null;
        const paint = self.mapPaint(scene);
        var legend_buffer: [MAX_LEGENDS]text_mod.Legend = undefined;
        const card = legendBox(dc, self.legends(scene, &paint, &legend_buffer), self.areas, text, self.state.chrome.bottomBars());
        _ = win32.SelectObject(dc, text.name_font);
        return card;
    }

    /// What a centred toggle bar keeps clear of; 0 without legends.
    pub fn legendCardWidth(self: *const Painter, dc: win32.HDC, scene: Scene, text: panel_chrome.Text) i32 {
        if (self.state.is_picking_region) return 0;
        const paint = self.mapPaint(scene);
        var legend_buffer: [MAX_LEGENDS]text_mod.Legend = undefined;
        const shown = self.legends(scene, &paint, &legend_buffer);
        return if (shown.len == 0) 0 else cardWidth(dc, shown, text);
    }

    /// The metric's, or the jump range's while one shows, then any storms' and incursions'; `buffer` holds what's returned.
    fn legends(self: *const Painter, scene: Scene, paint: *const MapPaint, buffer: *[MAX_LEGENDS]text_mod.Legend) []const text_mod.Legend {
        buffer[0] = if (self.state.reach) |*reach| text_mod.rangeLegend(reach) else legendFor(scene, paint, self.state.layout.nodes[0..self.state.layout.node_count]);
        var count: usize = 1;
        if (self.stormLegend(scene)) |storm_legend| {
            buffer[count] = storm_legend;
            count += 1;
        }
        if (self.incursionLegend(scene)) |incursion_legend| {
            buffer[count] = incursion_legend;
            count += 1;
        }
        return buffer[0..count];
    }

    /// Layers is on while its menu is open.
    fn isToggleOn(self: *const Painter, toggle: look.Toggle) bool {
        return switch (toggle) {
            .layers => self.state.layers_menu != null,
            .follow => self.config.mapPanel.followActive,
        };
    }

    /// Null while they're hidden, or the last fetch didn't get them.
    fn shownStorms(self: *const Painter, scene: Scene) ?*const Storms {
        const stats = scene.stats orelse return null;
        return if (self.config.mapPanel.showStorms and stats.has_storms) &stats.storms else null;
    }

    fn stormLegend(self: *const Painter, scene: Scene) ?text_mod.Legend {
        const storms = self.shownStorms(scene) orelse return null;
        return text_mod.stormLegend(storms, self.state.layout.nodes[0..self.state.layout.node_count]);
    }

    /// Null while they're hidden, or the last fetch didn't get them.
    fn shownIncursions(self: *const Painter, scene: Scene) ?*const Incursions {
        const stats = scene.stats orelse return null;
        return if (self.config.mapPanel.showIncursions and stats.has_incursions) &stats.incursions else null;
    }

    fn incursionLegend(self: *const Painter, scene: Scene) ?text_mod.Legend {
        const incursions = self.shownIncursions(scene) orelse return null;
        return text_mod.incursionLegend(incursions, self.state.layout.nodes[0..self.state.layout.node_count]);
    }

    fn mapPaint(self: *const Painter, scene: Scene) MapPaint {
        const metric = self.config.mapPanel.metric;
        const nodes = self.state.layout.nodes[0..self.state.layout.node_count];
        return .{
            .metric = metric,
            .peak = peakValue(&self.state.layout, scene, metric),
            .holders = if (scene.stats) |stats| .fromNodes(stats, nodes, scene.logo_colors) else .{},
        };
    }

    /// The newest reports or kills that fit, two lines each, under its tabs; filled after the labels it covers, so GDI has to finish them first.
    fn drawIntelCard(self: *const Painter, bitmap: *const gdi_overlay.OverlayBitmap, fonts: MapFonts, card: *const look.IntelCard, entries: []const history.Entry, scene: Scene) void {
        _ = win32.GdiFlush();
        look.drawIntelCard(bitmap.canvas(), card, self.state.hoveredIndex(.intel_row) orelse self.state.hoveredIndex(.kill_row), self.state.hover.kind == .intel_header);

        const dc = bitmap.mem_dc;
        const text = fonts.chrome;
        const left = card.box.left + look.INTEL_PADDING_X;
        const right = card.box.right - look.INTEL_PADDING_X;
        const header_top = centredTop(card.header, text.name_height);
        if (card.hasTabs()) {
            for (std.enums.values(look.CardTab), card.tabs) |tab, box| {
                const is_picked = tab == card.tab;
                _ = win32.SelectObject(dc, if (is_picked) fonts.semibold_font else text.name_font);
                const tab_color = if (is_picked or self.isHovered(.card_tab, @backingInt(tab))) list_look.NAME else list_look.MUTED;
                panel_chrome.drawLine(dc, cardTabName(tab), box.left, header_top, tab_color);
            }
        } else {
            _ = win32.SelectObject(dc, fonts.semibold_font);
            panel_chrome.drawLine(dc, cardTabName(card.tab), left, header_top, list_look.NAME);
        }
        _ = win32.SelectObject(dc, text.name_font);
        if (card.is_collapsed) return;
        if (card.tab == .kills) return self.drawKillRows(dc, text, card, scene);
        if (card.row_count == 0) {
            panel_chrome.drawLine(dc, history_rows.INTEL_EMPTY_TEXT, left, card.header.bottom + look.INTEL_PADDING_Y, list_look.MUTED);
            return;
        }
        const now = win32.Ticks.now();
        const history_settings = &self.config.historyPanel;
        for (self.state.intel_rows[0..card.row_count], card.rows[0..card.row_count]) |row, box| {
            history_rows.drawStacked(dc, text, entries, row, &self.config.thumbnail.notifications, .{
                .left = left,
                .top = box.top + look.INTEL_PADDING_Y,
                .right = right,
                .line_gap = look.TITLE_LINE_GAP,
                .shows_timestamp = history_settings.showTimestamp,
                .shows_leads = self.config.intelPanel.colorSystemNames,
            }, now);
        }
    }

    /// Under a tab a hub, a line a connection: its system, region, and the largest ship and hours left; filled after the labels it covers, so GDI has to finish them first.
    fn drawWormholeCard(self: *const Painter, bitmap: *const gdi_overlay.OverlayBitmap, fonts: MapFonts, card: *const look.ListCard, scene: Scene) void {
        _ = win32.GdiFlush();
        look.drawListCard(bitmap.canvas(), card, self.state.hoveredIndex(.wormhole_row), self.state.hover.kind == .wormhole_header);

        const dc = bitmap.mem_dc;
        const text = fonts.chrome;
        const left = card.box.left + look.INTEL_PADDING_X;
        const right = card.box.right - look.INTEL_PADDING_X;
        const header_top = centredTop(card.header, text.name_height);
        for (std.enums.values(wormholes.Hub), card.tabs) |hub, box| {
            const is_picked = hub == self.state.wormhole_hub;
            _ = win32.SelectObject(dc, if (is_picked) fonts.semibold_font else text.name_font);
            const tab_color = if (is_picked or self.isHovered(.wormhole_tab, @backingInt(hub))) list_look.NAME else list_look.MUTED;
            panel_chrome.drawLine(dc, text_mod.hubName(hub), box.left, header_top, tab_color);
        }
        const connections = shownWormholes(self.config, scene);
        _ = win32.SelectObject(dc, text.name_font);
        if (card.is_collapsed) return;
        const listed = connections orelse {
            panel_chrome.drawLine(dc, "Waiting for EVE-Scout", left, card.header.bottom + look.INTEL_PADDING_Y, list_look.MUTED);
            return;
        };
        if (card.row_count == 0) {
            panel_chrome.drawLine(dc, "No connections reported", left, card.header.bottom + look.INTEL_PADDING_Y, list_look.MUTED);
            return;
        }
        for (card.rows[0..card.row_count], 0..) |box, row_index| {
            const item = self.state.wormholeEntryAt(row_index) orelse break;
            const top = centredTop(box, text.name_height);
            const connection = &listed.connections[item.index];
            var detail_buf: [32]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buf, "{s}  {d}h", .{ text_mod.shipSizeShort(connection.ship_size), connection.remaining_hours }) catch unreachable;
            const detail_width = panel_chrome.textWidth(dc, detail);
            panel_chrome.drawLine(dc, detail, right - detail_width, top, list_look.MUTED);
            const system_name = universe.systemName(item.system);
            const is_lit = self.state.focus_system == item.system;
            panel_chrome.drawLine(dc, system_name, left, top, if (is_lit) list_look.NAME else look.securityTextColor(universe.systemInfo(item.system).security_tenths));
            const region_left = left + panel_chrome.textWidth(dc, system_name) + look.LABEL_SUFFIX_GAP * 2;
            _ = panel_chrome.drawFitted(dc, universe.regionName(universe.systemInfo(item.system).region), region_left, top, list_look.MUTED, right - detail_width - look.LEGEND_VALUE_GAP - region_left);
        }
    }

    /// A line a sov timer: its system, constellation, and its countdown or the defender's score; filled after the labels it covers, so GDI has to finish them first.
    fn drawTimerCard(self: *const Painter, bitmap: *const gdi_overlay.OverlayBitmap, fonts: MapFonts, card: *const look.ListCard, scene: Scene) void {
        _ = win32.GdiFlush();
        look.drawListCard(bitmap.canvas(), card, self.state.hoveredIndex(.timer_row), self.state.hover.kind == .timer_header);

        const dc = bitmap.mem_dc;
        const text = fonts.chrome;
        const left = card.box.left + look.INTEL_PADDING_X;
        const right = card.box.right - look.INTEL_PADDING_X;
        _ = win32.SelectObject(dc, fonts.semibold_font);
        panel_chrome.drawLine(dc, "Sov timers", left, centredTop(card.header, text.name_height), list_look.NAME);
        _ = win32.SelectObject(dc, text.name_font);
        if (card.is_collapsed) return;
        const campaigns = shownCampaigns(self.config, scene) orelse return;
        for (card.rows[0..card.row_count], 0..) |box, row_index| {
            const entry = self.state.timerEntryAt(row_index) orelse break;
            const campaign = &campaigns.slice()[entry.index];
            const top = centredTop(box, text.name_height);
            const timer = text_mod.timerText(campaign, scene.now_seconds);
            const timer_width = panel_chrome.textWidth(dc, timer.slice());
            panel_chrome.drawLine(dc, timer.slice(), right - timer_width, top, look.SOV_TIMER);
            const system_name = universe.systemName(campaign.system);
            const is_lit = self.state.focus_system == campaign.system;
            panel_chrome.drawLine(dc, system_name, left, top, if (is_lit) list_look.NAME else look.securityTextColor(universe.systemInfo(campaign.system).security_tenths));
            const constellation_left = left + panel_chrome.textWidth(dc, system_name) + look.LABEL_SUFFIX_GAP * 2;
            _ = panel_chrome.drawFitted(dc, universe.constellationName(universe.systemInfo(campaign.system).constellation), constellation_left, top, list_look.MUTED, right - timer_width - look.LEGEND_VALUE_GAP - constellation_left);
        }
    }

    /// Two lines a kill: its ship and value, then its system, victim and age.
    fn drawKillRows(self: *const Painter, dc: win32.HDC, text: panel_chrome.Text, card: *const look.IntelCard, scene: Scene) void {
        const left = card.box.left + look.INTEL_PADDING_X;
        const right = card.box.right - look.INTEL_PADDING_X;
        if (card.row_count == 0) {
            var empty_buf: [panel_chrome.MAX_TEXT_LENGTH]u8 = undefined;
            const empty = std.fmt.bufPrint(&empty_buf, "No kills here in the last {d}m", .{self.config.mapPanel.killLifetimeMin}) catch unreachable;
            panel_chrome.drawLine(dc, empty, left, card.header.bottom + look.INTEL_PADDING_Y, list_look.MUTED);
            return;
        }
        for (self.state.kill_rows[0..card.row_count], card.rows[0..card.row_count]) |*kill, box| {
            const top = box.top + look.INTEL_PADDING_Y;
            const second_top = top + text.name_height + look.TITLE_LINE_GAP;
            const value = zkill.valueText(kill.value_isk);
            const value_width = panel_chrome.textWidth(dc, value.slice());
            panel_chrome.drawLine(dc, value.slice(), right - value_width, top, list_look.MUTED);
            _ = panel_chrome.drawFitted(dc, text_mod.killShipName(scene.kill_names, kill), left, top, list_look.NAME, right - value_width - look.LEGEND_VALUE_GAP - left);

            var age_buf: [panel_look.TIME_TEXT_MAX]u8 = undefined;
            const age = text_mod.killAge(&age_buf, kill, scene.now_seconds);
            const age_width = panel_chrome.textWidth(dc, age);
            panel_chrome.drawLine(dc, age, right - age_width, second_top, list_look.MUTED);
            const system_name = universe.systemName(kill.system);
            panel_chrome.drawLine(dc, system_name, left, second_top, look.securityTextColor(universe.systemInfo(kill.system).security_tenths));
            const victim_left = left + panel_chrome.textWidth(dc, system_name) + look.LABEL_SUFFIX_GAP * 2;
            _ = panel_chrome.drawFitted(dc, text_mod.killVictimName(scene.kill_names, kill), victim_left, second_top, list_look.MUTED, right - age_width - look.LEGEND_VALUE_GAP - victim_left);
        }
    }

    /// Filled after the labels it covers, so GDI has to finish them first; `stops` gets where the query's gaps were drawn.
    fn drawSearchBox(self: *const Painter, bitmap: *const gdi_overlay.OverlayBitmap, text: panel_chrome.Text, stops: *search.Stops) void {
        const box = self.areas.search_box;
        _ = win32.GdiFlush();
        const is_open = self.state.search != null;
        const is_lit = is_open or self.state.hover.kind == .search_box;
        look.drawSearchCard(bitmap.canvas(), box, is_open, if (is_lit) self.config.accentColor else null);

        const dc = bitmap.mem_dc;
        _ = win32.SelectObject(dc, text.name_font);
        const y = box.top + @divTrunc(box.bottom - box.top - text.name_height, 2);
        const left = box.left + look.SEARCH_TEXT_INSET;
        const right = box.right - look.TOGGLE_PADDING_X;
        const open = if (self.state.search) |*shown| shown else {
            _ = panel_chrome.drawFitted(dc, "Search systems", left, y, look.CARD_MUTED, right - left);
            return;
        };
        const query = open.query();
        var widths: @FieldType(search.Stops, "x_positions") = undefined;
        for (widths[0 .. query.len + 1], 0..) |*width, i| width.* = panel_chrome.textWidth(dc, query[0..i]);
        // A query wider than the box scrolls to keep the one-pixel cursor in it.
        const scroll = @max(0, widths[open.cursor] - (right - left - 1));
        for (widths[0 .. query.len + 1], stops.x_positions[0 .. query.len + 1]) |width, *stop| stop.* = left + width - scroll;
        stops.count = query.len + 1;

        // The selection and cursor go on the canvas first, as GDI's text lands on top.
        const canvas = bitmap.canvas();
        const height: usize = @intCast(@max(0, text.name_height));
        const range = open.selection();
        if (range.start != range.end) {
            const start = std.math.clamp(stops.x_positions[range.start], left, right);
            const end = std.math.clamp(stops.x_positions[range.end], left, right);
            pixel_buffer.fillRect(canvas, @intCast(@max(0, start)), @intCast(@max(0, y)), @intCast(end - start), height, look.SEARCH_SELECTION);
        }
        pixel_buffer.fillRect(canvas, @intCast(@max(0, stops.x_positions[open.cursor])), @intCast(@max(0, y)), 1, height, list_look.NAME);

        // Only whole characters, since nothing clips GDI's text to the box.
        var first: usize = 0;
        while (first < query.len and stops.x_positions[first] < left) first += 1;
        var last = first;
        while (last < query.len and stops.x_positions[last + 1] <= right) last += 1;
        panel_chrome.drawLine(dc, query[first..last], stops.x_positions[first], y, list_look.NAME);
    }

    /// Bubbles coloured by the traffic the map shows, by who holds most of each region under Sovereignty, or else by security.
    fn drawOverview(self: *const Painter, canvas: pixel_buffer.Canvas, scene: Scene) void {
        const overview = &self.state.overview;
        const metric = self.config.mapPanel.metric;
        for (overview.links[0..overview.link_count]) |link| {
            const first = overview.bubbles[link.first];
            const second = overview.bubbles[link.second];
            pixel_buffer.drawLine(canvas, first.x, first.y, second.x, second.y, look.EDGE_LOCAL);
        }

        var totals: [universe.REGION_COUNT]u32 = @splat(0);
        var peak: u32 = 0;
        if (scene.stats) |stats| {
            for (stats.systems, 0..) |system_stats, index| {
                totals[universe.systemInfo(@intCast(index)).region] += look.metricValue(metric, system_stats);
            }
            peak = std.mem.max(u32, &totals);
        }
        var region_holders: [universe.REGION_COUNT]u16 = @splat(stats_mod.NO_HOLDER);
        var ranks: look.HolderRanks = .{};
        var region_occupiers: [universe.REGION_COUNT]u8 = @splat(faction_warfare.NO_FACTION);
        if (scene.stats) |stats| {
            switch (metric) {
                .Sovereignty => {
                    region_holders = look.regionHolders(stats);
                    ranks = .fromHolders(stats, &region_holders, scene.logo_colors);
                },
                .FactionWarfare => region_occupiers = look.regionOccupiers(stats),
                .Security, .ShipKills, .PodKills, .NpcKills, .NpcDelta, .Jumps => {},
            }
        }
        for (overview.bubbles, totals, 0..) |bubble, total, index| {
            const region: RegionIndex = @intCast(index);
            const metric_color = switch (metric) {
                .Sovereignty => ranks.colorOf(region_holders[region]),
                .FactionWarfare => if (region_occupiers[region] == faction_warfare.NO_FACTION) look.securityColor(bubble.security_tenths) else look.factionColorOf(region_occupiers[region]),
                .Security, .ShipKills, .PodKills, .NpcKills, .NpcDelta, .Jumps => if (peak > 0) look.heatColor(total, peak) else look.securityColor(bubble.security_tenths),
            };
            const bubble_color = if (self.state.reach) |*reach| look.regionRangeColor(reach.region_counts[region]) else metric_color;
            look.drawMarker(canvas, bubble.x, bubble.y, bubble.radius, bubble_color);
            const is_hovered = self.state.hover.kind == .region and self.state.hover.index == region;
            // A picked region's ring is heavier than a hover's, so the picks stay visible while pointing elsewhere.
            const ring_thickness = if (self.state.ringedRegions().contains(region)) look.FOCUS_RING_THICKNESS else if (is_hovered) look.RING_THICKNESS else null;
            if (ring_thickness) |thickness| pixel_buffer.drawRing(canvas, bubble.x, bubble.y, bubble.radius + look.RING_GAP, thickness, look.FOCUS);
            if (self.state.marks.countIn(region) > 0) pixel_buffer.drawRing(canvas, bubble.x, bubble.y, bubble.radius + 2 * look.RING_GAP, look.RING_THICKNESS, self.config.listView.activeColor);
        }
        // Outside those rings, stepping out as a region can hold more than one storm or incursion.
        var ring_gaps: [universe.REGION_COUNT]f32 = @splat(3);
        if (self.shownStorms(scene)) |storms| {
            for (storms.slice()) |*storm| self.drawRegionRing(canvas, storm.center, look.stormColor(storm.kind), &ring_gaps);
        }
        if (self.shownIncursions(scene)) |incursions| {
            for (incursions.slice()) |*incursion| self.drawRegionRing(canvas, incursion.staging, look.INCURSION, &ring_gaps);
        }
    }

    /// Around the bubble of the region holding `system`, steps out from those drawn before it.
    fn drawRegionRing(self: *const Painter, canvas: pixel_buffer.Canvas, system: SystemIndex, ring_color: u32, ring_gaps: *[universe.REGION_COUNT]f32) void {
        const region = universe.systemInfo(system).region;
        const bubble = self.state.overview.bubbles[region];
        pixel_buffer.drawRing(canvas, bubble.x, bubble.y, bubble.radius + ring_gaps[region] * look.RING_GAP, look.RING_THICKNESS, ring_color);
        ring_gaps[region] += 1;
    }

    /// A region with a client in it stands out, as the likely pick.
    fn drawOverviewLabels(self: *const Painter, dc: win32.HDC, label_font: win32.HFONT) void {
        _ = win32.SelectObject(dc, label_font);
        for (self.state.overview.bubbles, 0..) |bubble, index| {
            const region: RegionIndex = @intCast(index);
            const label = bubble.label orelse continue;
            const is_hovered = self.state.hover.kind == .region and self.state.hover.index == region;
            const label_color = if (self.state.marks.countIn(region) > 0) self.config.listView.activeColor else if (is_hovered or self.state.ringedRegions().contains(region)) list_look.NAME else look.LABEL;
            drawHaloText(dc, universe.regionName(region), label.left, label.top, label_color, .full);
        }
    }

    /// The cards over the map: its title, the metric and toggle bars, and the map controls; filled after the labels they cover, so GDI has to finish them first.
    fn drawChrome(self: *const Painter, bitmap: *const gdi_overlay.OverlayBitmap, fonts: MapFonts) void {
        const dc = bitmap.mem_dc;
        const chrome = &self.state.chrome;
        const hover = self.state.hover;
        const map_settings = &self.config.mapPanel;
        const accent = self.config.accentColor;
        const title = titleText(self.state);
        _ = win32.SelectObject(dc, fonts.heading_font);
        const title_width = panel_chrome.textWidth(dc, title.slice());
        _ = win32.GdiFlush();

        const canvas = bitmap.canvas();
        const title_box = chrome.title;
        const is_title_lit = hover.kind == .title or self.state.is_picking_region;
        look.drawTitleCard(canvas, title_box, if (is_title_lit) accent else null);
        const title_x = title_box.left + look.TITLE_PADDING_X;
        // Centred, as the card grows when the metric bar drops below it.
        const title_y = title_box.top + @divTrunc(title_box.bottom - title_box.top - fonts.heading_height, 2);
        const title_room = title_box.right - look.TITLE_PADDING_X - look.CHEVRON_OFFSET - title_x;
        look.drawChevron(canvas, title_x + @min(title_width, title_room) + look.CHEVRON_OFFSET, title_y + @divTrunc(fonts.heading_height, 2), self.state.is_picking_region);

        look.drawBar(canvas, chrome.metric_bar);
        const picked_segment = look.segmentOf(map_settings.metric);
        for (look.SEGMENT_ORDER, chrome.metrics) |segment, box| {
            if (segment == picked_segment) look.fillSegment(canvas, box, accent) else if (self.isHovered(.metric, @backingInt(segment))) look.fillSegment(canvas, box, look.SEGMENT_HOVER);
        }
        look.drawBar(canvas, chrome.toggle_bar);
        for (look.TOGGLE_ORDER, chrome.toggles) |toggle, box| {
            if (self.isHovered(.toggle, @backingInt(toggle))) look.fillSegment(canvas, box, look.SEGMENT_HOVER);
            look.drawToggleMark(canvas, box, toggle, self.isToggleOn(toggle), self.config.listView.activeColor);
        }
        look.drawToggleDivider(canvas, chrome.toggle_bar, chrome.toggleDividerX());

        const hovered_control: ?look.MapControl = if (hover.kind == .map_control) @fromBackingInt(@intCast(hover.index)) else null;
        look.drawPinButton(canvas, self.areas.mapControlBox(.always_on_top), map_settings.alwaysOnTop, if (hovered_control == .always_on_top) accent else null);
        look.drawZoomStack(canvas, self.areas, hovered_control);

        _ = panel_chrome.drawFitted(dc, title.slice(), title_x, title_y, list_look.NAME, title_room);

        const name_height = fonts.chrome.name_height;
        for (look.SEGMENT_ORDER, chrome.metrics) |segment, box| {
            const is_picked = segment == picked_segment;
            _ = win32.SelectObject(dc, if (is_picked) fonts.semibold_font else fonts.chrome.name_font);
            const label = text_mod.metricLabel(if (is_picked) map_settings.metric else look.segmentMetrics(segment)[0]);
            const label_color = if (is_picked) color_mod.inkFor(accent) else if (self.isHovered(.metric, @backingInt(segment))) list_look.NAME else look.SEGMENT_TEXT;
            // Centred, as the segments are sized for the semibold label.
            const label_x = box.left + @divTrunc(box.right - box.left - panel_chrome.textWidth(dc, label), 2);
            panel_chrome.drawLine(dc, label, label_x, centredTop(box, name_height), label_color);
        }
        _ = win32.SelectObject(dc, fonts.chrome.name_font);
        for (look.TOGGLE_ORDER, chrome.toggles) |toggle, box| {
            const is_lit = self.isToggleOn(toggle) or self.isHovered(.toggle, @backingInt(toggle));
            panel_chrome.drawLine(dc, text_mod.toggleLabel(toggle), box.left + look.TOGGLE_PADDING_X + look.TOGGLE_MARK_ROOM, centredTop(box, name_height), if (is_lit) list_look.NAME else look.CARD_MUTED);
        }
    }

    fn isHovered(self: *const Painter, kind: state_mod.Hover.Kind, index: usize) bool {
        return self.state.hover.kind == kind and self.state.hover.index == index;
    }

    fn drawRegionLabels(self: *const Painter, dc: win32.HDC, title_font: win32.HFONT) void {
        const layout = &self.state.layout;
        _ = win32.SelectObject(dc, title_font);
        for (layout.regions.slice(), layout.region_labels[0..layout.regions.count]) |region, region_label| {
            const label = region_label orelse continue;
            drawHaloText(dc, universe.regionName(region), label.left, label.top, look.REGION_NAME, .full);
        }
    }

    /// One tag a system, naming the active client if it's there, as a stack of rings can't say who's where.
    fn drawClientTags(self: *const Painter, bitmap: *const gdi_overlay.OverlayBitmap, text: panel_chrome.Text, scene: Scene, paint: *const MapPaint) void {
        if (!self.config.mapPanel.showCharacterNames) return;
        const dc = bitmap.mem_dc;
        _ = win32.SelectObject(dc, text.small_font);
        _ = win32.GdiFlush();
        const canvas = bitmap.canvas();
        const area = self.areas.body;
        const layout = &self.state.layout;
        var taken: [layout_mod.MAX_NODES + marks.MAX_MARKS]Box = undefined;
        var taken_count: usize = 0;
        for (layout.nodes[0..layout.node_count]) |node| {
            const label = node.label orelse continue;
            taken[taken_count] = layout_mod.chipBox(label);
            taken_count += 1;
        }
        for (self.state.marks.slice(), 0..) |mark, index| {
            if (!self.state.marks.leadsSystem(index)) continue;
            const node_index = layout.nodeOf(mark.system) orelse continue;
            const node = layout.nodes[node_index];
            const label = text_mod.clientTagText(mark.character_name, self.state.marks.countAt(mark.system) - 1);
            const box_width = panel_chrome.wideTextWidth(dc, label.slice());
            const reach = self.markReach(scene, paint, mark.system);
            const offset = look.clientTagOffset(reach);
            // Dropped where the names leave no room, as the marker's ring still shows the client.
            const box = look.clientTagBox(area, node.x, node.y, offset, box_width, text.small_height, taken[0..taken_count]) orelse continue;
            taken[taken_count] = box;
            taken_count += 1;
            const tag_color = self.markColor(mark);
            look.drawClientLead(canvas, node.x, node.y, reach, box, tag_color);
            drawHaloWideText(dc, label.slice(), box.left, box.top, tag_color);
        }
    }

    /// The selected system's disc, out past its ring.
    fn focusRadius(self: *const Painter, scene: Scene, paint: *const MapPaint, system: SystemIndex) f32 {
        const value = if (scene.stats) |stats| look.metricValue(paint.metric, stats.systems[system]) else 0;
        return look.markerRadius(value, paint.peak) * look.markerScale(self.state.layout.view.zoom) + look.RING_GAP + look.FOCUS_OUTLINE_THICKNESS;
    }

    /// How far the rings around a client's marker go: the selected system's disc, else the client's ring.
    fn markReach(self: *const Painter, scene: Scene, paint: *const MapPaint, system: SystemIndex) f32 {
        if (self.state.focus_system == system) return self.focusRadius(scene, paint, system);
        return self.markRingRadius() + look.RING_THICKNESS;
    }

    /// Kept to a resting marker's size, so a busy system's ring doesn't jump as its traffic changes.
    fn markRingRadius(self: *const Painter) f32 {
        return look.markerRadius(0, 0) * look.markerScale(self.state.layout.view.zoom) + 2 * look.RING_GAP;
    }

    fn markColor(self: *const Painter, mark: marks.Mark) u32 {
        return if (mark.is_active) self.config.listView.activeColor else mark.color;
    }

    /// The colour of the client whose tag names the selected system, else FOCUS.
    fn focusRingColor(self: *const Painter) u32 {
        const system = self.state.focus_system orelse return look.FOCUS;
        for (self.state.marks.slice(), 0..) |mark, index| {
            if (mark.system == system and self.state.marks.leadsSystem(index)) return self.markColor(mark);
        }
        return look.FOCUS;
    }

    fn haloRadius(self: *const Painter, pin: *const intel_pins.Pin, now_ms: u64) f32 {
        return intelHaloRadius(&self.config.mapPanel, pin, look.markerScale(self.state.layout.view.zoom), now_ms);
    }

    fn drawMap(self: *const Painter, canvas: pixel_buffer.Canvas, scene: Scene, paint: *const MapPaint, now_ms: u64) void {
        const layout = &self.state.layout;
        const scale = look.markerScale(layout.view.zoom);
        const hovered_node: ?u16 = if (self.state.hover.kind == .node) self.state.hover.index else null;
        const lifetime_ms = self.config.mapPanel.intelShrinkMs();
        // Under everything else, so a new halo doesn't hide the systems around it.
        for (layout.nodes[0..layout.node_count]) |node| {
            const pin = scene.pins.find(node.system, lifetime_ms, now_ms) orelse continue;
            look.drawIntelHalo(canvas, node.x, node.y, self.haloRadius(pin, now_ms), pin.is_clear, pin.freshnessPercent(lifetime_ms, now_ms));
            if (look.rippleAt(now_ms -| pin.seen_ms)) |ripple| look.drawRipple(canvas, node.x, node.y, ripple, scale, look.intelColor(pin.is_clear));
        }
        if (self.state.ping) |ping| {
            if (layout.nodeOf(ping.system)) |node_index| {
                const node = layout.nodes[node_index];
                if (look.rippleAt(now_ms -| ping.started_ms)) |ripple| look.drawRipple(canvas, node.x, node.y, ripple, scale, look.PING);
            }
        }
        const storms = self.shownStorms(scene);
        const incursions = self.shownIncursions(scene);
        self.drawAreas(canvas, scene, scale);
        const focus_node_index: ?u16 = if (self.state.focus_system) |system| layout.nodeOf(system) else null;
        for (layout.edges[0..layout.edge_count]) |edge| {
            const first = layout.nodes[edge.first_index];
            const second = layout.nodes[edge.second_index];
            const is_lit = hovered_node == edge.first_index or hovered_node == edge.second_index or focus_node_index == edge.first_index or focus_node_index == edge.second_index;
            const plain_color = look.edgeColor(edge.kind);
            const edge_color = if (is_lit) look.EDGE_HOVER else stormEdgeColor(storms, first.system, second.system) orelse incursionEdgeColor(incursions, first.system, second.system) orelse holderEdgeColor(scene, paint, first.system, second.system) orelse plain_color;
            var point_buffer: [layout_mod.CURVE_SEGMENTS + 1]layout_mod.PixelPoint = undefined;
            const points = layout.edgePoints(edge, &point_buffer);
            for (points[0 .. points.len - 1], points[1..]) |from, to| pixel_buffer.drawLine(canvas, from.x, from.y, to.x, to.y, edge_color);
        }
        for (layout.exits[0..layout.exit_count], 0..) |exit, index| {
            const is_hovered = self.state.hover.kind == .exit and self.state.hover.index == index;
            look.drawExit(canvas, layout.nodes[exit.from_index], exit, if (is_hovered) look.EDGE_HOVER else look.EXIT);
        }
        if (shownBridges(self.config, self.has_eve_stars, scene)) |bridges| {
            for (bridges.slice()) |bridge| {
                const from_index = layout.nodeOf(bridge.from) orelse continue;
                const to_index = layout.nodeOf(bridge.to) orelse continue;
                look.drawBridge(canvas, layout, from_index, to_index, look.ANSIBLEX);
            }
        }
        for (layout.portals[0..layout.portal_count], 0..) |portal, index| {
            look.drawPortal(canvas, layout.nodes[portal.from_index], portal, if (self.isHovered(.portal, index)) look.EDGE_HOVER else portalColor(portal.target));
        }
        if (self.state.focusNode()) |node| look.drawFocusMark(canvas, node.x, node.y, self.focusRadius(scene, paint, node.system));

        const focus_ring_color = self.focusRingColor();
        for (layout.nodes[0..layout.node_count], 0..) |node, index| {
            const value = if (scene.stats) |stats| look.metricValue(paint.metric, stats.systems[node.system]) else 0;
            const radius = look.markerRadius(value, paint.peak) * scale;
            const ring_radius = radius + look.RING_GAP;
            const is_focus = self.state.focus_system == node.system;
            look.drawMarker(canvas, node.x, node.y, radius, if (self.state.isOutOfRange(node.system)) look.OUT_OF_RANGE else markerColor(scene, paint, node.system, value));
            const is_hovered = if (hovered_node) |hovered| hovered == index else false;
            if (is_focus) {
                pixel_buffer.drawRing(canvas, node.x, node.y, ring_radius, look.FOCUS_RING_THICKNESS, focus_ring_color);
            } else if (is_hovered) {
                pixel_buffer.drawRing(canvas, node.x, node.y, ring_radius, look.RING_THICKNESS, look.FOCUS);
            }
        }

        const resting_radius = look.markerRadius(0, 0) * scale;
        for (self.state.marks.slice()) |mark| {
            // The selected system's ring takes the client's colour instead, as a second ring there lands on its border.
            if (self.state.focus_system == mark.system) continue;
            const index = layout.nodeOf(mark.system) orelse continue;
            const node = layout.nodes[index];
            pixel_buffer.drawRing(canvas, node.x, node.y, self.markRingRadius(), look.RING_THICKNESS, self.markColor(mark));
        }
        if (self.state.reach) |*reach| {
            for (layout.nodes[0..layout.node_count]) |node| {
                if (reach.includes(node.system)) look.drawRangeMark(canvas, node.x, node.y, scale);
            }
            // Outside a client's ring, as the origin is often where one sits.
            if (layout.nodeOf(reach.origin)) |index| pixel_buffer.drawRing(canvas, layout.nodes[index].x, layout.nodes[index].y, resting_radius + 3 * look.RING_GAP, look.RING_THICKNESS, look.RANGE);
        }
        // Outside a client's ring and the jump range's origin, as Turnur is the hub itself.
        if (shownWormholes(self.config, scene) != null) {
            if (universe.findSystemById(wormholes.TURNUR_ID)) |turnur| {
                if (layout.nodeOf(turnur)) |index| pixel_buffer.drawRing(canvas, layout.nodes[index].x, layout.nodes[index].y, resting_radius + 4 * look.RING_GAP, look.RING_THICKNESS, look.WORMHOLE);
            }
        }
        if (shownCampaigns(self.config, scene)) |campaigns| {
            for (campaigns.slice()) |*campaign| {
                const index = layout.nodeOf(campaign.system) orelse continue;
                look.drawTimerMark(canvas, layout.nodes[index].x, layout.nodes[index].y, scale, campaign.hasStarted(scene.now_seconds));
            }
        }
        if (scene.kills) |kills| self.drawKills(canvas, kills, scene.now_seconds, now_ms, scale);
        if (self.has_eve_stars) self.drawAvoidMarks(canvas);
    }

    /// A ripple for each new kill, and one mark a system for its newest, fading over the kills' lifetime.
    fn drawKills(self: *const Painter, canvas: pixel_buffer.Canvas, kills: *const Kills, now_seconds: i64, now_ms: u64, scale: f32) void {
        const layout = &self.state.layout;
        const lifetime_seconds = self.config.mapPanel.killLifetimeSeconds();
        var is_marked: [layout_mod.MAX_NODES]bool = @splat(false);
        for (0..kills.count) |index| {
            const kill = kills.fromNewest(index);
            const node_index = layout.nodeOf(kill.system) orelse continue;
            const node = layout.nodes[node_index];
            if (look.rippleAt(now_ms -| kill.seen_ms)) |ripple| look.drawRipple(canvas, node.x, node.y, ripple, scale, look.KILL);
            if (is_marked[node_index]) continue;
            is_marked[node_index] = true;
            const age_seconds = std.math.clamp(now_seconds - kill.time_seconds, 0, lifetime_seconds);
            look.drawKillMark(canvas, node.x, node.y, scale, @intCast(100 - @divTrunc(age_seconds * 100, lifetime_seconds)));
        }
    }

    /// Each storm and incursion as one shape following its systems and gates here, so an area that leaves the regions shown stops at their edge.
    fn drawAreas(self: *const Painter, canvas: pixel_buffer.Canvas, scene: Scene, scale: f32) void {
        // The legends list what reaches the map, and most regions have nothing to mask.
        if (self.stormLegend(scene) == null and self.incursionLegend(scene) == null) return;
        var mask = pixel_buffer.Mask.init(self.allocator, canvas.width, canvas.height) catch |err| {
            slog.warn("Failed to draw storm and incursion areas: {}", .{err});
            return;
        };
        defer mask.deinit();
        const radius = look.areaRadius(scale);
        if (self.shownStorms(scene)) |storms| {
            for (storms.slice()) |*storm| {
                const shade = look.stormColor(storm.kind);
                self.fillMaskWith(&mask, &storm.covered, radius);
                look.drawArea(canvas, &mask, shade);
                self.fillMaskWith(&mask, &storm.core, radius);
                look.drawAreaCore(canvas, &mask, shade);
            }
        }
        if (self.shownIncursions(scene)) |incursions| {
            for (incursions.slice()) |*incursion| {
                self.fillMaskWith(&mask, &incursion.infested, radius);
                look.drawArea(canvas, &mask, look.INCURSION);
                mask.clear();
                const index = self.state.layout.nodeOf(incursion.staging) orelse continue;
                mask.addDisc(self.state.layout.nodes[index].x, self.state.layout.nodes[index].y, radius);
                look.drawAreaCore(canvas, &mask, look.INCURSION);
            }
        }
    }

    /// Replaces what `mask` held with `systems` here and the gates among them.
    fn fillMaskWith(self: *const Painter, mask: *pixel_buffer.Mask, systems: *const universe.SystemSet, radius: f32) void {
        const layout = &self.state.layout;
        mask.clear();
        // A band reaches its ends as deep as a disc there would, so only a system with no gate in `systems` needs one.
        var has_band: [layout_mod.MAX_NODES]bool = undefined;
        @memset(has_band[0..layout.node_count], false);
        for (layout.edges[0..layout.edge_count]) |edge| {
            const first = layout.nodes[edge.first_index];
            const second = layout.nodes[edge.second_index];
            if (!systems.isSet(first.system) or !systems.isSet(second.system)) continue;
            has_band[edge.first_index] = true;
            has_band[edge.second_index] = true;
            var point_buffer: [layout_mod.CURVE_SEGMENTS + 1]layout_mod.PixelPoint = undefined;
            const points = layout.edgePoints(edge, &point_buffer);
            for (points[0 .. points.len - 1], points[1..]) |from, to| mask.addBand(from.x, from.y, to.x, to.y, radius);
        }
        for (layout.nodes[0..layout.node_count], has_band[0..layout.node_count]) |node, is_covered| {
            if (!is_covered and systems.isSet(node.system)) mask.addDisc(node.x, node.y, radius);
        }
    }

    /// Only with a token, as nothing else reads the list.
    fn drawAvoidMarks(self: *const Painter, canvas: pixel_buffer.Canvas) void {
        for (self.config.avoidedSystems.items) |avoided| {
            const system = universe.findSystemById(avoided.systemId) orelse continue;
            const index = self.state.layout.nodeOf(system) orelse continue;
            const node = self.state.layout.nodes[index];
            look.drawAvoidMark(canvas, node.x, node.y);
        }
    }

    fn drawLabels(self: *const Painter, dc: win32.HDC, scene: Scene, label_font: win32.HFONT, now_ms: u64) void {
        const layout = &self.state.layout;
        const storms = self.shownStorms(scene);
        const incursions = self.shownIncursions(scene);
        const campaigns = shownCampaigns(self.config, scene);
        _ = win32.SelectObject(dc, label_font);
        const outline: Outline = if (self.state.isPanning()) .shadow else .full;
        for (layout.nodes[0..layout.node_count], 0..) |node, index| {
            const label = node.label orelse continue;
            const plain_color = if (self.state.isNoteworthy(node.system)) list_look.NAME else look.LABEL;
            const label_color = if (self.state.focus_system == node.system) look.FOCUS_NAME else if (scene.pins.find(node.system, self.config.mapPanel.intelShrinkMs(), now_ms) != null) list_look.NAME else stormCenterColor(storms, node.system) orelse incursionStagingColor(incursions, node.system) orelse plain_color;
            drawHaloText(dc, universe.systemName(node.system), label.left, label.top, label_color, outline);
            var suffix_buffer: [text_mod.SECURITY_TEXT_MAX]u8 = undefined;
            if (self.labelSuffix(node.system, &suffix_buffer)) |suffix| {
                drawHaloText(dc, suffix.text, label.left + self.state.label_widths.names[index] + look.LABEL_SUFFIX_GAP, label.top, suffix.color, outline);
            }
            const shown_campaigns = campaigns orelse continue;
            const campaign = shown_campaigns.soonestIn(node.system) orelse continue;
            // A timed name's box is two lines tall, the timer on the second.
            drawHaloText(dc, text_mod.timerText(campaign, scene.now_seconds).slice(), label.left, label.top + @divTrunc(label.bottom - label.top, 2), look.SOV_TIMER, outline);
        }
        for (layout.exits[0..layout.exit_count], 0..) |exit, index| {
            const label = exit.label orelse continue;
            const is_hovered = self.state.hover.kind == .exit and self.state.hover.index == index;
            drawHaloText(dc, text_mod.exitLabel(exit).slice(), label.left, label.top, if (is_hovered) look.EDGE_HOVER else look.EXIT, outline);
        }
        for (layout.portals[0..layout.portal_count], 0..) |portal, index| {
            const label = portal.label orelse continue;
            drawHaloText(dc, text_mod.portalLabel(portal.target), label.left, label.top, if (self.isHovered(.portal, index)) look.EDGE_HOVER else portalColor(portal.target), outline);
        }
    }

    /// The security once zoomed in enough; null before that.
    fn labelSuffix(self: *const Painter, system: SystemIndex, buffer: *[text_mod.SECURITY_TEXT_MAX]u8) ?LabelSuffix {
        if (!look.showsSecurityLabel(self.state.layout.view.zoom)) return null;
        const security_tenths = universe.systemInfo(system).security_tenths;
        return .{ .text = text_mod.securityText(buffer, security_tenths), .color = look.securityTextColor(security_tenths) };
    }

    fn tooltipFor(self: *const Painter, scene: Scene, now_ms: u64) ?text_mod.Tooltip {
        const system: SystemIndex = switch (self.state.hover.kind) {
            .none, .title, .toggle, .bar, .metric, .intel_header, .card_tab, .intel_row, .kill_row, .wormhole_header, .wormhole_tab, .wormhole_row, .timer_header, .timer_row, .popup_row, .submenu_row, .nested_row, .search_box => return null,
            .map_control => return text_mod.mapControlTooltip(@fromBackingInt(@intCast(self.state.hover.index)), self.config.mapPanel.alwaysOnTop),
            .region => {
                const region: RegionIndex = @intCast(self.state.hover.index);
                return text_mod.regionTooltip(region, self.state.overview.bubbles[region].system_count, self.state.marks.countIn(region), if (self.state.reach) |*reach| reach else null, self.shownStorms(scene), self.shownIncursions(scene), shownCampaigns(self.config, scene));
            },
            .exit => {
                const exit = self.state.layout.exits[self.state.hover.index];
                return text_mod.exitTooltip(self.state.layout.nodes[exit.from_index].system, exit.destination);
            },
            .portal => {
                const portal = self.state.layout.portals[self.state.hover.index];
                const from = self.state.layout.nodes[portal.from_index].system;
                switch (portal.target) {
                    .hub => |hub| return text_mod.portalTooltip(shownWormholes(self.config, scene) orelse return null, from, hub),
                    .system => |to| return text_mod.bridgeTooltip(shownBridges(self.config, self.has_eve_stars, scene) orelse return null, from, to),
                }
            },
            .node => self.state.layout.nodes[self.state.hover.index].system,
        };
        var facts: text_mod.SystemFacts = .{ .system = system, .stats = scene.stats, .is_avoided = self.has_eve_stars and self.config.avoidedSystemIndex(universe.systemInfo(system).id) != null, .reach = if (self.state.reach) |*reach| reach else null, .storms = self.shownStorms(scene), .incursions = self.shownIncursions(scene), .campaigns = shownCampaigns(self.config, scene), .wormholes = shownWormholes(self.config, scene), .bridges = shownBridges(self.config, self.has_eve_stars, scene), .now_seconds = scene.now_seconds };
        var names: [marks.MAX_MARKS][]const u8 = undefined;
        facts.characters = self.state.marks.namesAt(system, &names);
        if (scene.pins.find(system, self.config.mapPanel.intelShrinkMs(), now_ms)) |pin| {
            facts.intel_message = pin.message();
            facts.intel_age_ms = now_ms -| pin.seen_ms;
            facts.is_intel_clear = pin.is_clear;
        }
        return text_mod.systemTooltip(facts);
    }

    /// Filled after the labels it covers, so GDI has to finish them first.
    fn drawTooltip(self: *const Painter, bitmap: *const gdi_overlay.OverlayBitmap, scene: Scene, fonts: MapFonts, now_ms: u64) void {
        const tooltip = self.tooltipFor(scene, now_ms) orelse return;
        if (tooltip.line_count == 0) return;
        const shape = tooltipShape(bitmap.mem_dc, &tooltip, fonts);
        const anchor = self.hoverAnchor();
        drawTextBox(bitmap, &tooltip, popup_look.tooltipBox(self.areas.body, anchor.x, anchor.y, shape.size.x, shape.size.y), fonts, shape);
    }

    /// A menu's rows, or the search's results; `buffer` holds what's returned.
    fn fillMainRows(self: *const Painter, buffer: *[menu_mod.MAX_ROWS]PopupRow) []const PopupRow {
        if (self.menu) |open| return open.menu.fill(open.context, .main, buffer);
        if (self.state.region_menu) |*region_menu| return region_menu.fill(buffer);
        if (self.state.layers_menu) |*layers_menu| {
            var shown: [look.LAYER_ORDER.len]bool = undefined;
            for (&shown, look.LAYER_ORDER) |*is_shown, layer| is_shown.* = look.isLayerShown(&self.config.mapPanel, layer);
            return layers_menu.fill(shown, buffer);
        }
        const open = if (self.state.search) |*shown| shown else return buffer[0..0];
        return open.fill(buffer[0..search.MAX_ROWS]);
    }

    fn litPopupRow(self: *const Painter) ?usize {
        if (self.state.search) |*open| return open.litRow();
        if (self.state.region_menu) |*region_menu| return region_menu.litRow(self.state.hoveredIndex(.popup_row));
        if (self.state.layers_menu != null) return self.state.hoveredIndex(.popup_row);
        const open = self.menu orelse return null;
        return open.menu.litRow(self.has_eve_stars, self.state.hoveredIndex(.popup_row));
    }

    fn drawPopup(self: *const Painter, bitmap: *const gdi_overlay.OverlayBitmap, fonts: popup_menu.Fonts, popup: *popup_menu.PopupMenu) void {
        if (!self.state.isPopupOpen()) return;
        const search_box = self.areas.search_box;
        const is_searching = self.state.search != null;
        var main_rows: [menu_mod.MAX_ROWS]PopupRow = undefined;
        var options: popup_menu.DrawOptions = .{
            .rows = self.fillMainRows(&main_rows),
            .min_column_width = if (is_searching) look.SEARCH_WIDTH else 0,
            .lit_row = self.litPopupRow(),
            .flat_lit_color = if (is_searching) look.SEGMENT_HOVER else null,
            .row_height = if (is_searching) popup_look.rowHeightForBox(search_box.bottom - search_box.top) else null,
        };
        var submenu_rows: [menu_mod.MAX_ROWS]PopupRow = undefined;
        var character_rows: [menu_mod.MAX_ROWS]PopupRow = undefined;
        if (self.menu) |open| {
            const menu = open.menu;
            const context = open.context;
            if (menu.branch) |branch| options.submenu = .{
                .rows = menu.fill(context, .{ .branch = branch }, &submenu_rows),
                .parent_index = menu_mod.branchRowIndex(context.has_eve_stars, branch),
                .lit_row = menu.litSubmenuRow(context.targets, branch, self.state.hoveredIndex(.submenu_row)),
            };
            if (menu.shows_characters) {
                // The list can lose its last character while they're open.
                if (menu_mod.individualRow(context.targets)) |parent_index| options.nested = .{
                    .rows = menu.fill(context, .characters, &character_rows),
                    .parent_index = parent_index,
                    .lit_row = self.state.hoveredIndex(.nested_row),
                };
            }
        }
        const area = self.areas.body;
        // Offset by the gaps the grid leaves, so the results open flush with the box's right edge just below it.
        const anchor: win32.POINT = if (self.state.menu) |menu| menu.anchor else if (self.state.region_menu) |region_menu| region_menu.anchor else if (self.state.layers_menu) |layers_menu| layers_menu.anchor else .{
            .x = search_box.right + 2 * popup_look.TOOLTIP_PADDING,
            .y = search_box.bottom + look.SEARCH_RESULTS_GAP - popup_look.TOOLTIP_PADDING,
        };
        popup.draw(bitmap, fonts, area, anchor, options);
    }

    fn hoverAnchor(self: *const Painter) win32.POINT {
        return switch (self.state.hover.kind) {
            .node => .{ .x = self.state.layout.nodes[self.state.hover.index].x, .y = self.state.layout.nodes[self.state.hover.index].y },
            .exit => .{ .x = self.state.layout.exits[self.state.hover.index].x, .y = self.state.layout.exits[self.state.hover.index].y },
            .portal => .{ .x = self.state.layout.portals[self.state.hover.index].x, .y = self.state.layout.portals[self.state.hover.index].y },
            .region => .{ .x = self.state.overview.bubbles[self.state.hover.index].x, .y = self.state.overview.bubbles[self.state.hover.index].y },
            .map_control => blk: {
                const box = self.areas.mapControlBox(@fromBackingInt(@intCast(self.state.hover.index)));
                // Up by the gap the grid leaves, so the tooltip sits level with the control.
                break :blk .{ .x = box.left, .y = box.top - popup_look.TOOLTIP_PADDING };
            },
            .none, .title, .toggle, .bar, .metric, .intel_header, .card_tab, .intel_row, .kill_row, .wormhole_header, .wormhole_tab, .wormhole_row, .timer_header, .timer_row, .popup_row, .submenu_row, .nested_row, .search_box => .{ .x = 0, .y = 0 },
        };
    }
};

/// Null while they're hidden, or the last fetch didn't get them.
pub fn shownCampaigns(config: *const config_mod.Config, scene: Scene) ?*const Campaigns {
    const stats = scene.stats orelse return null;
    return if (config.mapPanel.showSovTimers and stats.has_campaigns) &stats.campaigns else null;
}

/// Null while they're hidden, or the last fetch didn't get them.
pub fn shownWormholes(config: *const config_mod.Config, scene: Scene) ?*const Connections {
    const stats = scene.stats orelse return null;
    return if (config.mapPanel.showWormholes and stats.has_wormholes) &stats.wormholes else null;
}

/// Null while they're hidden, without Eve Stars, or before any arrive.
pub fn shownBridges(config: *const config_mod.Config, has_eve_stars: bool, scene: Scene) ?*const Bridges {
    if (!config.mapPanel.showAnsiblex or !has_eve_stars) return null;
    const bridges = &scene.destinations.bridges;
    return if (bridges.count > 0) bridges else null;
}

pub fn cardTabName(tab: look.CardTab) []const u8 {
    return switch (tab) {
        .intel => "Intel",
        .kills => "Kills",
    };
}

/// What's shown; New Eden while picking a region.
pub fn titleText(state: *const MapState) FixedText {
    if (state.is_picking_region) return .print("New Eden", .{});
    return text_mod.regionsTitle(state.regions.slice());
}

/// `scale` is the zoom's marker scale.
pub fn intelHaloRadius(map_settings: *const config_mod.MapPanelConfig, pin: *const intel_pins.Pin, scale: f32, now_ms: u64) f32 {
    return look.intelHaloRadius(now_ms -| pin.seen_ms, map_settings.intelShrinkMs()) * scale;
}

fn portalColor(target: layout_mod.PortalTarget) u32 {
    return switch (target) {
        .hub => look.WORMHOLE,
        .system => look.ANSIBLEX,
    };
}

/// Each legend as a section of one card, in the map's bottom left and above `avoid` where it would cover it; filled after the labels it covers, so GDI has to finish them first.
fn drawLegends(bitmap: *const gdi_overlay.OverlayBitmap, legends: []const text_mod.Legend, areas: look.Areas, text: panel_chrome.Text, avoid: Box) void {
    const card = legendBox(bitmap.mem_dc, legends, areas, text, avoid) orelse return;
    const row_height = text.name_height + look.LEGEND_ROW_GAP;
    _ = win32.GdiFlush();
    look.drawCard(bitmap.canvas(), card);
    var y = card.top;
    for (legends, 0..) |*legend, index| {
        if (index > 0) look.drawLegendDivider(bitmap.canvas(), card, y);
        drawLegendSection(bitmap, legend, text, card, y, row_height);
        y += legendHeight(legend, text, row_height);
    }
}

/// In the bottom left, above `avoid` where they'd meet; null without legends, in a window too small for them, or once `avoid` keeps to the bottom left itself.
fn legendBox(dc: win32.HDC, legends: []const text_mod.Legend, areas: look.Areas, text: panel_chrome.Text, avoid: Box) ?Box {
    const row_height = text.name_height + look.LEGEND_ROW_GAP;
    var box_height: i32 = 0;
    for (legends) |*legend| box_height += legendHeight(legend, text, row_height);
    const box_width = cardWidth(dc, legends, text);
    const area = areas.body;
    const left = area.left + look.CARD_MARGIN;
    // A narrow window's toggle bar takes the corner, and stacking the legends above it would cover the map.
    if (avoid.left <= left) return null;
    var top = area.bottom - look.CARD_MARGIN - box_height;
    if (left + box_width > avoid.left and top + box_height > avoid.top) top = @min(top, avoid.top - look.CARD_GAP - box_height);
    if (legends.len == 0 or top < area.top or left + box_width > area.right) return null;
    return .{ .left = left, .top = top, .right = left + box_width, .bottom = top + box_height };
}

/// Its uppercase heading, its ramp, then its rows: a swatch, a name, and any value flush right.
fn drawLegendSection(bitmap: *const gdi_overlay.OverlayBitmap, legend: *const text_mod.Legend, text: panel_chrome.Text, card: Box, top: i32, row_height: i32) void {
    const dc = bitmap.mem_dc;
    const canvas = bitmap.canvas();
    const left = card.left + look.LEGEND_PADDING_X;
    const right = card.right - look.LEGEND_PADDING_X;
    var y = top + look.LEGEND_PADDING_Y;

    var heading_buffer: [panel_chrome.MAX_TEXT_LENGTH]u8 = undefined;
    _ = win32.SelectObject(dc, text.small_font);
    _ = win32.SetTextCharacterExtra(dc, look.LEGEND_HEADING_SPACING);
    panel_chrome.drawWideLine(dc, headingText(&heading_buffer, legend), left, y, look.CARD_MUTED);
    _ = win32.SetTextCharacterExtra(dc, 0);
    y += text.small_height + look.LEGEND_HEADING_GAP;

    _ = win32.SelectObject(dc, text.name_font);
    if (legend.ramp.len > 0) {
        const low_width = panel_chrome.textWidth(dc, legend.ramp_low.slice());
        panel_chrome.drawLine(dc, legend.ramp_low.slice(), left, y, look.CARD_MUTED);
        look.drawRamp(canvas, left + low_width + look.LEGEND_SWATCH_GAP, y, text.name_height, legend.ramp);
        panel_chrome.drawLine(dc, legend.ramp_high.slice(), left + low_width + 2 * look.LEGEND_SWATCH_GAP + look.LEGEND_RAMP_WIDTH, y, look.CARD_MUTED);
        y += row_height;
    }
    for (legend.rows[0..legend.row_count]) |*row| {
        look.drawLegendSwatch(canvas, left, y, text.name_height, row.swatch, row.is_area);
        const name_left = left + look.LEGEND_SWATCH_SIZE + look.LEGEND_SWATCH_GAP;
        var name_right = right;
        if (row.value.length > 0) {
            const value_width = panel_chrome.wideTextWidth(dc, row.value.slice());
            panel_chrome.drawWideLine(dc, row.value.slice(), right - value_width, y, look.CARD_MUTED);
            name_right = right - value_width - look.LEGEND_VALUE_GAP;
        }
        _ = panel_chrome.drawFitted(dc, row.text.slice(), name_left, y, list_look.NAME, name_right - name_left);
        y += row_height;
    }
}

/// The widest legend and the card's padding; leaves `dc` holding the name font.
fn cardWidth(dc: win32.HDC, legends: []const text_mod.Legend, text: panel_chrome.Text) i32 {
    var content_width: i32 = 0;
    for (legends) |*legend| content_width = @max(content_width, legendWidth(dc, legend, text));
    _ = win32.SelectObject(dc, text.name_font);
    return content_width + 2 * look.LEGEND_PADDING_X;
}

/// Leaves `dc` holding the name font.
fn legendWidth(dc: win32.HDC, legend: *const text_mod.Legend, text: panel_chrome.Text) i32 {
    var heading_buffer: [panel_chrome.MAX_TEXT_LENGTH]u8 = undefined;
    _ = win32.SelectObject(dc, text.small_font);
    _ = win32.SetTextCharacterExtra(dc, look.LEGEND_HEADING_SPACING);
    var width = panel_chrome.wideTextWidth(dc, headingText(&heading_buffer, legend));
    _ = win32.SetTextCharacterExtra(dc, 0);

    _ = win32.SelectObject(dc, text.name_font);
    if (legend.ramp.len > 0) {
        const ramp_width = panel_chrome.textWidth(dc, legend.ramp_low.slice()) + panel_chrome.textWidth(dc, legend.ramp_high.slice()) + look.LEGEND_RAMP_WIDTH + 2 * look.LEGEND_SWATCH_GAP;
        width = @max(width, ramp_width);
    }
    for (legend.rows[0..legend.row_count]) |*row| {
        var row_width = look.LEGEND_SWATCH_SIZE + look.LEGEND_SWATCH_GAP + panel_chrome.wideTextWidth(dc, row.text.slice());
        if (row.value.length > 0) row_width += look.LEGEND_VALUE_GAP + panel_chrome.wideTextWidth(dc, row.value.slice());
        width = @max(width, row_width);
    }
    return width;
}

fn legendHeight(legend: *const text_mod.Legend, text: panel_chrome.Text, row_height: i32) i32 {
    const line_count: i32 = @as(i32, @intFromBool(legend.ramp.len > 0)) + @as(i32, @intCast(legend.row_count));
    const lines_height = if (line_count > 0) line_count * row_height - look.LEGEND_ROW_GAP else 0;
    return 2 * look.LEGEND_PADDING_Y + text.small_height + look.LEGEND_HEADING_GAP + lines_height;
}

/// The legend's title in capitals, as the dialog's small headings are; borrows from `buffer`.
fn headingText(buffer: *[panel_chrome.MAX_TEXT_LENGTH]u8, legend: *const text_mod.Legend) []const u8 {
    const title = legend.title.slice();
    const length = @min(title.len, buffer.len);
    return std.ascii.upperString(buffer[0..length], title[0..length]);
}

/// Centred above the toggle bar, `toggle_bar`.
fn drawNotice(bitmap: *const gdi_overlay.OverlayBitmap, destinations: *const Destinations, areas: look.Areas, toggle_bar: Box, fonts: MapFonts) void {
    const notice = if (destinations.notice) |*shown| shown else return;
    const tooltip = text_mod.noticeTooltip(notice);
    if (tooltip.line_count == 0) return;
    const shape = tooltipShape(bitmap.mem_dc, &tooltip, fonts);
    const size = shape.size;
    const area = areas.body;
    const middle = @divTrunc(toggle_bar.left + toggle_bar.right, 2);
    const left = std.math.clamp(middle - @divTrunc(size.x, 2), area.left, @max(area.left, area.right - size.x));
    const top = @max(area.top, toggle_bar.top - 2 * look.CARD_GAP - size.y);
    drawTextBox(bitmap, &tooltip, .{ .left = left, .top = top, .right = left + size.x, .bottom = top + size.y }, fonts, shape);
}

/// A tooltip's title, its accent and aside, then each line, its label in a column of its own; `tooltip` has a title.
fn tooltipShape(dc: win32.HDC, tooltip: *const text_mod.Tooltip, fonts: MapFonts) TooltipShape {
    const text = fonts.chrome;
    const is_detailed = tooltip.isDetailed();
    const padding: win32.POINT = if (is_detailed) .{ .x = look.TOOLTIP_PADDING_X, .y = look.TOOLTIP_PADDING_Y } else .{ .x = popup_look.TOOLTIP_PADDING, .y = popup_look.TOOLTIP_PADDING };
    _ = win32.SelectObject(dc, tooltipTitleFont(tooltip, fonts));
    var header_width = panel_chrome.wideTextWidth(dc, tooltip.line(0));
    if (tooltip.accent.length > 0) header_width += look.TOOLTIP_PART_GAP + panel_chrome.wideTextWidth(dc, tooltip.accent.slice());
    if (tooltip.aside.length > 0) {
        _ = win32.SelectObject(dc, text.small_font);
        header_width += look.TOOLTIP_ASIDE_GAP + panel_chrome.wideTextWidth(dc, tooltip.aside.slice());
    }

    _ = win32.SelectObject(dc, text.name_font);
    var label_column: i32 = 0;
    for (1..tooltip.line_count) |index| {
        const label = tooltip.label(index);
        if (label.len > 0) label_column = @max(label_column, panel_chrome.wideTextWidth(dc, label) + look.TOOLTIP_LABEL_GAP);
    }
    var content_width = header_width;
    for (1..tooltip.line_count) |index| {
        const indent = if (tooltip.label(index).len > 0) label_column else 0;
        content_width = @max(content_width, indent + panel_chrome.wideTextWidth(dc, tooltip.line(index)));
    }

    const row_gap: i32 = if (is_detailed) look.TOOLTIP_ROW_GAP else 0;
    const row_count: i32 = @intCast(tooltip.line_count - 1);
    const rule_room: i32 = if (is_detailed and row_count > 0) 2 * look.TOOLTIP_HEADER_GAP + 1 else 0;
    const rows_top = padding.y + text.name_height + rule_room;
    const rows_height = row_count * (text.name_height + row_gap) - if (row_count > 0) row_gap else 0;
    return .{
        .size = .{ .x = content_width + 2 * padding.x, .y = rows_top + rows_height + padding.y },
        .padding = padding,
        .rows_top = rows_top,
        .row_height = text.name_height + row_gap,
        .label_column = label_column,
    };
}

/// Filled after the labels it covers, so GDI has to finish them first.
fn drawTextBox(bitmap: *const gdi_overlay.OverlayBitmap, tooltip: *const text_mod.Tooltip, box: Box, fonts: MapFonts, shape: TooltipShape) void {
    const dc = bitmap.mem_dc;
    const text = fonts.chrome;
    _ = win32.GdiFlush();
    const canvas = bitmap.canvas();
    look.drawCard(canvas, box);
    const left = box.left + shape.padding.x;
    const right = box.right - shape.padding.x;
    const top = box.top + shape.padding.y;
    if (shape.rows_top > shape.padding.y + text.name_height) look.drawDivider(canvas, left, right, top + text.name_height + look.TOOLTIP_HEADER_GAP);

    _ = win32.SelectObject(dc, tooltipTitleFont(tooltip, fonts));
    const title_width = panel_chrome.drawFitted(dc, tooltip.line(0), left, top, tooltip.lineColor(0), right - left);
    if (tooltip.accent.length > 0) {
        const accent_left = left + title_width + look.TOOLTIP_PART_GAP;
        _ = panel_chrome.drawFitted(dc, tooltip.accent.slice(), accent_left, top, tooltip.accent_color, right - accent_left);
    }
    if (tooltip.aside.length > 0) {
        _ = win32.SelectObject(dc, text.small_font);
        const aside = tooltip.aside.slice();
        panel_chrome.drawWideLine(dc, aside, right - panel_chrome.wideTextWidth(dc, aside), centredTop(.{ .left = left, .top = top, .right = right, .bottom = top + text.name_height }, text.small_height), list_look.MUTED);
    }

    _ = win32.SelectObject(dc, text.name_font);
    var y = box.top + shape.rows_top;
    for (1..tooltip.line_count) |index| {
        const label = tooltip.label(index);
        if (label.len > 0) panel_chrome.drawWideLine(dc, label, left, y, list_look.MUTED);
        const indent = if (label.len > 0) shape.label_column else 0;
        panel_chrome.drawWideLine(dc, tooltip.line(index), left + indent, y, tooltip.lineColor(index));
        y += shape.row_height;
    }
}

fn tooltipTitleFont(tooltip: *const text_mod.Tooltip, fonts: MapFonts) win32.HFONT {
    return if (tooltip.isDetailed()) fonts.semibold_font else fonts.chrome.name_font;
}

fn centredTop(box: Box, height: i32) i32 {
    return box.top + @divTrunc(box.bottom - box.top - height, 2);
}

/// A dark outline, so a name stays readable across the gates running behind it; copies and sets up once for all its draws, as there are hundreds a frame.
fn drawHaloText(dc: win32.HDC, text: []const u8, x: i32, y: i32, text_color: u32, outline: Outline) void {
    const buffer = gdi_overlay.terminatedCopy(panel_chrome.MAX_TEXT_LENGTH, text);
    const length: c_int = @intCast(@min(text.len, panel_chrome.MAX_TEXT_LENGTH - 1));
    _ = win32.SetBkMode(dc, win32.TRANSPARENT);
    _ = win32.SetTextColor(dc, gdi_overlay.toColorRef(look.BACKGROUND));
    switch (outline) {
        .full => inline for (.{ [2]i32{ -1, 0 }, [2]i32{ 1, 0 }, [2]i32{ 0, -1 }, [2]i32{ 0, 1 } }) |offset| {
            _ = win32.TextOutA(dc, x + offset[0], y + offset[1], &buffer, length);
        },
        .shadow => _ = win32.TextOutA(dc, x + 1, y + 1, &buffer, length),
    }
    _ = win32.SetTextColor(dc, gdi_overlay.toColorRef(text_color));
    _ = win32.TextOutA(dc, x, y, &buffer, length);
}

/// UTF-8, as character names can be; slower than drawHaloText, so kept to the few client tags.
fn drawHaloWideText(dc: win32.HDC, text: []const u8, x: i32, y: i32, text_color: u32) void {
    inline for (.{ [2]i32{ -1, 0 }, [2]i32{ 1, 0 }, [2]i32{ 0, -1 }, [2]i32{ 0, 1 } }) |offset| {
        panel_chrome.drawWideLine(dc, text, x + offset[0], y + offset[1], look.BACKGROUND);
    }
    panel_chrome.drawWideLine(dc, text, x, y, text_color);
}

/// `nodes` are the systems shown.
fn legendFor(scene: Scene, paint: *const MapPaint, nodes: []const layout_mod.Node) text_mod.Legend {
    return switch (paint.metric) {
        .Security => text_mod.securityLegend(),
        .ShipKills, .PodKills, .NpcKills, .Jumps => text_mod.heatLegend(paint.metric, paint.peak, scene.stats != null),
        .NpcDelta => text_mod.deltaLegend(paint.peak, if (scene.stats) |stats| stats.has_npc_delta else false),
        .Sovereignty => text_mod.sovereigntyLegend(&paint.holders, scene.stats),
        .FactionWarfare => text_mod.warfareLegend(scene.stats, nodes),
    };
}

/// Null where no storm covers the gate between them, or `storms` is.
fn stormEdgeColor(storms: ?*const Storms, first: SystemIndex, second: SystemIndex) ?u32 {
    const shown = storms orelse return null;
    const mark = shown.edgeMark(first, second) orelse return null;
    return look.stormEdgeColor(mark);
}

/// Null unless a storm is centred on `system`.
fn stormCenterColor(storms: ?*const Storms, system: SystemIndex) ?u32 {
    const shown = storms orelse return null;
    const storm = shown.centeredOn(system) orelse return null;
    return look.stormColor(storm.kind);
}

/// Null where no incursion covers the gate between them, or `incursions` is.
fn incursionEdgeColor(incursions: ?*const Incursions, first: SystemIndex, second: SystemIndex) ?u32 {
    const shown = incursions orelse return null;
    return if (shown.coversGate(first, second)) look.INCURSION else null;
}

/// Null outside Sovereignty and Faction Warfare, or unless one holder or occupier has both ends, so a grey gate marks where two meet.
fn holderEdgeColor(scene: Scene, paint: *const MapPaint, first: SystemIndex, second: SystemIndex) ?u32 {
    const stats = scene.stats orelse return null;
    if (paint.metric == .FactionWarfare) {
        const occupier = stats.warfare[first].occupier;
        if (occupier == faction_warfare.NO_FACTION or occupier != stats.warfare[second].occupier) return null;
        return look.factionColorOf(occupier);
    }
    if (paint.metric != .Sovereignty) return null;
    const holder = stats.systems[first].holder;
    if (holder == stats_mod.NO_HOLDER or holder != stats.systems[second].holder) return null;
    return paint.holders.colorOf(holder);
}

/// Null unless an incursion stages from `system`.
fn incursionStagingColor(incursions: ?*const Incursions, system: SystemIndex) ?u32 {
    const shown = incursions orelse return null;
    return if (shown.stagedAt(system) != null) look.INCURSION else null;
}

fn markerColor(scene: Scene, paint: *const MapPaint, system: SystemIndex, value: u32) u32 {
    return switch (paint.metric) {
        .Security => look.securityColor(universe.systemInfo(system).security_tenths),
        .ShipKills, .PodKills, .NpcKills, .Jumps => look.heatColor(value, paint.peak),
        .NpcDelta => if (scene.stats) |stats| look.deltaColor(stats.systems[system].npc_delta, paint.peak) else look.HEAT_NONE,
        .Sovereignty => paint.holders.colorOf(if (scene.stats) |stats| stats.systems[system].holder else stats_mod.NO_HOLDER),
        .FactionWarfare => if (scene.stats) |stats| look.warfareColor(stats.warfare[system]) else look.HEAT_NONE,
    };
}

/// The busiest system shown by `metric`, which heat is measured against.
fn peakValue(layout: *const Layout, scene: Scene, metric: MapMetric) u32 {
    const stats = scene.stats orelse return 0;
    var peak: u32 = 0;
    for (layout.nodes[0..layout.node_count]) |node| peak = @max(peak, look.metricValue(metric, stats.systems[node.system]));
    return peak;
}
