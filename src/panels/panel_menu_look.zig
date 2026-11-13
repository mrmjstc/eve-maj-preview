//! The panels' ⋯ menu: which rows a panel's menu has, where they sit and what's under the cursor; no I/O.
const std = @import("std");
const types = @import("../config/types.zig");
const ranges = @import("../config/ranges.zig");
const palette = @import("palette.zig");
const popup_look = @import("popup_look.zig");
const segmented = @import("segmented.zig");
const box = @import("../util/box.zig");

const Box = box.Box;
const ListViewOrder = types.ListViewOrder;

/// Leaves the order's segmented control room beside its label.
pub const WIDTH: i32 = palette.MENU_WIDTH;
const PADDING: i32 = palette.MENU_PADDING;
const ROW_HEIGHT: i32 = popup_look.MENU_ROW_HEIGHT;
const RULE_HEIGHT: i32 = 9;
/// A rule's ends, in from its row's.
pub const RULE_INSET: i32 = 6;
/// The order's segmented control, a control's full height like every other.
const ORDER_BAR_HEIGHT: i32 = palette.CONTROL_HEIGHT;
/// Taller than a plain row, so the bar keeps clear of the rules above and below it.
const ORDER_ROW_HEIGHT: i32 = ORDER_BAR_HEIGHT + 6;
const TRACK_HEIGHT: i32 = 4;
pub const KNOB_RADIUS: i32 = 6;
/// The opacity row's label, before its track.
const OPACITY_LABEL_WIDTH: i32 = 52;
/// The opacity's percentage, after the track.
const VALUE_WIDTH: i32 = 28;
/// Between the track and its percentage.
const VALUE_GAP: i32 = 8;
pub const ORDER_LABEL = "Order";
pub const OPACITY_LABEL = "Opacity";
pub const HIDE_LABEL = "Hide Panel";
/// Fits percentText's longest result.
pub const PERCENT_TEXT_MAX = 8;
pub const MAX_ROWS = 10;
const MIN_OPACITY: u8 = ranges.OPACITY[0];
const MAX_OPACITY: u8 = ranges.OPACITY[1];

/// The order row's segments, left to right, as the configuration window offers them too.
pub const ORDER_OPTIONS = std.enums.values(ListViewOrder);
pub const ORDER_COUNT = ORDER_OPTIONS.len;

pub const Toggle = enum { keep_on_top, group_by_system, lock_position };
pub const Command = enum { settings, hide };
pub const Row = union(enum) { toggle: Toggle, rule, order, opacity, command: Command };

/// What a panel's menu offers and shows, read again for each draw.
pub const Contents = struct {
    is_on_top: bool,
    /// Null for a panel without the setting.
    groups_by_system: ?bool = null,
    is_locked: bool,
    /// Null for a panel without the setting.
    order: ?ListViewOrder = null,
    opacity: u8,
    /// Borrowed for the draw, e.g. "Client list settings...".
    settings_label: []const u8,
    can_hide: bool,
    /// The ticks' and the slider's.
    accent: u32,

    pub fn isOn(self: *const Contents, toggle: Toggle) bool {
        return switch (toggle) {
            .keep_on_top => self.is_on_top,
            .group_by_system => self.groups_by_system orelse false,
            .lock_position => self.is_locked,
        };
    }
};

/// What a click in the menu asks its panel to do.
pub const Action = union(enum) {
    toggle: Toggle,
    order: ListViewOrder,
    opacity: Opacity,
    command: Command,
};

pub const Opacity = struct {
    value: u8,
    /// The slider was let go, so the value is saved; otherwise it's shown unsaved.
    is_final: bool,
};

/// What's under the cursor.
pub const Hit = union(enum) {
    /// A toggle's or command's row, by index.
    row: usize,
    order: ListViewOrder,
    opacity,
};

