//! A screen preview: every monitor in miniature, numbered and sized, with the caller's boxes drawn over them; main thread only.
const std = @import("std");
const ui = @import("ui");
const win32 = @import("../../platform/win32.zig");
const monitors = @import("../../layout/monitors.zig");
const screen_math = @import("screen_math.zig");
const style = @import("style.zig");
const glyphs = @import("glyphs.zig");
const widgets = @import("widgets.zig");
const lang = @import("../../lang/lang.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Canvas = ui.component.Canvas;
const DrawCmd = Canvas.DrawCmd;
const Box = screen_math.Box;

const MAX_WIDTH = 560;
const MAX_HEIGHT = 120;
const MAX_MONITORS = 16;
const SAVED_POSITION_FILL_ALPHA = 0.25;
/// Kept between a monitor's details and its box's sides, so a detail that won't fit is left out rather than touching them.
const DETAIL_MARGIN = 4;
/// The number's line, gap included.
const NUMBER_LINE_HEIGHT = 16;
/// A detail's line, gap included.
const DETAIL_LINE_HEIGHT = 13;

/// Built and shown within one frame; its slices live in the frame arena, so there's nothing to free.
pub const ScreenMap = struct {
    key: ui.Key,
    frame: screen_math.Frame,
    /// How far to shift drawing onto whole device pixels.
    snap: [2]f32,
    commands: std.ArrayList(DrawCmd) = .empty,
    /// Each monitor's box, primary first; borrows from the frame arena.
    screen_boxes: []const Box,
    /// Each monitor's size in desktop pixels, in screen_boxes' order; borrows from the frame arena.
    screen_sizes: []const [2]i32,

    /// Draws the monitors, shrunk to fit their section; boxes added afterwards go over them.
    pub fn init(context: *ui.Frame, key: ui.Key) !ScreenMap {
        const arena = context.arena();
        const desktop = win32.virtualScreenRect();
        var map: ScreenMap = .{
            .key = key,
            .frame = .fit(desktop, try availableWidth(context, key), MAX_HEIGHT),
            .snap = try glyphs.snapOffset(context, key),
            .screen_boxes = &.{},
            .screen_sizes = &.{},
        };
        var monitor_buffer: [MAX_MONITORS]win32.RECT = undefined;
        var screens = monitors.monitorRects(&monitor_buffer);
        if (screens.len == 0) {
            monitor_buffer[0] = desktop;
            screens = monitor_buffer[0..1];
        }
        const screen_boxes = try arena.alloc(Box, screens.len);
        const screen_sizes = try arena.alloc([2]i32, screens.len);
        for (screens, screen_boxes, screen_sizes) |screen, *screen_box, *size| {
            screen_box.* = map.frame.box(screen);
            size.* = .{ win32.rectWidth(screen), win32.rectHeight(screen) };
            try map.addBox(arena, screen_box.*, style.BG.value, style.BORDER.value);
        }
        map.screen_boxes = screen_boxes;
        map.screen_sizes = screen_sizes;
        return map;
    }

    /// `box` is unsnapped, as screen_math.Frame gives it.
    pub fn addBox(self: *ScreenMap, arena: std.mem.Allocator, box: Box, fill_color: [4]f32, line_color: [4]f32) !void {
        const x = box[0] + self.snap[0];
        const y = box[1] + self.snap[1];
        const width = box[2];
        const height = box[3];
        try self.commands.append(arena, .{ .fill_rect = .{ .x = x, .y = y, .w = width, .h = height, .color = fill_color } });
        try self.commands.append(arena, .{ .fill_rect = .{ .x = x, .y = y, .w = width, .h = 1, .color = line_color } });
        try self.commands.append(arena, .{ .fill_rect = .{ .x = x, .y = y + height - 1, .w = width, .h = 1, .color = line_color } });
        try self.commands.append(arena, .{ .fill_rect = .{ .x = x, .y = y + 1, .w = 1, .h = height - 2, .color = line_color } });
        try self.commands.append(arena, .{ .fill_rect = .{ .x = x + width - 1, .y = y + 1, .w = 1, .h = height - 2, .color = line_color } });
    }

    /// A saved position, outlined and faintly filled in the accent, alike on every tab that shows one.
    pub fn addSavedPosition(self: *ScreenMap, context: *ui.Frame, box: Box) !void {
        const line_color = context.ui().theme.primary.value;
        var fill_color = line_color;
        fill_color[3] = SAVED_POSITION_FILL_ALPHA;
        try self.addBox(context.arena(), box, fill_color, line_color);
    }

    /// The mouse on the preview while it's over it, else null; measured last frame.
    pub fn mousePoint(self: *const ScreenMap, ui_state: *ui.UI) ?[2]f32 {
        if (!ui_state.isHoveredWithin(self.key.hash())) return null;
        const measured = ui_state.state.get(.measured, self.key.hash()) orelse return null;
        const mouse = ui_state.input.mouse_pos;
        return .{ @as(f32, @floatCast(mouse[0])) - measured.box.x(), @as(f32, @floatCast(mouse[1])) - measured.box.y() };
    }

    /// Centred in its section; `is_interactive` lets the caller read clicks on `key`.
    pub fn show(self: *const ScreenMap, context: *ui.Frame, is_interactive: bool) !void {
        const arena = context.arena();
        const map_style = try arena.create(ui.Style);
        map_style.* = .{ .width = .fixed(self.frame.width), .height = .fixed(self.frame.height) };
        const centered = Rect{ .key = self.key.indexed(1), .style = &style.screen_map_row };
        _ = try centered.open(context);
        const canvas = Canvas{ .key = self.key, .commands = self.commands.items, .style = map_style, .interactive = is_interactive };
        _ = try canvas.open(context);
        const label_base = self.key.indexed(2);
        for (self.screen_boxes, 0..) |box, screen_index| {
            const label_style = try arena.create(ui.Style);
            label_style.* = style.monitor_label.with(.{ .offset = .{ box[0], box[1] }, .width = .fixed(box[2]), .height = .fixed(box[3]) });
            const label = Rect{ .key = label_base.indexed(screen_index), .style = label_style };
            _ = try label.open(context);
            try context.e(Text{
                .selectable = false,
                .key = label_base.indexed(screen_index).indexed(1),
                .content = try arena.print("{d}", .{screen_index + 1}),
                .style = &style.monitor_label_text,
            });
            const size = self.screen_sizes[screen_index];
            var room = box[3] - NUMBER_LINE_HEIGHT;
            const size_text = try arena.print("{d}\u{00D7}{d}", .{ size[0], size[1] });
            if (try detail(context, label_base.indexed(screen_index).indexed(2), size_text, box, &room)) {
                if (screen_index == 0 and self.screen_boxes.len > 1) _ = try detail(context, label_base.indexed(screen_index).indexed(3), lang.text("Primary"), box, &room);
            }
            try label.close(context);
        }
        try canvas.close(context);
        try centered.close(context);
    }

    /// Draws `text` under the number if it fits `box` and the `room` left below, so a small box shows only what fits; returns whether it did.
    fn detail(context: *ui.Frame, key: ui.Key, text: []const u8, box: Box, room: *f32) !bool {
        if (room.* < DETAIL_LINE_HEIGHT) return false;
        if (try widgets.textWidth(context, text, &style.monitor_detail_text) > box[2] - 2 * DETAIL_MARGIN) return false;
        room.* -= DETAIL_LINE_HEIGHT;
        try context.e(Text{ .selectable = false, .key = key, .content = text, .style = &style.monitor_detail_text });
        return true;
    }

    /// Its row's width, measured last frame, up to MAX_WIDTH; MAX_WIDTH until the row has been laid out once.
    fn availableWidth(context: *ui.Frame, key: ui.Key) !f32 {
        const ui_state = context.ui();
        const row_key = key.indexed(1);
        const measured = try ui_state.state.getOrCreate(.measured, ui_state.allocator, row_key.hash());
        if (measured.box.w() > 0) return @min(measured.box.w(), MAX_WIDTH);
        context.requestRedraw();
        return MAX_WIDTH;
    }
};
