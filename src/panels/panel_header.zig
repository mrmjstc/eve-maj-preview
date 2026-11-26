//! The header the Client List, History and Intel panels share: its size, the collapse chevron and the icon buttons on its right; no I/O.
const std = @import("std");
const box = @import("../util/box.zig");

const Box = box.Box;

pub const HEIGHT: i32 = 34;
pub const BUTTON_SIZE: i32 = 24;
/// The most buttons a header has on its right.
pub const MAX_BUTTONS = 3;
const PADDING_LEFT: i32 = 5;
const PADDING_RIGHT: i32 = 6;
const BUTTON_GAP: i32 = 2;
/// The chevron's glyph is inset in its box, so the title sits close.
const TITLE_GAP: i32 = 2;
/// Between the header's text and its buttons.
const TEXT_GAP: i32 = 6;

/// What a header button does.
pub const Action = enum { pin, clear, mute, menu };

/// What's under the cursor in a header.
pub const Hit = union(enum) {
    chevron,
    button: Action,
};

/// Where a header's parts sit, from the panel's outer left edge.
pub const Layout = struct {
    chevron: Box,
    /// Where the title starts.
    title_left: i32,
    /// Where the title and anything after it must stop.
    content_right: i32,
    buttons: [MAX_BUTTONS]Box = undefined,
    actions: [MAX_BUTTONS]Action = undefined,
    button_count: usize = 0,

    /// `actions` left to right, at most MAX_BUTTONS of them.
    pub fn init(width: i32, actions: []const Action) Layout {
        const top = @divTrunc(HEIGHT - BUTTON_SIZE, 2);
        const chevron: Box = .{ .left = PADDING_LEFT, .top = top, .right = PADDING_LEFT + BUTTON_SIZE, .bottom = top + BUTTON_SIZE };
        var layout: Layout = .{ .chevron = chevron, .title_left = chevron.right + TITLE_GAP, .content_right = width - PADDING_RIGHT };
        const count = @min(actions.len, MAX_BUTTONS);
        var right = width - PADDING_RIGHT;
        var index = count;
        while (index > 0) {
            index -= 1;
            layout.buttons[index] = .{ .left = right - BUTTON_SIZE, .top = top, .right = right, .bottom = top + BUTTON_SIZE };
            layout.actions[index] = actions[index];
            right -= BUTTON_SIZE + BUTTON_GAP;
        }
        layout.button_count = count;
        if (count > 0) layout.content_right = layout.buttons[0].left - TEXT_GAP;
        return layout;
    }

    /// Null over the header's empty space, which drags the panel, and below the header.
    pub fn hitAt(self: *const Layout, x: i32, y: i32) ?Hit {
        if (self.chevron.containsPoint(x, y)) return .chevron;
        for (self.buttons[0..self.button_count], self.actions[0..self.button_count]) |button, action| {
            if (button.containsPoint(x, y)) return .{ .button = action };
        }
        return null;
    }

    /// The box `hit` is drawn in.
    pub fn boxOf(self: *const Layout, hit: Hit) ?Box {
        switch (hit) {
            .chevron => return self.chevron,
            .button => |action| {
                for (self.buttons[0..self.button_count], self.actions[0..self.button_count]) |button, button_action| {
                    if (button_action == action) return button;
                }
                return null;
            },
        }
    }
};

/// A panel's whole height: the header alone while it's collapsed.
pub fn panelHeight(is_collapsed: bool, expanded_height: i32) i32 {
    return if (is_collapsed) HEIGHT else @max(HEIGHT, expanded_height);
}

/// Equal when both are null or both hit the same part.
pub fn sameHit(first: ?Hit, second: ?Hit) bool {
    const first_hit = first orelse return second == null;
    const second_hit = second orelse return false;
    return std.meta.eql(first_hit, second_hit);
}

const testing = std.testing;

test "buttons line up from the right edge in the order given" {
    const layout: Layout = .init(300, &.{ .clear, .pin });
    try testing.expectEqual(@as(usize, 2), layout.button_count);
    try testing.expectEqual(300 - PADDING_RIGHT, layout.buttons[1].right);
    try testing.expectEqual(Action.pin, layout.actions[1]);
    try testing.expect(layout.buttons[0].right <= layout.buttons[1].left);
    try testing.expect(layout.content_right < layout.buttons[0].left);
}

test "hitAt finds the chevron and buttons and leaves the rest of the header to drag" {
    const layout: Layout = .init(300, &.{.pin});
    try testing.expect(sameHit(.chevron, layout.hitAt(layout.chevron.left + 1, HEIGHT / 2)));
    try testing.expect(sameHit(.{ .button = .pin }, layout.hitAt(layout.buttons[0].left + 1, HEIGHT / 2)));
    try testing.expectEqual(@as(?Hit, null), layout.hitAt(150, HEIGHT / 2));
    try testing.expectEqual(@as(?Hit, null), layout.hitAt(layout.chevron.left + 1, HEIGHT + 5));
}

test "a collapsed panel is as tall as its header" {
    try testing.expectEqual(HEIGHT, panelHeight(true, 400));
    try testing.expectEqual(@as(i32, 400), panelHeight(false, 400));
    try testing.expectEqual(HEIGHT, panelHeight(false, 10));
}
