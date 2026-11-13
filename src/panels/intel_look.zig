//! The detached Intel Panel's look: its range filter, distance pills, faded old reports and row sizes; no I/O.
const std = @import("std");
const types = @import("../config/types.zig");
const list_look = @import("list_look.zig");
const palette = @import("palette.zig");
const segmented = @import("segmented.zig");
const box = @import("../util/box.zig");
const color = @import("../util/color.zig");

const Box = box.Box;
const IntelRange = types.IntelRange;

pub const HEADER_TEXT = "Intel";
/// Before the range filter.
pub const RANGE_LABEL = "Within";
pub const CLEAR_TEXT = "clear";
/// Fits pillText's, filterText's and emptyText's longest results.
pub const TEXT_MAX = 48;
/// A row's sides, and the range bar's.
pub const PADDING_X: i32 = palette.PADDING_X;
/// Between a row's pill, its text and its age.
pub const ROW_GAP: i32 = 9;
/// Above the first row.
pub const ROWS_PADDING_TOP: i32 = 4;
pub const PILL_MIN_WIDTH: i32 = 30;
pub const PILL_HEIGHT: i32 = 20;
pub const PILL_RADIUS: usize = palette.RADIUS;
pub const PILL_PADDING_X: i32 = 6;
/// Inside the clear tag.
pub const TAG_PADDING_X: i32 = 5;
pub const TAG_RADIUS: usize = palette.SMALL_RADIUS;
/// A hovered row's action buttons, square.
pub const ACTION_SIZE: i32 = 22;
pub const ACTION_GAP: i32 = 2;
pub const ACTION_RADIUS: usize = palette.RADIUS;
/// Between the range label and the segments.
pub const LABEL_GAP: i32 = 8;
/// A report this old is drawn faded.
pub const OLD_AFTER_MS: u64 = 10 * std.time.ms_per_min;
const BAR_PADDING_Y: i32 = 8;
/// So the pill leaves room above and below it.
const MIN_ROW_HEIGHT: i32 = PILL_HEIGHT + 8;
const NEAR_JUMPS = 1;
const MID_JUMPS = 5;
const NEAR_FILL_PERCENT = 20;
const MID_FILL_PERCENT = 16;
const CLEAR_FILL_PERCENT = 14;
/// How much of an old report's colour is left.
const OLD_PERCENT = 55;

// The colours below are 0xAARRGGBB, not premultiplied.
const NEAR_TEXT: u32 = 0xFFFFB4A8;
const MID_TEXT: u32 = 0xFFF2E088;
const MID_BASE: u32 = palette.CAUTION;
const CLEAR_COLOR: u32 = 0xFF5EC98F;

/// The filter's segments, left to right.
pub const RANGE_ORDER = [_]IntelRange{ .OneJump, .FiveJumps, .TenJumps, .All };
pub const RANGE_COUNT = RANGE_ORDER.len;

/// A coloured label and what's behind it.
pub const Swatch = struct { text: u32, fill: u32 };

/// Where the range filter's parts sit.
pub const RangeLayout = struct {
    /// The segmented control's bar, round the segments.
    bar: Box,
    /// In RANGE_ORDER.
    segments: [RANGE_COUNT]Box,
    /// Below the bar's divider, where the rows start.
    bottom: i32,

    pub fn rangeAt(self: *const RangeLayout, x: i32, y: i32) ?IntelRange {
        for (self.segments, RANGE_ORDER) |segment, range| {
            if (segment.containsPoint(x, y)) return range;
        }
        return null;
    }
};

/// A row grows with the font, and is never shorter than its pill needs.
pub fn rowHeight(font_size: i32) i32 {
    return @max(MIN_ROW_HEIGHT, list_look.rowHeight(font_size));
}

/// `label_widths` are each segment's text, in RANGE_ORDER; the control starts at `left`, under a bar of the panel from `top`.
pub fn layOutRange(label_widths: [RANGE_COUNT]i32, left: i32, top: i32) RangeLayout {
    var layout: RangeLayout = undefined;
    var widths: [RANGE_COUNT]i32 = undefined;
    for (label_widths, &widths) |label_width, *width| width.* = segmented.buttonWidth(label_width);
    const bar_top = top + BAR_PADDING_Y;
    layout.bar = .{ .left = left, .top = bar_top, .right = left + segmented.barWidth(&widths, segmented.GAP, 0), .bottom = bar_top + palette.CONTROL_HEIGHT };
    segmented.placeButtons(layout.bar, &widths, segmented.GAP, null, 0, &layout.segments);
    layout.bottom = layout.bar.bottom + BAR_PADDING_Y + 1;
    return layout;
}

