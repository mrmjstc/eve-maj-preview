//! Suggesting logged-in clients' names under a name box; main thread only.
const std = @import("std");
const ui = @import("ui");
const positions = @import("positions.zig");
const style = @import("style.zig");
const log = @import("../../log.zig");

const Button = ui.component.Button;
const slog = log.Scoped("dialog_knots");

/// Clear of the indexes the box's own key is used with.
const LIST_KEY_INDEX = 70;

/// Kept while the mouse is down on the list, since pressing it takes the box's focus.
var g_open_box_id: ?u64 = null;

/// Open clients whose name contains `typed` but isn't it or one of `taken`; returns the one clicked.
pub fn openClients(context: *ui.Frame, box_key: ui.Key, typed: []const u8, taken: []const []const u8) !?[]const u8 {
    const ui_state = context.ui();
    const box_id = box_key.hash();
    const list_key = box_key.indexed(LIST_KEY_INDEX);
    if (ui_state.focused(box_id)) {
        g_open_box_id = box_id;
    } else if (g_open_box_id == box_id) {
        const measured = ui_state.state.get(.measured, list_key.hash());
        const mouse = ui_state.input.mouse_pos;
        const is_over_list = if (measured) |shown| shown.box.contains(.{ @floatCast(mouse[0]), @floatCast(mouse[1]) }) else false;
        if (!(ui_state.input.mouseButton(.left).down and is_over_list) and !ui_state.input.mouseButton(.left).released) g_open_box_id = null;
    }
    if (g_open_box_id != box_id) return null;

    const names = positions.openClients(context.arena()) catch |err| {
        slog.warn("Failed to list open clients for suggestions: {}", .{err});
        return null;
    };
    const query = std.mem.trim(u8, typed, " ");
    var matches: std.ArrayList([]const u8) = .empty;
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(name, query) or isTaken(taken, name)) continue;
        if (query.len > 0 and std.ascii.findIgnoreCase(name, query) == null) continue;
        try matches.append(context.arena(), name);
    }
    if (matches.items.len == 0) return null;

    // Floats under the box, from where it was laid out last frame, rather than taking room below it.
    const anchor = (try ui_state.state.getOrCreate(.measured, ui_state.allocator, box_id)).box;
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, list_key.hash());
    if (anchor.w() == 0) {
        context.requestRedraw();
        return null;
    }
    const list = ui_state.resolveStyle(list_key.hash(), .{ .base = &.{}, .user = &style.suggest_list }, .{}, null);
    const row_height = try ui_state.lineHeight(list.content.font_size, list.content.font) + 2 * style.SUGGEST_ROW_PADDING_Y;
    const list_height = row_height * @as(f32, @floatFromInt(matches.items.len)) + 2 * (style.SUGGEST_LIST_PADDING + style.SUGGEST_LIST_BORDER);
    const viewport_height: f32 = @floatFromInt(context.input().logical_extent.height);
    const space_below = viewport_height - (anchor.y() + anchor.h());
    const space_above = anchor.y();
    const is_above = list_height > space_below and space_above > space_below;
    const max_height = if (is_above) space_above else space_below;
    const list_y = if (is_above) anchor.y() - @min(list_height, max_height) else anchor.y() + anchor.h();
    var config = list.element(.{});
    config.width = .fixed(anchor.w());
    config.height = .{ .kind = .fit, .max = max_height };
    _ = try ui_state.openResolved(list_key, &list, config, .{ anchor.x(), list_y });

    var picked: ?[]const u8 = null;
    for (matches.items, 1..) |name, index| {
        if ((try context.interact(Button{ .key = list_key.indexed(index), .label = name, .style = &style.suggest_row })).clicked) picked = name;
    }
    ui_state.close();
    if (picked != null) {
        g_open_box_id = null;
        context.requestRedraw();
    }
    return picked;
}

fn isTaken(taken: []const []const u8, name: []const u8) bool {
    for (taken) |other| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, other, " "), name)) return true;
    }
    return false;
}
