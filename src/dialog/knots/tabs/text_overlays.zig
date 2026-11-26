//! The Appearance tab's Text Overlays section: whether texts show, then the thumbnail preview they're placed and edited on; main thread only.
const ui = @import("ui");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const stage = @import("thumbnails/stage.zig");
const window_mod = @import("../window.zig");

const Rect = ui.component.Rect;
const Window = window_mod.Window;

/// Thumbnails mode only.
pub fn show(window: *Window, context: *ui.Frame) !void {
    const thumbnail = window.session.profile().child("thumbnail");
    const section = try window.widgets.openSection(context, "Text Overlays", "Drag a text to move it, or click it to edit it.", &style.bench_section);
    const intro = Rect{ .key = .src(@src()), .style = &style.bench_intro };
    _ = try intro.open(context);
    try window.bind.toggle(context, thumbnail, "showText", "Enable Text Overlays");
    try intro.close(context);
    // Outside a group, so it still previews size and opacity while texts are off.
    try stage.show(window, context);
    try section.close(context);
}
