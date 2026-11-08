//! What the Map Panel does with the mouse and keyboard: hover, pan and zoom, clicks, the right-click menu and the search.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const vk = @import("../../platform/virtual_keys.zig");
const config_mod = @import("../../config.zig");
const destinations_mod = @import("destinations.zig");
const look = @import("look.zig");
const menu_mod = @import("menu.zig");
const search = @import("search.zig");
const state = @import("state.zig");
const window_mod = @import("window.zig");
const panel_host = @import("../panel_host.zig");
const popup_look = @import("../popup_look.zig");
const universe = @import("../../map/universe.zig");
const evestars = @import("../../map/evestars.zig");
const system_links = @import("../../map/system_links.zig");
const zkill = @import("../../map/zkill.zig");
const wormhole_list = @import("wormhole_list.zig");
const log = @import("../../log.zig");

const Destinations = destinations_mod.Destinations;
const Hover = state.Hover;
const MapPan = state.MapPan;
const MapPanelWindow = window_mod.MapPanelWindow;
const SystemIndex = universe.SystemIndex;
const slog = log.Scoped("map_panel");

/// Each wheel notch or zoom button press.
const ZOOM_STEP: f32 = 1.25;
/// How far the cursor must move before a press on empty map counts as a drag.
const PAN_START_DISTANCE: i32 = 3;

/// Whether the search gives the keyboard back to what had it, or something else already took it.
pub const SearchEnding = enum { hand_back, keyboard_gone };

/// What input reaches beyond the window.
pub const Context = struct {
    /// Borrowed for one message.
    destinations: *Destinations,
    host: panel_host.Host,
};

/// What a message leaves for the panel, which owns the redraw.
pub const Response = enum {
    none,
    redraw,
    /// For input that can come faster than the screen refreshes.
    redraw_paced,
};

/// Null for a message left to Windows.
pub fn handleMessage(window: *MapPanelWindow, context: Context, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) ?Response {
    switch (msg) {
        win32.WM_MOUSEMOVE => return if (onMouseMove(window, context, win32.lparamX(lParam), win32.lparamY(lParam))) .redraw_paced else .none,
        win32.WM_MOUSELEAVE => onMouseLeave(window),
        win32.WM_LBUTTONDOWN => handleClick(window, context, win32.lparamX(lParam), win32.lparamY(lParam)),
        win32.WM_LBUTTONUP => {
            endPan(window);
            endSelecting(window);
        },
        win32.WM_CAPTURECHANGED => {
            // A pan ended by Windows rather than the button keeps the view it reached.
            window.state.pan = null;
            if (window.state.search) |*open| open.is_selecting = false;
            return .none;
        },
        win32.WM_MOUSEWHEEL => return if (onWheel(window, wParam, lParam)) .redraw_paced else .none,
        win32.WM_RBUTTONDOWN => handleRightClick(window, context, win32.lparamX(lParam), win32.lparamY(lParam)),
        win32.WM_CHAR => onSearchChar(window, wParam),
        win32.WM_KEYDOWN => onSearchKey(window, context, wParam),
        win32.WM_KILLFOCUS => {
            if (window.state.search == null) return .none;
            closeSearch(window, context, .keyboard_gone);
        },
        else => return null,
    }
    return .redraw;
}

pub fn closeSearch(window: *MapPanelWindow, context: Context, ending: SearchEnding) void {
    if (window.state.search == null) return;
    endSelecting(window);
    window.state.search = null;
    window.state.popup.clear();
    context.host.run(.resume_hotkeys);
    switch (ending) {
        .keyboard_gone => {},
        .hand_back => if (window.search_return_hwnd) |hwnd| {
            _ = win32.SetForegroundWindow(hwnd);
        },
    }
}

/// Shows the regions Ctrl-clicked in New Eden once Ctrl is let go; with none, New Eden stays.
pub fn finishChoosingRegions(window: *MapPanelWindow) void {
    if (!window.state.is_choosing_regions or win32.isCtrlPressed()) return;
    window.state.is_choosing_regions = false;
    const chosen = window.state.chosen_regions orelse return;
    if (!window.state.is_picking_region or chosen.count == 0) return;
    window.chooseRegions(chosen);
}

