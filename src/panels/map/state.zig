//! What the Map Panel shows and what's under the cursor, which its input changes and its painting reads; no I/O.
const std = @import("std");
const history = @import("../../notifications/history.zig");
const history_rows = @import("../history_rows.zig");
const look = @import("look.zig");
const marks_mod = @import("marks.zig");
const menu_mod = @import("menu.zig");
const search_mod = @import("search.zig");
const popup_menu = @import("../popup_menu.zig");
const universe = @import("../../map/universe.zig");
const jump_range = @import("../../map/jump_range.zig");
const layout_mod = @import("../../map/layout.zig");
const zkill = @import("../../map/zkill.zig");
const timer_list = @import("timer_list.zig");
const wormhole_list = @import("wormhole_list.zig");
const wormholes = @import("../../map/wormholes.zig");
const overview_mod = @import("../../map/overview.zig");

const Layout = layout_mod.Layout;
const Regions = layout_mod.Regions;
const RegionIndex = universe.RegionIndex;
const SystemIndex = universe.SystemIndex;

pub const Hover = struct {
    kind: Kind = .none,
    /// A `nodes`, `exits` or `portals` place, a RegionIndex, a MetricSegment's, Toggle's, MapControl's or card tab's value, a card's row, or a popup, submenu or nested row, by kind.
    index: u16 = 0,

    /// `bar` is a card's part that does nothing, such as a bar's padding, which keeps a click off the map.
    pub const Kind = enum { none, node, exit, portal, region, title, metric, toggle, bar, intel_header, card_tab, intel_row, kill_row, wormhole_header, wormhole_tab, wormhole_row, timer_header, timer_row, popup_row, submenu_row, nested_row, search_box, map_control };

    pub fn eql(self: Hover, other: Hover) bool {
        return self.kind == other.kind and self.index == other.index;
    }
};

/// A left-button press on empty map, which a drag turns into panning.
pub const MapPan = struct {
    start_x: i32,
    start_y: i32,
    start_view: layout_mod.View,
    has_moved: bool = false,
};

/// A system picked from the search or a card's row, rippled once so it's easy to spot.
pub const Ping = struct {
    system: SystemIndex,
    /// In ms since boot.
    started_ms: u64,
    /// Checked once against the cards, so panning by hand during the ripple isn't undone.
    is_revealed: bool = false,
};

/// Labels in the label font, in pixels, by place in the layout's `nodes` and `exits`.
pub const LabelWidths = struct {
    names: [layout_mod.MAX_NODES]i32 = undefined,
    securities: [layout_mod.MAX_NODES]i32 = undefined,
    exits: [layout_mod.MAX_EXITS]i32 = undefined,
    /// The most a sov timer's text takes beside a name.
    timer: i32 = 0,
};