/// Where the menu's rows sit, from its own top-left corner.
pub const Layout = struct {
    boxes: [MAX_ROWS]Box = undefined,
    row_count: usize = 0,
    height: i32 = 0,
    /// The order's segmented control; only while the menu has an order row.
    order_bar: Box = undefined,
    segments: [ORDER_COUNT]Box = undefined,
    /// The opacity row's track; only while it has one.
    track: Box = undefined,

    pub fn hitAt(self: *const Layout, menu_rows: []const Row, x: i32, y: i32) ?Hit {
        for (self.boxes[0..self.row_count], menu_rows, 0..) |row_box, row, index| {
            if (!row_box.containsPoint(x, y)) continue;
            switch (row) {
                .toggle, .command => return .{ .row = index },
                .rule => return null,
                .order => {
                    for (self.segments, ORDER_OPTIONS) |segment, order| {
                        if (segment.containsPoint(x, y)) return .{ .order = order };
                    }
                    return null;
                },
                .opacity => return if (x >= self.track.left - KNOB_RADIUS and x < self.track.right + KNOB_RADIUS) .opacity else null,
            }
        }
        return null;
    }
};

pub fn rows(contents: *const Contents, out: *[MAX_ROWS]Row) []const Row {
    var count: usize = 0;
    out[count] = .{ .toggle = .keep_on_top };
    count += 1;
    if (contents.groups_by_system != null) {
        out[count] = .{ .toggle = .group_by_system };
        count += 1;
    }
    out[count] = .{ .toggle = .lock_position };
    count += 1;
    out[count] = .rule;
    count += 1;
    if (contents.order != null) {
        out[count] = .order;
        count += 1;
    }
    out[count] = .opacity;
    count += 1;
    out[count] = .rule;
    count += 1;
    out[count] = .{ .command = .settings };
    count += 1;
    if (contents.can_hide) {
        out[count] = .{ .command = .hide };
        count += 1;
    }
    return out[0..count];
}

/// `segment_widths` are the order labels', in ORDER_OPTIONS.
pub fn layOut(menu_rows: []const Row, segment_widths: [ORDER_COUNT]i32) Layout {
    var layout: Layout = .{ .row_count = menu_rows.len };
    const left = PADDING;
    const right = WIDTH - PADDING;
    var y = PADDING;
    for (menu_rows, layout.boxes[0..menu_rows.len]) |row, *row_box| {
        const height = switch (row) {
            .rule => RULE_HEIGHT,
            .order => ORDER_ROW_HEIGHT,
            .toggle, .opacity, .command => ROW_HEIGHT,
        };
        row_box.* = .{ .left = left, .top = y, .right = right, .bottom = y + height };
        const middle = y + @divTrunc(height, 2);
        switch (row) {
            .order => layOutSegments(&layout, segment_widths, right - popup_look.MENU_RIGHT_INSET, middle),
            .opacity => layout.track = .{
                .left = left + popup_look.MENU_TEXT_LEFT + OPACITY_LABEL_WIDTH,
                .top = middle - @divTrunc(TRACK_HEIGHT, 2),
                .right = right - popup_look.MENU_RIGHT_INSET - VALUE_WIDTH - VALUE_GAP,
                .bottom = middle - @divTrunc(TRACK_HEIGHT, 2) + TRACK_HEIGHT,
            },
            .toggle, .rule, .command => {},
        }
        y += height;
    }
    layout.height = y + PADDING;
    return layout;
}

/// The value the slider takes at `x` across `track`.
pub fn opacityAt(track: Box, x: i32) u8 {
    const width = @max(1, track.right - track.left);
    const across = std.math.clamp(x - track.left, 0, width);
    const span: i32 = MAX_OPACITY - MIN_OPACITY;
    return @intCast(MIN_OPACITY + @divTrunc(across * span + @divTrunc(width, 2), width));
}

/// Where the knob sits for `opacity`.
pub fn knobX(track: Box, opacity: u8) i32 {
    const clamped: i32 = std.math.clamp(opacity, MIN_OPACITY, MAX_OPACITY);
    const span: i32 = MAX_OPACITY - MIN_OPACITY;
    return track.left + @divTrunc((clamped - MIN_OPACITY) * (track.right - track.left), span);
}

