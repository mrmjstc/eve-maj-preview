//! The Text Overlays section's thumbnail preview: drawn from the edited settings at its real size on a bench, its texts dragged into place and clicked to edit beside it; main thread only.
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
const panel_preview = @import("../panel_preview.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Image = ui.component.Image;
const Tooltip = ui.component.Tooltip;
const Box = widgets.Box;
const measuredBox = widgets.measuredBox;

const BENCH_KEY: ui.Key = .str("knots.stage.bench");
/// Within this many stage pixels a dragged chip locks flush to its anchor.
const SNAP_DISTANCE: f32 = 5;
const CLIENT_BACKGROUND = 0xFF2A3240;

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
var g_picker: panel_preview.Picker(chips.Part) = .{ .part_key = .str("knots.stage.chip"), .selected = .character_name };

/// At the thumbnail's size, shrunk only to fit the stage, with the selected text's settings beside it or under it.
pub fn show(context: *ui.Frame) !void {
    const thumbnail = &session.profile().ptr.thumbnail;
    const width: f32 = @floatFromInt(@max(thumbnail.width, 1));
    const height: f32 = @floatFromInt(@max(thumbnail.height, 1));
    const arena = context.arena();
    const ui_state = context.ui();
    // The frame's 1px border on each side.
    var bench = try panel_preview.Bench.open(context, BENCH_KEY, width + 2);
    const room = bench.available_width;
    const scale = if (room > 2 and width > room - 2) (room - 2) / width else 1;
    const stage_size = [2]f32{ @round(width * scale), @round(height * scale) };

    try bench.openStage(context, scale, &g_picker.shows_off);
    const frame = Rect{ .key = .src(@src()), .style = &style.stage_frame };
    _ = try frame.open(context);

    const stage_key: ui.Key = .str("knots.stage");
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, stage_key.hash());
    const stage_box = measuredBox(ui_state, stage_key);
    const opacity = @as(f32, @floatFromInt(thumbnail.thumbnailOpacity)) / 255.0;
    // Opaque, since the real fill ignores alpha.
    const background = if (thumbnail.showLivePreview) CLIENT_BACKGROUND else thumbnail.blankFill(session.profile().ptr.focusedBorderColor()) | 0xFF000000;
    const stage_style = try arena.create(ui.Style);
    stage_style.* = .{
        .width = .fixed(stage_size[0]),
        .height = .fixed(stage_size[1]),
        .background = .{ .color = scaleAlpha(background, opacity) },
        .overflow = .hidden,
    };
    const stage = Rect{ .key = stage_key, .style = stage_style };
    _ = try stage.open(context);
    if (thumbnail.showLivePreview) try stageBackground(context, stage_size, opacity);

    inline for (chips.CHIPS, 0..) |chip, index| {
        try showChip(context, chip, index, stage_box, stage_size, scale);
    }
    try focusedBorder(context, session.profile().ptr, stage_size);

    try stage.close(context);
    try frame.close(context);
    try bench.closeStage(context);
    try g_picker.partBar(context, BENCH_KEY.indexed(10), &partChips());
    try bench.openInspector(context);
    inline for (chips.CHIPS, 0..) |chip, index| {
        if (index == @backingInt(g_picker.selected)) try chips.showSettings(context, chip, index);
    }
    try bench.close(context);
}

/// Every text's chip for the part bar, its dot in the text's colour.
fn partChips() [chips.CHIPS.len]panel_preview.Picker(chips.Part).Chip {
    var part_chips: [chips.CHIPS.len]panel_preview.Picker(chips.Part).Chip = undefined;
    inline for (chips.CHIPS, 0..) |chip, index| {
        const part: chips.Part = @fromBackingInt(index);
        const look = chips.look(chip);
        part_chips[index] = .{ .part = part, .label = chip.label, .is_shown = look.off_switch == null, .color = look.color, .starts_group = part.startsGroup() };
    }
    return part_chips;
}

