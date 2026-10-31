//! The configuration window's Map Panel tab: its size, look, when it shows, its live figures, and the Intel Panel; main thread only.
const ui = @import("ui");
const config = @import("../../../config.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const panel_settings = @import("panel_settings.zig");

const Text = ui.component.Text;
const DisplayRef = session.Ref(config.DisplayConfig);

pub fn show(context: *ui.Frame) !void {
    const ref = session.profile().child("display");

    const section = try widgets.openSection(context, "Map Panel", "A map of one region at a time, with its gates, security and who's there. Hover a system for its details.", &style.section);
    try bind.toggle(context, ref, "showMapPanel", "Enable Map Panel");
    try widgets.hintText(context, .src(@src()), "Pick a region with its Regions button, or click a gate leading out of the map.");
    try section.close(context);

    const is_shown = ref.get("showMapPanel");
    try layout(context, ref, is_shown);
    try panel_settings.visibility(context, ref, .map, is_shown, .{
        .remember = "rememberMapPanelPosition",
        .opacity = "mapPanelOpacity",
        .without_characters = "hideMapPanelWhenNoCharacters",
        .without_focus = "hideMapPanelWhenNoEveFocus",
        .delay_ms = "mapPanelHideDebounceMs",
    });
    try behavior(context, ref, is_shown);
    try intelPanel(context, ref);
}

fn intelPanel(context: *ui.Frame, ref: DisplayRef) !void {
    const section = try widgets.openSection(context, "Intel Panel", "Lists every report from your intel channels, beside the map or on its own.", &style.section);
    try bind.toggle(context, ref, "showIntelPanel", "Enable Intel Panel");
    try widgets.hintText(context, .src(@src()), "Lists reports at any distance. Intel alerts leave the Notification History while this is on.");
    const options = try widgets.openGroup(context, .src(@src()), ref.get("showIntelPanel"));
    try bind.toggle(context, ref, "intelPanelAttached", "Inside Map Panel");
    try widgets.hintText(context, .src(@src()), "Shows as a sidebar in the map's window, which grows to fit it. Off gives it a window of its own.");
    const inside = try widgets.openGroup(context, .src(@src()), ref.get("intelPanelAttached"));
    try bind.segmented(context, ref, "intelPanelSide", "Side", &.{ "Left", "Right" });
    try widgets.hintText(context, .src(@src()), "Which side of the map the sidebar sits on.");
    try inside.close(context);
    const size = try widgets.openBinding(context, .src(@src()), "Size");
    try bind.unitNumberBox(context, ref, "intelPanelWidth", "px", .{});
    if (!ref.get("intelPanelAttached")) {
        try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "\u{00D7}", .style = &style.muted_text });
        try bind.unitNumberBox(context, ref, "intelPanelHeight", "px", .{});
    }
    try size.close(context);
    try bind.slider(context, ref, "intelPanelOpacity", "Opacity", .{ .display = .percent_of_255 });
    try widgets.hintText(context, .src(@src()), "Lower lets you see through the panel.");
    try bind.toggle(context, ref, "intelPanelColorSystemNames", "Color System Names");
    try widgets.hintText(context, .src(@src()), "Shows each system in the same color as its name on thumbnails: System Colors first, then unique colors if those are on.");
    const detached = try widgets.openGroup(context, .src(@src()), !ref.get("intelPanelAttached"));
    try bind.toggle(context, ref, "rememberIntelPanelPosition", "Remember Position");
    try widgets.hintText(context, .src(@src()), "Opens the panel where you last left it.");
    try panel_settings.autoHide(context, ref, .intel, "hideIntelPanelWhenNoCharacters", "hideIntelPanelWhenNoEveFocus", "intelPanelHideDebounceMs");
    try detached.close(context);
    try options.close(context);
    try section.close(context);
}

fn layout(context: *ui.Frame, ref: DisplayRef, is_shown: bool) !void {
    const section = try widgets.openSection(context, "Layout", "The panel's size and font. A bigger panel fits more system names.", &style.section);
    const options = try widgets.openGroup(context, .src(@src()), is_shown);
    const size = try widgets.openBinding(context, .src(@src()), "Size");
    try bind.unitNumberBox(context, ref, "mapPanelWidth", "px", .{});
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "\u{00D7}", .style = &style.muted_text });
    try bind.unitNumberBox(context, ref, "mapPanelHeight", "px", .{});
    try size.close(context);
    const font = try widgets.openBinding(context, .src(@src()), "System Name Font");
    try bind.fontBox(context, ref, "mapPanelFontName");
    try bind.unitNumberBox(context, ref, "mapPanelFontSize", "px", .{});
    try bind.choiceBox(context, ref, "mapPanelFontWeight");
    try font.close(context);
    try widgets.hintText(context, .src(@src()), "Names that don't fit show when you hover their system.");
    try widgets.hintText(context, .src(@src()), "The header, buttons and tooltips use the History Panel's font, so the two panels match.");
    try options.close(context);
    try section.close(context);
}

fn behavior(context: *ui.Frame, ref: DisplayRef, is_shown: bool) !void {
    const section = try widgets.openSection(context, "Behavior", "What the map follows, where its figures come from, and how intel shows.", &style.section);
    const options = try widgets.openGroup(context, .src(@src()), is_shown);
    try bind.toggle(context, ref, "mapPanelFollowActive", "Follow Active Client");
    try widgets.hintText(context, .src(@src()), "Opens a client's region when you switch to it, or when it jumps into another.");
    try bind.toggle(context, ref, "mapPanelLiveStats", "Live Stats");
    try widgets.hintText(context, .src(@src()), "Fetches kills, jumps and sovereignty from CCP while the panel shows. They cover the last hour.");
    try bind.toggle(context, ref, "mapPanelShowIntel", "Mark Systems With Intel");
    try widgets.hintText(context, .src(@src()), "Highlights systems named in intel channels. Needs log monitoring and an intel rule.");
    const intel = try widgets.openGroup(context, .src(@src()), ref.get("mapPanelShowIntel"));
    try bind.number(context, ref, "mapPanelIntelShrinkSec", "Intel Shrink Time", .{ .unit = "s" });
    try widgets.hintText(context, .src(@src()), "New intel shows as a large circle, which shrinks to its normal size over this time.");
    try bind.toggle(context, ref, "mapPanelIntelShowClear", "Mark Cleared Systems");
    try widgets.hintText(context, .src(@src()), "Turns a system's intel circle yellow when someone calls it clear or clr.");
    try intel.close(context);
    try options.close(context);
    try section.close(context);
}