/// E.g. "80%".
pub fn percentText(buffer: *[PERCENT_TEXT_MAX]u8, opacity: u8) []const u8 {
    const percent = (@as(u32, opacity) * 100 + MAX_OPACITY / 2) / MAX_OPACITY;
    return std.mem.print(buffer, "{d}%", .{percent}) catch unreachable;
}

/// Short enough for the menu, and the configuration window's words too.
pub fn orderLabel(order: ListViewOrder) []const u8 {
    return switch (order) {
        .ConfiguredCharacters => "Setup",
        .Alphabetical => "A\u{2013}Z",
        .Tracked => "Found",
    };
}

pub fn toggleLabel(toggle: Toggle) []const u8 {
    return switch (toggle) {
        .keep_on_top => "Always on Top",
        .group_by_system => "Group by System",
        .lock_position => "Lock Position",
    };
}

/// The panels' segmented control, flush against `right` and centred on `middle`.
fn layOutSegments(layout: *Layout, segment_widths: [ORDER_COUNT]i32, right: i32, middle: i32) void {
    var widths: [ORDER_COUNT]i32 = undefined;
    for (segment_widths, &widths) |label_width, *width| width.* = segmented.buttonWidth(label_width);
    const bar_top = middle - @divTrunc(ORDER_BAR_HEIGHT, 2);
    layout.order_bar = .{ .left = right - segmented.barWidth(&widths, segmented.GAP, 0), .top = bar_top, .right = right, .bottom = bar_top + ORDER_BAR_HEIGHT };
    segmented.placeButtons(layout.order_bar, &widths, segmented.GAP, null, 0, &layout.segments);
}

const testing = std.testing;

fn sampleContents() Contents {
    return .{ .is_on_top = true, .groups_by_system = false, .is_locked = false, .order = .Alphabetical, .opacity = 255, .settings_label = "Settings", .can_hide = true, .accent = 0xFFD9A441 };
}

test "a panel without grouping or order leaves those rows out" {
    var buffer: [MAX_ROWS]Row = undefined;
    var contents = sampleContents();
    const full = rows(&contents, &buffer).len;
    contents.groups_by_system = null;
    contents.order = null;
    contents.can_hide = false;
    try testing.expectEqual(full - 3, rows(&contents, &buffer).len);
}

test "hitAt finds rows, segments and the slider, but not rules" {
    var buffer: [MAX_ROWS]Row = undefined;
    const contents = sampleContents();
    const menu_rows = rows(&contents, &buffer);
    const layout = layOut(menu_rows, @splat(30));
    const first = layout.boxes[0];
    try testing.expectEqual(@as(?Hit, .{ .row = 0 }), layout.hitAt(menu_rows, first.left + 1, first.top + 1));
    const rule = layout.boxes[3];
    try testing.expectEqual(@as(?Hit, null), layout.hitAt(menu_rows, rule.left + 1, rule.top + 1));
    const segment = layout.segments[1];
    try testing.expectEqual(@as(?Hit, .{ .order = .Alphabetical }), layout.hitAt(menu_rows, segment.left, segment.top));
    try testing.expectEqual(@as(?Hit, .opacity), layout.hitAt(menu_rows, layout.track.left + 5, layout.track.top));
    for (layout.segments) |each| try testing.expect(each.right <= WIDTH - PADDING);
}

test "opacityAt runs from the minimum at the track's left to opaque at its right" {
    const track: Box = .{ .left = 100, .top = 0, .right = 200, .bottom = 4 };
    try testing.expectEqual(MIN_OPACITY, opacityAt(track, 50));
    try testing.expectEqual(MAX_OPACITY, opacityAt(track, 250));
    try testing.expectEqual(@as(i32, 200), knobX(track, 255));
    try testing.expectEqual(@as(i32, 100), knobX(track, MIN_OPACITY));
}

test "percentText rounds to whole percent" {
    var buffer: [PERCENT_TEXT_MAX]u8 = undefined;
    try testing.expectEqualStrings("100%", percentText(&buffer, 255));
    try testing.expectEqualStrings("80%", percentText(&buffer, 204));
}
