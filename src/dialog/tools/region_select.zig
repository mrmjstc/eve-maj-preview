//! The full-screen overlay for dragging out, or adjusting, a screen region for the config dialog.
const std = @import("std");
const ui = @import("ui");
const win32 = @import("../../platform/win32.zig");
const gdi_overlay = @import("../../platform/gdi_overlay.zig");
const fonts = @import("../../platform/fonts.zig");
const vk = @import("../../platform/virtual_keys.zig");
const color = @import("../../util/color.zig");
const region_math = @import("region_math.zig");
const pixel_buffer = @import("../../util/pixel_buffer.zig");
const style = @import("../knots/style.zig");
const color_convert = @import("../knots/color_convert.zig");
const log = @import("../../log.zig");

const slog = log.Scoped("region_select");

const WINDOW_CLASS_NAME = "EVE_REGION_SELECT_CLASS";
const REDRAW_THROTTLE_MS: u64 = 16;
const BORDER_THICKNESS: usize = 1;
/// Below this, a drag is treated as an accidental click.
const MIN_DRAG_PX: i32 = 10;

const DIM_COLOR: u32 = 0x60000000;
const CLEAR_COLOR: u32 = 0x00000000;
const DEFAULT_BORDER_COLOR: u32 = 0xFF3399FF;
/// Alpha 0 would make the interior click-through, so a click inside a cut-out region would hit the window below.
const HIT_TESTABLE_CLEAR_COLOR: u32 = 0x01000000;
/// Other regions show through the dim a little, outlined in dashes, so a new one can be drawn beside them.
const OTHER_REGION_FILL: u32 = 0x38000000;
const OTHER_REGION_BORDER: u32 = 0xC0FFFFFF;
const OTHER_REGION_DASH: usize = 6;
/// Regions past this aren't shown.
pub const MAX_OTHER_REGIONS = 32;
const HANDLE_HIT_PX: u32 = 6;
const HANDLE_SIZE: i32 = 8;
const HANDLE_COLOR: u32 = 0xFFFFFFFF;
const LABEL_PADDING_X: usize = 10;
const LABEL_PADDING_Y: usize = 4;
const LABEL_CURSOR_OFFSET: i32 = 16;
/// Enough for any monitor's width or height.
const MAX_FIELD_DIGITS = 5;
pub const BUTTON_LABEL_SIZE = 32;
pub const HINT_SIZE = 192;
/// A size field's short name before its number, e.g. "W".
pub const FIELD_PREFIX_SIZE = 16;

// Save/Cancel and the size fields draw like the dialog's primary_button, outline_button and text_input: sizes are dialog px scaled by monitor DPI.
const BUTTON_WIDTH: i32 = 80;
const BUTTON_HEIGHT: i32 = 28;
const BUTTON_GAP: i32 = 8;
const BUTTON_CHAR_WIDTH: i32 = 8;
const BUTTON_TEXT_PADDING: i32 = 12;
const BUTTON_MARGIN: i32 = 8;
/// The dialog theme's radius, which its buttons and boxes use.
const BUTTON_RADIUS: i32 = 6;
const TEXT_FONT_PX: i32 = 12;
/// The config dialog's face, first loaded wins; Segoe UI only if the bundled one failed to load.
const TEXT_FONTS = [_]FontChoice{
    .{ .name = fonts.UI_FACE, .weight = win32.FW_NORMAL },
    .{ .name = "Segoe UI", .weight = win32.FW_NORMAL },
};
/// Save's face, like the dialog's primary buttons; Geist SemiBold is its own face, since GDI won't embolden a variable font.
const STRONG_FONTS = [_]FontChoice{
    .{ .name = fonts.UI_SEMIBOLD_FACE, .weight = win32.FW_NORMAL },
    .{ .name = "Segoe UI", .weight = win32.FW_SEMIBOLD },
};
/// Matches the dialog's accented colour, which form.zig makes 15% toward white.
const BUTTON_LIGHTEN_PERCENT = 15;
const EMPTY_RECT: win32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

const FontChoice = struct { name: [:0]const u8, weight: c_int };

const Handle = enum { none, move, left, right, top, bottom, top_left, top_right, bottom_left, bottom_right };
const Outline = enum { solid, dashed };
const Button = enum { save, cancel };
const Field = enum { width, height };

/// The size fields sit in a row above Save/Cancel, each the width of the button below it.
const Controls = struct {
    fields: [2]win32.RECT,
    buttons: [2]win32.RECT,
};

pub const Labels = struct {
    save: [BUTTON_LABEL_SIZE]u8 = fixedText(BUTTON_LABEL_SIZE, "Save"),
    cancel: [BUTTON_LABEL_SIZE]u8 = fixedText(BUTTON_LABEL_SIZE, "Cancel"),
    hint_new: [HINT_SIZE]u8 = fixedText(HINT_SIZE, "Drag to draw the region, then drag its edges to adjust"),
    hint_edit: [HINT_SIZE]u8 = fixedText(HINT_SIZE, "Drag the edges to resize, or the inside to move"),
    hint_confirm: [HINT_SIZE]u8 = fixedText(HINT_SIZE, "Enter or Save to confirm, Esc or right-click to cancel"),
    width_prefix: [FIELD_PREFIX_SIZE]u8 = fixedText(FIELD_PREFIX_SIZE, "W"),
    height_prefix: [FIELD_PREFIX_SIZE]u8 = fixedText(FIELD_PREFIX_SIZE, "H"),
};

pub const Status = enum { success, cancelled, too_small };

/// What a selection shows and starts from.
pub const StartOptions = struct {
    /// The region's outline and Save's colour.
    accent_color: u32,
    /// The size label's text.
    label_color: u32,
    /// The region to adjust; null drags out a new one.
    edit_region: ?win32.RECT,
    /// Copied; shown dashed, and snapped to.
    other_regions: []const win32.RECT,
    labels: Labels,
};

