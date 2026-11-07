//! What the Map Panel shows and what's under the cursor, which its input changes and its painting reads; no I/O.
const std = @import("std");
const panels = @import("../../config/panels.zig");
const history = @import("../../notifications/history.zig");
const history_rows = @import("../history_rows.zig");
const look = @import("look.zig");
const marks_mod = @import("marks.zig");
const menu_mod = @import("menu.zig");
const search_mod = @import("search.zig");
const panel_look = @import("../panel_look.zig");
const popup_menu = @import("../popup_menu.zig");
const universe = @import("../../map/universe.zig");
const jump_range = @import("../../map/jump_range.zig");
const layout_mod = @import("../../map/layout.zig");
const overview_mod = @import("../../map/overview.zig");

const HistoryPanelConfig = panels.HistoryPanelConfig;
const Layout = layout_mod.Layout;
const Regions = layout_mod.Regions;
const RegionIndex = universe.RegionIndex;
const SystemIndex = universe.SystemIndex;

pub const Hover = struct {
    kind: Kind = .none,
    /// A `nodes` or `exits` place, a RegionIndex, a Button's or MapControl's value, an `intel_rows` place or a popup, submenu or nested row, by kind.
    index: u16 = 0,

    pub const Kind = enum { none, node, exit, region, button, intel_row, popup_row, submenu_row, nested_row, search_box, map_control };

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

/// Labels in the label font, in pixels, by place in the layout's `nodes` and `exits`.
pub const LabelWidths = struct {
    names: [layout_mod.MAX_NODES]i32 = undefined,
    securities: [layout_mod.MAX_NODES]i32 = undefined,
    exits: [layout_mod.MAX_EXITS]i32 = undefined,
};

pub const MapState = struct {
    regions: Regions,
    /// The region the active client was last seen in; following acts when it changes, so a region picked by hand stays until then.
    followed_region: ?RegionIndex = null,
    layout: Layout = .{},
    /// What `layout` was built for.
    layout_signature: ?u64 = null,
    label_widths: LabelWidths = .{},
    /// What `label_widths` were measured for.
    label_widths_signature: ?u64 = null,
    hover: Hover = .{},
    /// Null unless the left button is down on empty map.
    pan: ?MapPan = null,
    /// Shows New Eden in place of the map.
    is_picking_region: bool = false,
    overview: overview_mod.Overview = .{},
    /// What `overview` was built for.
    overview_signature: ?u64 = null,
    /// The selected system, ringed: one clicked, or arrived at through a gate or the Intel Panel.
    focus_system: ?SystemIndex = null,
    /// The jump range showing, kept across regions as it reaches past those on screen.
    reach: ?jump_range.Reach = null,
    /// Rebuilt each render; borrows from the thumbnails.
    marks: marks_mod.Marks = .{},
    /// The sidebar's rows, from the last render.
    intel_rows: [history.CAPACITY]history_rows.Row = undefined,
    intel_row_count: usize = 0,
    /// Null while it's closed.
    menu: ?menu_mod.Menu = null,
    /// Null unless the search box is open, which gives it the keyboard.
    search: ?search_mod.Search = null,
    /// From the last render that drew the search open.
    search_stops: search_mod.Stops = .{},
    /// Where the last render drew the menu or search results, for hit testing.
    popup: popup_menu.PopupMenu = .{},

    pub fn isPopupOpen(self: *const MapState) bool {
        return self.menu != null or self.search != null;
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
        self.hover = .{};
    }

    /// While a popup is open, only it and the search box can be hit, the popup first as it can lie over the box.
    pub fn hitTest(self: *const MapState, areas: look.Areas, history_settings: *const HistoryPanelConfig, x: i32, y: i32) Hover {
        if (self.isPopupOpen()) {
            if (self.popup.hitAt(x, y)) |hit| return switch (hit) {
                .main => |row_index| .{ .kind = .popup_row, .index = @intCast(row_index) },
                .submenu => |row_index| .{ .kind = .submenu_row, .index = @intCast(row_index) },
                .nested => |row_index| .{ .kind = .nested_row, .index = @intCast(row_index) },
            };
        }
        if (areas.search_box.containsPoint(x, y)) return .{ .kind = .search_box };
        if (self.isPopupOpen()) return .{};
        if (y >= areas.inner.bottom) {
            const button = look.buttonAt(areas.inner.right, x) orelse return .{};
            return .{ .kind = .button, .index = @backingInt(button) };
        }
        if (areas.sidebar) |sidebar| {
            if (sidebar.containsPoint(x, y)) {
                const row_index: usize = @intCast(@divTrunc(y - sidebar.top, history_rows.intelRowHeight(history_settings)));
                return if (row_index < self.intel_row_count) .{ .kind = .intel_row, .index = @intCast(row_index) } else .{};
            }
        }
        if (self.is_picking_region) {
            const region = self.overview.regionAt(x, y) orelse return .{};
            return .{ .kind = .region, .index = region };
        }
        if (look.mapControlAt(areas.body, x, y)) |control| return .{ .kind = .map_control, .index = @backingInt(control) };
        // Chips lie over the map, so one beats a system just behind its edge.
        if (self.layout.exitLabelAt(x, y)) |exit| return .{ .kind = .exit, .index = exit };
        if (self.layout.nodeAt(x, y)) |node| return .{ .kind = .node, .index = node };
        if (self.layout.exitAt(x, y)) |exit| return .{ .kind = .exit, .index = exit };
        return .{};
    }

    /// A jump range is showing and doesn't take in `system`; its origin counts as taken in.
    pub fn isOutOfRange(self: *const MapState, system: SystemIndex) bool {
        const reach = if (self.reach) |*shown| shown else return false;
        return system != reach.origin and !reach.includes(system);
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
        self.marks.hash(hasher);
    }
};

const testing = std.testing;

const TEST_HISTORY: HistoryPanelConfig = .{};
const TEST_AREAS: look.Areas = .init(800, 600, 30, 0, .Right);

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
    const hover = state.hitTest(TEST_AREAS, &TEST_HISTORY, jita.x, jita.y);
    try testing.expectEqual(Hover.Kind.node, hover.kind);
    try testing.expectEqual(universe.findSystem("Jita").?, state.layout.nodes[hover.index].system);
}

