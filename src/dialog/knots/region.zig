//! Drawing a Thumbnail Space on screen with the app's region overlay, and storing the result in the edited profile; main thread only.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const painter_mod = @import("../../painter.zig");
const monitors = @import("../../layout/monitors.zig");
const region_select = @import("../tools/region_select.zig");
const session = @import("session.zig");
const status = @import("status.zig");
const host = @import("host.zig");
const log = @import("../../log.zig");

const slog = log.scoped("dialog_knots");

/// Which space's four settings a selection fills.
pub const Space = enum { thumbnail, not_logged_in };

var g_allocator: std.mem.Allocator = undefined;
/// The space a running selection fills; null when none is running, or it belongs to the WebView2 window.
var g_target: ?Space = null;
/// The thumbnail windows a selection hid, to show again once it ends.
var g_hidden: std.ArrayList(win32.HWND) = .empty;

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// Starts the overlay; `edit` adjusts the space's current rectangle instead of dragging a new one.
pub fn start(space: Space, edit: bool) void {
    const painter = painter_mod.g_painter_ptr orelse return;
    const current = rect(space);
    if (edit and current == null) return;
    const display = session.profile().ptr.display;
    const hide = switch (space) {
        .thumbnail => display.hideThumbnailsDuringRegionSelect,
        .not_logged_in => display.notLoggedInSpaceHideThumbnailsDuringRegionSelect,
    };
    const edit_region: ?win32.RECT = if (edit) current else null;
    const labels = region_select.Labels{};

    if (hide) painter.hideVisibleThumbnails(g_allocator, &g_hidden);
    const cursor = monitors.cursorMonitorBounds();
    const text_color = painter.config.thumbnail.characterNameColor | 0xFF000000;
    const label_font = painter.font_cache.characterNameFont(&painter.config.thumbnail, monitors.dpiForMonitor(cursor.monitor)) catch |err| blk: {
        slog.err("Failed to get font for region-select label: {}", .{err});
        break :blk null;
    };
    region_select.start(painter.instance, painter.config.accentColor, .{ .font = label_font, .color = text_color }, edit_region, labels, onFinished) catch |err| {
        onFinished();
        slog.err("Failed to start region selection: {}", .{err});
        status.show(.failure, "Failed to start region selection: {}", .{err});
        return;
    };
    g_target = space;
    if (label_font) |font| {
        const line1 = region_select.labelText(if (edit_region != null) &labels.hint_edit else &labels.hint_new);
        painter.hint_box.show(painter.instance, font, text_color, line1, region_select.labelText(&labels.hint_confirm), cursor.bounds);
    }
}

/// Once the window has closed, so a selection still running doesn't write to the next session.
pub fn cancel() void {
    g_target = null;
}

/// From dialog/events.zig once the overlay closes; returns whether this window had started it.
pub fn onSelected(result: region_select.Status, selected: win32.RECT) bool {
    const space = g_target orelse return false;
    g_target = null;
    defer host.redraw();
    switch (result) {
        .cancelled => return true,
        .too_small => {
            status.show(.info, "Selection too small - drag a larger area.", .{});
            return true;
        },
        .success => {},
    }
    setRect(space, selected.left, selected.top, win32.rectWidth(selected), win32.rectHeight(selected));
    status.show(.success, "Thumbnail region set", .{});
    return true;
}

/// The space's rectangle, or null while it's unset, which greys out Edit and Clear.
pub fn rect(space: Space) ?win32.RECT {
    const display = session.profile().ptr.display;
    const values = switch (space) {
        .thumbnail => [4]?i32{ display.regionX, display.regionY, display.regionWidth, display.regionHeight },
        .not_logged_in => [4]?i32{ display.notLoggedInSpaceX, display.notLoggedInSpaceY, display.notLoggedInSpaceWidth, display.notLoggedInSpaceHeight },
    };
    const x = values[0] orelse return null;
    const y = values[1] orelse return null;
    const width = values[2] orelse return null;
    const height = values[3] orelse return null;
    if (width <= 0 or height <= 0) return null;
    return .{ .left = x, .top = y, .right = x + width, .bottom = y + height };
}

pub fn clear(space: Space) void {
    setRect(space, null, null, null, null);
}

fn setRect(space: Space, x: ?i32, y: ?i32, width: ?i32, height: ?i32) void {
    const display = session.profile().child("display");
    switch (space) {
        .thumbnail => {
            display.set("regionX", x);
            display.set("regionY", y);
            display.set("regionWidth", width);
            display.set("regionHeight", height);
        },
        .not_logged_in => {
            display.set("notLoggedInSpaceX", x);
            display.set("notLoggedInSpaceY", y);
            display.set("notLoggedInSpaceWidth", width);
            display.set("notLoggedInSpaceHeight", height);
        },
    }
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