/// One selection's state, replaced whole by `start` so nothing carries over from the last one.
const Session = struct {
    on_finished: ?*const fn () void = null,
    on_result: ?*const fn (Status, win32.RECT) void = null,
    border_color: u32 = DEFAULT_BORDER_COLOR,
    label_color: u32 = 0xFFFFFFFF,
    labels: Labels = .{},
    other_regions: [MAX_OTHER_REGIONS]win32.RECT = undefined,
    other_region_count: usize = 0,
    virtual_screen: win32.RECT = EMPTY_RECT,
    /// The one monitor a selection is confined to, so it can't spill into the gap between monitors of different sizes.
    bounds: win32.RECT = EMPTY_RECT,
    ui_scale: f32 = 1.0,
    last_redraw: win32.Ticks = .{},

    is_dragging: bool = false,
    anchor: win32.POINT = .{ .x = 0, .y = 0 },
    current: win32.POINT = .{ .x = 0, .y = 0 },

    is_edit_mode: bool = false,
    edit_rect: win32.RECT = EMPTY_RECT,
    edit_handle: Handle = .none,
    edit_grab: win32.POINT = .{ .x = 0, .y = 0 },
    edit_grab_rect: win32.RECT = EMPTY_RECT,
    hovered_button: ?Button = null,
    pressed_button: ?Button = null,

    field_focus: ?Field = null,
    field_digits: [MAX_FIELD_DIGITS]u8 = undefined,
    field_digit_count: usize = 0,
    /// The focused field still shows the region's size, which the first digit typed replaces.
    is_field_untouched: bool = false,
};