test "a map control lies over the map" {
    const state = forgeState();
    const box = look.mapControlBox(TEST_AREAS.body, .fit);
    const hover = state.hitTest(TEST_AREAS, &TEST_HISTORY, box.left + 1, box.top + 1);
    try testing.expect(hover.eql(.{ .kind = .map_control, .index = @backingInt(look.MapControl.fit) }));
}

test "the footer finds its buttons" {
    const state = forgeState();
    const span = panel_look.buttonSpan(800, look.BUTTON_ORDER.len, 0);
    const hover = state.hitTest(TEST_AREAS, &TEST_HISTORY, span.left, 590);
    try testing.expect(hover.eql(.{ .kind = .button, .index = @backingInt(look.BUTTON_ORDER[0]) }));
}

test "while a popup is open the map takes no hover, though the search box still does" {
    var state = forgeState();
    state.search = .{};
    const jita = jitaNode(&state);
    try testing.expectEqual(Hover.Kind.none, state.hitTest(TEST_AREAS, &TEST_HISTORY, jita.x, jita.y).kind);
    const box = TEST_AREAS.search_box;
    try testing.expectEqual(Hover.Kind.search_box, state.hitTest(TEST_AREAS, &TEST_HISTORY, box.left + 1, box.top + 1).kind);
}

test "only the intel rows listed take a hover in the sidebar" {
    var state = forgeState();
    state.intel_row_count = 1;
    const areas: look.Areas = .init(800, 600, 30, 200, .Left);
    const row_height = history_rows.intelRowHeight(&TEST_HISTORY);
    try testing.expect(state.hitTest(areas, &TEST_HISTORY, 10, 1).eql(.{ .kind = .intel_row, .index = 0 }));
    try testing.expectEqual(Hover.Kind.none, state.hitTest(areas, &TEST_HISTORY, 10, row_height + 1).kind);
}

test "picking a region hits its bubble rather than the map behind" {
    var state = forgeState();
    state.is_picking_region = true;
    state.overview.build(TEST_AREAS.map);
    const region = universe.systemInfo(universe.findSystem("Amarr").?).region;
    const bubble = state.overview.bubbles[region];
    try testing.expect(state.hitTest(TEST_AREAS, &TEST_HISTORY, bubble.x, bubble.y).eql(.{ .kind = .region, .index = region }));
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
