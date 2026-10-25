//! The configuration window's Appearance tab: how clients are shown, then that mode's settings, texts and system colours; main thread only.
const ui = @import("ui");
const win32 = @import("../../../platform/win32.zig");
const config = @import("../../../config.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const status = @import("../status.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const client_list = @import("client_list.zig");
const text_overlays = @import("text_overlays.zig");
const system_colors = @import("system_colors.zig");
const log = @import("../../../log.zig");

const Text = ui.component.Text;
const ThumbnailRef = session.Ref(config.ThumbnailConfig);
const DisplayRef = session.Ref(config.DisplayConfig);
const slog = log.Scoped("dialog_knots");

/// The boxes can go up to the setting's own maximum.
const MAX_SIZE_SLIDER = 1280;

/// The first matches a running client; the last is whatever the size boxes say.
const RATIOS = [_]Ratio{
    .{ .label = "Match EVE", .ratio = null },
    .{ .label = "16:9", .ratio = 16.0 / 9.0 },
    .{ .label = "16:10", .ratio = 16.0 / 10.0 },
    .{ .label = "21:9", .ratio = 43.0 / 18.0 },
    .{ .label = "4:3", .ratio = 4.0 / 3.0 },
    .{ .label = "Custom", .ratio = null },
};
const RATIO_LABELS = blk: {
    var names: [RATIOS.len][]const u8 = undefined;
    for (RATIOS, &names) |ratio, *name| name.* = ratio.label;
    break :blk names;
};
const MATCH_CLIENT_INDEX = 0;
const CUSTOM_INDEX = RATIOS.len - 1;

const Ratio = struct { label: []const u8, ratio: ?f32 };

/// One border state's row: its label and hint, and the ThumbnailConfig fields it binds.
const BorderFields = struct {
    label: []const u8,
    hint: []const u8,
    show_field: []const u8,
    width_field: []const u8,
    style_field: []const u8,
    color_field: []const u8,
};

const SliderShape = struct { width: i32, height: i32, ratio: f32 };

/// The exact ratio the size slider last applied, reused while the size is still what it set, so rounding can't drift the shape.
var g_slider_shape: ?SliderShape = null;

pub fn show(context: *ui.Frame) !void {
    const thumbnail = session.profile().child("thumbnail");
    const display = session.profile().child("display");
    try displayMode(context, display);
    const view_mode = display.get("viewMode");
    if (view_mode.showsThumbnails()) {
        try text_overlays.show(context);
        try dimensions(context, thumbnail);
        try borders(context, thumbnail);
        try visibility(context, thumbnail);
    }
    if (view_mode.showsClientList()) try client_list.show(context, display);
    if (view_mode.showsThumbnails() or view_mode.showsClientList()) try system_colors.show(context);
}

fn dimensions(context: *ui.Frame, thumbnail: ThumbnailRef) !void {
    const section = try widgets.openSection(context, "Dimensions", "The pixel size each thumbnail is rendered at.", &style.section);
    try aspectRatio(context, thumbnail);

    const row = try widgets.openBinding(context, .str("knots.thumbnails.size"), "Thumbnail Size");
    var width: f32 = @floatFromInt(thumbnail.get("width"));
    const ratio = sliderRatio(thumbnail);
    // Stops where either side hits its bound, or saving clamps that side alone and breaks the ratio.
    const min_width = @max(@as(f32, config.ThumbnailConfig.WIDTH[0]), @as(f32, config.ThumbnailConfig.HEIGHT[0]) * ratio);
    const max_width = @max(min_width, @min(@as(f32, MAX_SIZE_SLIDER), @as(f32, config.ThumbnailConfig.HEIGHT[1]) * ratio));
    if (try widgets.slider(context, .str("knots.thumbnails.size.slider"), &width, min_width, max_width, 1)) {
        const new_width: i32 = @intFromFloat(@round(width));
        const new_height: i32 = @intFromFloat(@round(width / ratio));
        thumbnail.setFields(.{ .width = new_width, .height = new_height });
        // Read back, since validation may have clamped either side.
        g_slider_shape = .{ .width = thumbnail.get("width"), .height = thumbnail.get("height"), .ratio = ratio };
    }
    try bind.unitNumberBox(context, thumbnail, "width", "px", .{});
    try context.e(Text{ .selectable = false, .key = .str("knots.thumbnails.size.x"), .content = "\u{00D7}", .style = &style.muted_text });
    try bind.unitNumberBox(context, thumbnail, "height", "px", .{});
    try row.close(context);
    try widgets.hintText(context, .src(@src()), "The slider keeps the shape; type in the boxes for any size.");
    try section.close(context);
}

/// The slider's last ratio while the size is still what it set, else the size's own.
fn sliderRatio(thumbnail: ThumbnailRef) f32 {
    const width = thumbnail.get("width");
    const height = thumbnail.get("height");
    if (g_slider_shape) |shape| {
        if (shape.width == width and shape.height == height) return shape.ratio;
    }
    return @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(@max(height, 1)));
}

