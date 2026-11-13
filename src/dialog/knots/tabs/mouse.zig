//! The configuration window's Mouse tab: how thumbnails and the client list react to the mouse, and Shift+Click exclusion; main thread only.
const ui = @import("ui");
const config = @import("../../../config.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

pub fn show(context: *ui.Frame) !void {
    try interaction(context);
    try exclusion(context);
}

fn interaction(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Interaction", "How thumbnails and the client list react to the mouse.", &style.section);
    const ref = session.profile().child("interaction");
    try bind.toggle(context, ref, "clickThrough", "Click Through");
    try widgets.hintText(context, .src(@src()), "Clicks go through thumbnails and the client list to what's behind.");
    const is_click_through = ref.get("clickThrough");

    const mouse_options = try widgets.openGroup(context, .src(@src()), !is_click_through);
    try bind.segmented(context, ref, "clickTrigger", "Click Trigger", &.{ "Mouse Down", "Mouse Up" });
    try widgets.hintText(context, .src(@src()), "Mouse Up waits until you let go, so sliding off first cancels the click.");
    try bind.choice(context, ref, "hoverCursor", "Hover Cursor");
    try widgets.hintText(context, .src(@src()), "The pointer shown over thumbnails and the client list.");
    try mouse_options.close(context);
    if (session.showsThumbnails()) try hoverZoom(context, ref, is_click_through);
    try section.close(context);
}

fn hoverZoom(context: *ui.Frame, ref: session.Ref(config.InteractionConfig), is_click_through: bool) !void {
    const zoom_options = try widgets.openGroup(context, .src(@src()), !is_click_through);
    try bind.toggle(context, ref, "hoverZoomEnabled", "Zoom on Hover");
    try widgets.hintText(context, .src(@src()), "Shows a bigger copy of a thumbnail while you hover over it.");
    const zoom = try widgets.openGroup(context, .src(@src()), ref.get("hoverZoomEnabled"));
    try bind.number(context, ref, "hoverZoomPercent", "Zoom Size", .{ .unit = "%" });
    try widgets.hintText(context, .src(@src()), "Shrinks to fit if it would go off the monitor.");
    try bind.choice(context, ref, "hoverZoomAnchor", "Zoom Anchor");
    try widgets.hintText(context, .src(@src()), "The part of the thumbnail that stays put as it grows.");
    try zoom.close(context);
    try zoom_options.close(context);
}

fn exclusion(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Character Exclusion", "Controls Shift+Click exclusion of characters from hotkey cycling.", &style.section);
    const ref = session.profile().child("exclusion");
    try bind.toggle(context, ref, "enableShiftClickExclude", "Enable Shift+Click to Exclude");
    try widgets.hintText(context, .src(@src()), "Shift+click a thumbnail to skip its character when cycling.");
    try bind.toggle(context, ref, "autoMinimizeExcluded", "Auto-Minimize Excluded Characters");
    try widgets.hintText(context, .src(@src()), "Minimizes them straight away, without the delay.");
    try bind.toggle(context, ref, "logoutClearsExclusion", "Logging Out Clears Exclusion");
    try widgets.hintText(context, .src(@src()), "A character stops being excluded once you log it out.");
    if (session.showsThumbnails()) try exclusionOverlay(context);
    try section.close(context);
}

fn exclusionOverlay(context: *ui.Frame) !void {
    const thumbnail = session.profile().child("thumbnail");
    try bind.choice(context, thumbnail, "exclusionOverlayStyle", "Overlay Style");
    try widgets.hintText(context, .src(@src()), "How excluded thumbnails are marked.");
    try bind.rgb(context, thumbnail, "exclusionOverlayColor", "Overlay Color");
    try widgets.hintText(context, .src(@src()), "The tint laid over excluded thumbnails.");
    try bind.alphaSlider(context, thumbnail, "exclusionOverlayColor", "Overlay Opacity");
    try widgets.hintText(context, .src(@src()), "How strongly excluded thumbnails are tinted.");
}