fn closePopup(window: *MapPanelWindow, context: Context) void {
    window.state.menu = null;
    window.state.region_menu = null;
    window.state.layers_menu = null;
    window.state.popup.clear();
    closeSearch(window, context, .hand_back);
}

/// Whether the hover changed, and so the panel needs a redraw.
fn onMouseMove(window: *MapPanelWindow, context: Context, x: i32, y: i32) bool {
    if (!window.is_tracking_mouse) window.is_tracking_mouse = win32.trackMouseLeave(window.panel.hwnd);
    if (window.state.pan) |*pan| return continuePan(window, pan, x, y);
    if (window.state.search) |*open| {
        if (open.is_selecting) {
            open.placeCursor(window.state.search_stops.indexAt(x), .extend);
            return true;
        }
    }
    const hover = window.state.hitTest(window.currentAreas(), x, y);
    if (hover.eql(window.state.hover)) return false;
    window.state.hover = hover;
    if (hover.kind == .popup_row) {
        if (window.state.search) |*open| open.picked_index = hover.index;
    }
    if (window.state.menu) |*menu| {
        if (hover.kind == .popup_row) menu.followRow(window.hasEveStars(), hover.index);
        if (hover.kind == .submenu_row) menu.followSubmenuRow(&context.destinations.targets, hover.index);
        followMenu(window);
    }
    return true;
}

fn onMouseLeave(window: *MapPanelWindow) void {
    window.is_tracking_mouse = false;
    window.state.hover = .{};
}

/// Whether the map moved.
fn continuePan(window: *MapPanelWindow, pan: *MapPan, x: i32, y: i32) bool {
    const delta_x = x - pan.start_x;
    const delta_y = y - pan.start_y;
    if (!pan.has_moved and @abs(delta_x) + @abs(delta_y) < PAN_START_DISTANCE) return false;
    pan.has_moved = true;
    const area = window.currentAreas().map;
    window.state.layout.view = pan.start_view.panned(area, @floatFromInt(delta_x), @floatFromInt(delta_y));
    return true;
}

fn beginPan(window: *MapPanelWindow, x: i32, y: i32) void {
    window.state.pan = .{ .start_x = x, .start_y = y, .start_view = window.state.layout.view };
    _ = win32.SetCapture(window.panel.hwnd);
}

/// A press that never moved is a click on empty map, which drops the selection.
fn endPan(window: *MapPanelWindow) void {
    const pan = window.state.pan orelse return;
    window.state.pan = null;
    _ = win32.ReleaseCapture();
    if (!pan.has_moved) window.state.focus_system = null;
}

/// Whether the map zoomed, New Eden opened or closed, or the wormhole list scrolled; `wParam` and `lParam` are WM_MOUSEWHEEL's, whose position is on the screen.
fn onWheel(window: *MapPanelWindow, wParam: win32.WPARAM, lParam: win32.LPARAM) bool {
    if (window.state.isPopupOpen()) return false;
    var point: win32.POINT = .{ .x = win32.lparamX(lParam), .y = win32.lparamY(lParam) };
    _ = win32.ScreenToClient(window.panel.hwnd, &point);
    if (window.state.wormhole_card) |*card| {
        if (card.box.containsPoint(point.x, point.y)) {
            const notches: i32 = @divTrunc(@as(i32, win32.getWheelDelta(@truncate(wParam))), @as(i32, win32.WHEEL_DELTA));
            const scroll = wormhole_list.scrolled(window.state.wormhole_scroll, notches, window.state.wormhole_entry_count, card.visible_count);
            if (scroll == window.state.wormhole_scroll) return false;
            window.state.wormhole_scroll = scroll;
            return true;
        }
    }
    const area = window.currentAreas().map;
    if (point.x < area.left or point.x >= area.right or point.y >= area.bottom) return false;
    const notches = @as(f32, @floatFromInt(win32.getWheelDelta(@truncate(wParam)))) / win32.WHEEL_DELTA;
    if (window.state.is_picking_region) {
        if (notches <= 0) return false;
        leaveNewEden(window, window.state.overview.regionAt(point.x, point.y));
        return true;
    }
    if (notches < 0 and window.state.layout.view.isFitted()) {
        openNewEden(window);
        return true;
    }
    window.state.layout.view = window.state.layout.view.zoomedAt(area, point.x, point.y, std.math.pow(f32, ZOOM_STEP, notches));
    return true;
}

