//! The full-screen overlay for dragging out, or adjusting, a screen region for the config dialog.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const gdi_overlay = @import("../../platform/gdi_overlay.zig");
const color = @import("../../util/color.zig");
const region_math = @import("region_math.zig");
const log = @import("../../log.zig");

const slog = log.scoped("region_select");

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

// Save/Cancel mirror the config dialog's buttons (dialog/ui/style.css): sizes are CSS px scaled by monitor DPI, colors are its palette.
const BUTTON_WIDTH: i32 = 80;
const BUTTON_HEIGHT: i32 = 28;
const BUTTON_GAP: i32 = 8;
const BUTTON_CHAR_WIDTH: i32 = 8;
const BUTTON_TEXT_PADDING: i32 = 12;
const BUTTON_MARGIN: i32 = 8;
const BUTTON_RADIUS: i32 = 3;
const BUTTON_FONT_PX: i32 = 12;
/// The dialog's --font-mono stack. GDI doesn't embolden Cascadia Code's variable-font weights, so its bold is the separate SemiBold face.
const BUTTON_FONTS = [_]ButtonFont{
    .{ .name = "Cascadia Code SemiBold", .weight = win32.FW_SEMIBOLD },
    .{ .name = "Cascadia Code", .weight = win32.FW_BOLD },
    .{ .name = "Consolas", .weight = win32.FW_BOLD },
    .{ .name = "Courier New", .weight = win32.FW_BOLD },
};
const BUTTON_LIGHTEN_PERCENT = 15;
const BUTTON_BG: u32 = 0xFF0B0C0D;
const BUTTON_SURFACE: u32 = 0xFF1A1B1D;
const BUTTON_SURFACE_ALT: u32 = 0xFF202224;
const BUTTON_BORDER: u32 = 0xFF6B6E75;
const BUTTON_TEXT: u32 = 0xFFE8E6E1;

const ButtonFont = struct { name: [:0]const u8, weight: c_int };

pub const LabelStyle = struct {
    font: ?win32.HFONT,
    color: u32,
};

const Handle = enum { none, move, left, right, top, bottom, top_left, top_right, bottom_left, bottom_right };
const Outline = enum { solid, dashed };
const Button = enum { save, cancel };
const Field = enum { width, height };

/// The size fields sit in a row above Save/Cancel, each the width of the button below it.
const Controls = struct {
    fields: [2]win32.RECT,
    buttons: [2]win32.RECT,
};

/// The overlay's on-screen text.
pub const Labels = struct {
    save: [32]u8 = fixedText(32, "Save"),
    cancel: [32]u8 = fixedText(32, "Cancel"),
    hint_new: [192]u8 = fixedText(192, "Drag to draw the region, then drag its edges to adjust"),
    hint_edit: [192]u8 = fixedText(192, "Drag the edges to resize, or the inside to move"),
    hint_confirm: [192]u8 = fixedText(192, "Enter or Save to confirm, Esc or right-click to cancel"),
};

pub const Status = enum { success, cancelled, too_small };

var g_window_class_registered = false;
var g_border_color: u32 = DEFAULT_BORDER_COLOR;
var g_dragging = false;
var g_hwnd: ?win32.HWND = null;
var g_bitmap: ?gdi_overlay.OverlayBitmap = null;
var g_virtual_screen: win32.RECT = undefined;
/// The one monitor a selection is confined to, so it can't spill into the gap between monitors of different sizes.
var g_bounds: win32.RECT = undefined;
var g_anchor: win32.POINT = undefined;
var g_current: win32.POINT = undefined;
var g_last_redraw: win32.Ticks = undefined;
var g_cross_cursor: ?win32.HCURSOR = null;
var g_on_finished: ?*const fn () void = null;
var g_on_result: ?*const fn (Status, win32.RECT) void = null;
var g_label_style: LabelStyle = .{ .font = null, .color = 0xFFFFFFFF };
var g_labels = Labels{};
var g_other_regions: [MAX_OTHER_REGIONS]win32.RECT = undefined;
var g_other_region_count: usize = 0;

var g_button_hover: ?Button = null;
var g_button_pressed: ?Button = null;
var g_ui_scale: f32 = 1.0;
var g_button_font_px: i32 = 0;
var g_button_font: ?win32.HFONT = null;
var g_hand_cursor: ?win32.HCURSOR = null;

