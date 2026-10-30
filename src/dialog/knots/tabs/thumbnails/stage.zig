//! The Appearance tab's thumbnail preview: drawn from the edited settings at its real size, its texts dragged into place and clicked to edit in a popover; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../../config.zig");
const types = @import("../../../../config/types.zig");
const draw = @import("../../../../thumbnail/draw.zig");
const session = @import("../../session.zig");
const style = @import("../../style.zig");
const widgets = @import("../../widgets.zig");
const color_convert = @import("../../color_convert.zig");
const chips = @import("chips.zig");
const images = @import("../../images.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Image = ui.component.Image;
const Tooltip = ui.component.Tooltip;
const Canvas = ui.component.Canvas;
const Box = widgets.Box;
const measuredBox = widgets.measuredBox;

const STAGE_ROW_KEY: ui.Key = .str("knots.stage.row");
/// Within this many stage pixels a dragged chip locks flush to its anchor.
const SNAP_DISTANCE: f32 = 5;
const CLIENT_BACKGROUND = 0xFF2A3240;
const POPOVER_KEY: ui.Key = .str("knots.stage.popover");

const Drag = struct {
    index: usize,
    /// Where in the chip it was grabbed.
    grab: [2]f32,
    start: [2]f64,
    has_moved: bool = false,
    /// The chip's top-left on the stage while it's dragged.
    position: [2]f32,
};

const Drop = struct { anchor: types.TextPosition, offset: [2]i32 };

var g_drag: ?Drag = null;
var g_selected_index: usize = 0;
var g_is_popover_open: bool = false;

/// At the thumbnail's size, shrunk only to fit the section.
pub fn show(context: *ui.Frame) !void {
    const thumbnail = &session.profile().ptr.thumbnail;
    const width: f32 = @floatFromInt(@max(thumbnail.width, 1));
    const height: f32 = @floatFromInt(@max(thumbnail.height, 1));
    const arena = context.arena();
    const ui_state = context.ui();
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, STAGE_ROW_KEY.hash());
    const available_width = measuredBox(ui_state, STAGE_ROW_KEY).w();
    // Not laid out yet, so draw once more knowing the room there is.
    if (available_width == 0) context.requestRedraw();
    // The frame's 1px border on each side.
    const scale = if (available_width > 2 and width > available_width - 2) (available_width - 2) / width else 1;
    const stage_size = [2]f32{ @round(width * scale), @round(height * scale) };

    const row = Rect{ .key = STAGE_ROW_KEY, .style = &style.stage_row };
    _ = try row.open(context);
    const frame = Rect{ .key = .src(@src()), .style = &style.stage_frame };
    _ = try frame.open(context);

    const stage_key: ui.Key = .str("knots.stage");
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, stage_key.hash());
    const stage_box = measuredBox(ui_state, stage_key);
    const opacity = @as(f32, @floatFromInt(thumbnail.thumbnailOpacity)) / 255.0;
    const stage_style = try arena.create(ui.Style);
    stage_style.* = .{
        .width = .fixed(stage_size[0]),
        .height = .fixed(stage_size[1]),
        .background = .{ .color = scaleAlpha(CLIENT_BACKGROUND, opacity) },
        .overflow = .hidden,
    };
    const stage = Rect{ .key = stage_key, .style = stage_style };
    _ = try stage.open(context);
    try stageBackground(context, stage_size, opacity);

    inline for (chips.CHIPS, 0..) |chip, index| {
        try showChip(context, chip, index, stage_box, stage_size, scale);
    }
    try focusedBorder(context, thumbnail, stage_size);

    try stage.close(context);
    try frame.close(context);
    try row.close(context);
    try popover(context);
}

