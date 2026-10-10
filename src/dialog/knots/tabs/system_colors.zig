//! The Appearance tab's System Colors section: a colour per solar system, or per name pattern; main thread only.
const ui = @import("ui");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

const Rect = ui.component.Rect;
const Button = ui.component.Button;

/// Both thumbnails and the client list colour system names by these.
pub fn show(context: *ui.Frame) !void {
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