var g_edit_mode = false;
var g_edit_rect: win32.RECT = undefined;
var g_edit_handle: Handle = .none;
var g_edit_grab: win32.POINT = undefined;
var g_edit_grab_rect: win32.RECT = undefined;
var g_arrow_cursor: ?win32.HCURSOR = null;
var g_size_we_cursor: ?win32.HCURSOR = null;
var g_size_ns_cursor: ?win32.HCURSOR = null;
var g_size_nwse_cursor: ?win32.HCURSOR = null;
var g_size_nesw_cursor: ?win32.HCURSOR = null;
var g_size_all_cursor: ?win32.HCURSOR = null;
var g_ibeam_cursor: ?win32.HCURSOR = null;

var g_field_focus: ?Field = null;
var g_field_digits: [MAX_FIELD_DIGITS]u8 = undefined;
var g_field_digit_count: usize = 0;
/// The focused field still shows the region's size, which the first digit typed replaces.
var g_field_untouched = false;

/// Zero-padded fixed-size copy of `text` (UTF-8), truncated at a character boundary so a NUL always fits.
pub fn fixedText(comptime n: usize, text: []const u8) [n]u8 {
    var out = std.mem.zeroes([n]u8);
    var len = @min(text.len, n - 1);
    while (len > 0 and len < text.len and (text[len] & 0xC0) == 0x80) len -= 1;
    @memcpy(out[0..len], text[0..len]);
    return out;
}

/// The text in a fixed-size, NUL-padded label buffer.
pub fn labelText(buf: []const u8) []const u8 {
    return std.mem.sliceTo(buf, 0);
}