/// Beside the selected chip, on whichever side has room; a click outside closes it.
fn popover(context: *ui.Frame) !void {
    if (!g_is_popover_open) return;
    const ui_state = context.ui();
    const dialog = try widgets.openPopover(context, POPOVER_KEY, &g_is_popover_open, measuredBox(ui_state, chipKey(g_selected_index)));
    inline for (chips.CHIPS, 0..) |chip, index| {
        if (index == g_selected_index) {
            if (try chips.showSettings(context, chip, index)) {
                g_is_popover_open = false;
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
            g_is_popover_open = true;
        }
    }
}

fn chipKey(index: usize) ui.Key {
    return ui.Key.str("knots.stage.chip").indexed(index);
}

/// With its sample text, outlined, and a tooltip saying how to use it; a ghost with a dashed outline while off.
fn showChip(context: *ui.Frame, comptime chip: chips.Chip, comptime index: usize, stage_box: Box, stage_size: [2]f32, scale: f32) !void {
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
            if (@abs(mouse[0] - drag.start[0]) + @abs(mouse[1] - drag.start[1]) > widgets.DRAG_THRESHOLD) drag.has_moved = true;
            if (drag.has_moved) drag.position = dragTarget(mouse, drag.grab, stage_box, chip_size, stage_size, scale, range);
            position = drag.position;
        } else {
            if (drag.has_moved) {
                const drop = dropResult(drag.position, chip_size, stage_size, scale, range);
                chips.place(chip, drop.anchor, drop.offset[0], drop.offset[1]);
                position = drag.position;
            } else {
                g_is_popover_open = true;
            }
            g_selected_index = index;
            g_drag = null;
            context.requestRedraw();
        }
    };

    const is_selected = g_is_popover_open and index == g_selected_index;
    const is_shown = look.off_switch == null;
    const arena = context.arena();
    const trigger_style = try arena.create(ui.Style);
    trigger_style.* = style.overlay_text_trigger.with(.{ .offset = position });
    const tip = Tooltip{ .key = key.indexed(2), .content = try chips.tipText(arena, look.off_switch), .style = trigger_style, .parts = .{ .popup = &style.row_tooltip } };
    _ = try tip.open(context);
    const padding = [2]f32{ draw.TEXT_PADDING_X * scale, draw.TEXT_PADDING_Y * scale };
    const chip_style = try arena.create(ui.Style);
    chip_style.* = style.overlay_text.with(.{
        .padding = .xy(padding[0], padding[1]),
        .background = if (is_shown) .{ .color = color_convert.fromArgb(look.background_color) } else .{ .color = style.CHIP_OFF_FILL },
        .border_color = if (is_selected) .accent else if (is_shown) .{ .color = style.CHIP_OUTLINE } else .{ .color = .transparent },
    });
    const button = Button{ .key = key, .style = chip_style };
    const is_hovered = (try button.openResponse(context)).hovered;
    if (is_hovered) ui_state.requestCursor(.move);
    const text_style = try arena.create(ui.Style);
    text_style.* = .{
        .font = switch (look.font_weight) {
            .Regular, .Italic => style.FONT_REGULAR,
            .Bold, .BoldItalic => style.FONT_SEMIBOLD,
        },
        .font_size = .{ .px = @as(f32, @floatFromInt(look.font_size)) * scale },
        .foreground = if (is_shown) color_convert.solid(look.color) else .{ .color = style.TEXT },
    };
    try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = chip.sample, .style = text_style });
    // Hover and selection draw the accent outline instead.
    if (!is_shown and !is_hovered and !is_selected) {
        const outline_style = try arena.create(ui.Style);
        // Absolute children start inside the padding, so step back out to the chip's edge.
        outline_style.* = .{ .position = .absolute, .offset = .{ -padding[0], -padding[1] }, .width = .fixed(chip_size[0]), .height = .fixed(chip_size[1]) };
        try context.e(Canvas{ .key = key.indexed(3), .commands = try dashedOutline(arena, chip_size, style.MUTED.value), .style = outline_style });
    }
    try button.close(context);
    try tip.close(context);
}

/// Where the settings put a chip: its anchor's box corner plus the scaled offsets, kept on the stage.
fn settledPosition(look: chips.Look, chip_size: [2]f32, stage_size: [2]f32, scale: f32) [2]f32 {
    const anchor = anchorPosition(look.position, chip_size, stage_size);
    return .{
        std.math.clamp(anchor[0] + @as(f32, @floatFromInt(look.offset_x)) * scale, 0, @max(0, stage_size[0] - chip_size[0])),
        std.math.clamp(anchor[1] + @as(f32, @floatFromInt(look.offset_y)) * scale, 0, @max(0, stage_size[1] - chip_size[1])),
    };
}

/// Snapped flush to the nearest anchor when close, and held within the offset range.
fn dragTarget(mouse: [2]f64, grab: [2]f32, stage_box: Box, chip_size: [2]f32, stage_size: [2]f32, scale: f32, range: [2]f32) [2]f32 {
    const max = [2]f32{ @max(0, stage_size[0] - chip_size[0]), @max(0, stage_size[1] - chip_size[1]) };
    var raw_position = [2]f32{
        std.math.clamp(@as(f32, @floatCast(mouse[0])) - stage_box.x() - grab[0], 0, max[0]),
        std.math.clamp(@as(f32, @floatCast(mouse[1])) - stage_box.y() - grab[1], 0, max[1]),
    };
    const anchor = anchorPosition(zoneFor(raw_position, chip_size, stage_size), chip_size, stage_size);
    if (std.math.hypot(raw_position[0] - anchor[0], raw_position[1] - anchor[1]) < SNAP_DISTANCE) raw_position = anchor;
    return .{
        std.math.clamp(raw_position[0], @max(0, anchor[0] + range[0] * scale), @min(max[0], anchor[0] + range[1] * scale)),
        std.math.clamp(raw_position[1], @max(0, anchor[1] + range[0] * scale), @min(max[1], anchor[1] + range[1] * scale)),
    };
}

/// The anchor is the third the chip's centre lands in; offsets are the rest, in real pixels.
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
    const column: u8 = if (centre[0] < stage_size[0] / 3) 0 else if (centre[0] < stage_size[0] * 2 / 3) 1 else 2;
    const row: u8 = if (centre[1] < stage_size[1] / 3) 0 else if (centre[1] < stage_size[1] * 2 / 3) 1 else 2;
    // TextPosition's tags run in reading order, three to a row.
    return @fromBackingInt(@intCast(row * 3 + column));
}