/// Picking a ratio keeps the width and fits the height to it; Custom leaves the size as typed.
fn aspectRatio(context: *ui.Frame, thumbnail: ThumbnailRef) !void {
    const row = try widgets.openBinding(context, .str("knots.thumbnails.ratio"), "Aspect Ratio");
    const picked = try widgets.segmented(context, .str("knots.thumbnails.ratio.options"), &RATIO_LABELS, currentRatio(thumbnail.get("width"), thumbnail.get("height")));
    try row.close(context);
    try widgets.hintText(context, .src(@src()), "Match EVE copies the shape of an open EVE window.");

    const index = picked orelse return;
    const width: f32 = @floatFromInt(thumbnail.get("width"));
    const ratio: f32 = if (index == MATCH_CLIENT_INDEX) clientRatio() orelse {
        status.show(.info, "No EVE client is open to match; open one and pick this again", .{});
        return;
    } else RATIOS[index].ratio orelse return;
    thumbnail.set("height", @intFromFloat(@round(width / ratio)));
}

/// The preset the size already has, give or take rounding; Custom when none fits.
fn currentRatio(width: i32, height: i32) usize {
    for (RATIOS, 0..) |preset, index| {
        const ratio = preset.ratio orelse continue;
        const fitted: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(width)) / ratio));
        if (@abs(fitted - height) <= 1) return index;
    }
    return CUSTOM_INDEX;
}

/// The first open, non-minimized client's game-area ratio.
fn clientRatio() ?f32 {
    const scout_ptr = &session.runningApp().scout;
    for (scout_ptr.getWindows()) |window| {
        // A minimized window's client area reads as 0x0.
        if (!window.is_eve_client or win32.isWindowIconic(window.hwnd)) continue;
        var rect: win32.RECT = undefined;
        if (!win32.toBool(win32.GetClientRect(window.hwnd, &rect))) {
            slog.debug("Failed to read a client's size to match its shape: error {d}", .{win32.GetLastError()});
            continue;
        }
        const width = rect.right - rect.left;
        const height = rect.bottom - rect.top;
        if (width > 0 and height > 0) return @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    }
    return null;
}

