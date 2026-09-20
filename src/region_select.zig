const std = @import("std");
const win32 = @import("win32.zig");
const gdi_overlay = @import("gdi_overlay.zig");
const protocol = @import("protocol.zig");
const color_mod = @import("color.zig");
const log = @import("log.zig");
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
const HANDLE_HIT_PX: u32 = 6;
const HANDLE_SIZE: i32 = 8;
const HANDLE_COLOR: u32 = 0xFFFFFFFF;
const LABEL_PADDING_X: usize = 10;
const LABEL_PADDING_Y: usize = 4;
const LABEL_CURSOR_OFFSET: i32 = 16;

// Save/Cancel mirror the config dialog's buttons (config_dialog.css): sizes are CSS px scaled by monitor DPI, colors are its palette.
const BUTTON_WIDTH: i32 = 80;
const BUTTON_HEIGHT: i32 = 28;
const BUTTON_GAP: i32 = 8;
const BUTTON_CHAR_WIDTH: i32 = 8;
const BUTTON_TEXT_PADDING: i32 = 12;
const BUTTON_MARGIN: i32 = 8;
const BUTTON_RADIUS: i32 = 3;
const BUTTON_FONT_PX: i32 = 12;
const ButtonFont = struct { name: [:0]const u8, weight: c_int };
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

pub const LabelStyle = struct {
    font: ?win32.HFONT,
    color: u32,
};

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
var g_label_style: LabelStyle = .{ .font = null, .color = 0xFFFFFFFF };
var g_labels = protocol.RegionSelectLabels{};

const Handle = enum { none, move, left, right, top, bottom, top_left, top_right, bottom_left, bottom_right };
const Button = enum { save, cancel };

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

pub fn registerWindowClass(instance: win32.HINSTANCE) !void {
    if (g_window_class_registered) return;
    g_cross_cursor = win32.LoadCursorA(null, win32.IDC_CROSS);
    g_arrow_cursor = win32.LoadCursorA(null, win32.IDC_ARROW);
    g_size_we_cursor = win32.LoadCursorA(null, win32.IDC_SIZEWE);
    g_size_ns_cursor = win32.LoadCursorA(null, win32.IDC_SIZENS);
    g_size_nwse_cursor = win32.LoadCursorA(null, win32.IDC_SIZENWSE);
    g_size_nesw_cursor = win32.LoadCursorA(null, win32.IDC_SIZENESW);
    g_size_all_cursor = win32.LoadCursorA(null, win32.IDC_SIZEALL);
    g_hand_cursor = win32.LoadCursorA(null, win32.IDC_HAND);
    try gdi_overlay.registerWindowClass(instance, wndProc, WINDOW_CLASS_NAME, null);
    g_window_class_registered = true;
}

/// Called once the overlay closes, whether the drag was committed or cancelled.
pub fn setOnFinishedCallback(cb: ?*const fn () void) void {
    g_on_finished = cb;
}

/// Starts (or resets, if already in progress) the drag-to-select overlay; publishes the result via
/// protocol.publishRegionSelectResult. accent_color is 0xAARRGGBB, forced fully opaque.
/// With `edit_region`, that region's edges are adjusted instead of dragging a new one.
pub fn start(instance: win32.HINSTANCE, accent_color: u32, label_style: LabelStyle, edit_region: ?win32.RECT, labels: protocol.RegionSelectLabels) void {
    g_border_color = accent_color | 0xFF000000;
    g_label_style = label_style;
    g_labels = labels;

    const left: i32 = win32.GetSystemMetrics(win32.SM_XVIRTUALSCREEN);
    const top: i32 = win32.GetSystemMetrics(win32.SM_YVIRTUALSCREEN);
    const width: i32 = win32.GetSystemMetrics(win32.SM_CXVIRTUALSCREEN);
    const height: i32 = win32.GetSystemMetrics(win32.SM_CYVIRTUALSCREEN);
    g_virtual_screen = .{ .left = left, .top = top, .right = left + width, .bottom = top + height };
    g_bounds = g_virtual_screen;
    g_dragging = false;
    g_edit_handle = .none;

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
        ) orelse {
            slog.err("Failed to create region-select overlay window", .{});
            return;
        };
    }

    const hwnd = g_hwnd.?;
    ensureBitmap(width, height);
    g_last_redraw = win32.Ticks.now();
    redraw();

    _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
    grabForegroundFocus(hwnd);
}