/// Collapses the cards, which would cover the regions.
fn openNewEden(window: *MapPanelWindow) void {
    window.state.is_picking_region = true;
    window.state.is_choosing_regions = false;
    window.state.chosen_regions = null;
    window.state.is_intel_collapsed = true;
    window.state.is_wormholes_collapsed = true;
    window.state.is_timers_collapsed = true;
    // A hovered system's place means nothing over New Eden.
    window.state.hover = .{};
}

/// Opens `region` when it isn't shown, else goes back to the regions shown.
fn leaveNewEden(window: *MapPanelWindow, region: ?universe.RegionIndex) void {
    if (region) |picked| {
        if (!window.state.regions.contains(picked)) return window.chooseRegion(picked);
    }
    window.state.is_picking_region = false;
    window.state.hover = .{};
}

fn handleClick(window: *MapPanelWindow, context: Context, x: i32, y: i32) void {
    const hit = window.state.hitTest(window.currentAreas(), x, y);
    switch (hit.kind) {
        .none => {
            if (window.state.isPopupOpen()) {
                closePopup(window, context);
                return;
            }
            // New Eden stays until a region is picked, or its title closes it.
            if (window.state.is_picking_region) return;
            beginPan(window, x, y);
        },
        .map_control => pressMapControl(window, @fromBackingInt(@intCast(hit.index))),
        .popup_row => pressPopupRow(window, context, hit.index),
        .submenu_row => pressSubmenuRow(window, context, hit.index),
        .nested_row => pressCharacterRow(window, context, hit.index),
        .search_box => pressSearchBox(window, context, x),
        .title => if (window.state.is_picking_region) {
            window.state.is_picking_region = false;
        } else {
            openNewEden(window);
        },
        .metric => window.store.update(.{ .mapPanel = .{ .metric = look.metricAfterClick(window.config.mapPanel.metric, @fromBackingInt(@intCast(hit.index))) } }),
        .toggle => pressToggle(window, @fromBackingInt(@intCast(hit.index))),
        .bar => {},
        .intel_header => window.state.is_intel_collapsed = !window.state.is_intel_collapsed,
        .region => {
            if (win32.isCtrlPressed()) {
                window.toggleChosenRegion(context.destinations, @intCast(hit.index));
                return;
            }
            window.chooseRegion(@intCast(hit.index));
        },
        .intel_row => openIntelRow(window, hit.index),
        .wormhole_header => window.state.is_wormholes_collapsed = !window.state.is_wormholes_collapsed,
        .wormhole_row => openWormholeRow(window, hit.index),
        .timer_header => window.state.is_timers_collapsed = !window.state.is_timers_collapsed,
        .timer_row => openTimerRow(window, hit.index),
        .wormhole_tab => {
            window.state.wormhole_hub = @fromBackingInt(@intCast(hit.index));
            window.state.wormhole_scroll = 0;
            window.state.is_wormholes_collapsed = false;
        },
        .kill_row => openKillRow(window, context, hit.index),
        .card_tab => {
            window.state.card_tab = @fromBackingInt(@intCast(hit.index));
            window.state.is_intel_collapsed = false;
        },
        .node => {
            const system = window.state.layout.nodes[hit.index].system;
            window.state.focus_system = if (window.state.focus_system == system) null else system;
            for (window.state.marks.slice()) |mark| {
                if (mark.system != system) continue;
                context.host.run(.{ .activate = mark.source_hwnd });
                return;
            }
        },
        .exit => {
            const exit = window.state.layout.exits[hit.index];
            if (win32.isCtrlPressed()) {
                if (window.toggleRegion(context.destinations, exit.region)) window.state.focus_system = exit.destination;
                return;
            }
            window.chooseRegion(exit.region);
            window.state.focus_system = exit.destination;
        },
        .portal => switch (window.state.layout.portals[hit.index].target) {
            .hub => window.state.focus_system = window.state.layout.nodes[window.state.layout.portals[hit.index].from_index].system,
            // Like an exit: the gate's far end, in its region.
            .system => |destination| {
                const region = universe.systemInfo(destination).region;
                if (win32.isCtrlPressed()) {
                    if (window.toggleRegion(context.destinations, region)) window.state.focus_system = destination;
                    return;
                }
                window.chooseRegion(region);
                window.state.focus_system = destination;
            },
        },
    }
}

