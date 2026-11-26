//! The configuration window's Mouse tab: how thumbnails and the client list react to the mouse, and Shift+Click exclusion; main thread only.
const ui = @import("ui");
const config = @import("../../../config.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const window_mod = @import("../window.zig");

const Window = window_mod.Window;

pub fn show(window: *Window, context: *ui.Frame) !void {
    try interaction(window, context);
    try exclusion(window, context);
}

fn interaction(window: *Window, context: *ui.Frame) !void {
    const section = try window.widgets.openSection(context, "Interaction", "How thumbnails and the client list react to the mouse.", &style.section);
    const ref = window.session.profile().child("interaction");
    try window.bind.toggle(context, ref, "clickThrough", "Click Through");
    try window.widgets.hintText(context, .src(@src()), "Clicks go through thumbnails and the client list to what's behind.");
    const is_click_through = ref.get("clickThrough");

    const mouse_options = try window.widgets.openGroup(context, .src(@src()), !is_click_through);
    try window.bind.segmented(context, ref, "clickTrigger", "Click Trigger", &.{ "Mouse Down", "Mouse Up" });
    try window.widgets.hintText(context, .src(@src()), "Mouse Up waits until you let go, so sliding off first cancels the click.");
    try window.bind.choice(context, ref, "hoverCursor", "Hover Cursor");
    try window.widgets.hintText(context, .src(@src()), "The pointer shown over thumbnails and the client list.");
    try mouse_options.close(context);
    if (window.session.showsThumbnails()) try hoverZoom(window, context, ref, is_click_through);
    try section.close(context);
}

fn hoverZoom(window: *Window, context: *ui.Frame, ref: session.Ref(config.InteractionConfig), is_click_through: bool) !void {
    const zoom_options = try window.widgets.openGroup(context, .src(@src()), !is_click_through);
    try window.bind.toggle(context, ref, "hoverZoomEnabled", "Zoom on Hover");
    try window.widgets.hintText(context, .src(@src()), "Shows a bigger copy of a thumbnail while you hover over it.");
    const zoom = try window.widgets.openGroup(context, .src(@src()), ref.get("hoverZoomEnabled"));
    try window.bind.number(context, ref, "hoverZoomPercent", "Zoom Size", .{ .unit = "%" });
    try window.widgets.hintText(context, .src(@src()), "Shrinks to fit if it would go off the monitor.");
    try window.bind.choice(context, ref, "hoverZoomAnchor", "Zoom Anchor");
    try window.widgets.hintText(context, .src(@src()), "The part of the thumbnail that stays put as it grows.");
    try zoom.close(context);
    try zoom_options.close(context);
}

fn exclusion(window: *Window, context: *ui.Frame) !void {
    const section = try window.widgets.openSection(context, "Character Exclusion", "Controls Shift+Click exclusion of characters from hotkey cycling.", &style.section);
    const ref = window.session.profile().child("exclusion");
    try window.bind.toggle(context, ref, "enableShiftClickExclude", "Enable Shift+Click to Exclude");
    try window.widgets.hintText(context, .src(@src()), "Shift+click a thumbnail to skip its character when cycling.");
    try window.bind.toggle(context, ref, "autoMinimizeExcluded", "Auto-Minimize Excluded Characters");
    try window.widgets.hintText(context, .src(@src()), "Minimizes them straight away, without the delay.");
    try window.bind.toggle(context, ref, "logoutClearsExclusion", "Logging Out Clears Exclusion");
    try window.widgets.hintText(context, .src(@src()), "A character stops being excluded once you log it out.");
    if (window.session.showsThumbnails()) try exclusionOverlay(window, context);
    try section.close(context);
}

fn exclusionOverlay(window: *Window, context: *ui.Frame) !void {
    const thumbnail = window.session.profile().child("thumbnail");
    try window.bind.choice(context, thumbnail, "exclusionOverlayStyle", "Overlay Style");
    try window.widgets.hintText(context, .src(@src()), "How excluded thumbnails are marked.");
    try window.bind.rgb(context, thumbnail, "exclusionOverlayColor", "Overlay Color");
    try window.widgets.hintText(context, .src(@src()), "The tint laid over excluded thumbnails.");
    try window.bind.alphaSlider(context, thumbnail, "exclusionOverlayColor", "Overlay Opacity");
    try window.widgets.hintText(context, .src(@src()), "How strongly excluded thumbnails are tinted.");
}
