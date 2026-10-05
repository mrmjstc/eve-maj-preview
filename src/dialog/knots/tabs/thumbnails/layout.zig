//! The Thumbnails tab's Layout page: how clients are shown and where thumbnails go; main thread only.
const ui = @import("ui");
const config = @import("../../../../config.zig");
const session = @import("../../session.zig");
const bind = @import("../../bind.zig");
const style = @import("../../style.zig");
const widgets = @import("../../widgets.zig");

const Text = ui.component.Text;
const DisplayRef = session.Ref(config.DisplayConfig);

pub fn show(context: *ui.Frame) !void {
    const display = session.profile().child("display");
    try displayMode(context, display);
    if (display.get("viewMode") != .Thumbnails) return;
    try thumbnailSpace(context, display);
    try notLoggedInSpace(context, display);
    if (session.global().get("advancedMode")) try placement(context, display);
    try snapping(context);
}

fn displayMode(context: *ui.Frame, display: DisplayRef) !void {
    const section = try widgets.openSection(context, "Display Mode", "Thumbnails show each client live; the Client List is a compact text panel that uses fewer resources. With Nothing, hotkeys and notifications still work.", .profile, &style.section);
    try bind.choiceStyled(context, display, "viewMode", "Show Clients As", &style.select_wide);
    switch (display.get("viewMode")) {
        .Thumbnails => {},
        .ClientList => {
            try bind.choice(context, display, "listViewOrder", "Order");
            try bind.number(context, display, "listViewColumns", "Columns", .{});
            try bind.slider(context, display, "listViewOpacity", "Opacity", .{ .display = .percent_of_255 });
            try bind.fontName(context, display, "listViewFontName", "Font Name");
            try bind.number(context, display, "listViewFontSize", "Font Size (px)", .{});
            try bind.choice(context, display, "listViewFontWeight", "Font Weight");
            try bind.toggle(context, display, "rememberListViewPosition", "Remember Client List Position");
        },
        .Nothing => try widgets.hintText(context, .src(@src()), "The settings for placing thumbnails are hidden while nothing is shown."),
    }
    try section.close(context);
}

fn thumbnailSpace(context: *ui.Frame, display: DisplayRef) !void {
    const section = try widgets.openSection(context, "Thumbnail Space", "An area of the screen that thumbnails fill automatically, reflowing as characters log in and out.", .profile, &style.section);
    var is_enabled = display.get("layoutMode") == .RegionFit;
    if (try widgets.checkbox(context, .src(@src()), "Arrange Thumbnails in a Thumbnail Space", &is_enabled)) {
        display.set("layoutMode", if (is_enabled) .RegionFit else .Custom);
    }
    try widgets.hintText(context, .src(@src()), "While on, thumbnails are placed by the space instead of their saved positions, and can't be dragged.");
    if (is_enabled) {
        try region(context, display, "regionX", "regionY", "regionWidth", "regionHeight");
        try bind.choice(context, display, "regionFitOrder", "Order By");
        try widgets.hintText(context, .src(@src()), "Character Order follows the Characters list; Hotkey Group Order follows the hotkey groups instead.");
        try bind.choiceStyled(context, display, "regionFitDirection", "Fill Order", &style.select_wide);
        try bind.number(context, display, "spacing", "Spacing (px)", .{});
        try bind.toggle(context, display, "regionFitLimitToThumbnailSize", "Never Grow Past the Thumbnail Size");
        try bind.toggle(context, display, "regionFitReorderLoggedOut", "Move Logged-Out Characters to the End");
        try widgets.hintText(context, .src(@src()), "When off, a logged-out character keeps its spot until the next reflow.");
        try bind.toggle(context, display, "hideThumbnailsDuringRegionSelect", "Hide Thumbnails While Selecting the Space");
    }
    try section.close(context);
}