pub const MapState = struct {
    regions: Regions,
    /// The region the active client was last seen in; following acts when it changes, so a region picked by hand stays until then.
    followed_region: ?RegionIndex = null,
    layout: Layout = .{},
    /// What `layout` was built for.
    layout_signature: ?u64 = null,
    /// What `layout`'s names were placed for; null after a build, which drops them.
    labels_signature: ?u64 = null,
    /// What `layout`'s portals were set for.
    portals_signature: ?u64 = null,
    label_widths: LabelWidths = .{},
    /// What `label_widths` were measured for.
    label_widths_signature: ?u64 = null,
    hover: Hover = .{},
    /// Null unless the left button is down on empty map.
    pan: ?MapPan = null,
    /// Shows New Eden in place of the map.
    is_picking_region: bool = false,
    /// Set by a Ctrl-click in New Eden, which then closes once Ctrl is let go.
    is_choosing_regions: bool = false,
    /// What New Eden's Ctrl-clicks will show, possibly none; null until the first, and once shown.
    chosen_regions: ?Regions = null,
    /// Where the last render put the cards sized to their text, for hit testing.
    chrome: look.Chrome = .{},
    overview: overview_mod.Overview = .{},
    /// What `overview` was built for.
    overview_signature: ?u64 = null,
    /// The selected system, ringed: one clicked, or arrived at through a gate or the Intel Panel.
    focus_system: ?SystemIndex = null,
    ping: ?Ping = null,
    /// The jump range showing, kept across regions as it reaches past those on screen.
    reach: ?jump_range.Reach = null,
    /// Rebuilt each render; borrows from the thumbnails.
    marks: marks_mod.Marks = .{},
    /// The Intel card's rows, from the last render.
    intel_rows: [history.CAPACITY]history_rows.Row = undefined,
    intel_row_count: usize = 0,
    /// What the Kills tab lists, newest first, copied so a click finds the kill it showed.
    kill_rows: [look.MAX_INTEL_ROWS]zkill.Kill = undefined,
    /// The side card's tab while both can show.
    card_tab: look.CardTab = .intel,
    /// Where the last render drew the Thera and Turnur card; null while it isn't shown.
    wormhole_card: ?look.ListCard = null,
    /// What that card lists, rebuilt each render.
    wormhole_entries: [wormhole_list.MAX_ENTRIES]wormhole_list.Entry = undefined,
    wormhole_entry_count: usize = 0,
    /// The hub the wormhole card lists.
    wormhole_hub: wormholes.Hub = .thera,
    /// The first entry showing.
    wormhole_scroll: usize = 0,
    /// Collapsed until opened, as the list is long.
    is_wormholes_collapsed: bool = true,
    /// Where the last render drew the sov timer card; null while no region shown has a timer.
    timer_card: ?look.ListCard = null,
    /// What that card lists, soonest first; rebuilt each render.
    timer_entries: [timer_list.MAX_ENTRIES]timer_list.Entry = undefined,
    timer_entry_count: usize = 0,
    /// Collapsed until opened, like the other cards.
    is_timers_collapsed: bool = true,
    /// Where the last render drew the Intel card; null while it isn't shown.
    intel_card: ?look.IntelCard = null,
    /// Collapsed until opened, so the map starts clear.
    is_intel_collapsed: bool = true,
    /// Null while it's closed.
    menu: ?menu_mod.Menu = null,
    /// Null while it's closed.
    region_menu: ?menu_mod.RegionMenu = null,
    /// Null while it's closed.
    layers_menu: ?menu_mod.LayersMenu = null,
    /// Null unless the search box is open, which gives it the keyboard.
    search: ?search_mod.Search = null,
    /// From the last render that drew the search open.
    search_stops: search_mod.Stops = .{},
    /// Where the last render drew the menu or search results, for hit testing.
    popup: popup_menu.PopupMenu = .{},

    pub fn isPopupOpen(self: *const MapState) bool {
        return self.menu != null or self.region_menu != null or self.layers_menu != null or self.search != null;
    }

    /// A press on empty map has moved it; one that hasn't yet may still be a click.
    pub fn isPanning(self: *const MapState) bool {
        return if (self.pan) |pan| pan.has_moved else false;
    }

    /// Null unless the hover is of `kind`.
    pub fn hoveredIndex(self: *const MapState, kind: Hover.Kind) ?usize {
        return if (self.hover.kind == kind) self.hover.index else null;
    }

    pub fn showRegions(self: *MapState, regions: Regions) void {
        self.regions = regions;
        self.layout.view = .{};
        self.focus_system = null;
        self.is_picking_region = false;
        self.is_choosing_regions = false;
        self.chosen_regions = null;
        self.hover = .{};
    }

    /// Those New Eden rings: the Ctrl-clicked ones while choosing, else those shown.
    pub fn ringedRegions(self: *const MapState) *const Regions {
        return if (self.chosen_regions) |*chosen| chosen else &self.regions;
    }

    /// While a popup is open, only it and the search box can be hit, the popup first as it can lie over the box.
    pub fn hitTest(self: *const MapState, areas: look.Areas, x: i32, y: i32) Hover {
        if (self.isPopupOpen()) {
            if (self.popup.hitAt(x, y)) |hit| return switch (hit) {
                .main => |row_index| .{ .kind = .popup_row, .index = @intCast(row_index) },
                .submenu => |row_index| .{ .kind = .submenu_row, .index = @intCast(row_index) },
                .nested => |row_index| .{ .kind = .nested_row, .index = @intCast(row_index) },
            };
        }
        if (areas.search_box.containsPoint(x, y)) return .{ .kind = .search_box };
        if (self.isPopupOpen()) return .{};
        if (self.chrome.title.containsPoint(x, y)) return .{ .kind = .title };
        if (self.chrome.segmentAt(x, y)) |segment| return .{ .kind = .metric, .index = @backingInt(segment) };
        if (self.chrome.toggleAt(x, y)) |toggle| return .{ .kind = .toggle, .index = @backingInt(toggle) };
        if (self.chrome.hasBarAt(x, y)) return .{ .kind = .bar };
        if (areas.mapControlAt(x, y)) |control| return .{ .kind = .map_control, .index = @backingInt(control) };
        if (self.intel_card) |*card| {
            if (card.tabAt(x, y)) |tab| return .{ .kind = .card_tab, .index = @backingInt(tab) };
            if (card.header.containsPoint(x, y)) return .{ .kind = .intel_header };
            if (card.rowAt(x, y)) |row_index| return .{ .kind = if (card.tab == .kills) .kill_row else .intel_row, .index = @intCast(row_index) };
            if (card.box.containsPoint(x, y)) return .{ .kind = .bar };
        }
        if (self.wormhole_card) |*card| {
            if (card.tabAt(x, y)) |hub| return .{ .kind = .wormhole_tab, .index = @backingInt(hub) };
            if (card.header.containsPoint(x, y)) return .{ .kind = .wormhole_header };
            if (card.rowAt(x, y)) |row_index| return .{ .kind = .wormhole_row, .index = @intCast(row_index) };
            if (card.box.containsPoint(x, y)) return .{ .kind = .bar };
        }
        if (self.timer_card) |*card| {
            if (card.header.containsPoint(x, y)) return .{ .kind = .timer_header };
            if (card.rowAt(x, y)) |row_index| return .{ .kind = .timer_row, .index = @intCast(row_index) };
            if (card.box.containsPoint(x, y)) return .{ .kind = .bar };
        }
        if (self.is_picking_region) {
            const region = self.overview.regionAt(x, y) orelse return .{};
            return .{ .kind = .region, .index = region };
        }
        // An exit's or portal's name lies over the map, so it beats a system just behind its padding.
        if (self.layout.exitLabelAt(x, y)) |exit| return .{ .kind = .exit, .index = exit };
        if (self.layout.portalLabelAt(x, y)) |portal| return .{ .kind = .portal, .index = portal };
        if (self.layout.nodeAt(x, y)) |node| return .{ .kind = .node, .index = node };
        if (self.layout.exitAt(x, y)) |exit| return .{ .kind = .exit, .index = exit };
        if (self.layout.portalAt(x, y)) |portal| return .{ .kind = .portal, .index = portal };
        return .{};
    }

    /// A jump range is showing and doesn't take in `system`; its origin counts as taken in.
    pub fn isOutOfRange(self: *const MapState, system: SystemIndex) bool {
        const reach = if (self.reach) |*shown| shown else return false;
        return system != reach.origin and !reach.includes(system);
    }

    /// The entry a wormhole card row shows; null past the list.
    pub fn wormholeEntryAt(self: *const MapState, row_index: usize) ?wormhole_list.Entry {
        const index = self.wormhole_scroll + row_index;
        if (index >= self.wormhole_entry_count) return null;
        return self.wormhole_entries[index];
    }

    /// The entry a sov timer card row shows; null past the list.
    pub fn timerEntryAt(self: *const MapState, row_index: usize) ?timer_list.Entry {
        if (row_index >= self.timer_entry_count) return null;
        return self.timer_entries[row_index];
    }

    /// Null with nothing selected.
    pub fn focusNode(self: *const MapState) ?layout_mod.Node {
        const system = self.focus_system orelse return null;
        const index = self.layout.nodeOf(system) orelse return null;
        return self.layout.nodes[index];
    }

    /// Has something at it, so its name stands out from the quiet ones.
    pub fn isNoteworthy(self: *const MapState, system: SystemIndex) bool {
        if (self.focus_system == system or self.marks.countAt(system) > 0) return true;
        if (self.reach != null and !self.isOutOfRange(system)) return true;
        return self.hover.kind == .node and self.layout.nodes[self.hover.index].system == system;
    }

    /// What a render shows that only input changes.
    pub fn hash(self: *const MapState, hasher: *std.hash.Wyhash) void {
        hasher.update(std.mem.asBytes(&self.is_picking_region));
        hasher.update(std.mem.sliceAsBytes(self.ringedRegions().slice()));
        hasher.update(std.mem.asBytes(&self.is_intel_collapsed));
        hasher.update(std.mem.asBytes(&self.card_tab));
        hasher.update(std.mem.asBytes(&self.wormhole_scroll));
        hasher.update(std.mem.asBytes(&self.wormhole_hub));
        hasher.update(std.mem.asBytes(&self.is_wormholes_collapsed));
        hasher.update(std.mem.asBytes(&self.is_timers_collapsed));
        // So letting go of a drag redraws the names' full outline.
        hasher.update(std.mem.asBytes(&self.isPanning()));
        hasher.update(std.mem.asBytes(&self.hover.kind));
        hasher.update(std.mem.asBytes(&self.hover.index));
        if (self.focus_system) |system| hasher.update(std.mem.asBytes(&system));
        if (self.reach) |*reach| {
            hasher.update(std.mem.asBytes(&reach.origin));
            hasher.update(std.mem.asBytes(&reach.ship));
        }
        hasher.update(std.mem.asBytes(&(self.search != null)));
        if (self.search) |*open| open.hash(hasher);
        if (self.menu) |*menu| menu.hash(hasher);
        hasher.update(std.mem.asBytes(&(self.region_menu != null)));
        if (self.region_menu) |*region_menu| region_menu.hash(hasher);
        hasher.update(std.mem.asBytes(&(self.layers_menu != null)));
        if (self.layers_menu) |*layers_menu| layers_menu.hash(hasher);
        self.marks.hash(hasher);
    }
};