pub fn rangeLabel(range: IntelRange) []const u8 {
    return switch (range) {
        .OneJump => "1j",
        .FiveJumps => "5j",
        .TenJumps => "10j",
        .All => "All",
    };
}

/// A report `jumps` away shows in `range`; one no client can reach shows only in All.
pub fn isWithin(range: IntelRange, jumps: ?u8) bool {
    const limit: u8 = switch (range) {
        .OneJump => 1,
        .FiveJumps => 5,
        .TenJumps => 10,
        .All => return true,
    };
    const distance = jumps orelse return false;
    return distance <= limit;
}

/// E.g. "3j"; "-" when no client can reach it.
pub fn pillText(buffer: *[TEXT_MAX]u8, jumps: ?u8) []const u8 {
    const distance = jumps orelse return "-";
    return std.mem.print(buffer, "{d}j", .{distance}) catch unreachable;
}

/// Red while a jump or less, yellow within a few, quiet past that.
pub fn pillSwatch(jumps: ?u8) Swatch {
    const distance = jumps orelse return .{ .text = palette.MUTED, .fill = palette.PANEL };
    if (distance <= NEAR_JUMPS) return .{ .text = NEAR_TEXT, .fill = color.mix(palette.ERROR, list_look.PANEL, NEAR_FILL_PERCENT) };
    if (distance <= MID_JUMPS) return .{ .text = MID_TEXT, .fill = color.mix(MID_BASE, list_look.PANEL, MID_FILL_PERCENT) };
    return .{ .text = palette.MUTED, .fill = palette.PANEL };
}

pub fn clearSwatch() Swatch {
    return .{ .text = CLEAR_COLOR, .fill = color.mix(CLEAR_COLOR, list_look.PANEL, CLEAR_FILL_PERCENT) };
}

/// `argb` as an old report draws it.
pub fn faded(argb: u32, is_old: bool) u32 {
    return if (is_old) color.mix(argb, list_look.PANEL, OLD_PERCENT) else argb;
}

/// How many of the reports the filter shows, at the bar's right.
pub fn filterText(buffer: *[TEXT_MAX]u8, shown_count: usize, total_count: usize) []const u8 {
    return std.mem.print(buffer, "{d} of {d}", .{ shown_count, total_count }) catch unreachable;
}

/// In place of the rows, when the filter leaves none.
pub fn emptyText(buffer: *[TEXT_MAX]u8, range: IntelRange) []const u8 {
    return std.mem.print(buffer, "Nothing reported within {s}", .{rangeLabel(range)}) catch unreachable;
}

const testing = std.testing;

test "isWithin keeps reports at the limit and drops unreachable ones unless showing all" {
    try testing.expect(isWithin(.FiveJumps, 5));
    try testing.expect(!isWithin(.FiveJumps, 6));
    try testing.expect(!isWithin(.TenJumps, null));
    try testing.expect(isWithin(.All, null));
}

test "pillSwatch is loudest close by" {
    try testing.expectEqual(NEAR_TEXT, pillSwatch(1).text);
    try testing.expectEqual(MID_TEXT, pillSwatch(4).text);
    try testing.expectEqual(palette.MUTED, pillSwatch(12).text);
    try testing.expectEqual(palette.MUTED, pillSwatch(null).text);
}

test "pillText counts jumps and marks an unreachable report" {
    var buffer: [TEXT_MAX]u8 = undefined;
    try testing.expectEqualStrings("3j", pillText(&buffer, 3));
    try testing.expectEqualStrings("-", pillText(&buffer, null));
}

test "layOutRange puts the segments side by side inside their bar" {
    const layout = layOutRange(@splat(20), 50, 34);
    try testing.expect(layout.segments[0].left > layout.bar.left);
    try testing.expect(layout.segments[RANGE_COUNT - 1].right < layout.bar.right);
    try testing.expect(layout.segments[1].left > layout.segments[0].right);
    try testing.expectEqual(@as(?IntelRange, .FiveJumps), layout.rangeAt(layout.segments[1].left, layout.segments[1].top));
    try testing.expectEqual(@as(?IntelRange, null), layout.rangeAt(layout.segments[0].right, layout.segments[0].top));
    try testing.expect(layout.bottom > layout.bar.bottom);
}

test "an old report fades and a new one keeps its colour" {
    try testing.expectEqual(palette.TEXT, faded(palette.TEXT, false));
    try testing.expect(faded(palette.TEXT, true) != palette.TEXT);
}