/// Zooming out past the fit opens New Eden, and zooming in leaves it.
fn pressMapControl(window: *MapPanelWindow, control: look.MapControl) void {
    const area = window.currentAreas().map;
    const x = @divTrunc(area.left + area.right, 2);
    const y = @divTrunc(area.top + area.bottom, 2);
    const is_zoomable = !window.state.is_picking_region;
    switch (control) {
        .zoom_in => {
            if (!is_zoomable) return leaveNewEden(window, null);
            window.state.layout.view = window.state.layout.view.zoomedAt(area, x, y, ZOOM_STEP);
        },
        .zoom_out => {
            if (!is_zoomable) return;
            if (window.state.layout.view.isFitted()) return openNewEden(window);
            window.state.layout.view = window.state.layout.view.zoomedAt(area, x, y, 1 / ZOOM_STEP);
        },
        .fit => if (is_zoomable) {
            window.state.layout.view = .{};
        },
        .always_on_top => window.store.update(.{ .mapPanel = .{ .alwaysOnTop = !window.config.mapPanel.alwaysOnTop } }),
    }
}

fn pressToggle(window: *MapPanelWindow, toggle: look.Toggle) void {
    const map_settings = &window.config.mapPanel;
    switch (toggle) {
        // Above the button, as the bar sits along the bottom; a press while it's open lands outside it and closes it.
        .layers => {
            const box = window.state.chrome.toggles[@backingInt(look.Toggle.layers)];
            window.state.layers_menu = .{ .anchor = .{ .x = box.left - 2 * popup_look.TOOLTIP_PADDING, .y = box.top - popup_look.TOOLTIP_PADDING } };
            window.state.hover = .{};
        },
        .follow => {
            window.store.update(.{ .mapPanel = .{ .followActive = !map_settings.followActive } });
            window.state.followed_region = null;
        },
    }
}

fn openIntelRow(window: *MapPanelWindow, row_index: usize) void {
    const intel_history = window.intel_history orelse return;
    const entry = intel_history.entryFromNewest(window.state.intel_rows[row_index].first_index) orelse return;
    if (entry.system) |system| window.selectSystem(system);
}

/// Opens `system`'s region unless it's shown, selects it and ripples it once.
fn pingSystem(window: *MapPanelWindow, system: SystemIndex) void {
    window.selectSystem(system);
    window.state.ping = .{ .system = system, .started_ms = win32.Ticks.now().ms };
}

fn openWormholeRow(window: *MapPanelWindow, row_index: usize) void {
    const entry = window.state.wormholeEntryAt(row_index) orelse return;
    pingSystem(window, entry.system);
}

fn openTimerRow(window: *MapPanelWindow, row_index: usize) void {
    const entry = window.state.timerEntryAt(row_index) orelse return;
    pingSystem(window, entry.system);
}

/// Pings the kill's system, or with Ctrl opens the kill on zKillboard.
fn openKillRow(window: *MapPanelWindow, context: Context, row_index: usize) void {
    const kill = window.state.kill_rows[row_index];
    if (!win32.isCtrlPressed()) {
        pingSystem(window, kill.system);
        return;
    }
    const url: evestars.Text = .print(zkill.KILL_URL_FORMAT, .{kill.id});
    openUrl(context.destinations, .zkillboard, url);
}

fn handleRightClick(window: *MapPanelWindow, context: Context, x: i32, y: i32) void {
    const hit = window.state.hitTest(window.currentAreas(), x, y);
    if (window.state.isPopupOpen()) {
        closePopup(window, context);
        return;
    }
    // A listed system may be off the map, so its menu opens at the cursor.
    if (listedSystemAt(window, hit)) |system| {
        openSystemMenu(window, context, system, .{ .x = x, .y = y });
        return;
    }
    const node_index = nodeWithMenuAt(window, hit, x, y) orelse {
        if (regionWithMenuAt(window, hit, x, y)) |region| openRegionMenu(window, region, x, y);
        return;
    };
    const node = window.state.layout.nodes[node_index];
    openSystemMenu(window, context, node.system, .{ .x = node.x, .y = node.y });
}