const testing = std.testing;

const TEST_AREAS: look.Areas = .init(800, 600, 30, false);

fn forgeState() MapState {
    var state: MapState = .{ .regions = .one(universe.systemInfo(universe.findSystem("Jita").?).region) };
    state.layout.build(state.regions, TEST_AREAS.map);
    return state;
}

fn jitaNode(state: *const MapState) layout_mod.Node {
    return state.layout.nodes[state.layout.nodeOf(universe.findSystem("Jita").?).?];
}

test "a system's marker takes the hover" {
    const state = forgeState();
    const jita = jitaNode(&state);
    const hover = state.hitTest(TEST_AREAS, jita.x, jita.y);
    try testing.expectEqual(Hover.Kind.node, hover.kind);
    try testing.expectEqual(universe.findSystem("Jita").?, state.layout.nodes[hover.index].system);
}

test "a map control lies over the map" {
    const state = forgeState();
    const box = TEST_AREAS.mapControlBox(.fit);
    const hover = state.hitTest(TEST_AREAS, box.left + 1, box.top + 1);
    try testing.expect(hover.eql(.{ .kind = .map_control, .index = @backingInt(look.MapControl.fit) }));
}

test "the bars find their buttons, and their padding keeps a click off the map" {
    var state = forgeState();
    state.chrome = .init(TEST_AREAS, .{ .title_width = 80, .title_height = 20, .metric_widths = @splat(40), .toggle_widths = @splat(50) });
    const kills = state.chrome.metrics[@backingInt(look.MetricSegment.kills)];
    try testing.expect(state.hitTest(TEST_AREAS, kills.left, kills.top).eql(.{ .kind = .metric, .index = @backingInt(look.MetricSegment.kills) }));
    const follow = state.chrome.toggles[@backingInt(look.Toggle.follow)];
    try testing.expect(state.hitTest(TEST_AREAS, follow.left, follow.top).eql(.{ .kind = .toggle, .index = @backingInt(look.Toggle.follow) }));
    const bar = state.chrome.toggle_bar;
    try testing.expectEqual(Hover.Kind.bar, state.hitTest(TEST_AREAS, bar.left, bar.top).kind);
    const title = state.chrome.title;
    try testing.expectEqual(Hover.Kind.title, state.hitTest(TEST_AREAS, title.left, title.top).kind);
}

