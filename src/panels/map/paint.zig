//! Draws the Map Panel's frame from what it shows; nothing here changes the map's state.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const gdi_overlay = @import("../../platform/gdi_overlay.zig");
const config_mod = @import("../../config.zig");
const types = @import("../../config/types.zig");
const history = @import("../../notifications/history.zig");
const history_look = @import("../history_look.zig");
const history_rows = @import("../history_rows.zig");
const list_look = @import("../list_look.zig");
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
const intel_pins = @import("../../map/intel_pins.zig");
const destinations_mod = @import("../../map/destinations.zig");
const window = @import("../../thumbnail/window.zig");
const fixed_text = @import("../../util/fixed_text.zig");
const pixel_buffer = @import("../../util/pixel_buffer.zig");
const log = @import("../../log.zig");

const Box = layout_mod.Box;
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
};

/// The shared fonts, and the map's own for the names on it.
pub const MapFonts = struct {
    chrome: panel_chrome.Text,
    label_font: win32.HFONT,
    label_height: i32,
    title_font: win32.HFONT,
    title_height: i32,
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
    intel_rows: *[history.CAPACITY]history_rows.Row,
    /// Borrowed for one render.
    intel_row_count: *usize,
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
    sizes: look.Metrics,
    has_eve_stars: bool,
    /// Null while the menu's closed.
    menu: ?OpenMenu,
    panel_height: i32,
    /// For the storm and incursion areas' mask, freed before draw returns.
    allocator: std.mem.Allocator,

    /// With `bitmap` begun and the panel's font selected.
    pub fn draw(self: *const Painter, bitmap: *const gdi_overlay.OverlayBitmap, scene: Scene, fonts: ?MapFonts, intel_entries: []const history.Entry, now_ms: u64, measured: Measured) void {
        const dc = bitmap.mem_dc;
        const canvas = bitmap.canvas();
        const areas = self.areas;
        const panel_width = @max(1, areas.inner.right);
        const footer_top = panel_look.footerTop(@max(1, self.panel_height), 0, self.sizes.footer_height);
        const buttons = self.footerButtons();

        look.drawGrid(canvas, areas.body, if (self.state.is_picking_region) .{} else self.state.layout.view);
        const paint = self.mapPaint(scene);
        if (self.state.is_picking_region) {
            self.drawOverview(canvas, scene);
        } else {
            self.drawMap(canvas, scene, &paint, now_ms);
        }

        // After the map, which a new intel halo can reach past.
        const sidebar = areas.sidebar;
        if (sidebar) |box| self.fillIntelSidebar(canvas, box);
        panel_chrome.fillFooter(canvas, footer_top);
        panel_chrome.fillButtons(canvas, &buttons, panel_width, footer_top, self.sizes.header_height);

        if (fonts) |loaded| {
            panel_chrome.drawButtonLabels(dc, loaded.chrome, &buttons, panel_width, footer_top, self.sizes.header_height);
            self.drawRegionTitle(dc, loaded, scene);
            if (self.state.is_picking_region) {
                self.drawOverviewLabels(dc, loaded.label_font);
            } else {
                self.drawRegionLabels(dc, loaded.title_font);
                self.drawLabels(dc, scene, loaded.label_font, now_ms);
                self.drawClientTags(bitmap, loaded.chrome, scene, &paint);
                self.drawMapControls(bitmap);
                const legend = if (self.state.reach) |*reach| text_mod.rangeLegend(reach) else legendFor(scene, &paint);
                var legend_top = drawLegend(bitmap, &legend, areas, loaded.chrome, areas.body.bottom);
                if (self.stormLegend(scene)) |*storm_legend| legend_top = drawLegend(bitmap, storm_legend, areas, loaded.chrome, legend_top);
                if (self.incursionLegend(scene)) |*incursion_legend| _ = drawLegend(bitmap, incursion_legend, areas, loaded.chrome, legend_top);
            }
            self.drawSearchBox(bitmap, loaded.chrome, measured.search_stops);
            self.drawTooltip(bitmap, scene, loaded.chrome, now_ms);
            if (sidebar) |box| self.drawIntelRows(dc, loaded.chrome, box, intel_entries, measured);
            self.drawPopup(bitmap, loaded.chrome, measured.popup);
            drawNotice(bitmap, scene.destinations, areas, loaded.chrome);
        }
    }

    fn isButtonLit(self: *const Painter, button: look.Button) bool {
        const map_settings = &self.config.mapPanel;
        if (look.metricOf(button)) |metric| return map_settings.metric == metric;
        return switch (button) {
            .regions => self.state.is_picking_region,
            .follow => map_settings.followActive,
            .storms => map_settings.showStorms,
            .incursions => map_settings.showIncursions,
            .security, .kills, .npc_kills, .jumps, .sovereignty => false,
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

    /// Over any of the map that reached past its side, like a new intel halo.
    fn fillIntelSidebar(self: *const Painter, canvas: pixel_buffer.Canvas, box: Box) void {
        pixel_buffer.fillRect(canvas, @intCast(box.left), @intCast(box.top), @intCast(box.right - box.left), @intCast(box.bottom - box.top), list_look.PANEL);
        const divider_x = switch (self.config.intelPanel.side) {
            .Left => box.right,
            .Right => box.left - 1,
        };
        pixel_buffer.fillRect(canvas, @intCast(divider_x), @intCast(box.top), 1, @intCast(box.bottom - box.top), list_look.DIVIDER);
    }

    fn drawIntelRows(self: *const Painter, dc: win32.HDC, text: panel_chrome.Text, box: Box, entries: []const history.Entry, measured: Measured) void {
        const history_settings = &self.config.historyPanel;
        const row_sizes: history_look.Metrics = .{ .header_height = 0, .row_height = history_rows.intelRowHeight(history_settings), .footer_height = self.sizes.footer_height };
        const capacity = history_look.rowsThatFit(self.panel_height, row_sizes, history.CAPACITY);
        measured.intel_row_count.* = history_rows.build(measured.intel_rows, entries, capacity, history_rows.buildOptions(history_settings, null));
        const area = history_rows.intelArea(history_settings, &self.config.intelPanel, box.left, box.top, box.right);
        history_rows.drawIntel(dc, text, measured.intel_rows[0..measured.intel_row_count.*], entries, &self.config.thumbnail.notifications, area);
    }

    fn footerButtons(self: *const Painter) [look.BUTTON_ORDER.len]panel_chrome.Button {
        var buttons: [look.BUTTON_ORDER.len]panel_chrome.Button = undefined;
        for (look.BUTTON_ORDER, &buttons) |button, *shown| shown.* = .{ .label = text_mod.buttonLabel(button), .is_lit = self.isButtonLit(button) };
        return buttons;
    }

    /// Filled after the labels it covers, so GDI has to finish them first; `stops` gets where the query's gaps were drawn.
    fn drawSearchBox(self: *const Painter, bitmap: *const gdi_overlay.OverlayBitmap, text: panel_chrome.Text, stops: *search.Stops) void {
        const box = self.areas.search_box;
        _ = win32.GdiFlush();
        // The cursor tends to stay on the box after the click that opens it.
        look.drawOverlayButton(bitmap.canvas(), box, self.state.hover.kind == .search_box and self.state.search == null);

        const dc = bitmap.mem_dc;
        _ = win32.SelectObject(dc, text.name_font);
        const y = box.top + @divTrunc(box.bottom - box.top - text.name_height, 2);
        const left = box.left + panel_look.BUTTON_GAP;
        const right = box.right - panel_look.BUTTON_GAP;
        const open = if (self.state.search) |*shown| shown else {
            _ = panel_chrome.drawFitted(dc, "Search map", left, y, list_look.MUTED, right - left);
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

    /// Bubbles coloured by the traffic the map shows, or by security when it shows neither.
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
        for (overview.bubbles, totals, 0..) |bubble, total, index| {
            const region: RegionIndex = @intCast(index);
            const heat_color = if (peak > 0) look.heatColor(total, peak) else look.securityColor(bubble.security_tenths);
            const bubble_color = if (self.state.reach) |*reach| look.regionRangeColor(reach.region_counts[region]) else heat_color;
            look.drawMarker(canvas, bubble.x, bubble.y, bubble.radius, bubble_color);
            const is_hovered = self.state.hover.kind == .region and self.state.hover.index == region;
            // A picked region's ring is heavier than a hover's, so the picks stay visible while pointing elsewhere.
            const ring_thickness = if (self.state.regions.contains(region)) look.FOCUS_RING_THICKNESS else if (is_hovered) look.RING_THICKNESS else null;
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
            const label_color = if (self.state.marks.countIn(region) > 0) self.config.listView.activeColor else if (is_hovered or self.state.regions.contains(region)) list_look.NAME else look.LABEL;
            drawHaloText(dc, universe.regionName(region), label.left, label.top, label_color, .full);
        }
    }

    /// The name of what's shown, and its figures for the last hour.
    fn drawRegionTitle(self: *const Painter, dc: win32.HDC, fonts: MapFonts, scene: Scene) void {
        const area = self.areas.body;
        const x = area.left + look.OVERLAY_MARGIN;
        const y = area.top + 2;
        const room = self.areas.search_box.left - x - look.OVERLAY_MARGIN;
        _ = win32.SelectObject(dc, fonts.title_font);
        const title: FixedText = if (self.state.is_picking_region) .print("New Eden", .{}) else text_mod.regionsTitle(self.state.regions.slice());
        _ = panel_chrome.drawFitted(dc, title.slice(), x, y, look.TITLE, room);

        const nodes = self.state.layout.nodes[0..self.state.layout.node_count];
        const totals: ?text_mod.RegionTotals = if (scene.stats) |stats| .fromNodes(stats, nodes) else null;
        const summary: FixedText = if (self.state.is_picking_region) .print("{d} regions, {d} systems. Click one to open it, Ctrl+click to show it alongside.", .{ universe.REGION_COUNT, universe.SYSTEM_COUNT }) else text_mod.regionSummary(self.state.layout.node_count, totals);
        _ = win32.SelectObject(dc, fonts.chrome.small_font);
        _ = panel_chrome.drawFitted(dc, summary.slice(), x, y + fonts.title_height, list_look.MUTED, room);
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
        // The names first, then the tags as they're placed, so the tags alone are the slice's end.
        var taken: [layout_mod.MAX_NODES + marks.MAX_MARKS]Box = undefined;
        var taken_count: usize = 0;
        for (layout.nodes[0..layout.node_count]) |node| {
            const label = node.label orelse continue;
            taken[taken_count] = look.labelChipBox(label);
            taken_count += 1;
        }
        const label_count = taken_count;
        for (self.state.marks.slice(), 0..) |mark, index| {
            if (!self.state.marks.leadsSystem(index)) continue;
            const node_index = layout.nodeOf(mark.system) orelse continue;
            const node = layout.nodes[node_index];
            const label = text_mod.clientTagText(mark.character_name, self.state.marks.countAt(mark.system) - 1);
            const box_width = panel_chrome.wideTextWidth(dc, label.slice()) + 2 * layout_mod.CHIP_PADDING_X;
            const box_height = text.small_height + 2 * layout_mod.CHIP_PADDING_Y;
            const reach = self.markReach(scene, paint, mark.system);
            const offset = look.clientTagOffset(reach);
            // Over a name rather than dropped, where the names leave no room near the marker.
            const box = look.clientTagBox(area, node.x, node.y, offset, box_width, box_height, taken[0..taken_count]) orelse
                look.clientTagBox(area, node.x, node.y, offset, box_width, box_height, taken[label_count..taken_count]) orelse continue;
            taken[taken_count] = box;
            taken_count += 1;
            look.drawClientTag(canvas, node.x, node.y, reach, box, self.markColor(mark));
            panel_chrome.drawWideLine(dc, label.slice(), box.left + layout_mod.CHIP_PADDING_X, box.top + layout_mod.CHIP_PADDING_Y, list_look.NAME);
        }
    }

    /// Filled after the labels they cover, so GDI has to finish them first.
    fn drawMapControls(self: *const Painter, bitmap: *const gdi_overlay.OverlayBitmap) void {
        _ = win32.GdiFlush();
        const canvas = bitmap.canvas();
        const area = self.areas.body;
        for (std.enums.values(look.MapControl)) |control| {
            const box = look.mapControlBox(area, control);
            if (box.left < 0) continue;
            const is_hovered = self.state.hover.kind == .map_control and self.state.hover.index == @backingInt(control);
            look.drawOverlayButton(canvas, box, is_hovered);
            look.drawMapControlGlyph(canvas, box, control, self.config.mapPanel.alwaysOnTop);
        }
    }

    /// The selected system's disc, out past its ring.
    fn focusRadius(self: *const Painter, scene: Scene, paint: *const MapPaint, system: SystemIndex) f32 {
        const value = if (scene.stats) |stats| look.metricValue(paint.metric, stats.systems[system]) else 0;
        return look.markerRadius(value, paint.peak) * look.markerScale(self.state.layout.view.zoom) + look.RING_GAP + look.FOCUS_OUTLINE_THICKNESS;
    }

    /// How far the rings around a client's marker go: the selected system's border, else the client's ring.
    fn markReach(self: *const Painter, scene: Scene, paint: *const MapPaint, system: SystemIndex) f32 {
        if (self.state.focus_system == system) return self.focusRadius(scene, paint, system) + look.FOCUS_BORDER;
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
            if (exit.label) |label| look.drawExitChip(canvas, label, is_hovered);
        }
        if (self.state.focusNode()) |node| look.drawFocusMark(canvas, node.x, node.y, self.focusRadius(scene, paint, node.system), node.label);

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
        if (self.has_eve_stars) self.drawAvoidMarks(canvas);
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
        _ = win32.SelectObject(dc, label_font);
        const outline: Outline = if (self.state.isPanning()) .shadow else .full;
        for (layout.nodes[0..layout.node_count], 0..) |node, index| {
            const label = node.label orelse continue;
            const plain_color = if (self.state.isNoteworthy(node.system)) list_look.NAME else look.LABEL;
            const label_color = if (scene.pins.find(node.system, self.config.mapPanel.intelShrinkMs(), now_ms)) |pin| look.intelColor(pin.is_clear) else stormCenterColor(storms, node.system) orelse incursionStagingColor(incursions, node.system) orelse plain_color;
            drawHaloText(dc, universe.systemName(node.system), label.left, label.top, label_color, outline);
            var suffix_buffer: [text_mod.SECURITY_TEXT_MAX]u8 = undefined;
            const suffix = self.labelSuffix(node.system, &suffix_buffer) orelse continue;
            drawHaloText(dc, suffix.text, label.left + self.state.label_widths.names[index] + look.LABEL_SUFFIX_GAP, label.top, suffix.color, outline);
        }
        for (layout.exits[0..layout.exit_count]) |exit| {
            const label = exit.label orelse continue;
            panel_chrome.drawLine(dc, text_mod.exitLabel(exit).slice(), label.left, label.top, look.EXIT);
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
            .none, .button, .intel_row, .popup_row, .submenu_row, .nested_row, .search_box => return null,
            .map_control => return text_mod.mapControlTooltip(@fromBackingInt(@intCast(self.state.hover.index)), self.config.mapPanel.alwaysOnTop),
            .region => {
                const region: RegionIndex = @intCast(self.state.hover.index);
                return text_mod.regionTooltip(region, self.state.overview.bubbles[region].system_count, self.state.marks.countIn(region), if (self.state.reach) |*reach| reach else null, self.shownStorms(scene), self.shownIncursions(scene));
            },
            .exit => {
                const exit = self.state.layout.exits[self.state.hover.index];
                return text_mod.exitTooltip(self.state.layout.nodes[exit.from_index].system, exit.destination);
            },
            .node => self.state.layout.nodes[self.state.hover.index].system,
        };
        var facts: text_mod.SystemFacts = .{ .system = system, .stats = scene.stats, .is_avoided = self.has_eve_stars and self.config.avoidedSystemIndex(universe.systemInfo(system).id) != null, .reach = if (self.state.reach) |*reach| reach else null, .storms = self.shownStorms(scene), .incursions = self.shownIncursions(scene) };
        var names: [marks.MAX_MARKS][]const u8 = undefined;
        facts.characters = self.state.marks.namesAt(system, &names);
        if (scene.pins.find(system, self.config.mapPanel.intelShrinkMs(), now_ms)) |pin| {
            facts.intel_message = pin.message();
            facts.intel_age_ms = now_ms -| pin.seen_ms;
        }
        return text_mod.systemTooltip(facts);
    }

    /// Filled after the labels it covers, so GDI has to finish them first.
    fn drawTooltip(self: *const Painter, bitmap: *const gdi_overlay.OverlayBitmap, scene: Scene, text: panel_chrome.Text, now_ms: u64) void {
        const tooltip = self.tooltipFor(scene, now_ms) orelse return;
        drawTextBox(bitmap, &tooltip, self.hoverAnchor(), self.areas, text);
    }

    /// The menu's rows, or the search's results; `buffer` holds what's returned.
    fn fillMainRows(self: *const Painter, buffer: *[menu_mod.MAX_ROWS]PopupRow) []const PopupRow {
        if (self.menu) |open| return open.menu.fill(open.context, .main, buffer);
        const open = if (self.state.search) |*shown| shown else return buffer[0..0];
        return open.fill(buffer[0..search.MAX_ROWS]);
    }

    fn litPopupRow(self: *const Painter) ?usize {
        if (self.state.search) |*open| return open.litRow();
        const open = self.menu orelse return null;
        return open.menu.litRow(self.has_eve_stars, self.state.hoveredIndex(.popup_row));
    }

    fn drawPopup(self: *const Painter, bitmap: *const gdi_overlay.OverlayBitmap, text: panel_chrome.Text, popup: *popup_menu.PopupMenu) void {
        if (!self.state.isPopupOpen()) return;
        const search_box = self.areas.search_box;
        const is_searching = self.state.search != null;
        var main_rows: [menu_mod.MAX_ROWS]PopupRow = undefined;
        var options: popup_menu.DrawOptions = .{
            .rows = self.fillMainRows(&main_rows),
            .min_column_width = if (is_searching) look.SEARCH_WIDTH else 0,
            .lit_row = self.litPopupRow(),
            .flat_lit_color = if (is_searching) look.FOCUS_MARK else null,
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
        // Offset by the gaps the grid leaves, so the results open flush with the box's right edge and the zoom-out button's top.
        const anchor: win32.POINT = if (self.state.menu) |menu| menu.anchor else .{
            .x = search_box.right + 2 * popup_look.TOOLTIP_PADDING,
            .y = look.mapControlBox(area, .zoom_out).top - popup_look.TOOLTIP_PADDING,
        };
        popup.draw(bitmap, text, area, anchor, options);
    }

    fn hoverAnchor(self: *const Painter) win32.POINT {
        return switch (self.state.hover.kind) {
            .node => .{ .x = self.state.layout.nodes[self.state.hover.index].x, .y = self.state.layout.nodes[self.state.hover.index].y },
            .exit => .{ .x = self.state.layout.exits[self.state.hover.index].x, .y = self.state.layout.exits[self.state.hover.index].y },
            .region => .{ .x = self.state.overview.bubbles[self.state.hover.index].x, .y = self.state.overview.bubbles[self.state.hover.index].y },
            .map_control => blk: {
                const box = look.mapControlBox(self.areas.body, @fromBackingInt(@intCast(self.state.hover.index)));
                // Up by the gap the grid leaves, so the tooltip sits level with the control.
                break :blk .{ .x = box.left, .y = box.top - popup_look.TOOLTIP_PADDING };
            },
            .none, .button, .intel_row, .popup_row, .submenu_row, .nested_row, .search_box => .{ .x = 0, .y = 0 },
        };
    }
};

/// `scale` is the zoom's marker scale.
pub fn intelHaloRadius(map_settings: *const config_mod.MapPanelConfig, pin: *const intel_pins.Pin, scale: f32, now_ms: u64) f32 {
    return look.intelHaloRadius(now_ms -| pin.seen_ms, map_settings.intelShrinkMs()) * scale;
}

/// In the map's left side above `bottom`, returning where the next one stacks; filled after the labels it covers, so GDI has to finish them first.
fn drawLegend(bitmap: *const gdi_overlay.OverlayBitmap, legend: *const text_mod.Legend, areas: look.Areas, text: panel_chrome.Text, bottom: i32) i32 {
    const dc = bitmap.mem_dc;
    _ = win32.SelectObject(dc, text.small_font);
    const line_height = text.small_height;
    const has_ramp = legend.ramp.len > 0;
    const low_width = panel_chrome.textWidth(dc, legend.ramp_low.slice());
    const high_width = panel_chrome.textWidth(dc, legend.ramp_high.slice());
    const swatch_room = look.LEGEND_SWATCH_SIZE + look.OVERLAY_PADDING;

    var content_width = panel_chrome.wideTextWidth(dc, legend.title.slice());
    if (has_ramp) content_width = @max(content_width, low_width + high_width + look.LEGEND_RAMP_WIDTH + 2 * look.OVERLAY_PADDING);
    for (legend.rows[0..legend.row_count]) |row| content_width = @max(content_width, swatch_room + panel_chrome.wideTextWidth(dc, row.text.slice()));

    const area = areas.body;
    const line_count: i32 = 1 + @as(i32, @intFromBool(has_ramp)) + @as(i32, @intCast(legend.row_count));
    const box_height = line_count * line_height + 2 * look.OVERLAY_PADDING;
    const box_width = content_width + 2 * look.OVERLAY_PADDING;
    const left = area.left + look.OVERLAY_MARGIN;
    const top = bottom - look.OVERLAY_MARGIN - box_height;
    // A window too small for it goes without.
    if (top < area.top or left + box_width > area.right) return bottom;

    _ = win32.GdiFlush();
    const canvas = bitmap.canvas();
    look.drawOverlayButton(canvas, .{ .left = left, .top = top, .right = left + box_width, .bottom = top + box_height }, false);

    const x = left + look.OVERLAY_PADDING;
    var y = top + look.OVERLAY_PADDING;
    panel_chrome.drawWideLine(dc, legend.title.slice(), x, y, list_look.NAME);
    y += line_height;
    if (has_ramp) {
        panel_chrome.drawLine(dc, legend.ramp_low.slice(), x, y, list_look.MUTED);
        look.drawRamp(canvas, x + low_width + look.OVERLAY_PADDING, y, line_height, legend.ramp);
        panel_chrome.drawLine(dc, legend.ramp_high.slice(), x + low_width + 2 * look.OVERLAY_PADDING + look.LEGEND_RAMP_WIDTH, y, list_look.MUTED);
        y += line_height;
    }
    for (legend.rows[0..legend.row_count]) |row| {
        const swatch_top = y + @divTrunc(line_height - look.LEGEND_SWATCH_SIZE, 2);
        pixel_buffer.fillRect(canvas, @intCast(x), @intCast(swatch_top), @intCast(look.LEGEND_SWATCH_SIZE), @intCast(look.LEGEND_SWATCH_SIZE), row.swatch);
        panel_chrome.drawWideLine(dc, row.text.slice(), x + swatch_room, y, list_look.MUTED);
        y += line_height;
    }
    return top;
}

fn drawNotice(bitmap: *const gdi_overlay.OverlayBitmap, destinations: *const Destinations, areas: look.Areas, text: panel_chrome.Text) void {
    const notice = if (destinations.notice) |*shown| shown else return;
    const area = areas.body;
    const tooltip = text_mod.noticeTooltip(notice);
    drawTextBox(bitmap, &tooltip, .{ .x = area.left, .y = area.bottom }, areas, text);
}

fn drawTextBox(bitmap: *const gdi_overlay.OverlayBitmap, tooltip: *const text_mod.Tooltip, anchor: win32.POINT, areas: look.Areas, text: panel_chrome.Text) void {
    const dc = bitmap.mem_dc;
    _ = win32.SelectObject(dc, text.name_font);

    var box_width: i32 = 0;
    for (0..tooltip.line_count) |index| box_width = @max(box_width, panel_chrome.wideTextWidth(dc, tooltip.line(index)));
    box_width += 2 * popup_look.TOOLTIP_PADDING;
    const line_count: i32 = @intCast(tooltip.line_count);
    const box_height = line_count * text.name_height + 2 * popup_look.TOOLTIP_PADDING;

    const box = popup_look.tooltipBox(areas.body, anchor.x, anchor.y, box_width, box_height);
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

fn legendFor(scene: Scene, paint: *const MapPaint) text_mod.Legend {
    return switch (paint.metric) {
        .Security => text_mod.securityLegend(),
        .ShipKills, .NpcKills, .Jumps => text_mod.heatLegend(paint.metric, paint.peak, scene.stats != null),
        .Sovereignty => text_mod.sovereigntyLegend(&paint.holders, scene.stats),
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

/// Null outside Sovereignty, or unless one holder has both ends, so a grey gate marks where two holders meet.
fn holderEdgeColor(scene: Scene, paint: *const MapPaint, first: SystemIndex, second: SystemIndex) ?u32 {
    if (paint.metric != .Sovereignty) return null;
    const stats = scene.stats orelse return null;
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
        .ShipKills, .NpcKills, .Jumps => look.heatColor(value, paint.peak),
        .Sovereignty => paint.holders.colorOf(if (scene.stats) |stats| stats.systems[system].holder else stats_mod.NO_HOLDER),
    };
}

/// The busiest system shown by `metric`, which heat is measured against.
fn peakValue(layout: *const Layout, scene: Scene, metric: MapMetric) u32 {
    const stats = scene.stats orelse return 0;
    var peak: u32 = 0;
    for (layout.nodes[0..layout.node_count]) |node| peak = @max(peak, look.metricValue(metric, stats.systems[node.system]));
    return peak;
}