/// The system a card row under `hit` lists; null off the rows.
fn listedSystemAt(window: *const MapPanelWindow, hit: Hover) ?SystemIndex {
    if (hit.kind == .wormhole_row) return (window.state.wormholeEntryAt(hit.index) orelse return null).system;
    if (hit.kind == .timer_row) return (window.state.timerEntryAt(hit.index) orelse return null).system;
    return null;
}

/// Selects `system` and opens its right-click menu beside `anchor`.
fn openSystemMenu(window: *MapPanelWindow, context: Context, system: SystemIndex, anchor: win32.POINT) void {
    window.state.focus_system = system;
    window.state.menu = .{ .system = system, .anchor = anchor };
    window.state.hover = .{};
    if (window.hasEveStars()) context.destinations.refreshTargets(window.panel.allocator, window.evestarsToken(), win32.Ticks.now().ms);
}

/// A system's name counts as well as its marker, though only the marker takes a hover.
fn nodeWithMenuAt(window: *const MapPanelWindow, hit: Hover, x: i32, y: i32) ?u16 {
    if (hit.kind == .node) return hit.index;
    if (hit.kind != .none or window.state.is_picking_region) return null;
    return window.state.layout.labelAt(x, y);
}

/// A region in New Eden, or on the map a region's name or empty space, which counts as the region of the nearest system.
fn regionWithMenuAt(window: *const MapPanelWindow, hit: Hover, x: i32, y: i32) ?universe.RegionIndex {
    if (hit.kind == .region) return @intCast(hit.index);
    if (hit.kind != .none or window.state.is_picking_region) return null;
    return window.state.layout.regionNear(x, y);
}

fn openRegionMenu(window: *MapPanelWindow, region: universe.RegionIndex, x: i32, y: i32) void {
    window.state.region_menu = .{ .region = region, .anchor = .{ .x = x, .y = y } };
    window.state.hover = .{};
}

/// Drops the popup's boxes for the submenus the menu has closed.
fn followMenu(window: *MapPanelWindow) void {
    const menu = window.state.menu orelse return;
    if (menu.branch == null) window.state.popup.submenu = null;
    if (!menu.shows_characters) window.state.popup.nested = null;
}

fn pressPopupRow(window: *MapPanelWindow, context: Context, row_index: usize) void {
    if (window.state.region_menu) |region_menu| return pressRegionRow(window, context, region_menu, row_index);
    if (window.state.layers_menu) |*layers_menu| return toggleLayer(window, layers_menu.layerAt(row_index) orelse return);
    const menu = if (window.state.menu) |*open| open else return pickHit(window, context, row_index);
    const action = menu.pressRow(window.hasEveStars(), row_index);
    followMenu(window);
    runMenuAction(window, context, action);
}

fn toggleLayer(window: *MapPanelWindow, layer: look.Layer) void {
    const is_shown = !look.isLayerShown(&window.config.mapPanel, layer);
    switch (layer) {
        .storms => window.store.update(.{ .mapPanel = .{ .showStorms = is_shown } }),
        .incursions => window.store.update(.{ .mapPanel = .{ .showIncursions = is_shown } }),
        .sov_timers => window.store.update(.{ .mapPanel = .{ .showSovTimers = is_shown } }),
        .wormholes => window.store.update(.{ .mapPanel = .{ .showWormholes = is_shown } }),
        .ansiblex => window.store.update(.{ .mapPanel = .{ .showAnsiblex = is_shown } }),
        .kills => window.store.update(.{ .mapPanel = .{ .showKills = is_shown } }),
        .intel => window.store.update(.{ .mapPanel = .{ .showIntel = is_shown } }),
        .names => window.store.update(.{ .mapPanel = .{ .showCharacterNames = is_shown } }),
    }
}