fn borders(context: *ui.Frame, thumbnail: ThumbnailRef) !void {
    const section = try widgets.openSection(context, "Borders", "Draw a styled border around thumbnails based on their focus state.", &style.section);
    const uses_unique = thumbnail.get("useUniqueCharacterBorderColors");
    try borderRow(context, thumbnail, .{
        .label = "Focused Border",
        .hint = "The border on the thumbnail of the client you're in.",
        .show_field = "showBorderWhenFocused",
        .width_field = "borderWidth",
        .style_field = "borderStyle",
        .color_field = "borderColor",
    }, uses_unique);
    try borderRow(context, thumbnail, .{
        .label = "Inactive Border",
        .hint = "The border on every other thumbnail.",
        .show_field = "showBorderWhenInactive",
        .width_field = "inactiveBorderWidth",
        .style_field = "inactiveBorderStyle",
        .color_field = "inactiveBorderColor",
    }, false);
    const unique_group = try widgets.openGroup(context, .src(@src()), thumbnail.get("showBorderWhenFocused"));
    try bind.toggle(context, thumbnail, "useUniqueCharacterBorderColors", "Unique Character Focused Border Colors");
    try widgets.hintText(context, .src(@src()), "Each character gets its own color, in place of the Focused Border color.");
    try unique_group.close(context);
    try section.close(context);
}

/// The state's width, style and colour, then its switch last so it lines up with the other rows' switches.
fn borderRow(context: *ui.Frame, thumbnail: ThumbnailRef, comptime fields: BorderFields, is_color_overridden: bool) !void {
    const row = try widgets.openBinding(context, .str("knots.border.row:" ++ fields.label), fields.label);
    const settings = try widgets.openInlineGroup(context, .str("knots.border.settings:" ++ fields.label), thumbnail.get(fields.show_field));
    try bind.unitNumberBox(context, thumbnail, fields.width_field, "px", .{});
    try bind.choiceBox(context, thumbnail, fields.style_field);
    // Unique colours replace it per character.
    const color = try widgets.openInlineGroup(context, .str("knots.border.color:" ++ fields.label), !is_color_overridden);
    try bind.colorBox(context, thumbnail, fields.color_field);
    try color.close(context);
    try settings.close(context);
    try bind.toggle(context, thumbnail, fields.show_field, "");
    try row.close(context);
    try widgets.hintText(context, .str("knots.border.hint:" ++ fields.label), fields.hint);
}

fn visibility(context: *ui.Frame, thumbnail: ThumbnailRef) !void {
    const section = try widgets.openSection(context, "Visibility", "How see-through thumbnails are, and when they're hidden automatically.", &style.section);
    try bind.slider(context, thumbnail, "thumbnailOpacity", "Opacity", .{ .display = .percent_of_255 });
    try widgets.hintText(context, .src(@src()), "Lower lets you see through thumbnails.");
    try bind.toggle(context, thumbnail, "applyOpacityToOverlayTexts", "Apply Opacity to Overlay Texts");
    try widgets.hintText(context, .src(@src()), "When off, texts stay solid while the thumbnail fades.");
    try bind.toggle(context, thumbnail, "activeThumbnailHidden", "Hide Active Thumbnail");
    try widgets.hintText(context, .src(@src()), "Hides the thumbnail of the client you're in.");
    try bind.toggle(context, thumbnail, "hideWhenNoEveFocus", "Hide When No EVE Focus");
    try widgets.hintText(context, .src(@src()), "Thumbnails come back when you return to EVE.");
    const delay = try widgets.openGroup(context, .src(@src()), thumbnail.get("hideWhenNoEveFocus"));
    try bind.number(context, thumbnail, "hideDebounceMs", "Hide Delay", .{ .shows_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "Waits this long, so quick switches don't flicker.");
    try delay.close(context);
    try section.close(context);
}

/// Picks which of the tab's other sections are drawn, and whether the Placement tab is offered.
fn displayMode(context: *ui.Frame, display: DisplayRef) !void {
    const section = try widgets.openSection(context, "Display Mode", "How clients are shown. With None, hotkeys and alerts keep working.", &style.section);
    try bind.segmented(context, display, "viewMode", "Show Clients As", &.{ "Thumbnails", "Client List", "Both", "None" });
    try widgets.hintText(context, .src(@src()), "Client List is lighter on your PC than Thumbnails.");
    if (display.get("viewMode") == .ThumbnailsAndList) try widgets.hintText(context, .src(@src()), "The list follows the thumbnails' colors and hiding.");
    try section.close(context);
}