/// Plain SetForegroundWindow (input.zig's forceSetForegroundWindow) only works when the calling process just received user input, which isn't true here since StartRegionSelect arrives over WM_COPYDATA - Windows' foreground-lock would otherwise silently eat it, leaving Escape going nowhere.
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
fn drawRegion(bmp: *const gdi_overlay.OverlayBitmap, rect: win32.RECT, fill: u32, border: u32) void {
    const w = win32.rectWidth(rect);
    const h = win32.rectHeight(rect);
    if (w <= 0 or h <= 0) return;
    const local_x = rect.left - g_virtual_screen.left;
    const local_y = rect.top - g_virtual_screen.top;
    const uw: usize = @intCast(w);
    const uh: usize = @intCast(h);
    gdi_overlay.fillRect(bmp.pixels, bmp.width, bmp.height, @intCast(local_x), @intCast(local_y), uw, uh, fill);
    gdi_overlay.drawRectOutline(bmp.pixels, bmp.width, bmp.height, local_x, local_y, uw, uh, BORDER_THICKNESS, border);
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

fn drawSizeLabel(bmp: *const gdi_overlay.OverlayBitmap, sel: win32.RECT) void {
    const font = g_label_style.font orelse return;

    var text_buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "{d} x {d}", .{ win32.rectWidth(sel), win32.rectHeight(sel) }) catch return;

    const old_font = win32.SelectObject(bmp.mem_dc, font);
    defer {
        if (old_font) |of| _ = win32.SelectObject(bmp.mem_dc, of);
    }

    const text_size = gdi_overlay.measureTextSize(text_buf.len, bmp.mem_dc, text);
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
    gdi_overlay.fillRect(bmp.pixels, bmp.width, bmp.height, local_x, local_y, @intCast(label_w), @intCast(label_h), gdi_overlay.HINT_BG_COLOR);
    gdi_overlay.drawText(text_buf.len, bmp.mem_dc, @intCast(local_x + LABEL_PADDING_X), @intCast(local_y + LABEL_PADDING_Y), text, g_label_style.color);
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
        r.left = std.math.clamp(r.left + dx, vs.left, vs.right - w);
        r.top = std.math.clamp(r.top + dy, vs.top, vs.bottom - h);
        r.right = r.left + w;
        r.bottom = r.top + h;
    } else {
        const moves_left = g_edit_handle == .left or g_edit_handle == .top_left or g_edit_handle == .bottom_left;
        const moves_right = g_edit_handle == .right or g_edit_handle == .top_right or g_edit_handle == .bottom_right;
        const moves_top = g_edit_handle == .top or g_edit_handle == .top_left or g_edit_handle == .top_right;
        const moves_bottom = g_edit_handle == .bottom or g_edit_handle == .bottom_left or g_edit_handle == .bottom_right;
        if (moves_left) r.left = std.math.clamp(r.left + dx, vs.left, r.right - MIN_DRAG_PX);
        if (moves_right) r.right = std.math.clamp(r.right + dx, r.left + MIN_DRAG_PX, vs.right);
        if (moves_top) r.top = std.math.clamp(r.top + dy, vs.top, r.bottom - MIN_DRAG_PX);
        if (moves_bottom) r.bottom = std.math.clamp(r.bottom + dy, r.top + MIN_DRAG_PX, vs.bottom);
    }
    g_edit_rect = r;
}

fn drawHandle(bmp: *const gdi_overlay.OverlayBitmap, center_x: i32, center_y: i32) void {
    const x = std.math.clamp(center_x - @divTrunc(HANDLE_SIZE, 2), g_bounds.left, g_bounds.right - HANDLE_SIZE);
    const y = std.math.clamp(center_y - @divTrunc(HANDLE_SIZE, 2), g_bounds.top, g_bounds.bottom - HANDLE_SIZE);
    const size: usize = @intCast(HANDLE_SIZE);
    gdi_overlay.fillRect(bmp.pixels, bmp.width, bmp.height, @intCast(x - g_virtual_screen.left), @intCast(y - g_virtual_screen.top), size, size, HANDLE_COLOR);
}

