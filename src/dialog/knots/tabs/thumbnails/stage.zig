//! The Appearance page's stage: a thumbnail drawn from the edited settings and enlarged, whose text chips are dragged into place and clicked to edit in a popover; main thread only.
const std = @import("std");
const ui = @import("ui");
const types = @import("../../../../config/types.zig");
const session = @import("../../session.zig");
const style = @import("../../style.zig");
const widgets = @import("../../widgets.zig");
const chips = @import("chips.zig");

const Rect = ui.component.Rect;
const Button = ui.component.Button;
const Dialog = ui.component.Dialog;
/// A laid-out element's rectangle, in window coordinates.
const Box = @FieldType(ui.State.Measured, "box");

/// The stage fits this box; small thumbnails are enlarged so their chips are easy to grab.
const MAX_WIDTH: f32 = 560;
const MAX_HEIGHT: f32 = 300;
/// Within this many stage pixels a dragged chip locks flush to its anchor, as the old page's did.
const SNAP_DISTANCE: f32 = 5;
/// Movement under this is a click, not a drag.
const DRAG_THRESHOLD: f64 = 4;
const CLIENT_BACKGROUND = 0xFF2A3240;
const HIDDEN_OPACITY = 0.35;
const POPOVER_KEY: ui.Key = .str("knots.stage.popover");
/// Dialog keys its panel as its own key indexed by this.
const DIALOG_PANEL_INDEX = 2;
/// Kept between the popover and the window's edges.
const POPOVER_MARGIN: f32 = 8;
const POPOVER_GAP: f32 = 8;
/// Until the popover has been laid out once.
const POPOVER_HEIGHT_GUESS: f32 = 480;

pub const Focus = enum { focused, inactive };

const Drag = struct {
    index: usize,
    /// Where in the chip it was grabbed.
    grab: [2]f32,
    start: [2]f64,
    moved: bool = false,
    /// The chip's top-left on the stage while it's dragged.
    position: [2]f32,
};

var g_drag: ?Drag = null;
var g_selected_index: usize = 0;
var g_popover_open: bool = false;

pub fn show(context: *ui.Frame, focus: Focus) !void {
    const thumbnail = &session.profile().ptr.thumbnail;
    const width: f32 = @floatFromInt(@max(thumbnail.width, 1));
    const height: f32 = @floatFromInt(@max(thumbnail.height, 1));
    const scale = @min(MAX_WIDTH / width, MAX_HEIGHT / height);
    const stage_size = [2]f32{ @round(width * scale), @round(height * scale) };
    const arena = context.arena();
    const ui_state = context.ui();

    const border = borderOf(thumbnail, focus);
    const frame_style = try arena.create(ui.Style);
    // The border is the frame showing round the stage, so chip offsets stay relative to the stage itself.
    frame_style.* = .{
        .padding = .all(if (border) |b| @max(1, @round(@as(f32, @floatFromInt(b.width)) * scale)) else 0),
        .background = if (border) |b| .{ .color = widgets.colorFromArgb(b.color) } else .transparent,
    };
    const frame = Rect{ .key = .src(@src()), .style = frame_style };
    _ = try frame.open(context);

    const stage_key: ui.Key = .str("knots.stage");
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, stage_key.hash());
    const stage_box = measuredBox(ui_state, stage_key);
    const opacity = @as(f32, @floatFromInt(thumbnail.thumbnailOpacity)) / 255.0;
    const stage_style = try arena.create(ui.Style);
    stage_style.* = .{
        .width = .fixed(stage_size[0]),
        .height = .fixed(stage_size[1]),
        .background = .{ .color = withAlpha(CLIENT_BACKGROUND, opacity) },
        .overflow = .hidden,
    };
    const stage = Rect{ .key = stage_key, .style = stage_style };
    _ = try stage.open(context);

    const text_opacity = if (thumbnail.applyOpacityToOverlayTexts) opacity else 1.0;
    inline for (chips.CHIPS, 0..) |chip, index| {
        try showChip(context, chip, index, stage_box, stage_size, scale, text_opacity);
    }

    try stage.close(context);
    try frame.close(context);
    try popover(context);
}