fn pressRegionRow(window: *MapPanelWindow, context: Context, region_menu: menu_mod.RegionMenu, row_index: usize) void {
    const site = region_menu.siteAt(row_index) orelse return;
    closePopup(window, context);
    openUrl(context.destinations, site, system_links.regionUrl(site, region_menu.region));
}

fn pressSubmenuRow(window: *MapPanelWindow, context: Context, row_index: usize) void {
    const menu = if (window.state.menu) |*open| open else return;
    const action = menu.pressSubmenuRow(window.menuContext(context.destinations, menu.system), row_index);
    followMenu(window);
    runMenuAction(window, context, action);
}

fn pressCharacterRow(window: *MapPanelWindow, context: Context, row_index: usize) void {
    if (window.state.menu == null) return;
    runMenuAction(window, context, menu_mod.pressCharacterRow(&context.destinations.targets, row_index));
}

fn runMenuAction(window: *MapPanelWindow, context: Context, action: menu_mod.Action) void {
    const menu = window.state.menu orelse return;
    if (action.closesMenu()) closePopup(window, context);
    const destinations = context.destinations;
    const map_settings = &window.config.mapPanel;
    const now_ms = win32.Ticks.now().ms;
    switch (action) {
        .none => {},
        .avoid_system => toggleAvoided(window, destinations, menu.system),
        .copy_name => copySystemName(destinations, menu.system),
        .open_site => |site| openUrl(destinations, site, system_links.siteUrl(site, menu.system)),
        .show_range => |ship| window.state.reach = if (ship) |shown| .measure(menu.system, shown) else null,
        .cycle_preference => window.store.update(.{ .mapPanel = .{ .routePreference = menu_mod.nextPreference(map_settings.routePreference) } }),
        .toggle_ansiblex => window.store.update(.{ .mapPanel = .{ .routeAnsiblex = !map_settings.routeAnsiblex } }),
        .toggle_waypoints => window.store.update(.{ .mapPanel = .{ .routeEveryWaypoint = !map_settings.routeEveryWaypoint } }),
        .send_to_all => {
            const options = routeOptions(window.config);
            destinations.sendToAll(window.panel.allocator, window.evestarsToken(), menu.system, &options, now_ms);
        },
        .send => |index| {
            const options = routeOptions(window.config);
            destinations.send(window.panel.allocator, window.evestarsToken(), &destinations.targets.slice()[index], menu.system, &options, now_ms);
        },
    }
}

