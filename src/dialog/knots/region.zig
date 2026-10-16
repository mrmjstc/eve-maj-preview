//! Drawing a thumbnail space on screen with the app's region overlay, and storing the result in the edited profile; main thread only.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const config = @import("../../config.zig");
const monitors = @import("../../layout/monitors.zig");
const spaces = @import("../../layout/spaces.zig");
const region_select = @import("../tools/region_select.zig");
const session = @import("session.zig");
const status = @import("status.zig");
const host = @import("host.zig");
const lang = @import("../../lang/lang.zig");
const log = @import("../../log.zig");

const slog = log.Scoped("dialog_knots");

var g_allocator: std.mem.Allocator = undefined;
/// By id, so a reorder or removal mid-selection can't redirect it; null when none is running.
var g_target_space_id: ?u32 = null;
/// The thumbnail windows a selection hid, to show again once it ends.
var g_hidden: std.ArrayList(win32.HWND) = .empty;

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// `is_editing` adjusts the space's current rectangle instead of dragging a new one.
pub fn start(space_id: u32, is_editing: bool) void {
    const thumbnail_set = session.runningApp().thumbnail_set orelse return;
    const current = rect(space_id);
    if (is_editing and current == null) return;
    const should_hide = session.profile().ptr.display.hideThumbnailsDuringRegionSelect;
    const edit_region: ?win32.RECT = if (is_editing) current else null;
    const labels = region_select.Labels{
        .save = region_select.fixedText(region_select.BUTTON_LABEL_SIZE, lang.text("Save")),
        .cancel = region_select.fixedText(region_select.BUTTON_LABEL_SIZE, lang.text("Cancel")),
        .hint_new = region_select.fixedText(region_select.HINT_SIZE, lang.text("Drag to draw the region, then drag its edges to adjust")),
        .hint_edit = region_select.fixedText(region_select.HINT_SIZE, lang.text("Drag the edges to resize, or the inside to move")),
        .hint_confirm = region_select.fixedText(region_select.HINT_SIZE, lang.text("Enter or Save to confirm, Esc or right-click to cancel")),
        .width_prefix = region_select.fixedText(region_select.FIELD_PREFIX_SIZE, lang.text("W")),
        .height_prefix = region_select.fixedText(region_select.FIELD_PREFIX_SIZE, lang.text("H")),
    };
    comptime std.debug.assert(region_select.MAX_OTHER_REGIONS >= spaces.MAX_SPACES);
    var others: [region_select.MAX_OTHER_REGIONS]win32.RECT = undefined;
    var other_count: usize = 0;
    for (session.profile().ptr.thumbnailSpaces.items) |*space| {
        if (space.id == space_id or other_count == others.len) continue;
        others[other_count] = spaces.rect(space) orelse continue;
        other_count += 1;
    }

    if (should_hide) thumbnail_set.hideVisibleThumbnails(g_allocator, &g_hidden);
    const cursor = monitors.cursorMonitorBounds();
    const text_color = thumbnail_set.config.thumbnail.characterNameColor | 0xFF000000;
    region_select.start(thumbnail_set.instance, .{
        .accent_color = thumbnail_set.config.accentColor,
        .label_color = text_color,
        .edit_region = edit_region,
        .other_regions = others[0..other_count],
        .labels = labels,
    }, onFinished, onSelected) catch |err| {
        onFinished();
        slog.err("Failed to start region selection: {}", .{err});
        status.show(.failure, "Failed to start region selection: {err}", .{ .err = err });
        return;
    };
    g_target_space_id = space_id;
    if (region_select.textFont()) |font| {
        const line1 = region_select.labelText(if (edit_region != null) &labels.hint_edit else &labels.hint_new);
        thumbnail_set.hint_box.show(thumbnail_set.instance, font, text_color, line1, region_select.labelText(&labels.hint_confirm), cursor.bounds);
    }
}

/// Once the window has closed, so a selection still running doesn't write to the next session.
pub fn cancel() void {
    g_target_space_id = null;
}

/// The space's rectangle, or null while it's unset, which greys out Edit and Clear.
pub fn rect(space_id: u32) ?win32.RECT {
    const space = find(space_id) orelse return null;
    return spaces.rect(space.ptr);
}

pub fn clear(space_id: u32) void {
    setRect(space_id, null, null, null, null);
}

/// From the overlay once it closes.
fn onSelected(result: region_select.Status, selected: win32.RECT) void {
    const space_id = g_target_space_id orelse return;
    g_target_space_id = null;
    defer host.redraw();
    switch (result) {
        .cancelled => return,
        .too_small => {
            status.show(.info, "Selection too small: drag a larger area.", .{});
            return;
        },
        .success => {},
    }
    setRect(space_id, selected.left, selected.top, win32.rectWidth(selected), win32.rectHeight(selected));
    if (find(space_id)) |space| space.set("enabled", true);
    status.show(.success, "Space region set", .{});
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
    space.setFields(.{ .x = x, .y = y, .width = width, .height = height });
}

fn onFinished() void {
    defer {
        g_hidden.deinit(g_allocator);
        g_hidden = .empty;
    }
    const thumbnail_set = session.runningApp().thumbnail_set orelse return;
    thumbnail_set.showThumbnails(g_hidden.items);
    thumbnail_set.hint_box.hide();
}