fn drawEditHandles(bmp: *const gdi_overlay.OverlayBitmap, r: win32.RECT) void {
    const center = win32.rectCenter(r);
    const xs = [3]i32{ r.left, center.x, r.right };
    const ys = [3]i32{ r.top, center.y, r.bottom };
    const roomy_w = win32.rectWidth(r) >= HANDLE_SIZE * 4;
    const roomy_h = win32.rectHeight(r) >= HANDLE_SIZE * 4;

    for (ys, 0..) |cy, row| {
        for (xs, 0..) |cx, col| {
            if (row == 1 and col == 1) continue;
            if (col == 1 and !roomy_w) continue;
            if (row == 1 and !roomy_h) continue;
            drawHandle(bmp, cx, cy);
        }
    }
}

fn scaled(css_px: i32) i32 {
    return win32.scalePixels(css_px, g_ui_scale);
}

/// Wide enough for the longer translated label; CJK glyphs count double. Estimated, since layout also runs from hit testing where there's no DC to measure with.
fn buttonWidthCss() i32 {
    var widest: i32 = 0;
    for ([_][]const u8{ protocol.labelText(&g_labels.save), protocol.labelText(&g_labels.cancel) }) |label| {
        var units: i32 = 0;
        for (label) |byte| {
            if ((byte & 0xC0) == 0x80) continue;
            units += if (byte >= 0xE0) 2 else 1;
        }
        widest = @max(widest, units);
    }
    return @max(BUTTON_WIDTH, widest * BUTTON_CHAR_WIDTH + 2 * BUTTON_TEXT_PADDING);
}

/// Save then Cancel, right-aligned under the region; flips above it, or inside its bottom edge, when there's no room below.
fn buttonRects() [2]win32.RECT {
    const width = scaled(buttonWidthCss());
    const height = scaled(BUTTON_HEIGHT);
    const gap = scaled(BUTTON_GAP);
    const margin = scaled(BUTTON_MARGIN);
    const group_width = width * 2 + gap;
    const region = g_edit_rect;

    const x = @max(g_bounds.left + margin, @min(region.right - margin - group_width, g_bounds.right - margin - group_width));
    var y = region.bottom + margin;
    if (y + height > g_bounds.bottom) y = region.top - margin - height;
    if (y < g_bounds.top) y = @max(g_bounds.top, region.bottom - margin - height);

    return .{
        .{ .left = x, .top = y, .right = x + width, .bottom = y + height },
        .{ .left = x + width + gap, .top = y, .right = x + group_width, .bottom = y + height },
    };
}