test "while a popup is open the map takes no hover, though the search box still does" {
    var state = forgeState();
    state.search = .{};
    const jita = jitaNode(&state);
    try testing.expectEqual(Hover.Kind.none, state.hitTest(TEST_AREAS, jita.x, jita.y).kind);
    const box = TEST_AREAS.search_box;
    try testing.expectEqual(Hover.Kind.search_box, state.hitTest(TEST_AREAS, box.left + 1, box.top + 1).kind);
}

test "the Intel card's header and rows take the hover, and the rest of it keeps a click off the map" {
    var state = forgeState();
    const areas: look.Areas = .init(800, 600, 30, true);
    const card: look.IntelCard = .init(areas, areas.intelTop(), look.intelHeaderHeight(areas.card_height), 40, 0, false);
    state.intel_card = card;
    try testing.expectEqual(Hover.Kind.intel_header, state.hitTest(areas, card.header.left, card.header.top).kind);
    try testing.expectEqual(Hover.Kind.bar, state.hitTest(areas, card.box.left, card.box.bottom - 1).kind);
    state.intel_card = .init(areas, areas.intelTop(), look.intelHeaderHeight(areas.card_height), 40, 2, false);
    const second = state.intel_card.?.rows[1];
    try testing.expect(state.hitTest(areas, second.left, second.top).eql(.{ .kind = .intel_row, .index = 1 }));
}

