//! The Appearance tab's System Colors section: a colour per solar system, or per name pattern; main thread only.
const ui = @import("ui");
const config = @import("../../../config.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const color_convert = @import("../color_convert.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const roster_mod = @import("../roster.zig");
const selection = @import("../selection.zig");
const lang = @import("../../../lang/lang.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const ProfileRef = session.Ref(config.Config);

const UNNAMED = "New System Color";

var g_selected: selection.Selection = .{};

/// Both thumbnails and the client list colour system names by these.
pub fn show(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "System Colors", "Give chosen solar systems' names their own color on thumbnails and in the client list.", &style.section);
    const profile = session.profile();
    const count = profile.ptr.systemColors.items.len;
    if (count == 0) {
        if (try widgets.emptyListRow(context, .src(@src()), "No system colors yet.", "Add System Color")) addEntry(context, profile);
        try section.close(context);
        return;
    }
    g_selected.clamp(count);
    const master_detail = Rect{ .key = .src(@src()), .style = &style.master_detail };
    _ = try master_detail.open(context);
    try roster(context, profile);
    try detail(context, profile, g_selected.index);
    try master_detail.close(context);
    try section.close(context);
}

/// Its details are the tab's last section, so the tab's end shows them.
fn addEntry(context: *ui.Frame, profile: ProfileRef) void {
    const added = profile.append("systemColors", .{ .systemName = "", .color = 0xFFFFFFFF }) orelse return;
    g_selected.index = added.index;
    widgets.scrollToEnd(context, widgets.TAB_CONTENT_KEY);
}

fn roster(context: *ui.Frame, profile: ProfileRef) !void {
    const entries = profile.ptr.systemColors.items;
    const list = try widgets.openRoster(context, .str("knots.system_color.roster"), &style.roster_fixed, true);
    const arena = context.arena();
    for (entries, 0..) |entry, index| {
        const row = try roster_mod.Row.open(context, ui.Key.str("knots.system_color.row").indexed(index), index == g_selected.index, null);
        if (row.is_picked) g_selected.index = index;
        const dot_style = try arena.create(ui.Style);
        dot_style.* = style.space_dot.with(.{ .background = color_convert.solid(entry.color) });
        try context.e(Rect{ .key = ui.Key.str("knots.system_color.dot").indexed(index), .style = dot_style });
        try row.close(context, try rowName(context, profile, index), style.SPACE_DOT_SIZE, .{});
    }
    if (try list.close(context, .{ .add_label = "Add System Color" }) == .add) addEntry(context, profile);
}

fn rowName(context: *ui.Frame, profile: ProfileRef, index: usize) ![]const u8 {
    const name = try bind.liveText(context, profile.item("systemColors", index), "systemName");
    return if (name.len > 0) name else lang.text(UNNAMED);
}

fn detail(context: *ui.Frame, profile: ProfileRef, index: usize) !void {
    const entry = profile.item("systemColors", index);
    const stack = Rect{ .key = .src(@src()), .style = &style.detail_fit };
    _ = try stack.open(context);

    const header = try widgets.openDetailHeader(context, .src(@src()), null);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("Systems"), .style = &style.inline_label });
    try bind.textBox(context, entry, "systemName", "e.g. Jita, Amarr or J######");
    const removed = try widgets.removeButton(context, ui.Key.str("knots.system_color.remove").indexed(index));
    try header.close(context);

    const color_row = try widgets.openBinding(context, ui.Key.str("knots.system_color.color").indexed(index), "Color");
    try bind.colorBox(context, entry, "color");
    try color_row.close(context);
    try widgets.hintText(context, .src(@src()), "The color these systems' names are drawn in; it beats Unique System Colors.");
    // Always shown, unlike a field hint: the wildcards are easy to miss otherwise.
    try widgets.paragraph(context, .src(@src()), "Separate names with commas. Wildcards: * any text, ? one character, # one digit, so J###### is every wormhole. Exact names beat wildcards.");
    try stack.close(context);

    if (removed) {
        profile.remove("systemColors", index);
        g_selected.afterRemove(index, profile.ptr.systemColors.items.len);
    }
}
