//! The configuration window's Text Overlays tab: the texts on each thumbnail and per-system colours; main thread only.
const ui = @import("ui");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const stage = @import("thumbnails/stage.zig");
const chips = @import("thumbnails/chips.zig");

const Rect = ui.component.Rect;
const Button = ui.component.Button;

pub fn show(context: *ui.Frame) !void {
    try textOverlays(context);
    try systemColors(context);
}

fn textOverlays(context: *ui.Frame) !void {
    const thumbnail = session.profile().child("thumbnail");
    const section = try widgets.openSection(context, "Text Overlays", "Texts shown on each thumbnail. Drag one on the preview to move it, or click it to turn it on or off and change its font and colours. Faded ones are off. The preview is not to scale.", &style.section);
    try bind.toggle(context, thumbnail, "showText", "Show Text Overlays");
    const options = try widgets.openGroup(context, .src(@src()), thumbnail.get("showText"));
    if (try widgets.checkbox(context, .src(@src()), "Sync Fonts and Backgrounds", &chips.g_sync_styling)) {
        if (chips.g_sync_styling) chips.syncFromCharacterName();
    }
    try widgets.hintText(context, .src(@src()), "Editing one overlay's font or background applies it to all the others.");
    const row = Rect{ .key = .src(@src()), .style = &style.stage_row };
    _ = try row.open(context);
    try stage.show(context);
    try row.close(context);
    try options.close(context);
    try section.close(context);
}

fn systemColors(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "System Colors", "Define custom colors for specific solar systems. These take priority over Unique System Colors and the default color. Separate names with commas; * matches any text, ? any character, # any digit (e.g. J######).", &style.section);
    const profile = session.profile();
    const list = Rect{ .key = .src(@src()), .style = &style.list };
    _ = try list.open(context);
    var index: usize = 0;
    while (index < profile.ptr.systemColors.items.len) : (index += 1) {
        const entry = profile.item("systemColors", index);
        const row = Rect{ .key = ui.Key.str("knots.system_color.row").indexed(index), .style = &style.list_row };
        _ = try row.open(context);
        try bind.textBox(context, entry, "systemName", "System name");
        try bind.colorBox(context, entry, "color");
        const removed = try widgets.confirmButton(context, ui.Key.str("knots.system_color.remove").indexed(index), "Remove", "Confirm", &style.remove_button, &style.confirm_remove_button);
        try row.close(context);
        if (removed) {
            profile.remove("systemColors", index);
            break;
        }
    }
    try list.close(context);
    if ((try context.interact(Button{ .key = .src(@src()), .label = "+ Add System Color", .style = &style.full_width_button })).clicked) {
        profile.append("systemColors", .{ .systemName = "", .color = 0xFFFFFFFF });
    }
    try section.close(context);
}