/// With its sample text and a tooltip saying how to use it; skipped while hidden, a dashed ghost while otherwise off.
fn showChip(context: *ui.Frame, comptime chip: chips.Chip, comptime index: usize, stage_box: Box, stage_size: [2]f32, scale: f32) !void {
    const ui_state = context.ui();
    const part: chips.Part = @fromBackingInt(index);
    const key = g_picker.keyOf(part);
    const id = key.hash();
    const look = chips.look(chip);
    const state = g_picker.stateOf(part, look.off_switch == null);
    if (state.isHidden()) return;
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, id);
    const box = measuredBox(ui_state, key);
    // First frame: not laid out yet, so draw once more with its real size.
    if (box.w() == 0) context.requestRedraw();
    const chip_size = [2]f32{ box.w(), box.h() };
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
            }
            g_picker.select(context, part);
            g_drag = null;
            context.requestRedraw();
        }
    };

    const is_outlined = state.is_selected or state.is_lit;
    const is_shown = state.is_shown;
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
        .border_color = if (is_outlined) .accent else .{ .color = .transparent },
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
    // Hover, light and selection draw the accent outline instead.
    if (!is_shown and !is_hovered and !is_outlined) try widgets.dashedOutline(context, key.indexed(3), chip_size, padding);
    try button.close(context);
    try tip.close(context);
}

/// Where the settings put a chip, by the thumbnails' own rule with the offsets scaled.
fn settledPosition(look: chips.Look, chip_size: [2]f32, stage_size: [2]f32, scale: f32) [2]f32 {
    const offset = [2]f32{ @as(f32, @floatFromInt(look.offset_x)) * scale, @as(f32, @floatFromInt(look.offset_y)) * scale };
    return draw.placedOrigin(f32, look.position, chip_size, stage_size, offset);
}

/// Snapped flush to the nearest anchor when close, and held within the offset range.
fn dragTarget(mouse: [2]f64, grab: [2]f32, stage_box: Box, chip_size: [2]f32, stage_size: [2]f32, scale: f32, range: [2]f32) [2]f32 {
    const max = [2]f32{ @max(0, stage_size[0] - chip_size[0]), @max(0, stage_size[1] - chip_size[1]) };
    var raw_position = [2]f32{
        std.math.clamp(@as(f32, @floatCast(mouse[0])) - stage_box.x() - grab[0], 0, max[0]),
        std.math.clamp(@as(f32, @floatCast(mouse[1])) - stage_box.y() - grab[1], 0, max[1]),
    };
    const anchor = draw.anchorOrigin(f32, zoneFor(raw_position, chip_size, stage_size), chip_size, stage_size);
    if (std.math.hypot(raw_position[0] - anchor[0], raw_position[1] - anchor[1]) < SNAP_DISTANCE) raw_position = anchor;
    return .{
        std.math.clamp(raw_position[0], @max(0, anchor[0] + range[0] * scale), @min(max[0], anchor[0] + range[1] * scale)),
        std.math.clamp(raw_position[1], @max(0, anchor[1] + range[0] * scale), @min(max[1], anchor[1] + range[1] * scale)),
    };
}

/// The anchor is the third the chip's centre lands in; offsets are the rest, in real pixels.
fn dropResult(position: [2]f32, chip_size: [2]f32, stage_size: [2]f32, scale: f32, range: [2]f32) Drop {
    const zone = zoneFor(position, chip_size, stage_size);
    const anchor = draw.anchorOrigin(f32, zone, chip_size, stage_size);
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
fn focusedBorder(context: *ui.Frame, profile: *const config.Config, stage_size: [2]f32) !void {
    const thumbnail = &profile.thumbnail;
    if (!thumbnail.showBorderWhenFocused) return;
    const border_color = profile.focusedBorderColor();
    const width: usize = @intCast(@max(thumbnail.width, 1));
    const height: usize = @intCast(@max(thumbnail.height, 1));
    // drawBorder needs room for both sides.
    const border_width = @min(thumbnail.borderWidth, @min(width, height) / 2);
    const pixels = try context.arena().alloc(u32, width * height);
    @memset(pixels, 0);
    draw.drawBorder(.{ .pixels = pixels.ptr, .width = width, .height = height }, border_width, border_color, thumbnail.borderStyle);

    const look = extern struct { width: u32, height: u32, border_width: u32, color: u32, style: u32 }{
        .width = @intCast(width),
        .height = @intCast(height),
        .border_width = @intCast(border_width),
        .color = border_color,
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

fn scaleAlpha(argb: u32, alpha: f32) ui.Color {
    const base = @as(f32, @floatFromInt(argb >> 24)) / 255.0;
    const combined: u32 = @intFromFloat(@round(base * alpha * 255.0));
    return color_convert.fromArgb((argb & 0x00FFFFFF) | (combined << 24));
}

comptime {
    // zoneFor relies on TextPosition's reading order.
    std.debug.assert(@backingInt(types.TextPosition.TopLeft) == 0);
    std.debug.assert(@backingInt(types.TextPosition.Center) == 4);
    std.debug.assert(@backingInt(types.TextPosition.BottomRight) == 8);
}