/// Beside the selected chip, on whichever side has room. A click outside closes it, or opens another chip's when it lands on one.
fn popover(context: *ui.Frame) !void {
    if (!g_popover_open) return;
    const ui_state = context.ui();
    const chip_box = measuredBox(ui_state, chipKey(g_selected_index));
    const extent = context.input().logical_extent;
    const viewport = [2]f32{ @floatFromInt(extent.width), @floatFromInt(extent.height) };
    const panel_id = POPOVER_KEY.indexed(DIALOG_PANEL_INDEX).hash();
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, panel_id);
    const panel_box = measuredBox(ui_state, POPOVER_KEY.indexed(DIALOG_PANEL_INDEX));
    const panel_size = [2]f32{ style.POPOVER_WIDTH, if (panel_box.h() > 0) panel_box.h() else POPOVER_HEIGHT_GUESS };

    const right_of_chip = chip_box.x() + chip_box.w() + POPOVER_GAP;
    const x = if (right_of_chip + panel_size[0] + POPOVER_MARGIN <= viewport[0])
        right_of_chip
    else
        @max(POPOVER_MARGIN, chip_box.x() - POPOVER_GAP - panel_size[0]);
    const y = std.math.clamp(chip_box.y(), POPOVER_MARGIN, @max(POPOVER_MARGIN, viewport[1] - panel_size[1] - POPOVER_MARGIN));

    // The backdrop's padding is how far the panel sits from the window's top-left corner.
    const backdrop = try context.arena().create(ui.Style);
    backdrop.* = .{
        .@"align" = .start,
        .justify = .start,
        .padding = .init(y, POPOVER_MARGIN, POPOVER_MARGIN, x),
        .background = .transparent,
    };
    const dialog = Dialog{ .is_open = &g_popover_open, .key = POPOVER_KEY, .style = &style.popover, .parts = .{ .backdrop = backdrop } };
    _ = try dialog.open(context);
    inline for (chips.CHIPS, 0..) |chip, index| {
        if (index == g_selected_index) {
            if (try chips.showSettings(context, chip, index)) {
                g_popover_open = false;
                context.requestRedraw();
            }
        }
    }
    const reason = try dialog.closeResponse(context);
    if (reason != .backdrop) return;
    const mouse = ui_state.input.mouse_pos;
    const point = [2]f32{ @floatCast(mouse[0]), @floatCast(mouse[1]) };
    inline for (chips.CHIPS, 0..) |_, index| {
        if (index != g_selected_index and measuredBox(ui_state, chipKey(index)).contains(point)) {
            g_selected_index = index;
            g_popover_open = true;
        }
    }
}

fn chipKey(index: usize) ui.Key {
    return ui.Key.str("knots.stage.chip").indexed(index);
}

fn showChip(context: *ui.Frame, comptime chip: chips.Chip, comptime index: usize, stage_box: Box, stage_size: [2]f32, scale: f32, text_opacity: f32) !void {
    const ui_state = context.ui();
    const key = chipKey(index);
    const id = key.hash();
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, id);
    const box = measuredBox(ui_state, key);
    // First frame: not laid out yet, so draw once more with its real size.
    if (box.w() == 0) context.requestRedraw();
    const chip_size = [2]f32{ box.w(), box.h() };
    const look = chips.look(chip);
    const range = chips.offsetRange(chip);

    const mouse = ui_state.input.mouse_pos;
    if (ui_state.leftPressed(id, .within)) {
        g_drag = .{
            .index = index,
            .grab = .{ @as(f32, @floatCast(mouse[0])) - box.x(), @as(f32, @floatCast(mouse[1])) - box.y() },
            .start = mouse,
            .position = .{ box.x() - stage_box.x(), box.y() - stage_box.y() },
        };
    }

    var position = settledPosition(look, chip_size, stage_size, scale);
    if (g_drag) |*drag| if (drag.index == index) {
        if (ui_state.input.mouseButton(.left).down) {
            if (@abs(mouse[0] - drag.start[0]) + @abs(mouse[1] - drag.start[1]) > DRAG_THRESHOLD) drag.moved = true;
            if (drag.moved) drag.position = dragTarget(mouse, drag.grab, stage_box, chip_size, stage_size, scale, range);
            position = drag.position;
        } else {
            if (drag.moved) {
                const drop = dropResult(drag.position, chip_size, stage_size, scale, range);
                chips.place(chip, drop.anchor, drop.offset[0], drop.offset[1]);
                position = drag.position;
            } else {
                g_popover_open = true;
            }
            g_selected_index = index;
            g_drag = null;
            context.requestRedraw();
        }
    };

    const is_selected = index == g_selected_index;
    const chip_style = try context.arena().create(ui.Style);
    chip_style.* = .{
        .position = .absolute,
        .offset = position,
        .padding = .xy(4, 2),
        .font_size = .{ .px = @floatFromInt(@max(look.font_size, 8)) },
        .foreground = .{ .color = widgets.colorFromArgb(look.color | 0xFF000000) },
        .background = .{ .color = widgets.colorFromArgb(look.bg_color) },
        .radius = .none,
        .border_width = .all(1),
        .border_color = if (is_selected) .accent else .transparent,
        .opacity = if (look.is_shown) text_opacity else HIDDEN_OPACITY,
        .hover = &.{ .border_color = .accent, .state_layer = 0 },
        .active = &.{ .state_layer = 0 },
    };
    _ = try context.interact(Button{ .key = key, .label = chip.sample, .style = chip_style });
}

/// Where the settings put a chip, as old page's placeOverlayChip did: its anchor's box corner plus the scaled offsets, kept on the stage.
fn settledPosition(look: chips.Look, chip_size: [2]f32, stage_size: [2]f32, scale: f32) [2]f32 {
    const anchor = anchorPosition(look.position, chip_size, stage_size);
    return .{
        std.math.clamp(anchor[0] + @as(f32, @floatFromInt(look.offset_x)) * scale, 0, @max(0, stage_size[0] - chip_size[0])),
        std.math.clamp(anchor[1] + @as(f32, @floatFromInt(look.offset_y)) * scale, 0, @max(0, stage_size[1] - chip_size[1])),
    };
}

