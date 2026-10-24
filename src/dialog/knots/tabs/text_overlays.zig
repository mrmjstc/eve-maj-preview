//! The Thumbnails tab's Text Overlays section: the thumbnail preview its texts are placed on, and whether they show and sync their styling; main thread only.
const ui = @import("ui");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const chips = @import("thumbnails/chips.zig");
const stage = @import("thumbnails/stage.zig");

/// Thumbnails mode only.
pub fn show(context: *ui.Frame) !void {
    const thumbnail = session.profile().child("thumbnail");
    const section = try widgets.openSection(context, "Text Overlays", "Drag a text to move it, or click it to edit it. Dashed ones are off.", &style.section);
    try bind.toggle(context, thumbnail, "showText", "Enable Text Overlays");
    const options = try widgets.openGroup(context, .src(@src()), thumbnail.get("showText"));
    if (try widgets.checkbox(context, .src(@src()), "Sync Fonts and Backgrounds", &chips.g_should_sync_styling)) {
        if (chips.g_should_sync_styling) chips.syncFromCharacterName();
    }
    try widgets.hintText(context, .src(@src()), "Changing one text's font or background changes them all.");
    try options.close(context);
    // Outside the group, so it still previews size and opacity while texts are off.
    try stage.show(context);
    try section.close(context);
}
