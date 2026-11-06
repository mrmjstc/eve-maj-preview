//! The configuration window's Map tab: its size, look, when it shows, its live figures, Eve Stars and the Intel Panel; main thread only.
const ui = @import("ui");
const config = @import("../../../config.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const panel_settings = @import("panel_settings.zig");
const universe = @import("../../../map/universe.zig");

const IntelRef = session.Ref(config.IntelPanelConfig);
const MapRef = session.Ref(config.MapPanelConfig);

pub fn show(context: *ui.Frame) !void {
    const ref = session.profile().child("mapPanel");

    const section = try widgets.openSection(context, "Map", "A map of one region at a time, with its gates, security and who's there. Hover a system for its details.", &style.section);
    try bind.toggle(context, ref, "show", "Enable Map");
    try widgets.hintText(context, .src(@src()), "Pick a region with its Regions button, or click a gate leading out of the map.");
    try section.close(context);

    const is_shown = ref.get("show");
    try layout(context, ref, is_shown);
    try panel_settings.visibility(context, ref, .map, is_shown);
    try behavior(context, ref, is_shown);
    try eveStars(context, ref, is_shown);
    try intelPanel(context, session.profile().child("intelPanel"));
}

fn eveStars(context: *ui.Frame, ref: MapRef, is_shown: bool) !void {
    const section = try widgets.openSection(context, "Eve Stars", "Sets destinations in your game clients through evestars.net.", &style.section);
    const global = session.global();
    const enable = try widgets.openGroup(context, .src(@src()), is_shown);
    try bind.toggle(context, global, "evestarsEnabled", "Enable Eve Stars");
    try enable.close(context);
    const options = try widgets.openGroup(context, .src(@src()), is_shown and global.get("evestarsEnabled"));
    try bind.text(context, global, "evestarsToken", "API Token", "evestars_...");
    try widgets.hintText(context, .src(@src()), "Make one on the Eve Stars site, under Pilot then API. It's kept on this PC, outside your profiles.");
    try widgets.hintText(context, .src(@src()), "Right-click a system on the map to set it as a group's or character's destination.");
    try bind.segmented(context, ref, "routePreference", "Route Preference", &.{ "Shorter", "Safer", "Less Secure" });
    try widgets.hintText(context, .src(@src()), "Keep this the same as the game's autopilot setting, or a client may route differently between waypoints.");
    try bind.toggle(context, ref, "routeAnsiblex", "Use Ansiblex Gates");
    try widgets.hintText(context, .src(@src()), "Routes through your Eve Stars account's gates. Keep the game's Ansiblex setting the same.");
    try bind.toggle(context, ref, "routeEveryWaypoint", "Set Every System as a Waypoint");
    try widgets.hintText(context, .src(@src()), "Flies the planned route whatever the game's autopilot settings. Uses more of each character's ESI limit and takes a little longer.");
    try widgets.hintText(context, .src(@src()), "These can also be changed from the map's right-click menu.");
    const zones = try widgets.openGroup(context, .src(@src()), ref.get("routeAnsiblex"));
    try bind.toggle(context, ref, "routeAvoidZone1", "Avoid Zone 1 (within 5 ly)");
    try bind.toggle(context, ref, "routeAvoidZone2", "Avoid Zone 2 (5 to 10 ly)");
    try bind.toggle(context, ref, "routeAvoidZone3", "Avoid Zone 3 (10 to 15 ly)");
    try bind.toggle(context, ref, "routeAvoidZone4", "Avoid Zone 4 (15 to 20 ly)");
    try bind.toggle(context, ref, "routeAvoidZone5", "Avoid Zone 5 (over 20 ly)");
    try widgets.hintText(context, .src(@src()), "Stops routes taking gates that land this far from their alliance's capital.");
    try zones.close(context);
    try avoidedSystems(context);
    try options.close(context);
    try section.close(context);
}

fn avoidedSystems(context: *ui.Frame) !void {
    const profile = session.profile();
    var removed: ?usize = null;
    for (profile.ptr.avoidedSystems.items, 0..) |avoided, index| {
        const system = universe.findSystemById(avoided.systemId);
        const row = try widgets.openBinding(context, ui.Key.str("knots.avoided_system").indexed(index), if (system) |known| universe.systemName(known) else "Unknown System");
        if (try widgets.removeButton(context, ui.Key.str("knots.avoided_system.remove").indexed(index))) removed = index;
        try row.close(context);
    }
    if (removed) |index| profile.remove("avoidedSystems", index);
    try widgets.hintText(context, .src(@src()), "Right-click a system on the map and pick Avoid System to keep routes out of it.");
}

fn intelPanel(context: *ui.Frame, ref: IntelRef) !void {
    const section = try widgets.openSection(context, "Intel Panel", "Lists every report from your intel channels, beside the map or on its own.", &style.section);
    try bind.toggle(context, ref, "show", "Enable Intel Panel");
    try widgets.hintText(context, .src(@src()), "Lists reports at any distance.");
    const options = try widgets.openGroup(context, .src(@src()), ref.get("show"));
    try bind.toggle(context, ref, "attached", "Inside Map");
    try widgets.hintText(context, .src(@src()), "Shows as a sidebar in the map's window, which grows to fit it. Off gives it a window of its own.");
    const inside = try widgets.openGroup(context, .src(@src()), ref.get("attached"));
    try bind.segmented(context, ref, "side", "Side", &.{ "Left", "Right" });
    try widgets.hintText(context, .src(@src()), "Which side of the map the sidebar sits on.");
    try inside.close(context);
    const size = try widgets.openBinding(context, .src(@src()), "Size");
    // Inside the map, the panel is the map's height.
    if (ref.get("attached")) try bind.unitNumberBox(context, ref, "width", "px", .{}) else try bind.sizeBoxes(context, ref, "width", "height");
    try size.close(context);
    try bind.slider(context, ref, "opacity", "Opacity", .{ .display = .percent_of_255 });
    try widgets.hintText(context, .src(@src()), "Lower lets you see through the panel.");
    try bind.toggle(context, ref, "colorSystemNames", "Color System Names");
    try widgets.hintText(context, .src(@src()), "Shows each system in the same color as its name on thumbnails: System Colors first, then unique colors if those are on.");
    const detached = try widgets.openGroup(context, .src(@src()), !ref.get("attached"));
    try bind.toggle(context, ref, "rememberPosition", "Remember Position");
    try widgets.hintText(context, .src(@src()), "Opens the panel where you last left it.");
    try panel_settings.alwaysOnTop(context, ref, .intel);
    try panel_settings.autoHide(context, ref, .intel);
    try detached.close(context);
    try options.close(context);
    try section.close(context);
}

fn layout(context: *ui.Frame, ref: MapRef, is_shown: bool) !void {
    const section = try widgets.openSection(context, "Layout", "The panel's size and font. A bigger panel fits more system names.", &style.section);
    const options = try widgets.openGroup(context, .src(@src()), is_shown);
    const size = try widgets.openBinding(context, .src(@src()), "Size");
    try bind.sizeBoxes(context, ref, "width", "height");
    try size.close(context);
    const font = try widgets.openBinding(context, .src(@src()), "System Name Font");
    try bind.fontBoxes(context, ref, "fontName", "fontSize", "fontWeight");
    try font.close(context);
    try widgets.hintText(context, .src(@src()), "Names that don't fit show when you hover their system.");
    try widgets.hintText(context, .src(@src()), "The buttons and tooltips use the History Panel's font, so the two panels match.");
    try options.close(context);
    try section.close(context);
}

fn behavior(context: *ui.Frame, ref: MapRef, is_shown: bool) !void {
    const section = try widgets.openSection(context, "Behavior", "What the map follows, where its figures come from, and how intel shows.", &style.section);
    const options = try widgets.openGroup(context, .src(@src()), is_shown);
    try bind.toggle(context, ref, "followActive", "Follow Active Client");
    try widgets.hintText(context, .src(@src()), "Opens a client's region when you switch to it, or when it jumps into another.");
    try bind.toggle(context, ref, "showCharacterNames", "Show Character Names");
    try widgets.hintText(context, .src(@src()), "Tags each system with a client in it. More than one in a system shows as a count.");
    try bind.toggle(context, ref, "liveStats", "Live Stats");
    try widgets.hintText(context, .src(@src()), "Fetches kills, jumps and sovereignty from CCP while the panel shows. They cover the last hour.");
    const live_stats = try widgets.openGroup(context, .src(@src()), ref.get("liveStats"));
    try bind.toggle(context, ref, "showStorms", "Show Storms");
    try widgets.hintText(context, .src(@src()), "Marks metaliminal storms and how far they spread. Positions come from EVE-Scout's player reports, so they can lag.");
    try bind.toggle(context, ref, "showIncursions", "Show Incursions");
    try widgets.hintText(context, .src(@src()), "Marks the systems each incursion infests and where it stages, as reported by CCP.");
    try live_stats.close(context);
    try bind.toggle(context, ref, "showIntel", "Mark Systems With Intel");
    try widgets.hintText(context, .src(@src()), "Highlights systems named in intel channels. Needs log monitoring and an intel rule.");
    const intel = try widgets.openGroup(context, .src(@src()), ref.get("showIntel"));
    try bind.number(context, ref, "intelShrinkSec", "Intel Shrink Time", .{ .unit = "s" });
    try widgets.hintText(context, .src(@src()), "New intel shows as a large circle, which shrinks over this time and then leaves the map.");
    try bind.toggle(context, ref, "intelShowClear", "Mark Cleared Systems");
    try widgets.hintText(context, .src(@src()), "Turns a system's intel circle yellow when someone calls it clear or clr.");
    try intel.close(context);
    try options.close(context);
    try section.close(context);
}