/// The chip's top-left when it sits flush in `position`'s corner or edge.
fn anchorPosition(position: types.TextPosition, chip_size: [2]f32, stage_size: [2]f32) [2]f32 {
    const index = @backingInt(position);
    const free_space = [2]f32{ @max(0, stage_size[0] - chip_size[0]), @max(0, stage_size[1] - chip_size[1]) };
    const fractions = [3]f32{ 0, 0.5, 1 };
    return .{ free_space[0] * fractions[index % 3], free_space[1] * fractions[index / 3] };
}

/// Covers the stage, centred and cropped by it.
fn stageBackground(context: *ui.Frame, stage_size: [2]f32, opacity: f32) !void {
    const image_style = try context.arena().create(ui.Style);
    const image_size = [2]f32{ @floatFromInt(images.g_layout_preview.width), @floatFromInt(images.g_layout_preview.height) };
    const cover = @max(stage_size[0] / image_size[0], stage_size[1] / image_size[1]);
    const size = [2]f32{ image_size[0] * cover, image_size[1] * cover };
    image_style.* = .{
        .position = .absolute,
        .offset = .{ (stage_size[0] - size[0]) / 2, (stage_size[1] - size[1]) / 2 },
        .width = .fixed(size[0]),
        .height = .fixed(size[1]),
        .opacity = opacity,
    };
    if (images.g_layout_preview.image(.str("knots.stage.backdrop"), image_style)) |image| try context.e(image);
}

/// Drawn by the thumbnail's own border code at real size, then scaled with the stage.
fn focusedBorder(context: *ui.Frame, thumbnail: *const config.ThumbnailConfig, stage_size: [2]f32) !void {
    if (!thumbnail.showBorderWhenFocused) return;
    const width: usize = @intCast(@max(thumbnail.width, 1));
    const height: usize = @intCast(@max(thumbnail.height, 1));
    // drawBorder needs room for both sides.
    const border_width = @min(thumbnail.borderWidth, @min(width, height) / 2);
    const pixels = try context.arena().alloc(u32, width * height);
    @memset(pixels, 0);
    draw.drawBorder(.{ .pixels = pixels.ptr, .width = width, .height = height }, border_width, thumbnail.borderColor, thumbnail.borderStyle);

    const look = extern struct { width: u32, height: u32, border_width: u32, color: u32, style: u32 }{
        .width = @intCast(width),
        .height = @intCast(height),
        .border_width = @intCast(border_width),
        .color = thumbnail.borderColor,
        .style = @backingInt(thumbnail.borderStyle),
    };
    const image_style = try context.arena().create(ui.Style);
    image_style.* = .{
        .position = .absolute,
        .width = .fixed(stage_size[0]),
        .height = .fixed(stage_size[1]),
    };
    try context.e(Image{
        .key = .str("knots.stage.border"),
        .source = .{
            .pixels = .{
                .data = std.mem.sliceAsBytes(pixels),
                .width = look.width,
                .height = look.height,
                // 0xAARRGGBB words sit in memory as B, G, R, A.
                .format = .bgra8_srgb,
                .upload_policy = .versioned,
                .version = std.hash.Wyhash.hash(0, std.mem.asBytes(&look)),
            },
        },
        .style = image_style,
    });
}

/// Knots borders can't be dashed, so the dashes are drawn.
fn dashedOutline(arena: std.mem.Allocator, size: [2]f32, color: [4]f32) ![]const Canvas.DrawCmd {
    const dash = style.CHIP_DASH_LENGTH;
    var commands: std.ArrayList(Canvas.DrawCmd) = .empty;
    var x: f32 = 0;
    while (x < size[0]) : (x += dash * 2) {
        const length = @min(dash, size[0] - x);
        try commands.append(arena, .{ .fill_rect = .{ .x = x, .y = 0, .w = length, .h = 1, .color = color } });
        try commands.append(arena, .{ .fill_rect = .{ .x = x, .y = size[1] - 1, .w = length, .h = 1, .color = color } });
    }
    var y: f32 = 0;
    while (y < size[1]) : (y += dash * 2) {
        const length = @min(dash, size[1] - y);
        try commands.append(arena, .{ .fill_rect = .{ .x = 0, .y = y, .w = 1, .h = length, .color = color } });
        try commands.append(arena, .{ .fill_rect = .{ .x = size[0] - 1, .y = y, .w = 1, .h = length, .color = color } });
    }
    return commands.items;
}

fn scaleAlpha(argb: u32, alpha: f32) ui.Color {
    const base = @as(f32, @floatFromInt(argb >> 24)) / 255.0;
    const combined: u32 = @intFromFloat(@round(base * alpha * 255.0));
    return color_convert.fromArgb((argb & 0x00FFFFFF) | (combined << 24));
}

comptime {
    // zoneFor and anchorPosition rely on TextPosition's reading order.
    std.debug.assert(@backingInt(types.TextPosition.TopLeft) == 0);
    std.debug.assert(@backingInt(types.TextPosition.Center) == 4);
    std.debug.assert(@backingInt(types.TextPosition.BottomRight) == 8);
}