/// The overlay and what it keeps between selections; its window finds it through GWLP_USERDATA, so it must stay put once started.
pub const Overlay = struct {
    session: Session = .{},
    is_window_class_registered: bool = false,
    /// Created on first use, then kept hidden between selections for the rest of the run.
    hwnd: ?win32.HWND = null,
    bitmap: ?gdi_overlay.OverlayBitmap = null,
    /// Like hwnd, kept hidden between selections.
    hint_box: gdi_overlay.HintBox = .{},
    cross_cursor: ?win32.HCURSOR = null,
    text_font_px: i32 = 0,
    /// Every text on the overlay but Save's, recreated when the scale changes; owned, kept for the rest of the run.
    text_font: ?win32.HFONT = null,
    /// Save's text, alongside text_font; owned, kept for the rest of the run.
    strong_font: ?win32.HFONT = null,
    hand_cursor: ?win32.HCURSOR = null,
    arrow_cursor: ?win32.HCURSOR = null,
    size_we_cursor: ?win32.HCURSOR = null,
    size_ns_cursor: ?win32.HCURSOR = null,
    size_nwse_cursor: ?win32.HCURSOR = null,
    size_nesw_cursor: ?win32.HCURSOR = null,
    size_all_cursor: ?win32.HCURSOR = null,
    ibeam_cursor: ?win32.HCURSOR = null,

    /// Starts or restarts the overlay; `on_finished` then `on_result` run as it closes, neither if this fails.
    pub fn start(self: *Overlay, instance: win32.HINSTANCE, options: StartOptions, on_finished: *const fn () void, on_result: *const fn (Status, win32.RECT) void) !void {
        try self.registerWindowClass(instance);
        const virtual_screen = win32.virtualScreenRect();
        const other_region_count = @min(options.other_regions.len, MAX_OTHER_REGIONS);
        self.session = .{
            .on_finished = on_finished,
            .on_result = on_result,
            .border_color = color.withAlpha(options.accent_color, 0xFF),
            .label_color = options.label_color,
            .labels = options.labels,
            .other_region_count = other_region_count,
            .virtual_screen = virtual_screen,
            .bounds = virtual_screen,
            // Sizes the text for the monitor the cursor is on until a region picks one.
            .ui_scale = if (cursorPos()) |point| dpiScaleAt(point) else 1.0,
        };
        @memcpy(self.session.other_regions[0..other_region_count], options.other_regions[0..other_region_count]);

        const left = virtual_screen.left;
        const top = virtual_screen.top;
        const width = win32.rectWidth(virtual_screen);
        const height = win32.rectHeight(virtual_screen);

        // A region that's mostly off the current screens clamps to nothing usable, so fall back to a fresh drag.
        if (options.edit_region) |region| {
            self.session.bounds = self.monitorBoundsAt(win32.rectCenter(win32.clampRect(region, self.session.virtual_screen)));
            const clamped = win32.clampRect(region, self.session.bounds);
            if (isBigEnough(clamped)) self.enterEditMode(clamped);
        }

        if (self.hwnd) |hwnd| {
            _ = win32.SetWindowPos(hwnd, win32.HWND_TOPMOST, left, top, width, height, win32.SWP_NOACTIVATE);
        } else {
            const created = win32.CreateWindowExA(
                win32.WS_EX_LAYERED | win32.WS_EX_TOPMOST | win32.WS_EX_TOOLWINDOW,
                WINDOW_CLASS_NAME,
                "",
                win32.WS_POPUP,
                left,
                top,
                width,
                height,
                null,
                null,
                instance,
                null,
            ) orelse return error.CreateWindowFailed;
            errdefer _ = win32.DestroyWindow(created);
            // A previous 0 and a failure look alike but for the last error.
            win32.SetLastError(0);
            if (win32.SetWindowLongPtrA(created, win32.GWLP_USERDATA, @bitCast(@intFromPtr(self))) == 0 and win32.GetLastError() != 0) return error.SetWindowLongPtrFailed;
            // Kept only once it can find this Overlay, so a window that would ignore input isn't reused.
            self.hwnd = created;
        }

        const hwnd = self.hwnd.?;
        self.ensureBitmap(width, height);
        self.session.last_redraw = win32.Ticks.now();
        self.redraw();

        _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
        grabForegroundFocus(hwnd);
        self.showHint(instance);
    }

    /// Shown after the overlay takes focus, so it sits above it.
    fn showHint(self: *Overlay, instance: win32.HINSTANCE) void {
        const font = self.text_font orelse return;
        const bounds = if (cursorPos()) |point| self.monitorBoundsAt(point) else self.session.virtual_screen;
        const line1 = labelText(if (self.session.is_edit_mode) &self.session.labels.hint_edit else &self.session.labels.hint_new);
        self.hint_box.show(instance, font, self.session.label_color, line1, labelText(&self.session.labels.hint_confirm), bounds);
    }

    fn registerWindowClass(self: *Overlay, instance: win32.HINSTANCE) !void {
        if (self.is_window_class_registered) return;
        self.cross_cursor = loadSystemCursor(win32.IDC_CROSS, "crosshair");
        self.arrow_cursor = loadSystemCursor(win32.IDC_ARROW, "arrow");
        self.size_we_cursor = loadSystemCursor(win32.IDC_SIZEWE, "left-right resize");
        self.size_ns_cursor = loadSystemCursor(win32.IDC_SIZENS, "up-down resize");
        self.size_nwse_cursor = loadSystemCursor(win32.IDC_SIZENWSE, "diagonal resize");
        self.size_nesw_cursor = loadSystemCursor(win32.IDC_SIZENESW, "diagonal resize");
        self.size_all_cursor = loadSystemCursor(win32.IDC_SIZEALL, "move");
        self.hand_cursor = loadSystemCursor(win32.IDC_HAND, "hand");
        self.ibeam_cursor = loadSystemCursor(win32.IDC_IBEAM, "text");
        try gdi_overlay.registerWindowClass(instance, wndProc, WINDOW_CLASS_NAME, null);
        self.is_window_class_registered = true;
    }

    fn ensureBitmap(self: *Overlay, width: i32, height: i32) void {
        _ = gdi_overlay.OverlayBitmap.ensureSize(&self.bitmap, width, height) catch |err| {
            slog.err("Failed to allocate region-select overlay bitmap: {}", .{err});
            return;
        };
    }

    fn normalizedSelection(self: *const Overlay) win32.RECT {
        return win32.clampRect(.{
            .left = @min(self.session.anchor.x, self.session.current.x),
            .top = @min(self.session.anchor.y, self.session.current.y),
            .right = @max(self.session.anchor.x, self.session.current.x),
            .bottom = @max(self.session.anchor.y, self.session.current.y),
        }, self.session.bounds);
    }

    /// Cuts `rect` out of the dim layer, fills it with `fill` and outlines it, clipped to the overlay since fillRect skips a rect that runs past the buffer.
    fn drawRegion(self: *const Overlay, bitmap: *const gdi_overlay.OverlayBitmap, rect: win32.RECT, fill: u32, border: u32, outline: Outline) void {
        const visible = win32.clampRect(rect, self.session.virtual_screen);
        const signed_width = win32.rectWidth(visible);
        const signed_height = win32.rectHeight(visible);
        if (signed_width <= 0 or signed_height <= 0) return;
        const local_x = visible.left - self.session.virtual_screen.left;
        const local_y = visible.top - self.session.virtual_screen.top;
        const width: usize = @intCast(signed_width);
        const height: usize = @intCast(signed_height);
        pixel_buffer.fillRect(bitmap.canvas(), @intCast(local_x), @intCast(local_y), width, height, fill);
        switch (outline) {
            .solid => pixel_buffer.drawRectOutline(bitmap.canvas(), local_x, local_y, width, height, BORDER_THICKNESS, border),
            .dashed => pixel_buffer.drawDashedRectOutline(bitmap.canvas(), local_x, local_y, width, height, BORDER_THICKNESS, OTHER_REGION_DASH, border),
        }
    }

    fn monitorBoundsAt(self: *const Overlay, point: win32.POINT) win32.RECT {
        const monitor = win32.nearestMonitor(point) orelse return self.session.virtual_screen;
        return win32.monitorRect(monitor) orelse self.session.virtual_screen;
    }

    /// Switches to adjusting `rect` (edges, handles, Save/Cancel); used for Edit Region and once a fresh drag is released.
    fn enterEditMode(self: *Overlay, rect: win32.RECT) void {
        self.session.edit_rect = rect;
        self.session.is_edit_mode = true;
        self.session.edit_handle = .none;
        self.session.hovered_button = null;
        self.session.pressed_button = null;
        self.session.ui_scale = dpiScaleAt(win32.rectCenter(rect));
    }

    fn drawSizeLabel(self: *const Overlay, bitmap: *const gdi_overlay.OverlayBitmap, selection: win32.RECT) void {
        const font = self.text_font orelse return;

        var text_buf: [32]u8 = undefined;
        const text = std.mem.print(&text_buf, "{d} x {d}", .{ win32.rectWidth(selection), win32.rectHeight(selection) }) catch unreachable;

        const old_font = win32.SelectObject(bitmap.mem_dc, font);
        defer {
            if (old_font) |previous_font| _ = win32.SelectObject(bitmap.mem_dc, previous_font);
        }

        const text_size = gdi_overlay.measureTextSize(text_buf.len, bitmap.mem_dc, text);
        const label_width: i32 = text_size.cx + @as(i32, LABEL_PADDING_X * 2);
        const label_height: i32 = text_size.cy + @as(i32, LABEL_PADDING_Y * 2);

        const bounds = self.monitorBoundsAt(self.session.current);
        const bounds_center = win32.rectCenter(bounds);
        const is_in_right_half = self.session.current.x >= bounds_center.x;
        const is_in_bottom_half = self.session.current.y >= bounds_center.y;
        var x = if (is_in_right_half) self.session.current.x - LABEL_CURSOR_OFFSET - label_width else self.session.current.x + LABEL_CURSOR_OFFSET;
        var y = if (is_in_bottom_half) self.session.current.y - LABEL_CURSOR_OFFSET - label_height else self.session.current.y + LABEL_CURSOR_OFFSET;
        x = @max(bounds.left, @min(x, bounds.right - label_width));
        y = @max(bounds.top, @min(y, bounds.bottom - label_height));

        const local_x: usize = @intCast(x - self.session.virtual_screen.left);
        const local_y: usize = @intCast(y - self.session.virtual_screen.top);
        pixel_buffer.fillRect(bitmap.canvas(), local_x, local_y, @intCast(label_width), @intCast(label_height), gdi_overlay.HINT_BACKGROUND_COLOR);
        gdi_overlay.drawText(text_buf.len, bitmap.mem_dc, @intCast(local_x + LABEL_PADDING_X), @intCast(local_y + LABEL_PADDING_Y), text, self.session.label_color);
    }

    fn hitTestEditRect(self: *const Overlay, point: win32.POINT) Handle {
        const rect = self.session.edit_rect;
        const slop: i32 = @intCast(HANDLE_HIT_PX);
        if (point.x < rect.left - slop or point.x > rect.right + slop or point.y < rect.top - slop or point.y > rect.bottom + slop) return .none;

        const distance_left = @abs(point.x - rect.left);
        const distance_right = @abs(point.x - rect.right);
        const distance_top = @abs(point.y - rect.top);
        const distance_bottom = @abs(point.y - rect.bottom);
        const is_near_left = distance_left <= HANDLE_HIT_PX and distance_left <= distance_right;
        const is_near_right = distance_right <= HANDLE_HIT_PX and distance_right < distance_left;
        const is_near_top = distance_top <= HANDLE_HIT_PX and distance_top <= distance_bottom;
        const is_near_bottom = distance_bottom <= HANDLE_HIT_PX and distance_bottom < distance_top;

        if (is_near_top and is_near_left) return .top_left;
        if (is_near_top and is_near_right) return .top_right;
        if (is_near_bottom and is_near_left) return .bottom_left;
        if (is_near_bottom and is_near_right) return .bottom_right;
        if (is_near_left) return .left;
        if (is_near_right) return .right;
        if (is_near_top) return .top;
        if (is_near_bottom) return .bottom;
        return .move;
    }

    fn cursorForHandle(self: *const Overlay, handle: Handle) ?win32.HCURSOR {
        return switch (handle) {
            .none => self.arrow_cursor,
            .move => self.size_all_cursor,
            .left, .right => self.size_we_cursor,
            .top, .bottom => self.size_ns_cursor,
            .top_left, .bottom_right => self.size_nwse_cursor,
            .top_right, .bottom_left => self.size_nesw_cursor,
        };
    }

    fn applyEditDrag(self: *Overlay, point: win32.POINT) void {
        const delta_x = point.x - self.session.edit_grab.x;
        const delta_y = point.y - self.session.edit_grab.y;
        const bounds = self.session.bounds;
        var rect = self.session.edit_grab_rect;

        if (self.session.edit_handle == .move) {
            const width = win32.rectWidth(rect);
            const height = win32.rectHeight(rect);
            var left = rect.left + delta_x;
            var top = rect.top + delta_y;
            left += region_math.snapSpanOffset(left, left + width, .x, self.otherRegions(), bounds, region_math.SNAP_DISTANCE_PX);
            top += region_math.snapSpanOffset(top, top + height, .y, self.otherRegions(), bounds, region_math.SNAP_DISTANCE_PX);
            rect.left = std.math.clamp(left, bounds.left, bounds.right - width);
            rect.top = std.math.clamp(top, bounds.top, bounds.bottom - height);
            rect.right = rect.left + width;
            rect.bottom = rect.top + height;
        } else {
            const moves_left = self.session.edit_handle == .left or self.session.edit_handle == .top_left or self.session.edit_handle == .bottom_left;
            const moves_right = self.session.edit_handle == .right or self.session.edit_handle == .top_right or self.session.edit_handle == .bottom_right;
            const moves_top = self.session.edit_handle == .top or self.session.edit_handle == .top_left or self.session.edit_handle == .top_right;
            const moves_bottom = self.session.edit_handle == .bottom or self.session.edit_handle == .bottom_left or self.session.edit_handle == .bottom_right;
            if (moves_left) rect.left = std.math.clamp(self.snapEdge(rect.left + delta_x, .x), bounds.left, rect.right - MIN_DRAG_PX);
            if (moves_right) rect.right = std.math.clamp(self.snapEdge(rect.right + delta_x, .x), rect.left + MIN_DRAG_PX, bounds.right);
            if (moves_top) rect.top = std.math.clamp(self.snapEdge(rect.top + delta_y, .y), bounds.top, rect.bottom - MIN_DRAG_PX);
            if (moves_bottom) rect.bottom = std.math.clamp(self.snapEdge(rect.bottom + delta_y, .y), rect.top + MIN_DRAG_PX, bounds.bottom);
        }
        self.session.edit_rect = rect;
    }

    fn otherRegions(self: *const Overlay) []const win32.RECT {
        return self.session.other_regions[0..self.session.other_region_count];
    }

    fn snapEdge(self: *const Overlay, value: i32, axis: region_math.Axis) i32 {
        return region_math.snapEdge(value, axis, self.otherRegions(), self.session.bounds, region_math.SNAP_DISTANCE_PX);
    }

    fn snapPoint(self: *const Overlay, point: win32.POINT) win32.POINT {
        return .{ .x = self.snapEdge(point.x, .x), .y = self.snapEdge(point.y, .y) };
    }

    fn drawHandle(self: *const Overlay, bitmap: *const gdi_overlay.OverlayBitmap, center_x: i32, center_y: i32) void {
        const x = std.math.clamp(center_x - @divTrunc(HANDLE_SIZE, 2), self.session.bounds.left, self.session.bounds.right - HANDLE_SIZE);
        const y = std.math.clamp(center_y - @divTrunc(HANDLE_SIZE, 2), self.session.bounds.top, self.session.bounds.bottom - HANDLE_SIZE);
        const size: usize = @intCast(HANDLE_SIZE);
        pixel_buffer.fillRect(bitmap.canvas(), @intCast(x - self.session.virtual_screen.left), @intCast(y - self.session.virtual_screen.top), size, size, HANDLE_COLOR);
    }

    fn drawEditHandles(self: *const Overlay, bitmap: *const gdi_overlay.OverlayBitmap, rect: win32.RECT) void {
        const center = win32.rectCenter(rect);
        const column_x = [3]i32{ rect.left, center.x, rect.right };
        const row_y = [3]i32{ rect.top, center.y, rect.bottom };
        const is_wide_enough = win32.rectWidth(rect) >= HANDLE_SIZE * 4;
        const is_tall_enough = win32.rectHeight(rect) >= HANDLE_SIZE * 4;

        for (row_y, 0..) |y, row| {
            for (column_x, 0..) |x, column| {
                if (row == 1 and column == 1) continue;
                if (column == 1 and !is_wide_enough) continue;
                if (row == 1 and !is_tall_enough) continue;
                self.drawHandle(bitmap, x, y);
            }
        }
    }

    fn scaled(self: *const Overlay, css_px: i32) i32 {
        return win32.scalePixels(css_px, self.session.ui_scale);
    }

    /// Estimated wide enough for the longer translated label, CJK glyphs counting double, since hit testing lays out without a DC to measure with.
    fn buttonWidthCss(self: *Overlay) i32 {
        var widest: i32 = 0;
        for ([_][]const u8{ labelText(&self.session.labels.save), labelText(&self.session.labels.cancel) }) |label| {
            var units: i32 = 0;
            for (label) |byte| {
                if ((byte & 0xC0) == 0x80) continue;
                units += if (byte >= 0xE0) 2 else 1;
            }
            widest = @max(widest, units);
        }
        return @max(BUTTON_WIDTH, widest * BUTTON_CHAR_WIDTH + 2 * BUTTON_TEXT_PADDING);
    }

    /// Width/Height over Save/Cancel, right-aligned under the region; flips above it, or inside its bottom edge, when there's no room below.
    fn controlRects(self: *Overlay, region: win32.RECT) Controls {
        const width = self.scaled(self.buttonWidthCss());
        const height = self.scaled(BUTTON_HEIGHT);
        const gap = self.scaled(BUTTON_GAP);
        const margin = self.scaled(BUTTON_MARGIN);
        const group_width = width * 2 + gap;
        const group_height = height * 2 + gap;

        const x = @max(self.session.bounds.left + margin, @min(region.right - margin - group_width, self.session.bounds.right - margin - group_width));
        var y = region.bottom + margin;
        if (y + group_height > self.session.bounds.bottom) y = region.top - margin - group_height;
        if (y < self.session.bounds.top) y = @max(self.session.bounds.top, region.bottom - margin - group_height);
        const button_y = y + height + gap;

        return .{
            .fields = .{
                .{ .left = x, .top = y, .right = x + width, .bottom = y + height },
                .{ .left = x + width + gap, .top = y, .right = x + group_width, .bottom = y + height },
            },
            .buttons = .{
                .{ .left = x, .top = button_y, .right = x + width, .bottom = button_y + height },
                .{ .left = x + width + gap, .top = button_y, .right = x + group_width, .bottom = button_y + height },
            },
        };
    }

    fn buttonAt(self: *Overlay, point: win32.POINT) ?Button {
        if (!self.session.is_edit_mode or self.session.edit_handle != .none) return null;
        const rects = self.controlRects(self.session.edit_rect).buttons;
        inline for (.{ Button.save, Button.cancel }) |button| {
            if (win32.rectContains(rects[@backingInt(button)], point)) return button;
        }
        return null;
    }

    fn fieldAt(self: *Overlay, point: win32.POINT) ?Field {
        if (!self.session.is_edit_mode or self.session.edit_handle != .none) return null;
        const rects = self.controlRects(self.session.edit_rect).fields;
        inline for (.{ Field.width, Field.height }) |field| {
            if (win32.rectContains(rects[@backingInt(field)], point)) return field;
        }
        return null;
    }

    fn focusField(self: *Overlay, field: Field) void {
        self.commitField();
        self.session.field_focus = field;
        self.session.is_field_untouched = true;
        self.session.field_digit_count = 0;
    }

    /// Applies what was typed into the focused field, if anything, and unfocuses it.
    fn commitField(self: *Overlay) void {
        const field = self.session.field_focus orelse return;
        self.session.field_focus = null;
        if (self.session.is_field_untouched or self.session.field_digit_count == 0) return;
        // Only ever digits, too few to overflow.
        const length = std.fmt.parseInt(i32, self.session.field_digits[0..self.session.field_digit_count], 10) catch unreachable;
        const axis: region_math.Axis = switch (field) {
            .width => .x,
            .height => .y,
        };
        self.session.edit_rect = region_math.withLength(self.session.edit_rect, axis, length, self.session.bounds, MIN_DRAG_PX);
    }

    /// Whether `key` went to the focused field.
    fn handleFieldKey(self: *Overlay, key: win32.WPARAM) bool {
        const field = self.session.field_focus orelse return false;
        switch (key) {
            '0'...'9', vk.VK_NUMPAD0...vk.VK_NUMPAD0 + 9 => {
                if (self.session.is_field_untouched) self.session.field_digit_count = 0;
                self.session.is_field_untouched = false;
                const digit: u8 = @intCast(if (key >= vk.VK_NUMPAD0) key - vk.VK_NUMPAD0 else key - '0');
                if (self.session.field_digit_count < MAX_FIELD_DIGITS) {
                    self.session.field_digits[self.session.field_digit_count] = '0' + digit;
                    self.session.field_digit_count += 1;
                }
            },
            vk.VK_BACK => {
                self.session.field_digit_count = if (self.session.is_field_untouched) 0 else self.session.field_digit_count -| 1;
                self.session.is_field_untouched = false;
            },
            vk.VK_TAB => self.focusField(switch (field) {
                .width => .height,
                .height => .width,
            }),
            vk.VK_RETURN => self.commitField(),
            // Drops the typed value rather than closing the overlay.
            vk.VK_ESCAPE => self.session.field_focus = null,
            else => return false,
        }
        self.redraw();
        return true;
    }

    fn ensureTextFonts(self: *Overlay, dc: win32.HDC) void {
        const height_px = self.scaled(TEXT_FONT_PX);
        if (self.text_font_px == height_px and self.text_font != null) return;

        for ([_]*?win32.HFONT{ &self.text_font, &self.strong_font }) |font| {
            if (font.*) |old| _ = win32.DeleteObject(old);
        }
        self.text_font = firstInstalledFont(dc, &TEXT_FONTS, height_px);
        self.strong_font = firstInstalledFont(dc, &STRONG_FONTS, height_px);
        if (self.text_font == null) slog.warn("Failed to create the region overlay's font, so it shows no text", .{});
        self.text_font_px = height_px;
    }

    fn drawButton(self: *const Overlay, bitmap: *const gdi_overlay.OverlayBitmap, rect: win32.RECT, label: []const u8, button: Button) void {
        const font = switch (button) {
            .save => self.strong_font orelse self.text_font,
            .cancel => self.text_font,
        } orelse return;
        const is_hovered = self.session.hovered_button == button or self.session.pressed_button == button;
        const accent = self.session.border_color;
        // Transparent in the dialog, over its footer.
        const fill = paletteArgb(if (is_hovered) style.SURFACE else style.CHROME);

        const face = switch (button) {
            .save => blk: {
                const ink = if (is_hovered) color.lighten(accent, BUTTON_LIGHTEN_PERCENT) else accent;
                break :blk self.controlFace(fill, ink, ink);
            },
            .cancel => self.controlFace(fill, if (is_hovered) accent else paletteArgb(style.BORDER_STRONG), paletteArgb(style.TEXT)),
        };
        gdi_overlay.drawButtonFace(bitmap, self.toLocal(rect), label, font, face);
    }

    /// The buttons' and size fields' shared shape at the current scale.
    fn controlFace(self: *const Overlay, fill: u32, border: u32, text_color: u32) gdi_overlay.ButtonFace {
        return .{
            .fill = fill,
            .border = border,
            .text_color = text_color,
            .radius = @intCast(self.scaled(BUTTON_RADIUS)),
            .border_px = @intCast(@max(1, self.scaled(1))),
        };
    }

    fn drawButtons(self: *Overlay, bitmap: *const gdi_overlay.OverlayBitmap) void {
        if (self.session.edit_handle != .none) return;
        const rects = self.controlRects(self.session.edit_rect).buttons;
        self.drawButton(bitmap, rects[@backingInt(Button.save)], labelText(&self.session.labels.save), .save);
        self.drawButton(bitmap, rects[@backingInt(Button.cancel)], labelText(&self.session.labels.cancel), .cancel);
    }

    fn drawField(self: *Overlay, bitmap: *const gdi_overlay.OverlayBitmap, rect: win32.RECT, field: Field, length: i32) void {
        const font = self.text_font orelse return;
        const is_focused = self.session.field_focus == field;
        const prefix = labelText(switch (field) {
            .width => &self.session.labels.width_prefix,
            .height => &self.session.labels.height_prefix,
        });
        const caret = if (is_focused) "_" else "";

        // Fits the longest prefix, a space, any i32 and the caret.
        var text_buf: [FIELD_PREFIX_SIZE + 13]u8 = undefined;
        const text = if (is_focused and !self.session.is_field_untouched)
            std.mem.print(&text_buf, "{s} {s}{s}", .{ prefix, self.session.field_digits[0..self.session.field_digit_count], caret }) catch unreachable
        else
            std.mem.print(&text_buf, "{s} {d}{s}", .{ prefix, length, caret }) catch unreachable;

        const face = self.controlFace(paletteArgb(style.SURFACE), if (is_focused) self.session.border_color else paletteArgb(style.BORDER_STRONG), paletteArgb(style.TEXT));
        gdi_overlay.drawButtonFace(bitmap, self.toLocal(rect), text, font, face);
    }

    /// Shown while drawing too, so they follow the region as it's dragged out.
    fn drawFields(self: *Overlay, bitmap: *const gdi_overlay.OverlayBitmap, region: win32.RECT) void {
        const rects = self.controlRects(region).fields;
        self.drawField(bitmap, rects[@backingInt(Field.width)], .width, win32.rectWidth(region));
        self.drawField(bitmap, rects[@backingInt(Field.height)], .height, win32.rectHeight(region));
    }

    fn toLocal(self: *const Overlay, rect: win32.RECT) win32.RECT {
        return .{
            .left = rect.left - self.session.virtual_screen.left,
            .top = rect.top - self.session.virtual_screen.top,
            .right = rect.right - self.session.virtual_screen.left,
            .bottom = rect.bottom - self.session.virtual_screen.top,
        };
    }

    fn redraw(self: *Overlay) void {
        const hwnd = self.hwnd orelse return;
        const bitmap = if (self.bitmap) |*overlay| overlay else return;
        self.ensureTextFonts(bitmap.mem_dc);

        pixel_buffer.fillRect(bitmap.canvas(), 0, 0, bitmap.width, bitmap.height, DIM_COLOR);
        for (self.session.other_regions[0..self.session.other_region_count]) |other| self.drawRegion(bitmap, other, OTHER_REGION_FILL, OTHER_REGION_BORDER, .dashed);

        if (self.session.is_edit_mode) {
            self.drawRegion(bitmap, self.session.edit_rect, HIT_TESTABLE_CLEAR_COLOR, self.session.border_color, .solid);
            self.drawEditHandles(bitmap, self.session.edit_rect);
            self.drawFields(bitmap, self.session.edit_rect);
            self.drawButtons(bitmap);
            if (self.session.edit_handle != .none) self.drawSizeLabel(bitmap, self.session.edit_rect);
        } else if (self.session.is_dragging) {
            const selection = self.normalizedSelection();
            self.drawRegion(bitmap, selection, CLEAR_COLOR, self.session.border_color, .solid);
            if (win32.rectWidth(selection) > 0 and win32.rectHeight(selection) > 0) {
                self.drawSizeLabel(bitmap, selection);
                self.drawFields(bitmap, selection);
            }
        }

        gdi_overlay.presentLayered(hwnd, bitmap, 255);
    }

    fn maybeRedrawThrottled(self: *Overlay) void {
        const now = win32.Ticks.now();
        if (now.elapsedSince(self.session.last_redraw) < REDRAW_THROTTLE_MS) return;
        self.session.last_redraw = now;
        self.redraw();
    }

    fn finish(self: *Overlay, is_cancelled: bool) void {
        if (is_cancelled) self.session.field_focus = null else self.commitField();
        if (self.hwnd) |hwnd| _ = win32.ShowWindow(hwnd, win32.SW_HIDE);
        self.hint_box.hide();
        self.session.is_dragging = false;

        if (self.bitmap) |bitmap| bitmap.deinit();
        self.bitmap = null;

        if (self.session.on_finished) |callback| callback();

        if (is_cancelled) {
            self.report(.cancelled, EMPTY_RECT);
            return;
        }

        const rect = if (self.session.is_edit_mode) self.session.edit_rect else self.normalizedSelection();
        if (!isBigEnough(rect)) {
            self.report(.too_small, EMPTY_RECT);
            return;
        }
        self.report(.success, rect);
    }

    fn report(self: *const Overlay, status: Status, rect: win32.RECT) void {
        if (self.session.on_result) |on_result| on_result(status, rect);
    }
};

