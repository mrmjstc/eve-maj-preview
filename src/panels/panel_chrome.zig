//! Draws what the Client List and the History, Map and Intel panels share, so they can't drift apart: their fonts, header, frame and text.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const panel_window = @import("../platform/panel_window.zig");
const panels = @import("../config/panels.zig");
const glyphs = @import("glyphs.zig");
const list_look = @import("list_look.zig");
const palette = @import("palette.zig");
const panel_header = @import("panel_header.zig");
const box = @import("../util/box.zig");
const pixel_buffer = @import("../util/pixel_buffer.zig");

const Box = box.Box;
const Canvas = pixel_buffer.Canvas;
const HistoryPanelConfig = panels.HistoryPanelConfig;
const PanelWindow = panel_window.PanelWindow;

pub const MAX_TEXT_LENGTH: usize = 160;
const HEADER_BUTTON_RADIUS: usize = palette.RADIUS;
/// Between a header's title and count, and between a summary's runs.
const HEADER_TEXT_GAP: i32 = 6;
const PILL_PADDING_X: i32 = 5;
const PILL_RADIUS: usize = palette.SMALL_RADIUS;
const SUMMARY_DOT_RADIUS: i32 = 3;

pub const Text = struct {
    name_font: win32.HFONT,
    small_font: win32.HFONT,
    name_height: i32,
    small_height: i32,
};

/// The header's fonts: the configuration window's, whatever font the panel's rows use.
pub const HeaderFonts = struct {
    title: gdi_overlay.CachedFont = .{},
    small: gdi_overlay.CachedFont = .{},

    pub fn ensure(self: *HeaderFonts, allocator: std.mem.Allocator) !void {
        try self.title.ensure(allocator, "panel header", palette.SEMIBOLD_FACE, palette.FONT_SIZE, .Regular);
        try self.small.ensure(allocator, "panel header small", palette.FACE, palette.SMALL_FONT_SIZE, .Regular);
    }

    pub fn deinit(self: *HeaderFonts, allocator: std.mem.Allocator) void {
        self.title.deinit(allocator);
        self.small.deinit(allocator);
    }
};

/// What a panel's header shows.
pub const Header = struct {
    layout: panel_header.Layout,
    /// Borrowed for the draw.
    title: []const u8,
    /// Muted after the title, such as a count; borrowed for the draw, empty for none.
    count: []const u8 = "",
    is_collapsed: bool,
    hovered: ?panel_header.Hit,
    /// Drawn in `accent`, as pin is while the panel stays on top and mute while sounds are off.
    lit: std.EnumSet(panel_header.Action) = .empty,
    accent: u32,
};

/// A coloured stretch of a collapsed header's summary.
pub const Run = struct {
    /// Borrowed for the draw; UTF-8.
    text: []const u8,
    color: u32,
    /// Behind the text, as a pill; null for none.
    fill: ?u32 = null,
};

/// Every panel uses the History Panel's font, so they match.
pub fn ensureFonts(panel: *PanelWindow, history_settings: *const HistoryPanelConfig) !void {
    try panel.ensureFont("panel", history_settings.fontName, history_settings.fontSize, history_settings.fontWeight);
    try panel.ensureSmallFont("panel small", history_settings.fontName, list_look.smallFontSize(history_settings.fontSize), history_settings.fontWeight);
}

pub fn hashFonts(hasher: *std.hash.Wyhash, history_settings: *const HistoryPanelConfig) void {
    hasher.update(history_settings.fontName);
    hasher.update(std.mem.asBytes(&history_settings.fontSize));
    hasher.update(std.mem.asBytes(&history_settings.fontWeight));
}

/// What to pass restoreFont once drawing is done, as a font still selected into the DC can't be deleted when the settings change.
pub fn selectFont(panel: *const PanelWindow, dc: win32.HDC) ?win32.HANDLE {
    return if (panel.font.handle) |font| win32.SelectObject(dc, font) else null;
}

pub fn restoreFont(dc: win32.HDC, old_font: ?win32.HANDLE) void {
    if (old_font) |font| _ = win32.SelectObject(dc, font);
}

/// Behind a panel's rows; the header draws over it.
pub fn fillBody(canvas: Canvas) void {
    pixel_buffer.fillRect(canvas, 0, 0, canvas.width, canvas.height, list_look.PANEL);
}

/// The bar, its divider while expanded, the hovered button's fill and the glyphs.
pub fn fillHeader(canvas: Canvas, header: *const Header) void {
    const layout = &header.layout;
    pixel_buffer.fillRect(canvas, 0, 0, canvas.width, @intCast(panel_header.HEIGHT), palette.CHROME);
    if (!header.is_collapsed) pixel_buffer.fillRect(canvas, 0, @intCast(panel_header.HEIGHT - 1), canvas.width, 1, list_look.DIVIDER);
    if (header.hovered) |hit| {
        if (layout.boxOf(hit)) |lit_box| pixel_buffer.fillRoundedRect(canvas, @intCast(lit_box.left), @intCast(lit_box.top), @intCast(lit_box.right - lit_box.left), @intCast(lit_box.bottom - lit_box.top), HEADER_BUTTON_RADIUS, palette.SURFACE);
    }
    const chevron_glyph: glyphs.Glyph = if (header.is_collapsed) .chevron_right else .chevron_down;
    drawGlyphIn(canvas, layout.chevron, chevron_glyph, if (panel_header.sameHit(header.hovered, .chevron)) palette.TEXT else palette.MUTED);
    for (layout.buttons[0..layout.button_count], layout.actions[0..layout.button_count]) |button, action| {
        const glyph_color = if (header.lit.contains(action)) header.accent else if (panel_header.sameHit(header.hovered, .{ .button = action })) palette.TEXT else palette.MUTED;
        drawGlyphIn(canvas, button, actionGlyph(action, header.lit.contains(action)), glyph_color);
    }
}