/// Starts or restarts the overlay, copying `other_regions`; `on_finished` then `on_result` run as it closes, neither if this fails.
pub fn start(instance: win32.HINSTANCE, accent_color: u32, label_style: LabelStyle, edit_region: ?win32.RECT, other_regions: []const win32.RECT, labels: Labels, on_finished: *const fn () void, on_result: *const fn (Status, win32.RECT) void) !void {
    try registerWindowClass(instance);
    g_on_finished = on_finished;
    g_on_result = on_result;
    g_border_color = accent_color | 0xFF000000;
    g_label_style = label_style;
    g_labels = labels;
    g_other_region_count = @min(other_regions.len, MAX_OTHER_REGIONS);
    @memcpy(g_other_regions[0..g_other_region_count], other_regions[0..g_other_region_count]);

    g_virtual_screen = win32.virtualScreenRect();
    const left = g_virtual_screen.left;
    const top = g_virtual_screen.top;
    const width = win32.rectWidth(g_virtual_screen);
    const height = win32.rectHeight(g_virtual_screen);
    g_bounds = g_virtual_screen;
    g_dragging = false;
    g_edit_handle = .none;
    g_field_focus = null;

    // A region that's mostly off the current screens clamps to nothing usable, so fall back to a fresh drag.
    g_edit_mode = false;
    if (edit_region) |region| {
        g_bounds = monitorBoundsAt(win32.rectCenter(win32.clampRect(region, g_virtual_screen)));
        const clamped = win32.clampRect(region, g_bounds);
        if (isBigEnough(clamped)) enterEditMode(clamped);
    }

    if (g_hwnd) |hwnd| {
        _ = win32.SetWindowPos(hwnd, win32.HWND_TOPMOST, left, top, width, height, win32.SWP_NOACTIVATE);
    } else {
        g_hwnd = win32.CreateWindowExA(
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
    }

    const hwnd = g_hwnd.?;
    ensureBitmap(width, height);
    g_last_redraw = win32.Ticks.now();
    redraw();

    _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
    grabForegroundFocus(hwnd);
}

fn registerWindowClass(instance: win32.HINSTANCE) !void {
    if (g_window_class_registered) return;
    g_cross_cursor = win32.LoadCursorA(null, win32.IDC_CROSS);
    g_arrow_cursor = win32.LoadCursorA(null, win32.IDC_ARROW);
    g_size_we_cursor = win32.LoadCursorA(null, win32.IDC_SIZEWE);
    g_size_ns_cursor = win32.LoadCursorA(null, win32.IDC_SIZENS);
    g_size_nwse_cursor = win32.LoadCursorA(null, win32.IDC_SIZENWSE);
    g_size_nesw_cursor = win32.LoadCursorA(null, win32.IDC_SIZENESW);
    g_size_all_cursor = win32.LoadCursorA(null, win32.IDC_SIZEALL);
    g_hand_cursor = win32.LoadCursorA(null, win32.IDC_HAND);
    g_ibeam_cursor = win32.LoadCursorA(null, win32.IDC_IBEAM);
    try gdi_overlay.registerWindowClass(instance, wndProc, WINDOW_CLASS_NAME, null);
    g_window_class_registered = true;
}

/// Plain SetForegroundWindow (platform/focus_grant.zig's forceSetForegroundWindow) only works when the calling process just received user input, which isn't true here since StartRegionSelect arrives over WM_COPYDATA - Windows' foreground-lock would otherwise silently eat it, leaving Escape going nowhere.
fn grabForegroundFocus(hwnd: win32.HWND) void {
    const current_thread = win32.GetCurrentThreadId();
    var attached = false;
    var foreground_thread: win32.DWORD = 0;

    if (win32.GetForegroundWindow()) |foreground| {
        foreground_thread = win32.GetWindowThreadProcessId(foreground, null);
        if (foreground_thread != 0 and foreground_thread != current_thread) {
            attached = win32.AttachThreadInput(current_thread, foreground_thread, win32.TRUE) != 0;
        }
    }

    _ = win32.SetForegroundWindow(hwnd);
    _ = win32.BringWindowToTop(hwnd);
    _ = win32.SetFocus(hwnd);

    if (attached) {
        _ = win32.AttachThreadInput(current_thread, foreground_thread, win32.FALSE);
    }
}

fn ensureBitmap(width: i32, height: i32) void {
    if (!gdi_overlay.OverlayBitmap.needsResize(g_bitmap, width, height)) return;

    const dc = win32.GetDC(null) orelse return;
    defer _ = win32.ReleaseDC(null, dc);
    gdi_overlay.OverlayBitmap.recreate(&g_bitmap, dc, width, height) catch |err| {
        slog.err("Failed to allocate region-select overlay bitmap: {}", .{err});
    };
}

fn isBigEnough(rect: win32.RECT) bool {
    return win32.rectWidth(rect) >= MIN_DRAG_PX and win32.rectHeight(rect) >= MIN_DRAG_PX;
}

fn normalizedSelection() win32.RECT {
    return win32.clampRect(.{
        .left = @min(g_anchor.x, g_current.x),
        .top = @min(g_anchor.y, g_current.y),
        .right = @max(g_anchor.x, g_current.x),
        .bottom = @max(g_anchor.y, g_current.y),
    }, g_bounds);
}

/// Cuts `rect` out of the dim layer and outlines it; `fill` is the interior color.
/// Clipped to the overlay, since fillRect skips a rect that runs past the buffer.
fn drawRegion(bitmap: *const gdi_overlay.OverlayBitmap, rect: win32.RECT, fill: u32, border: u32, outline: Outline) void {
    const visible = win32.clampRect(rect, g_virtual_screen);
    const w = win32.rectWidth(visible);
    const h = win32.rectHeight(visible);
    if (w <= 0 or h <= 0) return;
    const local_x = visible.left - g_virtual_screen.left;
    const local_y = visible.top - g_virtual_screen.top;
    const uw: usize = @intCast(w);
    const uh: usize = @intCast(h);
    gdi_overlay.fillRect(bitmap.pixels, bitmap.width, bitmap.height, @intCast(local_x), @intCast(local_y), uw, uh, fill);
    switch (outline) {
        .solid => gdi_overlay.drawRectOutline(bitmap.pixels, bitmap.width, bitmap.height, local_x, local_y, uw, uh, BORDER_THICKNESS, border),
        .dashed => gdi_overlay.drawDashedRectOutline(bitmap.pixels, bitmap.width, bitmap.height, local_x, local_y, uw, uh, BORDER_THICKNESS, OTHER_REGION_DASH, border),
    }
}

fn monitorBoundsAt(pt: win32.POINT) win32.RECT {
    const monitor = win32.nearestMonitor(pt) orelse return g_virtual_screen;
    return win32.monitorRect(monitor) orelse g_virtual_screen;
}

fn dpiScaleAt(pt: win32.POINT) f32 {
    const monitor = win32.nearestMonitor(pt) orelse return 1.0;
    return win32.dpiToScale(win32.monitorDpi(monitor));
}

/// Switches to adjusting `rect` (edges, handles, Save/Cancel); used for Edit Region and once a fresh drag is released.
fn enterEditMode(rect: win32.RECT) void {
    g_edit_rect = rect;
    g_edit_mode = true;
    g_edit_handle = .none;
    g_button_hover = null;
    g_button_pressed = null;
    g_ui_scale = dpiScaleAt(win32.rectCenter(rect));
}

fn drawSizeLabel(bitmap: *const gdi_overlay.OverlayBitmap, selection: win32.RECT) void {
    const font = g_label_style.font orelse return;

    var text_buf: [32]u8 = undefined;
    const text = std.mem.print(&text_buf, "{d} x {d}", .{ win32.rectWidth(selection), win32.rectHeight(selection) }) catch unreachable;

    const old_font = win32.SelectObject(bitmap.mem_dc, font);
    defer {
        if (old_font) |of| _ = win32.SelectObject(bitmap.mem_dc, of);
    }

    const text_size = gdi_overlay.measureTextSize(text_buf.len, bitmap.mem_dc, text);
    const label_w: i32 = text_size.cx + @as(i32, LABEL_PADDING_X * 2);
    const label_h: i32 = text_size.cy + @as(i32, LABEL_PADDING_Y * 2);

    const bounds = monitorBoundsAt(g_current);
    const bounds_center = win32.rectCenter(bounds);
    const in_right_half = g_current.x >= bounds_center.x;
    const in_bottom_half = g_current.y >= bounds_center.y;
    var x = if (in_right_half) g_current.x - LABEL_CURSOR_OFFSET - label_w else g_current.x + LABEL_CURSOR_OFFSET;
    var y = if (in_bottom_half) g_current.y - LABEL_CURSOR_OFFSET - label_h else g_current.y + LABEL_CURSOR_OFFSET;
    x = @max(bounds.left, @min(x, bounds.right - label_w));
    y = @max(bounds.top, @min(y, bounds.bottom - label_h));

    const local_x: usize = @intCast(x - g_virtual_screen.left);
    const local_y: usize = @intCast(y - g_virtual_screen.top);
    gdi_overlay.fillRect(bitmap.pixels, bitmap.width, bitmap.height, local_x, local_y, @intCast(label_w), @intCast(label_h), gdi_overlay.HINT_BG_COLOR);
    gdi_overlay.drawText(text_buf.len, bitmap.mem_dc, @intCast(local_x + LABEL_PADDING_X), @intCast(local_y + LABEL_PADDING_Y), text, g_label_style.color);
}

fn hitTestEditRect(pt: win32.POINT) Handle {
    const r = g_edit_rect;
    const slop: i32 = @intCast(HANDLE_HIT_PX);
    if (pt.x < r.left - slop or pt.x > r.right + slop or pt.y < r.top - slop or pt.y > r.bottom + slop) return .none;

    const dist_left = @abs(pt.x - r.left);
    const dist_right = @abs(pt.x - r.right);
    const dist_top = @abs(pt.y - r.top);
    const dist_bottom = @abs(pt.y - r.bottom);
    const near_left = dist_left <= HANDLE_HIT_PX and dist_left <= dist_right;
    const near_right = dist_right <= HANDLE_HIT_PX and dist_right < dist_left;
    const near_top = dist_top <= HANDLE_HIT_PX and dist_top <= dist_bottom;
    const near_bottom = dist_bottom <= HANDLE_HIT_PX and dist_bottom < dist_top;

    if (near_top and near_left) return .top_left;
    if (near_top and near_right) return .top_right;
    if (near_bottom and near_left) return .bottom_left;
    if (near_bottom and near_right) return .bottom_right;
    if (near_left) return .left;
    if (near_right) return .right;
    if (near_top) return .top;
    if (near_bottom) return .bottom;
    return .move;
}

fn cursorForHandle(handle: Handle) ?win32.HCURSOR {
    return switch (handle) {
        .none => g_arrow_cursor,
        .move => g_size_all_cursor,
        .left, .right => g_size_we_cursor,
        .top, .bottom => g_size_ns_cursor,
        .top_left, .bottom_right => g_size_nwse_cursor,
        .top_right, .bottom_left => g_size_nesw_cursor,
    };
}

fn applyEditDrag(pt: win32.POINT) void {
    const dx = pt.x - g_edit_grab.x;
    const dy = pt.y - g_edit_grab.y;
    const vs = g_bounds;
    var r = g_edit_grab_rect;

    if (g_edit_handle == .move) {
        const w = win32.rectWidth(r);
        const h = win32.rectHeight(r);
        var left = r.left + dx;
        var top = r.top + dy;
        left += region_math.snapSpanOffset(left, left + w, .x, otherRegions(), vs, region_math.SNAP_DISTANCE_PX);
        top += region_math.snapSpanOffset(top, top + h, .y, otherRegions(), vs, region_math.SNAP_DISTANCE_PX);
        r.left = std.math.clamp(left, vs.left, vs.right - w);
        r.top = std.math.clamp(top, vs.top, vs.bottom - h);
        r.right = r.left + w;
        r.bottom = r.top + h;
    } else {
        const moves_left = g_edit_handle == .left or g_edit_handle == .top_left or g_edit_handle == .bottom_left;
        const moves_right = g_edit_handle == .right or g_edit_handle == .top_right or g_edit_handle == .bottom_right;
        const moves_top = g_edit_handle == .top or g_edit_handle == .top_left or g_edit_handle == .top_right;
        const moves_bottom = g_edit_handle == .bottom or g_edit_handle == .bottom_left or g_edit_handle == .bottom_right;
        if (moves_left) r.left = std.math.clamp(snapEdge(r.left + dx, .x), vs.left, r.right - MIN_DRAG_PX);
        if (moves_right) r.right = std.math.clamp(snapEdge(r.right + dx, .x), r.left + MIN_DRAG_PX, vs.right);
        if (moves_top) r.top = std.math.clamp(snapEdge(r.top + dy, .y), vs.top, r.bottom - MIN_DRAG_PX);
        if (moves_bottom) r.bottom = std.math.clamp(snapEdge(r.bottom + dy, .y), r.top + MIN_DRAG_PX, vs.bottom);
    }
    g_edit_rect = r;
}

fn otherRegions() []const win32.RECT {
    return g_other_regions[0..g_other_region_count];
}

fn snapEdge(value: i32, axis: region_math.Axis) i32 {
    return region_math.snapEdge(value, axis, otherRegions(), g_bounds, region_math.SNAP_DISTANCE_PX);
}

fn snapPoint(pt: win32.POINT) win32.POINT {
    return .{ .x = snapEdge(pt.x, .x), .y = snapEdge(pt.y, .y) };
}

fn drawHandle(bitmap: *const gdi_overlay.OverlayBitmap, center_x: i32, center_y: i32) void {
    const x = std.math.clamp(center_x - @divTrunc(HANDLE_SIZE, 2), g_bounds.left, g_bounds.right - HANDLE_SIZE);
    const y = std.math.clamp(center_y - @divTrunc(HANDLE_SIZE, 2), g_bounds.top, g_bounds.bottom - HANDLE_SIZE);
    const size: usize = @intCast(HANDLE_SIZE);
    gdi_overlay.fillRect(bitmap.pixels, bitmap.width, bitmap.height, @intCast(x - g_virtual_screen.left), @intCast(y - g_virtual_screen.top), size, size, HANDLE_COLOR);
}

fn drawEditHandles(bitmap: *const gdi_overlay.OverlayBitmap, rect: win32.RECT) void {
    const center = win32.rectCenter(rect);
    const xs = [3]i32{ rect.left, center.x, rect.right };
    const ys = [3]i32{ rect.top, center.y, rect.bottom };
    const roomy_w = win32.rectWidth(rect) >= HANDLE_SIZE * 4;
    const roomy_h = win32.rectHeight(rect) >= HANDLE_SIZE * 4;

    for (ys, 0..) |cy, row| {
        for (xs, 0..) |cx, column| {
            if (row == 1 and column == 1) continue;
            if (column == 1 and !roomy_w) continue;
            if (row == 1 and !roomy_h) continue;
            drawHandle(bitmap, cx, cy);
        }
    }
}

fn scaled(css_px: i32) i32 {
    return win32.scalePixels(css_px, g_ui_scale);
}

/// Wide enough for the longer translated label; CJK glyphs count double. Estimated, since layout also runs from hit testing where there's no DC to measure with.
fn buttonWidthCss() i32 {
    var widest: i32 = 0;
    for ([_][]const u8{ labelText(&g_labels.save), labelText(&g_labels.cancel) }) |label| {
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
fn controlRects(region: win32.RECT) Controls {
    const width = scaled(buttonWidthCss());
    const height = scaled(BUTTON_HEIGHT);
    const gap = scaled(BUTTON_GAP);
    const margin = scaled(BUTTON_MARGIN);
    const group_width = width * 2 + gap;
    const group_height = height * 2 + gap;

    const x = @max(g_bounds.left + margin, @min(region.right - margin - group_width, g_bounds.right - margin - group_width));
    var y = region.bottom + margin;
    if (y + group_height > g_bounds.bottom) y = region.top - margin - group_height;
    if (y < g_bounds.top) y = @max(g_bounds.top, region.bottom - margin - group_height);
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

fn buttonAt(pt: win32.POINT) ?Button {
    if (!g_edit_mode or g_edit_handle != .none) return null;
    const rects = controlRects(g_edit_rect).buttons;
    inline for (.{ Button.save, Button.cancel }) |button| {
        if (win32.rectContains(rects[@backingInt(button)], pt)) return button;
    }
    return null;
}

fn fieldAt(pt: win32.POINT) ?Field {
    if (!g_edit_mode or g_edit_handle != .none) return null;
    const rects = controlRects(g_edit_rect).fields;
    inline for (.{ Field.width, Field.height }) |field| {
        if (win32.rectContains(rects[@backingInt(field)], pt)) return field;
    }
    return null;
}

fn focusField(field: Field) void {
    commitField();
    g_field_focus = field;
    g_field_untouched = true;
    g_field_digit_count = 0;
}

/// Applies what was typed into the focused field, if anything, and unfocuses it.
fn commitField() void {
    const field = g_field_focus orelse return;
    g_field_focus = null;
    if (g_field_untouched or g_field_digit_count == 0) return;
    // Only ever digits, too few to overflow.
    const length = std.fmt.parseInt(i32, g_field_digits[0..g_field_digit_count], 10) catch unreachable;
    const axis: region_math.Axis = switch (field) {
        .width => .x,
        .height => .y,
    };
    g_edit_rect = region_math.withLength(g_edit_rect, axis, length, g_bounds, MIN_DRAG_PX);
}

/// Whether `key` went to the focused field.
fn handleFieldKey(key: win32.WPARAM) bool {
    const field = g_field_focus orelse return false;
    switch (key) {
        '0'...'9', win32.VK_NUMPAD0...win32.VK_NUMPAD0 + 9 => {
            if (g_field_untouched) g_field_digit_count = 0;
            g_field_untouched = false;
            const digit: u8 = @intCast(if (key >= win32.VK_NUMPAD0) key - win32.VK_NUMPAD0 else key - '0');
            if (g_field_digit_count < MAX_FIELD_DIGITS) {
                g_field_digits[g_field_digit_count] = '0' + digit;
                g_field_digit_count += 1;
            }
        },
        win32.VK_BACK => {
            g_field_digit_count = if (g_field_untouched) 0 else g_field_digit_count -| 1;
            g_field_untouched = false;
        },
        win32.VK_TAB => focusField(switch (field) {
            .width => .height,
            .height => .width,
        }),
        win32.VK_RETURN => commitField(),
        // Drops the typed value rather than closing the overlay.
        win32.VK_ESCAPE => g_field_focus = null,
        else => return false,
    }
    redraw();
    return true;
}

fn ensureButtonFonts(dc: win32.HDC) void {
    const height_px = scaled(BUTTON_FONT_PX);
    if (g_button_font_px == height_px and g_button_font != null) return;

    if (g_button_font) |old| _ = win32.DeleteObject(old);
    g_button_font = null;
    for (BUTTON_FONTS) |entry| {
        g_button_font = gdi_overlay.createInstalledFont(dc, entry.name, height_px, entry.weight) orelse continue;
        break;
    }
    g_button_font_px = height_px;
}

fn drawButton(bitmap: *const gdi_overlay.OverlayBitmap, rect: win32.RECT, label: []const u8, button: Button) void {
    const font = g_button_font orelse g_label_style.font orelse return;
    const hovered = g_button_hover == button or g_button_pressed == button;
    const accent = g_border_color;

    const face = switch (button) {
        .save => if (hovered) blk: {
            const fill = color.lighten(accent, BUTTON_LIGHTEN_PERCENT);
            break :blk controlFace(fill, fill, color.inkFor(accent));
        } else controlFace(BUTTON_BG, accent, accent),
        .cancel => controlFace(if (hovered) BUTTON_SURFACE_ALT else BUTTON_SURFACE, if (hovered) accent else BUTTON_BORDER, BUTTON_TEXT),
    };
    gdi_overlay.drawButtonFace(bitmap, toLocal(rect), label, font, face);
}

/// The buttons' and size fields' shared shape at the current scale.
fn controlFace(fill: u32, border: u32, text_color: u32) gdi_overlay.ButtonFace {
    return .{
        .fill = fill,
        .border = border,
        .text_color = text_color,
        .radius = @intCast(scaled(BUTTON_RADIUS)),
        .border_px = @intCast(@max(1, scaled(1))),
    };
}

fn drawButtons(bitmap: *const gdi_overlay.OverlayBitmap) void {
    if (g_edit_handle != .none) return;
    ensureButtonFonts(bitmap.mem_dc);
    const rects = controlRects(g_edit_rect).buttons;
    drawButton(bitmap, rects[@backingInt(Button.save)], labelText(&g_labels.save), .save);
    drawButton(bitmap, rects[@backingInt(Button.cancel)], labelText(&g_labels.cancel), .cancel);
}

fn drawField(bitmap: *const gdi_overlay.OverlayBitmap, rect: win32.RECT, field: Field, length: i32) void {
    const font = g_button_font orelse g_label_style.font orelse return;
    const is_focused = g_field_focus == field;
    const prefix = switch (field) {
        .width => "W",
        .height => "H",
    };
    const caret = if (is_focused) "_" else "";

    var text_buf: [24]u8 = undefined;
    const text = if (is_focused and !g_field_untouched)
        std.mem.print(&text_buf, "{s} {s}{s}", .{ prefix, g_field_digits[0..g_field_digit_count], caret }) catch unreachable
    else
        std.mem.print(&text_buf, "{s} {d}{s}", .{ prefix, length, caret }) catch unreachable;

    const face = controlFace(BUTTON_BG, if (is_focused) g_border_color else BUTTON_BORDER, BUTTON_TEXT);
    gdi_overlay.drawButtonFace(bitmap, toLocal(rect), text, font, face);
}

/// Shown while drawing too, so they follow the region as it's dragged out.
fn drawFields(bitmap: *const gdi_overlay.OverlayBitmap, region: win32.RECT) void {
    ensureButtonFonts(bitmap.mem_dc);
    const rects = controlRects(region).fields;
    drawField(bitmap, rects[@backingInt(Field.width)], .width, win32.rectWidth(region));
    drawField(bitmap, rects[@backingInt(Field.height)], .height, win32.rectHeight(region));
}

fn toLocal(rect: win32.RECT) win32.RECT {
    return .{
        .left = rect.left - g_virtual_screen.left,
        .top = rect.top - g_virtual_screen.top,
        .right = rect.right - g_virtual_screen.left,
        .bottom = rect.bottom - g_virtual_screen.top,
    };
}

fn redraw() void {
    const hwnd = g_hwnd orelse return;
    if (g_bitmap == null) return;
    const bitmap = &g_bitmap.?;

    gdi_overlay.fillRect(bitmap.pixels, bitmap.width, bitmap.height, 0, 0, bitmap.width, bitmap.height, DIM_COLOR);
    for (g_other_regions[0..g_other_region_count]) |other| drawRegion(bitmap, other, OTHER_REGION_FILL, OTHER_REGION_BORDER, .dashed);

    if (g_edit_mode) {
        drawRegion(bitmap, g_edit_rect, HIT_TESTABLE_CLEAR_COLOR, g_border_color, .solid);
        drawEditHandles(bitmap, g_edit_rect);
        drawFields(bitmap, g_edit_rect);
        drawButtons(bitmap);
        if (g_edit_handle != .none) drawSizeLabel(bitmap, g_edit_rect);
    } else if (g_dragging) {
        const selection = normalizedSelection();
        drawRegion(bitmap, selection, CLEAR_COLOR, g_border_color, .solid);
        if (win32.rectWidth(selection) > 0 and win32.rectHeight(selection) > 0) {
            drawSizeLabel(bitmap, selection);
            drawFields(bitmap, selection);
        }
    }

    gdi_overlay.presentLayered(hwnd, bitmap, 255);
}

fn maybeRedrawThrottled() void {
    const now = win32.Ticks.now();
    if (now.elapsedSince(g_last_redraw) < REDRAW_THROTTLE_MS) return;
    g_last_redraw = now;
    redraw();
}

fn finish(cancelled: bool) void {
    if (cancelled) g_field_focus = null else commitField();
    if (g_hwnd) |hwnd| _ = win32.ShowWindow(hwnd, win32.SW_HIDE);
    g_dragging = false;

    if (g_bitmap) |bitmap| bitmap.destroy();
    g_bitmap = null;

    if (g_on_finished) |callback| callback();

    const empty_rect = win32.RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (cancelled) {
        report(.cancelled, empty_rect);
        return;
    }

    const rect = if (g_edit_mode) g_edit_rect else normalizedSelection();
    if (!isBigEnough(rect)) {
        report(.too_small, empty_rect);
        return;
    }
    report(.success, rect);
}

fn report(status: Status, rect: win32.RECT) void {
    if (g_on_result) |on_result| on_result(status, rect);
}

fn wndProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    switch (msg) {
        win32.WM_SETCURSOR => {
            if (g_edit_mode) {
                var pt: win32.POINT = undefined;
                _ = win32.GetCursorPos(&pt);
                const cursor = if (g_edit_handle != .none)
                    cursorForHandle(g_edit_handle)
                else if (fieldAt(pt) != null)
                    g_ibeam_cursor
                else if (buttonAt(pt) != null or g_button_pressed != null)
                    g_hand_cursor
                else
                    cursorForHandle(hitTestEditRect(pt));
                _ = win32.SetCursor(cursor);
                return 1;
            }
            // Explicit crosshair so it's obvious the whole screen is draggable, not just click-through like the ghost/hint overlays.
            _ = win32.SetCursor(g_cross_cursor);
            return 1;
        },
        win32.WM_LBUTTONDOWN => {
            var pt: win32.POINT = undefined;
            _ = win32.GetCursorPos(&pt);
            if (g_edit_mode) {
                if (fieldAt(pt)) |field| {
                    if (g_field_focus != field) focusField(field);
                    redraw();
                    return 0;
                }
                // Save commits a typed value in finish(), after the release has been matched to the button it pressed.
                if (buttonAt(pt)) |button| {
                    g_button_pressed = button;
                    _ = win32.SetCapture(hwnd);
                    redraw();
                    return 0;
                }
                commitField();
                const handle = hitTestEditRect(pt);
                if (handle == .none) {
                    redraw();
                    return 0;
                }
                g_edit_handle = handle;
                g_edit_grab = pt;
                g_edit_grab_rect = g_edit_rect;
                g_current = pt;
                _ = win32.SetCapture(hwnd);
                redraw();
                return 0;
            }
            g_bounds = monitorBoundsAt(pt);
            g_ui_scale = dpiScaleAt(pt);
            g_anchor = snapPoint(pt);
            g_current = g_anchor;
            g_dragging = true;
            _ = win32.SetCapture(hwnd);
            redraw();
            return 0;
        },
        win32.WM_MOUSEMOVE => {
            var pt: win32.POINT = undefined;
            _ = win32.GetCursorPos(&pt);
            if (g_edit_mode and g_edit_handle == .none) {
                const hovered = buttonAt(pt);
                if (hovered != g_button_hover) {
                    g_button_hover = hovered;
                    redraw();
                }
                return 0;
            }
            if (!g_dragging and g_edit_handle == .none) return 0;
            g_current = pt;
            if (g_edit_mode) applyEditDrag(pt) else g_current = snapPoint(pt);
            maybeRedrawThrottled();
            return 0;
        },
        win32.WM_LBUTTONUP => {
            if (g_edit_mode) {
                if (g_button_pressed) |pressed| {
                    g_button_pressed = null;
                    _ = win32.ReleaseCapture();
                    var pt: win32.POINT = undefined;
                    _ = win32.GetCursorPos(&pt);
                    if (buttonAt(pt) == pressed) {
                        finish(pressed == .cancel);
                    } else {
                        redraw();
                    }
                    return 0;
                }
                if (g_edit_handle == .none) return 0;
                g_edit_handle = .none;
                _ = win32.ReleaseCapture();
                redraw();
                return 0;
            }
            if (!g_dragging) return 0;
            // Cleared first so the WM_CAPTURECHANGED from ReleaseCapture doesn't read as a cancel.
            g_dragging = false;
            _ = win32.ReleaseCapture();
            const selection = normalizedSelection();
            if (!isBigEnough(selection)) {
                finish(false);
                return 0;
            }
            enterEditMode(selection);
            redraw();
            return 0;
        },
        win32.WM_RBUTTONDOWN => {
            if (g_dragging or g_edit_handle != .none) _ = win32.ReleaseCapture();
            finish(true);
            return 0;
        },
        win32.WM_KEYDOWN => {
            if (g_edit_mode and handleFieldKey(wParam)) return 0;
            if (wParam == win32.VK_TAB and g_edit_mode and g_edit_handle == .none) {
                focusField(.width);
                redraw();
                return 0;
            }
            if (wParam == win32.VK_ESCAPE) {
                if (g_dragging or g_edit_handle != .none) _ = win32.ReleaseCapture();
                finish(true);
            } else if (wParam == win32.VK_RETURN and g_edit_mode) {
                if (g_edit_handle != .none) _ = win32.ReleaseCapture();
                finish(false);
            }
            return 0;
        },
        win32.WM_CAPTURECHANGED => {
            // Capture stolen by something else mid-drag (e.g. alt-tab): treat as a cancel so the overlay never gets stuck.
            if (g_edit_mode) {
                // The edited rect stays put; only the active drag or button press ends.
                g_edit_handle = .none;
                g_button_pressed = null;
            } else if (g_dragging) {
                finish(true);
            }
            return 0;
        },
        else => return win32.DefWindowProcA(hwnd, msg, wParam, lParam),
    }
}