/// Zero-padded fixed-size copy of `text` (UTF-8), truncated at a character boundary so a NUL always fits.
pub fn fixedText(comptime size: usize, text: []const u8) [size]u8 {
    var out = std.mem.zeroes([size]u8);
    var length = @min(text.len, size - 1);
    while (length > 0 and length < text.len and (text[length] & 0xC0) == 0x80) length -= 1;
    @memcpy(out[0..length], text[0..length]);
    return out;
}

/// The text in a fixed-size, NUL-padded label buffer.
fn labelText(buf: []const u8) []const u8 {
    return std.mem.sliceTo(buf, 0);
}

/// Null, logged, if it can't be loaded; WM_SETCURSOR then leaves the class's arrow rather than hiding the pointer.
fn loadSystemCursor(id: win32.LPCSTR, name: []const u8) ?win32.HCURSOR {
    return win32.LoadCursorA(null, id) orelse {
        slog.warn("Failed to load the '{s}' cursor for the region overlay", .{name});
        return null;
    };
}

/// Attaches to the foreground thread so Windows' foreground lock can't refuse SetForegroundWindow, which would leave Escape going nowhere.
fn grabForegroundFocus(hwnd: win32.HWND) void {
    const current_thread = win32.GetCurrentThreadId();
    var attached = false;
    var foreground_thread: win32.DWORD = 0;

    if (win32.GetForegroundWindow()) |foreground| {
        foreground_thread = win32.GetWindowThreadProcessId(foreground, null);
        if (foreground_thread != 0 and foreground_thread != current_thread) {
            attached = win32.toBool(win32.AttachThreadInput(current_thread, foreground_thread, win32.TRUE));
        }
    }

    _ = win32.SetForegroundWindow(hwnd);
    _ = win32.BringWindowToTop(hwnd);
    _ = win32.SetFocus(hwnd);

    if (attached) {
        _ = win32.AttachThreadInput(current_thread, foreground_thread, win32.FALSE);
    }
}

