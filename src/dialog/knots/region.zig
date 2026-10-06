//! Drawing a thumbnail space on screen with the app's region overlay, and storing the result in the edited profile; main thread only.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const painter_mod = @import("../../painter.zig");
const config = @import("../../config.zig");
const monitors = @import("../../layout/monitors.zig");
const spaces = @import("../../layout/spaces.zig");
const region_select = @import("../tools/region_select.zig");
const session = @import("session.zig");
const status = @import("status.zig");
const host = @import("host.zig");
const log = @import("../../log.zig");

const slog = log.scoped("dialog_knots");

var g_allocator: std.mem.Allocator = undefined;
/// The id of the space a running selection fills, so a reorder or removal meanwhile can't redirect it; null when none is running.
var g_target: ?u32 = null;
/// The thumbnail windows a selection hid, to show again once it ends.
var g_hidden: std.ArrayList(win32.HWND) = .empty;

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// Starts the overlay for the space with id `space_id`; `edit` adjusts its current rectangle instead of dragging a new one.
pub fn start(space_id: u32, edit: bool) void {
    const painter = painter_mod.g_painter_ptr orelse return;
    const current = rect(space_id);
    if (edit and current == null) return;
    const hide = session.profile().ptr.display.hideThumbnailsDuringRegionSelect;
    const edit_region: ?win32.RECT = if (edit) current else null;
    const labels = region_select.Labels{};

    if (hide) painter.hideVisibleThumbnails(g_allocator, &g_hidden);
    const cursor = monitors.cursorMonitorBounds();
    const text_color = painter.config.thumbnail.characterNameColor | 0xFF000000;
    const label_font = painter.font_cache.characterNameFont(&painter.config.thumbnail, monitors.dpiForMonitor(cursor.monitor)) catch |err| blk: {
        slog.err("Failed to get font for region-select label: {}", .{err});
        break :blk null;
    };
    region_select.start(painter.instance, painter.config.accentColor, .{ .font = label_font, .color = text_color }, edit_region, labels, onFinished, onSelected) catch |err| {
        onFinished();
        slog.err("Failed to start region selection: {}", .{err});
        status.show(.failure, "Failed to start region selection: {}", .{err});
        return;
    };
    g_target = space_id;
    if (label_font) |font| {
        const line1 = region_select.labelText(if (edit_region != null) &labels.hint_edit else &labels.hint_new);
        painter.hint_box.show(painter.instance, font, text_color, line1, region_select.labelText(&labels.hint_confirm), cursor.bounds);
    }
}

/// Once the window has closed, so a selection still running doesn't write to the next session.
pub fn cancel() void {
    g_target = null;
}

/// From the overlay once it closes.
fn onSelected(result: region_select.Status, selected: win32.RECT) void {
    const space_id = g_target orelse return;
    g_target = null;
    defer host.redraw();
    switch (result) {
        .cancelled => return,
        .too_small => {
            status.show(.info, "Selection too small - drag a larger area.", .{});
            return;
        },
        .success => {},
    }
    setRect(space_id, selected.left, selected.top, win32.rectWidth(selected), win32.rectHeight(selected));
    status.show(.success, "Space region set", .{});
}

/// The space's rectangle, or null while it's unset, which greys out Edit and Clear.
pub fn rect(space_id: u32) ?win32.RECT {
    const space = find(space_id) orelse return null;
    return spaces.rect(space.ptr);
}

pub fn clear(space_id: u32) void {
    setRect(space_id, null, null, null, null);
}

fn find(space_id: u32) ?session.Ref(config.ThumbnailSpace) {
    const profile = session.profile();
    for (profile.ptr.thumbnailSpaces.items, 0..) |space, i| {
        if (space.id == space_id) return profile.item("thumbnailSpaces", i);
    }
    return null;
}

fn setRect(space_id: u32, x: ?i32, y: ?i32, width: ?i32, height: ?i32) void {
    const space = find(space_id) orelse return;
    space.set("x", x);
    space.set("y", y);
    space.set("width", width);
    space.set("height", height);
}

fn onFinished() void {
    defer {
        g_hidden.deinit(g_allocator);
        g_hidden = .empty;
    }
    const painter = painter_mod.g_painter_ptr orelse return;
    painter.showThumbnails(g_hidden.items);
    painter.hint_box.hide();
}