fn notLoggedInSpace(context: *ui.Frame, display: DisplayRef) !void {
    const section = try widgets.openSection(context, "Not-Logged-In Space", "A separate area for the placeholders of characters that haven't logged in yet. Works with or without the Thumbnail Space.", .profile, &style.section);
    try bind.toggle(context, display, "notLoggedInSpaceEnabled", "Arrange Not-Logged-In Placeholders in Their Own Space");
    if (display.get("notLoggedInSpaceEnabled")) {
        try region(context, display, "notLoggedInSpaceX", "notLoggedInSpaceY", "notLoggedInSpaceWidth", "notLoggedInSpaceHeight");
        try bind.number(context, display, "notLoggedInSpaceSpacing", "Spacing (px)", .{});
        try bind.toggle(context, display, "notLoggedInSpaceLimitToThumbnailSize", "Never Grow Past the Thumbnail Size");
        try bind.toggle(context, display, "notLoggedInSpaceHideThumbnailsDuringRegionSelect", "Hide Thumbnails While Selecting the Space");
    }
    try section.close(context);
}

/// A screen rectangle as two rows of boxes; an unset one waits for a selection.
fn region(context: *ui.Frame, display: DisplayRef, comptime x: []const u8, comptime y: []const u8, comptime width: []const u8, comptime height: []const u8) !void {
    const position_row = try widgets.openBinding(context, .str("knots.region.position:" ++ x), "Position (x, y)");
    try bind.numberBox(context, display, x, .{ .placeholder = "not set" });
    try bind.numberBox(context, display, y, .{ .placeholder = "not set" });
    try position_row.close(context);
    const size_row = try widgets.openBinding(context, .str("knots.region.size:" ++ x), "Size (w × h)");
    try bind.numberBox(context, display, width, .{ .placeholder = "not set" });
    try context.e(Text{ .key = .str("knots.region.x:" ++ x), .content = "×", .style = &style.muted_text });
    try bind.numberBox(context, display, height, .{ .placeholder = "not set" });
    try size_row.close(context);
    try widgets.notPorted(context, .str("knots.region.select:" ++ x), "dragging out the space on screen");
}

/// Advanced Mode only, as on the old page.
fn placement(context: *ui.Frame, display: DisplayRef) !void {
    const section = try widgets.openSection(context, "New Thumbnails & Monitor", "Where thumbnails without a saved position appear, and which monitor the layout uses.", .profile, &style.section);
    const start_row = try widgets.openBinding(context, .src(@src()), "Start Position (x, y)");
    try bind.numberBox(context, display, "startX", .{});
    try bind.numberBox(context, display, "startY", .{});
    try start_row.close(context);
    try bind.number(context, display, "newThumbnailSpacing", "Spacing (px)", .{});
    try widgets.hintText(context, .src(@src()), "Lines new thumbnails up left to right from the start position, instead of stacking them on top of each other.");
    try bind.number(context, display, "monitorIndex", "Monitor", .{ .placeholder = "none" });
    try widgets.hintText(context, .src(@src()), "Lays thumbnails out on this monitor, where 0 is the primary. Leave empty to use plain screen coordinates.");
    if (display.get("monitorIndex") != null) try bind.toggle(context, display, "useMonitorWorkArea", "Keep Clear of the Taskbar");
    try bind.toggle(context, display, "honorSavedPositions", "Honor Saved Positions");
    try section.close(context);
}

fn snapping(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Snapping", "How dragged thumbnails line up with edges.", .profile, &style.section);
    const ref = session.profile().child("snapping");
    try bind.toggle(context, ref, "enabled", "Snap While Dragging");
    if (ref.get("enabled")) {
        try bind.toggle(context, ref, "screenEdges", "Snap to Screen Edges");
        try bind.toggle(context, ref, "thumbnailEdges", "Snap to Other Thumbnails");
        try bind.toggle(context, ref, "ghostPositions", "Snap to Other Characters' Saved Positions");
        try bind.toggle(context, ref, "showGhostPositionBorders", "Outline Saved Positions While Dragging");
        try bind.number(context, ref, "threshold", "Snap Distance (px)", .{});
    }
    try section.close(context);
}
