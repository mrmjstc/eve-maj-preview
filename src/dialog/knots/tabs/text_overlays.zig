//! The Appearance tab's Text Overlays section: the thumbnail preview its texts are placed on, and whether they show and sync their styling; main thread only.
const ui = @import("ui");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const chips = @import("thumbnails/chips.zig");
const stage = @import("thumbnails/stage.zig");

/// Thumbnails mode only.
pub fn textOverlays(context: *ui.Frame) !void {
    const thumbnail = session.profile().child("thumbnail");
    const section = try widgets.openSection(context, "Text Overlays", "Texts shown on each thumbnail, previewed at its size. Drag one to move it, or click it to turn it on or off and change its font and colours. Faded ones are off.", &style.section);
    try bind.toggle(context, thumbnail, "showText", "Show Text Overlays");
    const options = try widgets.openGroup(context, .src(@src()), thumbnail.get("showText"));
    if (try widgets.checkbox(context, .src(@src()), "Sync Fonts and Backgrounds", &chips.g_sync_styling)) {
        if (chips.g_sync_styling) chips.syncFromCharacterName();
    }
    try widgets.hintText(context, .src(@src()), "Editing one overlay's font or background applies it to all the others.");
    try options.close(context);
    // Outside the group, so it still previews size and opacity while texts are off.
    try stage.show(context);
    try section.close(context);
}
