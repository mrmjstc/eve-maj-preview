//! Suggesting logged-in clients' names under a name box, like the page's suggestOpenClients; main thread only.
const std = @import("std");
const ui = @import("ui");
const positions = @import("positions.zig");
const style = @import("style.zig");
const log = @import("../../log.zig");

const Rect = ui.component.Rect;
const Button = ui.component.Button;
const slog = log.scoped("dialog_knots");

/// The box whose list is showing; kept while the mouse is down on the list, since pressing it takes the box's focus.
var g_open_for: ?u64 = null;

/// Under the box keyed `box_key`: open clients whose name contains what's typed but isn't it; returns the one clicked.
pub fn openClients(context: *ui.Frame, box_key: ui.Key, typed: []const u8) !?[]const u8 {
    const ui_state = context.ui();
    const box_id = box_key.hash();
    const list_key = box_key.indexed(70);
    if (ui_state.focused(box_id)) {
        g_open_for = box_id;
    } else if (g_open_for == box_id) {
        const measured = ui_state.state.get(.measured, list_key.hash());
        const mouse = ui_state.input.mouse_pos;
        const over_list = if (measured) |list| list.box.contains(.{ @floatCast(mouse[0]), @floatCast(mouse[1]) }) else false;
        if (!(ui_state.input.mouseButton(.left).down and over_list) and !ui_state.input.mouseButton(.left).released) g_open_for = null;
    }
    if (g_open_for != box_id) return null;

    const names = positions.openClients(context.arena()) catch |err| {
        slog.warn("Failed to list open clients for suggestions: {}", .{err});
        return null;
    };
    const query = std.mem.trim(u8, typed, " ");
    var picked: ?[]const u8 = null;
    var shown: usize = 0;
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, list_key.hash());
    const list = Rect{ .key = list_key, .style = &style.suggest_list };
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(name, query)) continue;
        if (query.len > 0 and std.ascii.findIgnoreCase(name, query) == null) continue;
        if (shown == 0) _ = try list.open(context);
        if ((try context.interact(Button{ .key = list_key.indexed(shown + 1), .label = name, .style = &style.suggest_row })).clicked) picked = name;
        shown += 1;
    }
    if (shown > 0) try list.close(context);
    if (picked != null) {
        g_open_for = null;
        context.requestRedraw();
    }
    return picked;
}