fn isBigEnough(rect: win32.RECT) bool {
    return win32.rectWidth(rect) >= MIN_DRAG_PX and win32.rectHeight(rect) >= MIN_DRAG_PX;
}

fn dpiScaleAt(point: win32.POINT) f32 {
    const monitor = win32.nearestMonitor(point) orelse return 1.0;
    return win32.dpiToScale(win32.monitorDpi(monitor));
}

fn firstInstalledFont(dc: win32.HDC, choices: []const FontChoice, height_px: i32) ?win32.HFONT {
    for (choices) |choice| {
        if (gdi_overlay.createInstalledFont(dc, choice.name, height_px, choice.weight)) |font| return font;
    }
    return null;
}

/// A dialog palette colour for GDI; converted as drawn, since the sRGB maths isn't known to fold at comptime.
fn paletteArgb(palette_color: ui.Color) u32 {
    return color_convert.toArgb(palette_color);
}

fn cursorPos() ?win32.POINT {
    var point: win32.POINT = undefined;
    if (!win32.toBool(win32.GetCursorPos(&point))) {
        slog.debug("Failed to read the cursor position for the region overlay", .{});
        return null;
    }
    return point;
}

/// The Overlay the window was created for, which start stores as soon as the window exists.
fn overlayOf(hwnd: win32.HWND) ?*Overlay {
    const user_data = win32.GetWindowLongPtrA(hwnd, win32.GWLP_USERDATA);
    if (user_data == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(user_data)));
}