fn toggleAvoided(window: *const MapPanelWindow, destinations: *Destinations, system: SystemIndex) void {
    const name = universe.systemName(system);
    const now_ms = win32.Ticks.now().ms;
    const is_avoided = window.store.toggleAvoidedSystem(universe.systemInfo(system).id) catch |err| {
        slog.warn("Failed to change whether routes avoid '{s}': {}", .{ name, err });
        destinations.showFailureText(.print("{s}", .{if (err == error.AvoidListFull) "The avoid list is full" else "Couldn't change the avoid list"}), now_ms);
        return;
    };
    destinations.showInfo(.print("Routes {s} {s}", .{ if (is_avoided) "avoid" else "no longer avoid", name }), now_ms);
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

fn openUrl(destinations: *Destinations, site: system_links.Site, url: evestars.Text) void {
    if (win32.shellOpenUrl(url.slice())) return;
    slog.warn("Failed to open '{s}'", .{url.slice()});
    destinations.showFailureText(.print("Couldn't open {s}", .{system_links.siteName(site)}), win32.Ticks.now().ms);
}

fn routeOptions(config: *const config_mod.Config) evestars.RouteOptions {
    const map_settings = &config.mapPanel;
    var options: evestars.RouteOptions = .{
        .preference = map_settings.routePreference,
        .uses_ansiblex = map_settings.routeAnsiblex,
        .sets_every_waypoint = map_settings.routeEveryWaypoint,
        .avoids_zone = .{ map_settings.routeAvoidZone1, map_settings.routeAvoidZone2, map_settings.routeAvoidZone3, map_settings.routeAvoidZone4, map_settings.routeAvoidZone5 },
    };
    for (config.avoidedSystems.items) |avoided| options.avoid(avoided.systemId);
    return options;
}

/// Asks for the keyboard as well as the click's activation did; the hotkeys let go of it meanwhile.
fn openSearch(window: *MapPanelWindow, context: Context) void {
    if (window.state.search != null) return;
    window.state.menu = null;
    window.state.region_menu = null;
    window.state.layers_menu = null;
    window.state.popup.clear();
    window.state.search = .{};
    window.search_return_hwnd = win32.GetForegroundWindow();
    context.host.run(.suspend_hotkeys);
    if (!win32.toBool(win32.SetForegroundWindow(window.panel.hwnd))) slog.warn("Failed to take the keyboard for the map's search", .{});
    _ = win32.SetFocus(window.panel.hwnd);
}

/// Opens the search, or places its cursor and starts a selection once it's open.
fn pressSearchBox(window: *MapPanelWindow, context: Context, x: i32) void {
    const open = if (window.state.search) |*shown| shown else return openSearch(window, context);
    open.placeCursor(window.state.search_stops.indexAt(x), if (win32.isShiftPressed()) .extend else .move);
    open.is_selecting = true;
    // So the drag carries on past the box's edge.
    _ = win32.SetCapture(window.panel.hwnd);
}

fn endSelecting(window: *MapPanelWindow) void {
    const open = if (window.state.search) |*shown| shown else return;
    if (!open.is_selecting) return;
    open.is_selecting = false;
    _ = win32.ReleaseCapture();
}

/// Shows the hit on the map; a hit list that has since shrunk picks nothing.
fn pickHit(window: *MapPanelWindow, context: Context, index: usize) void {
    const open = window.state.search orelse return;
    const hit = open.hitAt(index) orelse return;
    closePopup(window, context);
    switch (hit) {
        .system => |system| pingSystem(window, system),
        .region => |region| window.chooseRegion(region),
    }
}

fn onSearchChar(window: *MapPanelWindow, wParam: win32.WPARAM) void {
    const open = if (window.state.search) |*shown| shown else return;
    _ = open.typeChar(wParam);
}

/// Ctrl+F opens the search while it's closed.
fn onSearchKey(window: *MapPanelWindow, context: Context, wParam: win32.WPARAM) void {
    const open = if (window.state.search) |*shown| shown else {
        if (wParam == 'F' and win32.isCtrlPressed()) openSearch(window, context);
        return;
    };
    const is_ctrl_down = win32.isCtrlPressed();
    const extent: search.Extent = if (win32.isShiftPressed()) .extend else .move;
    switch (wParam) {
        win32.VK_ESCAPE => closePopup(window, context),
        win32.VK_RETURN => pickHit(window, context, open.picked_index),
        win32.VK_UP => open.pickPrevious(),
        win32.VK_DOWN => open.pickNext(),
        vk.VK_LEFT => open.move(if (is_ctrl_down) .word_left else .left, extent),
        vk.VK_RIGHT => open.move(if (is_ctrl_down) .word_right else .right, extent),
        vk.VK_HOME => open.move(.home, extent),
        vk.VK_END => open.move(.end, extent),
        vk.VK_DELETE => _ = open.deleteForward(),
        // Letter keys' codes are their capitals; WM_CHAR's control characters for these are ignored.
        'A' => if (is_ctrl_down) open.selectAll(),
        'C' => if (is_ctrl_down) {
            _ = copySelection(open);
        },
        'X' => if (is_ctrl_down and copySelection(open)) {
            _ = open.deleteForward();
        },
        'V' => if (is_ctrl_down) paste(window, open),
        else => {},
    }
}

/// Whether there was a selection and it reached the clipboard.
fn copySelection(open: *const search.Search) bool {
    const selected = open.selectedText();
    if (selected.len == 0) return false;
    if (win32.setClipboardText(selected)) return true;
    slog.warn("Failed to copy '{s}' from the map's search to the clipboard", .{selected});
    return false;
}

fn paste(window: *const MapPanelWindow, open: *search.Search) void {
    const allocator = window.panel.allocator;
    const text = win32.getClipboardText(allocator) orelse {
        slog.debug("The clipboard held no text to paste into the map's search", .{});
        return;
    };
    defer allocator.free(text);
    // A name copied from chat or a list often ends in a space or line break.
    _ = open.insert(std.mem.trim(u8, text, " \t\r\n"));
}