/// The title, then its count; returns where a collapsed panel's summary starts, a gap after them.
pub fn drawHeaderText(dc: win32.HDC, fonts: *const HeaderFonts, header: *const Header) i32 {
    const layout = &header.layout;
    const title_font = fonts.title.handle orelse return layout.title_left;
    _ = win32.SelectObject(dc, title_font);
    const title_y = @divTrunc(panel_header.HEIGHT - lineHeight(dc), 2);
    var x = layout.title_left + drawFitted(dc, header.title, layout.title_left, title_y, palette.TEXT, layout.content_right - layout.title_left) + HEADER_TEXT_GAP;
    if (header.count.len == 0) return x;
    const small_font = fonts.small.handle orelse return x;
    _ = win32.SelectObject(dc, small_font);
    x += drawFitted(dc, header.count, x, @divTrunc(panel_header.HEIGHT - lineHeight(dc), 2), palette.MUTED, layout.content_right - x) + HEADER_TEXT_GAP;
    return x;
}

/// A collapsed panel's summary from `left` to `right` in the small header font, a gap between runs, cut short where it runs out of room.
pub fn drawSummary(canvas: Canvas, dc: win32.HDC, fonts: *const HeaderFonts, left: i32, right: i32, runs: []const Run) void {
    const small_font = fonts.small.handle orelse return;
    _ = win32.SelectObject(dc, small_font);
    const text_height = lineHeight(dc);
    const y = @divTrunc(panel_header.HEIGHT - text_height, 2);
    var x = left;
    for (runs) |run| {
        if (run.text.len == 0) continue;
        if (x >= right) return;
        const inset: i32 = if (run.fill != null) PILL_PADDING_X else 0;
        if (run.fill) |fill| {
            const pill_width = @min(wideTextWidth(dc, run.text) + 2 * inset, right - x);
            pixel_buffer.fillRoundedRect(canvas, @intCast(x), @intCast(y - 1), @intCast(pill_width), @intCast(text_height + 2), PILL_RADIUS, fill);
        }
        x += drawFitted(dc, run.text, x + inset, y, run.color, right - x - 2 * inset) + 2 * inset + HEADER_TEXT_GAP;
    }
}

/// A dot before a summary, as the active client has; returns where text after it starts.
pub fn drawSummaryDot(canvas: Canvas, left: i32, dot_color: u32) i32 {
    pixel_buffer.fillCircle(canvas, left + SUMMARY_DOT_RADIUS, @divTrunc(panel_header.HEIGHT, 2), @floatFromInt(SUMMARY_DOT_RADIUS), dot_color);
    return left + 2 * SUMMARY_DOT_RADIUS + HEADER_TEXT_GAP;
}

/// What a header's pixels depend on, for a panel's render signature.
pub fn hashHeader(hasher: *std.hash.Wyhash, header: *const Header) void {
    hasher.update(header.title);
    hasher.update(header.count);
    hasher.update(std.mem.asBytes(&header.is_collapsed));
    hasher.update(std.mem.asBytes(&header.lit.bits.mask));
    hasher.update(std.mem.asBytes(&header.accent));
    const hovered = header.hovered orelse return;
    switch (hovered) {
        .chevron => hasher.update("chevron"),
        .button => |action| hasher.update(@tagName(action)),
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

/// Like drawLine, for text that may not be ASCII.
pub fn drawWideLine(dc: win32.HDC, text: []const u8, x: i32, y: i32, color: u32) void {
    gdi_overlay.drawTextUtf8(MAX_TEXT_LENGTH, dc, x, y, text, color & 0x00FF_FFFF);
}

/// UTF-8, as chat can be; cut short with "..." to fit `max_width` pixels; returns the width drawn.
pub fn drawFitted(dc: win32.HDC, text: []const u8, x: i32, y: i32, color: u32, max_width: i32) i32 {
    var out: [MAX_TEXT_LENGTH:0]u8 = undefined;
    const fitted = gdi_overlay.truncateUtf8ToFit(MAX_TEXT_LENGTH, dc, &out, text, @intCast(@max(0, max_width)));
    drawWideLine(dc, fitted, x, y, color);
    return gdi_overlay.measureTextSizeUtf8(MAX_TEXT_LENGTH, dc, fitted).cx;
}

pub fn lineHeight(dc: win32.HDC) i32 {
    return gdi_overlay.measureTextSize(MAX_TEXT_LENGTH, dc, "Ag").cy;
}

pub fn textWidth(dc: win32.HDC, text: []const u8) i32 {
    return @intCast(gdi_overlay.measureTextWidth(MAX_TEXT_LENGTH, dc, text));
}

/// Like textWidth, for text that may not be ASCII, as intel and alliance names can be.
pub fn wideTextWidth(dc: win32.HDC, text: []const u8) i32 {
    return gdi_overlay.measureTextSizeUtf8(MAX_TEXT_LENGTH, dc, text).cx;
}

fn drawGlyphIn(canvas: Canvas, glyph_box: Box, glyph: glyphs.Glyph, glyph_color: u32) void {
    const inset = @divTrunc(panel_header.BUTTON_SIZE - glyphs.SIZE, 2);
    glyphs.draw(canvas, glyph, glyph_box.left + inset, glyph_box.top + inset, glyph_color);
}

/// Mute shows what it's doing: a struck speaker while lit.
fn actionGlyph(action: panel_header.Action, is_lit: bool) glyphs.Glyph {
    return switch (action) {
        .pin => .pin,
        .clear => .delete,
        .mute => if (is_lit) .muted else .speaker,
        .menu => .more,
    };
}