fn wndProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    const self = overlayOf(hwnd) orelse return win32.DefWindowProcA(hwnd, msg, wParam, lParam);
    switch (msg) {
        win32.WM_SETCURSOR => {
            if (self.session.is_edit_mode) {
                const point = cursorPos() orelse return 1;
                const cursor = if (self.session.edit_handle != .none)
                    self.cursorForHandle(self.session.edit_handle)
                else if (self.fieldAt(point) != null)
                    self.ibeam_cursor
                else if (self.buttonAt(point) != null or self.session.pressed_button != null)
                    self.hand_cursor
                else
                    self.cursorForHandle(self.hitTestEditRect(point));
                _ = win32.SetCursor(cursor orelse return win32.DefWindowProcA(hwnd, msg, wParam, lParam));
                return 1;
            }
            // A crosshair, so the whole screen reads as somewhere to drag.
            _ = win32.SetCursor(self.cross_cursor orelse return win32.DefWindowProcA(hwnd, msg, wParam, lParam));
            return 1;
        },
        win32.WM_LBUTTONDOWN => {
            const point = cursorPos() orelse return 0;
            if (self.session.is_edit_mode) {
                if (self.fieldAt(point)) |field| {
                    if (self.session.field_focus != field) self.focusField(field);
                    self.redraw();
                    return 0;
                }
                // Save commits a typed value in self.finish(), after the release has been matched to the button it pressed.
                if (self.buttonAt(point)) |button| {
                    self.session.pressed_button = button;
                    _ = win32.SetCapture(hwnd);
                    self.redraw();
                    return 0;
                }
                self.commitField();
                const handle = self.hitTestEditRect(point);
                if (handle == .none) {
                    self.redraw();
                    return 0;
                }
                self.session.edit_handle = handle;
                self.session.edit_grab = point;
                self.session.edit_grab_rect = self.session.edit_rect;
                self.session.current = point;
                _ = win32.SetCapture(hwnd);
                self.redraw();
                return 0;
            }
            self.session.bounds = self.monitorBoundsAt(point);
            self.session.ui_scale = dpiScaleAt(point);
            self.session.anchor = self.snapPoint(point);
            self.session.current = self.session.anchor;
            self.session.is_dragging = true;
            _ = win32.SetCapture(hwnd);
            self.redraw();
            return 0;
        },
        win32.WM_MOUSEMOVE => {
            const point = cursorPos() orelse return 0;
            if (self.session.is_edit_mode and self.session.edit_handle == .none) {
                const hovered = self.buttonAt(point);
                if (hovered != self.session.hovered_button) {
                    self.session.hovered_button = hovered;
                    self.redraw();
                }
                return 0;
            }
            if (!self.session.is_dragging and self.session.edit_handle == .none) return 0;
            self.session.current = point;
            if (self.session.is_edit_mode) self.applyEditDrag(point) else self.session.current = self.snapPoint(point);
            self.maybeRedrawThrottled();
            return 0;
        },
        win32.WM_LBUTTONUP => {
            if (self.session.is_edit_mode) {
                if (self.session.pressed_button) |pressed| {
                    self.session.pressed_button = null;
                    _ = win32.ReleaseCapture();
                    const is_released_on_it = if (cursorPos()) |point| self.buttonAt(point) == pressed else false;
                    if (is_released_on_it) self.finish(pressed == .cancel) else self.redraw();
                    return 0;
                }
                if (self.session.edit_handle == .none) return 0;
                self.session.edit_handle = .none;
                _ = win32.ReleaseCapture();
                self.redraw();
                return 0;
            }
            if (!self.session.is_dragging) return 0;
            // Cleared first so the WM_CAPTURECHANGED from ReleaseCapture doesn't read as a cancel.
            self.session.is_dragging = false;
            _ = win32.ReleaseCapture();
            const selection = self.normalizedSelection();
            if (!isBigEnough(selection)) {
                self.finish(false);
                return 0;
            }
            self.enterEditMode(selection);
            self.redraw();
            return 0;
        },
        win32.WM_RBUTTONDOWN => {
            if (self.session.is_dragging or self.session.edit_handle != .none) _ = win32.ReleaseCapture();
            self.finish(true);
            return 0;
        },
        win32.WM_KEYDOWN => {
            if (self.session.is_edit_mode and self.handleFieldKey(wParam)) return 0;
            if (wParam == vk.VK_TAB and self.session.is_edit_mode and self.session.edit_handle == .none) {
                self.focusField(.width);
                self.redraw();
                return 0;
            }
            if (wParam == vk.VK_ESCAPE) {
                if (self.session.is_dragging or self.session.edit_handle != .none) _ = win32.ReleaseCapture();
                self.finish(true);
            } else if (wParam == vk.VK_RETURN and self.session.is_edit_mode) {
                if (self.session.edit_handle != .none) _ = win32.ReleaseCapture();
                self.finish(false);
            }
            return 0;
        },
        win32.WM_CAPTURECHANGED => {
            // Capture stolen by something else mid-drag (e.g. alt-tab): treat as a cancel so the overlay never gets stuck.
            if (self.session.is_edit_mode) {
                // The edited rect stays put; only the active drag or button press ends.
                self.session.edit_handle = .none;
                self.session.pressed_button = null;
            } else if (self.session.is_dragging) {
                self.finish(true);
            }
            return 0;
        },
        else => return win32.DefWindowProcA(hwnd, msg, wParam, lParam),
    }
}
