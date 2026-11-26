//! Drawing a thumbnail space on screen with the app's region overlay, and storing the result in the edited profile; main thread only.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const config = @import("../../config.zig");
const spaces = @import("../../layout/spaces.zig");
const region_select = @import("../tools/region_select.zig");
const session_mod = @import("session.zig");
const status_mod = @import("status.zig");
const lang = @import("../../lang/lang.zig");
const log = @import("../../log.zig");

const Session = session_mod.Session;
const Status = status_mod.Status;
const slog = log.Scoped("dialog_knots");

/// Outlives the window, since the overlay it starts can close after the window has.
pub const Region = struct {
    allocator: std.mem.Allocator,
    /// By id, so a reorder or removal mid-selection can't redirect it; null when none is running.
    target_space_id: ?u32 = null,
    /// The thumbnail windows a selection hid, to show again once it ends; owned, freed by finish.
    hidden: std.ArrayList(win32.HWND) = .empty,
    overlay: region_select.Overlay = .{},

    pub fn init(allocator: std.mem.Allocator) Region {
        return .{ .allocator = allocator };
    }

    /// `is_editing`: adjust the space's rectangle rather than draw a new one.
    /// `on_finished`: called as the overlay closes, to call finish.
    /// `on_selected`: called after it with the result, to call select.
    pub fn start(
        self: *Region,
        session: *Session,
        status: *Status,
        space_id: u32,
        is_editing: bool,
        on_finished: *const fn () void,
        on_selected: *const fn (region_select.Status, win32.RECT) void,
    ) void {
        const thumbnail_set = session.thumbnailSet() orelse return;
        const current = rect(session, space_id);
        if (is_editing and current == null) return;
        const should_hide = session.profile().ptr.display.hideThumbnailsDuringRegionSelect;
        const edit_region: ?win32.RECT = if (is_editing) current else null;
        const labels: region_select.Labels = .{
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

        if (should_hide) thumbnail_set.hideVisibleThumbnails(self.allocator, &self.hidden);
        const text_color = thumbnail_set.config.thumbnail.characterNameColor | 0xFF000000;
        self.overlay.start(thumbnail_set.instance, .{
            .accent_color = thumbnail_set.config.accentColor,
            .label_color = text_color,
            .edit_region = edit_region,
            .other_regions = others[0..other_count],
            .labels = labels,
        }, on_finished, on_selected) catch |err| {
            self.finish(session);
            slog.err("Failed to start region selection: {}", .{err});
            status.show(.failure, "Failed to start region selection: {err}", .{ .err = err });
            return;
        };
        self.target_space_id = space_id;
    }

    /// Once the window has closed, so a selection still running doesn't write to the next session.
    pub fn cancel(self: *Region) void {
        self.target_space_id = null;
    }

    /// From the overlay once it closes; returns whether it wrote to the window, which then needs a frame.
    pub fn select(self: *Region, session: *Session, status: *Status, result: region_select.Status, selected: win32.RECT) bool {
        const space_id = self.target_space_id orelse return false;
        self.target_space_id = null;
        switch (result) {
            .cancelled => return true,
            .too_small => {
                status.show(.info, "Selection too small: drag a larger area.", .{});
                return true;
            },
            .success => {},
        }
        setRect(session, space_id, selected.left, selected.top, win32.rectWidth(selected), win32.rectHeight(selected));
        if (find(session, space_id)) |space| space.set("enabled", true);
        status.show(.success, "Space region set", .{});
        return true;
    }

    /// Shows the thumbnails the selection hid.
    pub fn finish(self: *Region, session: *Session) void {
        defer {
            self.hidden.deinit(self.allocator);
            self.hidden = .empty;
        }
        const thumbnail_set = session.thumbnailSet() orelse return;
        thumbnail_set.showThumbnails(self.hidden.items);
    }
};

/// The space's rectangle, or null while it's unset, which greys out Edit and Clear.
pub fn rect(session: *Session, space_id: u32) ?win32.RECT {
    const space = find(session, space_id) orelse return null;
    return spaces.rect(space.ptr);
}

pub fn clear(session: *Session, space_id: u32) void {
    setRect(session, space_id, null, null, null, null);
}

fn find(session: *Session, space_id: u32) ?session_mod.Ref(config.ThumbnailSpace) {
    const profile = session.profile();
    for (profile.ptr.thumbnailSpaces.items, 0..) |space, i| {
        if (space.id == space_id) return profile.item("thumbnailSpaces", i);
    }
    return null;
}

fn setRect(session: *Session, space_id: u32, x: ?i32, y: ?i32, width: ?i32, height: ?i32) void {
    const space = find(session, space_id) orelse return;
    space.setFields(.{ .x = x, .y = y, .width = width, .height = height });
}