/// The cursor's spot for the chip, snapped flush to the nearest anchor when close and held within the offset range.
fn dragTarget(mouse: [2]f64, grab: [2]f32, stage_box: Box, chip_size: [2]f32, stage_size: [2]f32, scale: f32, range: [2]f32) [2]f32 {
    const max = [2]f32{ @max(0, stage_size[0] - chip_size[0]), @max(0, stage_size[1] - chip_size[1]) };
    var raw = [2]f32{
        std.math.clamp(@as(f32, @floatCast(mouse[0])) - stage_box.x() - grab[0], 0, max[0]),
        std.math.clamp(@as(f32, @floatCast(mouse[1])) - stage_box.y() - grab[1], 0, max[1]),
    };
    const anchor = anchorPosition(zoneFor(raw, chip_size, stage_size), chip_size, stage_size);
    if (std.math.hypot(raw[0] - anchor[0], raw[1] - anchor[1]) < SNAP_DISTANCE) raw = anchor;
    return .{
        std.math.clamp(raw[0], @max(0, anchor[0] + range[0] * scale), @min(max[0], anchor[0] + range[1] * scale)),
        std.math.clamp(raw[1], @max(0, anchor[1] + range[0] * scale), @min(max[1], anchor[1] + range[1] * scale)),
    };
}

const Drop = struct { anchor: types.TextPosition, offset: [2]i32 };

/// The anchor is the third of the thumbnail the chip's centre lands in; the offsets are what's left over, in real pixels.
fn dropResult(position: [2]f32, chip_size: [2]f32, stage_size: [2]f32, scale: f32, range: [2]f32) Drop {
    const zone = zoneFor(position, chip_size, stage_size);
    const anchor = anchorPosition(zone, chip_size, stage_size);
    return .{
        .anchor = zone,
        .offset = .{
            @intFromFloat(@round(std.math.clamp((position[0] - anchor[0]) / scale, range[0], range[1]))),
            @intFromFloat(@round(std.math.clamp((position[1] - anchor[1]) / scale, range[0], range[1]))),
        },
    };
}

fn zoneFor(position: [2]f32, chip_size: [2]f32, stage_size: [2]f32) types.TextPosition {
    const centre = [2]f32{ position[0] + chip_size[0] / 2, position[1] + chip_size[1] / 2 };
    const col: u8 = if (centre[0] < stage_size[0] / 3) 0 else if (centre[0] < stage_size[0] * 2 / 3) 1 else 2;
    const row: u8 = if (centre[1] < stage_size[1] / 3) 0 else if (centre[1] < stage_size[1] * 2 / 3) 1 else 2;
    // TextPosition's tags run in reading order, three to a row.
    return @enumFromInt(row * 3 + col);
}

/// The chip's top-left when it sits flush in `position`'s corner or edge.
fn anchorPosition(position: types.TextPosition, chip_size: [2]f32, stage_size: [2]f32) [2]f32 {
    const index = @intFromEnum(position);
    const free = [2]f32{ @max(0, stage_size[0] - chip_size[0]), @max(0, stage_size[1] - chip_size[1]) };
    const fractions = [3]f32{ 0, 0.5, 1 };
    return .{ free[0] * fractions[index % 3], free[1] * fractions[index / 3] };
}

const Border = struct { width: u8, color: u32 };

fn borderOf(thumbnail: anytype, focus: Focus) ?Border {
    return switch (focus) {
        .focused => if (thumbnail.showBorderWhenFocused) .{
            .width = thumbnail.borderWidth,
            .color = if (thumbnail.useUniqueCharacterBorderColors) chips.UNIQUE_SAMPLE else thumbnail.borderColor,
        } else null,
        .inactive => if (thumbnail.showBorderWhenInactive) .{
            .width = thumbnail.inactiveBorderWidth,
            .color = if (thumbnail.useUniqueCharacterBorderColors) chips.UNIQUE_SAMPLE else thumbnail.inactiveBorderColor,
        } else null,
    };
}

fn measuredBox(ui_state: *ui.UI, key: ui.Key) Box {
    const measured = ui_state.state.get(.measured, key.hash()) orelse return .zero;
    return measured.box;
}

fn withAlpha(value: u32, alpha: f32) ui.Color {
    const base = @as(f32, @floatFromInt(value >> 24)) / 255.0;
    const combined: u32 = @intFromFloat(@round(base * alpha * 255.0));
    return widgets.colorFromArgb((value & 0x00FFFFFF) | (combined << 24));
}

comptime {
    // zoneFor and anchorPosition rely on TextPosition's reading order.
    std.debug.assert(@intFromEnum(types.TextPosition.TopLeft) == 0);
    std.debug.assert(@intFromEnum(types.TextPosition.Center) == 4);
    std.debug.assert(@intFromEnum(types.TextPosition.BottomRight) == 8);
}
