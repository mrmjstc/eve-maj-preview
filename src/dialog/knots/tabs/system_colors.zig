//! The Appearance tab's System Colors section: a colour per solar system, or per name pattern; main thread only.
const ui = @import("ui");
const config = @import("../../../config.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const color_convert = @import("../color_convert.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const ProfileRef = session.Ref(config.Config);

const UNNAMED = "New System Color";

var g_selected_index: usize = 0;

/// Both thumbnails and the client list colour system names by these.
pub fn show(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "System Colors", "Colors chosen systems' names on thumbnails and in the client list.", &style.section);
    try widgets.hintText(context, .src(@src()), "These win over Unique System Colors. An exact name beats a pattern; otherwise the first matching row wins.");
    const profile = session.profile();
    const count = profile.ptr.systemColors.items.len;
    // The list can shrink while the window is open, e.g. on a profile switch.
    if (g_selected_index >= count) g_selected_index = count -| 1;
    const master_detail = Rect{ .key = .src(@src()), .style = &style.master_detail };
    _ = try master_detail.open(context);
    try roster(context, profile);
    if (profile.ptr.systemColors.items.len == 0) {
        const empty = Rect{ .key = .src(@src()), .style = &style.detail_fit };
        _ = try empty.open(context);
        try widgets.paragraph(context, .src(@src()), "Add a system color under the list to color a system's name.");
        try empty.close(context);
    } else {
        try detail(context, profile, g_selected_index);
    }
    try master_detail.close(context);
    try section.close(context);
}

fn roster(context: *ui.Frame, profile: ProfileRef) !void {
    const entries = profile.ptr.systemColors.items;
    const list = try widgets.openRoster(context, .str("knots.system_color.roster"), &style.roster_fixed, true);
    if (entries.len == 0) {
        try widgets.boxedText(context, .src(@src()), "No system colors yet.", &style.roster_empty, &style.roster_empty_text);
    }
    const arena = context.arena();
    for (entries, 0..) |entry, index| {
        const is_selected = index == g_selected_index;
        const row = Button{ .key = ui.Key.str("knots.system_color.row").indexed(index), .style = if (is_selected) &style.roster_row_selected else &style.roster_row };
        if ((try widgets.openRosterRow(context, row)).clicked and !is_selected) {
            g_selected_index = index;
            context.requestRedraw();
        }
        const dot_style = try arena.create(ui.Style);
        dot_style.* = style.space_dot.with(.{ .background = color_convert.solid(entry.color) });
        try context.e(Rect{ .key = ui.Key.str("knots.system_color.dot").indexed(index), .style = dot_style });
        try context.e(Text{
            .selectable = false,
            .key = ui.Key.str("knots.system_color.name").indexed(index),
            .content = try rowName(context, profile, index),
            .style = if (is_selected) &style.roster_name_selected else &style.roster_name,
        });
        try row.close(context);
    }
    if (try list.close(context, .{ .add_label = "Add System Color" }) == .add) {
        if (profile.append("systemColors", .{ .systemName = "", .color = 0xFFFFFFFF })) |added| g_selected_index = added.index;
    }
}

fn rowName(context: *ui.Frame, profile: ProfileRef, index: usize) ![]const u8 {
    const name = try bind.liveText(context, profile.item("systemColors", index), "systemName");
    return if (name.len > 0) name else UNNAMED;
}

fn detail(context: *ui.Frame, profile: ProfileRef, index: usize) !void {
    const entry = profile.item("systemColors", index);
    const stack = Rect{ .key = .src(@src()), .style = &style.detail_fit };
    _ = try stack.open(context);

    const header = try widgets.openDetailHeader(context, .src(@src()));
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "Systems", .style = &style.inline_label });
    try bind.textBox(context, entry, "systemName", "e.g. Jita, Amarr or J######");
    const removed = try widgets.confirmButton(context, ui.Key.str("knots.system_color.remove").indexed(index), "Remove", "Confirm", &style.plain_button, &style.confirm_button);
    try header.close(context);

    const color_row = try widgets.openBinding(context, ui.Key.str("knots.system_color.color").indexed(index), "Color");
    try bind.colorBox(context, entry, "color");
    try color_row.close(context);
    // Always shown, unlike a field hint: the wildcards are easy to miss otherwise.
    try widgets.paragraph(context, .src(@src()), "Separate names with commas. Wildcards: * any text, ? one character, # one digit, so J###### is every wormhole.");
    try stack.close(context);

    if (removed) {
        profile.remove("systemColors", index);
        g_selected_index = @min(index, profile.ptr.systemColors.items.len -| 1);
    }
}