fn buttonAt(pt: win32.POINT) ?Button {
    if (!g_edit_mode or g_edit_handle != .none) return null;
    const rects = buttonRects();
    inline for (.{ Button.save, Button.cancel }) |button| {
        if (win32.rectContains(rects[@intFromEnum(button)], pt)) return button;
    }
    return null;
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

fn drawButton(bmp: *const gdi_overlay.OverlayBitmap, rect: win32.RECT, label: []const u8, button: Button) void {
    const font = g_button_font orelse g_label_style.font orelse return;
    const hovered = g_button_hover == button or g_button_pressed == button;
    const accent = g_border_color;

    var face = gdi_overlay.ButtonFace{
        .fill = undefined,
        .border = undefined,
        .text_color = undefined,
        .radius = @intCast(scaled(BUTTON_RADIUS)),
        .border_px = @intCast(@max(1, scaled(1))),
    };
    switch (button) {
        .save => if (hovered) {
            face.fill = color_mod.lighten(accent, BUTTON_LIGHTEN_PERCENT);
            face.border = face.fill;
            face.text_color = color_mod.inkFor(accent);
        } else {
            face.fill = BUTTON_BG;
            face.border = accent;
            face.text_color = accent;
        },
        .cancel => {
            face.fill = if (hovered) BUTTON_SURFACE_ALT else BUTTON_SURFACE;
            face.border = if (hovered) accent else BUTTON_BORDER;
            face.text_color = BUTTON_TEXT;
        },
    }

    const local = win32.RECT{
        .left = rect.left - g_virtual_screen.left,
        .top = rect.top - g_virtual_screen.top,
        .right = rect.right - g_virtual_screen.left,
        .bottom = rect.bottom - g_virtual_screen.top,
    };
    gdi_overlay.drawButtonFace(bmp, local, label, font, face);
}

fn drawButtons(bmp: *const gdi_overlay.OverlayBitmap) void {
    if (g_edit_handle != .none) return;
    ensureButtonFonts(bmp.mem_dc);
    const rects = buttonRects();
    drawButton(bmp, rects[@intFromEnum(Button.save)], protocol.labelText(&g_labels.save), .save);
    drawButton(bmp, rects[@intFromEnum(Button.cancel)], protocol.labelText(&g_labels.cancel), .cancel);
}

fn redraw() void {
    const hwnd = g_hwnd orelse return;
    if (g_bitmap == null) return;
    const bmp = &g_bitmap.?;

    gdi_overlay.fillRect(bmp.pixels, bmp.width, bmp.height, 0, 0, bmp.width, bmp.height, DIM_COLOR);

    if (g_edit_mode) {
        drawRegion(bmp, g_edit_rect, HIT_TESTABLE_CLEAR_COLOR, g_border_color);
        drawEditHandles(bmp, g_edit_rect);
        drawButtons(bmp);
        if (g_edit_handle != .none) drawSizeLabel(bmp, g_edit_rect);
    } else if (g_dragging) {
        const sel = normalizedSelection();
        drawRegion(bmp, sel, CLEAR_COLOR, g_border_color);
        if (win32.rectWidth(sel) > 0 and win32.rectHeight(sel) > 0) drawSizeLabel(bmp, sel);
    }

    gdi_overlay.presentLayered(hwnd, bmp, 255);
}

fn maybeRedrawThrottled() void {
    const now = win32.Ticks.now();
    if (now.elapsedSince(g_last_redraw) < REDRAW_THROTTLE_MS) return;
    g_last_redraw = now;
    redraw();
}

fn finish(cancelled: bool) void {
    if (g_hwnd) |hwnd| _ = win32.ShowWindow(hwnd, win32.SW_HIDE);
    g_dragging = false;

    if (g_bitmap) |bmp| bmp.destroy();
    g_bitmap = null;

    if (g_on_finished) |cb| cb();

    const empty_rect = win32.RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (cancelled) {
        protocol.publishRegionSelectResult(.cancelled, empty_rect);
        return;
    }

    const rect = if (g_edit_mode) g_edit_rect else normalizedSelection();
    if (!isBigEnough(rect)) {
        protocol.publishRegionSelectResult(.too_small, empty_rect);
        return;
    }
    protocol.publishRegionSelectResult(.success, rect);
}

fn wndProc(hwnd: win32.HWND, msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.c) win32.LRESULT {
    switch (msg) {
        win32.WM_SETCURSOR => {
            if (g_edit_mode) {
                var pt: win32.POINT = undefined;
                _ = win32.GetCursorPos(&pt);
                const cursor = if (g_edit_handle != .none)
                    cursorForHandle(g_edit_handle)
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
                if (buttonAt(pt)) |button| {
                    g_button_pressed = button;
                    _ = win32.SetCapture(hwnd);
                    redraw();
                    return 0;
                }
                const handle = hitTestEditRect(pt);
                if (handle == .none) return 0;
                g_edit_handle = handle;
                g_edit_grab = pt;
                g_edit_grab_rect = g_edit_rect;
                g_current = pt;
                _ = win32.SetCapture(hwnd);
                redraw();
                return 0;
            }
            g_anchor = pt;
            g_current = pt;
            g_bounds = monitorBoundsAt(pt);
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
            if (g_edit_mode) applyEditDrag(pt);
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