test "the side card's tabs take the hover before its header, and the Kills tab's rows are kill rows" {
    var state = forgeState();
    const areas: look.Areas = .init(800, 600, 30, true);
    var card: look.IntelCard = .init(areas, areas.intelTop(), look.intelHeaderHeight(areas.card_height), 40, 2, false);
    card.tab = .kills;
    card.tabs[@backingInt(look.CardTab.kills)] = .{ .left = card.header.left + 60, .top = card.header.top, .right = card.header.left + 100, .bottom = card.header.bottom };
    state.intel_card = card;
    try testing.expect(state.hitTest(areas, card.header.left + 61, card.header.top).eql(.{ .kind = .card_tab, .index = @backingInt(look.CardTab.kills) }));
    try testing.expect(state.hitTest(areas, card.rows[0].left, card.rows[0].top).eql(.{ .kind = .kill_row, .index = 0 }));
}

test "picking a region hits its bubble rather than the map behind" {
    var state = forgeState();
    state.is_picking_region = true;
    state.overview.build(TEST_AREAS.map);
    const region = universe.systemInfo(universe.findSystem("Amarr").?).region;
    const bubble = state.overview.bubbles[region];
    try testing.expect(state.hitTest(TEST_AREAS, bubble.x, bubble.y).eql(.{ .kind = .region, .index = region }));
}

test "showing other regions drops the selection, the pick and the zoom" {
    var state = forgeState();
    state.focus_system = universe.findSystem("Jita").?;
    state.is_picking_region = true;
    state.layout.view.zoom = 3;
    state.showRegions(.one(universe.systemInfo(universe.findSystem("Amarr").?).region));
    try testing.expectEqual(@as(?SystemIndex, null), state.focus_system);
    try testing.expect(!state.is_picking_region);
    try testing.expect(state.layout.view.isFitted());
}
