//! Draws what the History, Map and Intel panels share, so they can't drift apart: their fonts, header, footer buttons, frame and text.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const panel_window = @import("../platform/panel_window.zig");
const display_mod = @import("../config/display.zig");
const list_look = @import("list_look.zig");
const panel_look = @import("panel_look.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");

const Canvas = pixel_buffer.Canvas;
const DisplayConfig = display_mod.DisplayConfig;
const PanelWindow = panel_window.PanelWindow;

pub const MAX_TEXT_LENGTH: usize = 160;

pub const Text = struct {
    name_font: win32.HFONT,
    small_font: win32.HFONT,
    name_height: i32,
    small_height: i32,
};

/// One footer button, drawn filled and bright while lit.
pub const Button = struct {
    /// Borrowed for the call it's passed to.
    label: []const u8,
    is_lit: bool,
};

/// Every panel uses the History Panel's font, so they match.
pub fn ensureFonts(panel: *PanelWindow, display: *const DisplayConfig) !void {
    try panel.ensureFont("panel", display.notifInfoPanelFontName, display.notifInfoPanelFontSize, display.notifInfoPanelFontWeight);
    try panel.ensureSmallFont("panel small", display.notifInfoPanelFontName, list_look.smallFontSize(display.notifInfoPanelFontSize), display.notifInfoPanelFontWeight);
}

pub fn hashFonts(hasher: *std.hash.Wyhash, display: *const DisplayConfig) void {
    hasher.update(display.notifInfoPanelFontName);
    hasher.update(std.mem.asBytes(&display.notifInfoPanelFontSize));
    hasher.update(std.mem.asBytes(&display.notifInfoPanelFontWeight));
}

/// What to pass restoreFont once drawing is done, as a font still selected into the DC can't be deleted when the settings change.
pub fn selectFont(panel: *const PanelWindow, dc: win32.HDC) ?win32.HANDLE {
    return if (panel.font.handle) |font| win32.SelectObject(dc, font) else null;
}

pub fn restoreFont(dc: win32.HDC, old_font: ?win32.HANDLE) void {
    if (old_font) |font| _ = win32.SelectObject(dc, font);
}

/// Null if a font couldn't be created, which leaves the panel without text; `name_font` is left selected.
pub fn textOf(panel: *const PanelWindow, dc: win32.HDC) ?Text {
    const name_font = panel.font.handle orelse return null;
    const small_font = panel.small_font.handle orelse return null;
    _ = win32.SelectObject(dc, small_font);
    const small_height = lineHeight(dc);
    _ = win32.SelectObject(dc, name_font);
    return .{ .name_font = name_font, .small_font = small_font, .name_height = lineHeight(dc), .small_height = small_height };
}

/// The header and footer backgrounds and dividers, over anything that reached past the panel's body; null `footer_top` for no footer.
pub fn fillBars(canvas: Canvas, header_height: i32, footer_top: ?i32) void {
    const width = canvas.width;
    pixel_buffer.fillRect(canvas, 0, 0, width, @intCast(header_height), list_look.PANEL);
    pixel_buffer.fillRect(canvas, 0, @intCast(header_height - 1), width, 1, list_look.DIVIDER);
    const top = footer_top orelse return;
    pixel_buffer.fillRect(canvas, 0, @intCast(top), width, canvas.height -| @as(usize, @intCast(top)), list_look.PANEL);
    pixel_buffer.fillRect(canvas, 0, @intCast(top), width, 1, list_look.DIVIDER);
}

pub fn fillButtons(canvas: Canvas, buttons: []const Button, panel_width: i32, footer_top: i32, button_height: i32) void {
    for (buttons, 0..) |button, index| {
        if (!button.is_lit) continue;
        const span = panel_look.buttonSpan(panel_width, buttons.len, index);
        pixel_buffer.fillRoundedRect(canvas, @intCast(span.left), @intCast(footer_top + panel_look.BUTTON_GAP), @intCast(span.right - span.left), @intCast(button_height), panel_look.BUTTON_RADIUS, panel_look.BUTTON_ON);
    }
}

/// `title` on the left, and `status`, if any, on the right.
pub fn drawHeader(dc: win32.HDC, text: Text, header_height: i32, panel_width: i32, title: []const u8, status: ?[]const u8) void {
    _ = win32.SelectObject(dc, text.small_font);
    const y = @divTrunc(header_height - text.small_height, 2);
    drawLine(dc, title, list_look.PADDING_X, y, list_look.MUTED);
    if (status) |right_text| drawLine(dc, right_text, panel_width - list_look.PADDING_X - textWidth(dc, right_text), y, list_look.MUTED);
}

/// Each label centred in its button, or cut to fit.
pub fn drawButtonLabels(dc: win32.HDC, text: Text, buttons: []const Button, panel_width: i32, footer_top: i32, button_height: i32) void {
    _ = win32.SelectObject(dc, text.small_font);
    const y = footer_top + panel_look.BUTTON_GAP + @divTrunc(button_height - text.small_height, 2);
    for (buttons, 0..) |button, index| {
        const span = panel_look.buttonSpan(panel_width, buttons.len, index);
        const label_color = if (button.is_lit) list_look.NAME else list_look.MUTED;
        const label_width = textWidth(dc, button.label);
        const span_width = span.right - span.left;
        if (label_width <= span_width) {
            drawLine(dc, button.label, span.left + @divTrunc(span_width - label_width, 2), y, label_color);
        } else {
            _ = drawFitted(dc, button.label, span.left, y, label_color, span_width);
        }
    }
}

/// The last of a frame's drawing: GDI text's alpha, then the rounded border over it all.
pub fn finish(canvas: Canvas) void {
    pixel_buffer.fixTextAlpha(canvas);
    pixel_buffer.drawRoundedFrame(canvas, list_look.CORNER_RADIUS, list_look.BORDER);
}

/// Ignores `color`'s alpha byte.
pub fn drawLine(dc: win32.HDC, text: []const u8, x: i32, y: i32, color: u32) void {
    gdi_overlay.drawText(MAX_TEXT_LENGTH, dc, x, y, text, color & 0x00FF_FFFF);
}

/// UTF-8, as chat can be; cut short with "..." to fit `max_width` pixels; returns the width drawn.
pub fn drawFitted(dc: win32.HDC, text: []const u8, x: i32, y: i32, color: u32, max_width: i32) i32 {
    var out: [MAX_TEXT_LENGTH:0]u8 = undefined;
    const fitted = gdi_overlay.truncateUtf8ToFit(MAX_TEXT_LENGTH, dc, &out, text, @intCast(@max(0, max_width)));
    gdi_overlay.drawTextUtf8(MAX_TEXT_LENGTH, dc, x, y, fitted, color & 0x00FF_FFFF);
    return gdi_overlay.measureTextSizeUtf8(MAX_TEXT_LENGTH, dc, fitted).cx;
}

pub fn lineHeight(dc: win32.HDC) i32 {
    return gdi_overlay.measureTextSize(MAX_TEXT_LENGTH, dc, "Ag").cy;
}

pub fn textWidth(dc: win32.HDC, text: []const u8) i32 {
    return @intCast(gdi_overlay.measureTextWidth(MAX_TEXT_LENGTH, dc, text));
}
