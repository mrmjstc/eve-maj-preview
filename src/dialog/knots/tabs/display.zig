//! The configuration window's Appearance tab: how clients are shown, then that mode's settings, texts and system colours; main thread only.
const ui = @import("ui");
const win32 = @import("../../../platform/win32.zig");
const config = @import("../../../config.zig");
const scout = @import("../../../clients/scout.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const status = @import("../status.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const client_list = @import("client_list.zig");
const text_overlays = @import("text_overlays.zig");
const system_colors = @import("system_colors.zig");

const Text = ui.component.Text;
const ThumbnailRef = session.Ref(config.ThumbnailConfig);
const DisplayRef = session.Ref(config.DisplayConfig);

const MIN_SIZE_SLIDER = 50;
const MAX_SIZE_SLIDER = 1280;

const Ratio = struct { label: []const u8, ratio: ?f32 };

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

pub fn show(context: *ui.Frame) !void {
    const thumbnail = session.profile().child("thumbnail");
    const display = session.profile().child("display");
    try displayMode(context, display);
    switch (display.get("viewMode")) {
        .Thumbnails => {
            try text_overlays.textOverlays(context);
            try sizeAndOpacity(context, thumbnail);
            try borders(context, thumbnail);
            try visibility(context, thumbnail);
            try system_colors.show(context);
        },
        .ClientList => {
            try client_list.show(context, display);
            try system_colors.show(context);
        },
        .Nothing => {},
    }
}

fn sizeAndOpacity(context: *ui.Frame, thumbnail: ThumbnailRef) !void {
    const section = try widgets.openSection(context, "Size and Opacity", "The pixel size each thumbnail is rendered at, and how see-through it is.", &style.section);
    try aspectRatio(context, thumbnail);

    const row = try widgets.openBinding(context, .str("knots.thumbnails.size"), "Size");
    var width: f32 = @floatFromInt(thumbnail.get("width"));
    const ratio = width / @as(f32, @floatFromInt(@max(thumbnail.get("height"), 1)));
    if (try widgets.slider(context, .str("knots.thumbnails.size.slider"), &width, MIN_SIZE_SLIDER, MAX_SIZE_SLIDER, 1)) {
        thumbnail.set("width", @intFromFloat(@round(width)));
        thumbnail.set("height", @intFromFloat(@round(width / ratio)));
    }
    try bind.numberBox(context, thumbnail, "width", .{});
    try context.e(Text{ .selectable = false, .key = .str("knots.thumbnails.size.x"), .content = "\u{00D7}", .style = &style.muted_text });
    try bind.numberBox(context, thumbnail, "height", .{});
    try row.close(context);
    try widgets.hintText(context, .src(@src()), "Width \u{00D7} height in pixels. The slider keeps the current aspect ratio; type into the boxes for any size.");

    try bind.slider(context, thumbnail, "thumbnailOpacity", "Opacity", .{ .display = .percent_of_255 });
    try bind.toggle(context, thumbnail, "applyOpacityToOverlayTexts", "Apply Opacity to Overlay Texts");
    try widgets.hintText(context, .src(@src()), "Also fades the name/badge/combat/mining/bounty/resource overlay text and backgrounds with the Opacity slider above; otherwise they stay fully opaque.");
    try section.close(context);
}

/// Picking a ratio keeps the width and fits the height to it; Custom leaves the size as typed.
fn aspectRatio(context: *ui.Frame, thumbnail: ThumbnailRef) !void {
    const row = try widgets.openBinding(context, .str("knots.thumbnails.ratio"), "Aspect Ratio");
    const picked = try widgets.segmented(context, .str("knots.thumbnails.ratio.options"), &RATIO_LABELS, currentRatio(thumbnail.get("width"), thumbnail.get("height")));
    try row.close(context);

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
    const scout_ptr = scout.g_scout_ptr orelse return null;
    for (scout_ptr.getWindows()) |window| {
        // A minimized window's client area reads as 0x0.
        if (!window.is_eve_client or win32.isWindowIconic(window.hwnd)) continue;
        var rect: win32.RECT = undefined;
        if (!win32.toBool(win32.GetClientRect(window.hwnd, &rect))) continue;
        const width = rect.right - rect.left;
        const height = rect.bottom - rect.top;
        if (width > 0 and height > 0) return @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    }
    return null;
}

fn borders(context: *ui.Frame, thumbnail: ThumbnailRef) !void {
    const section = try widgets.openSection(context, "Borders", "Draw a styled border around thumbnails based on their focus state.", &style.section);
    const uses_unique = thumbnail.get("useUniqueCharacterBorderColors");
    try borderRow(context, thumbnail, "Focused Border", "showBorderWhenFocused", "borderWidth", "borderStyle", "borderColor", uses_unique);
    try borderRow(context, thumbnail, "Inactive Border", "showBorderWhenInactive", "inactiveBorderWidth", "inactiveBorderStyle", "inactiveBorderColor", false);
    const unique_group = try widgets.openGroup(context, .src(@src()), thumbnail.get("showBorderWhenFocused"));
    try bind.toggle(context, thumbnail, "useUniqueCharacterBorderColors", "Unique Character Focused Border Colors");
    try widgets.hintText(context, .src(@src()), "Auto-generates a color per character name, overriding the Focused Border color above.");
    try unique_group.close(context);
    try section.close(context);
}

/// The state's width, style and colour, then its checkbox last so it lines up with the other rows' checkboxes.
fn borderRow(context: *ui.Frame, thumbnail: ThumbnailRef, comptime label: []const u8, comptime show_field: []const u8, comptime width_field: []const u8, comptime style_field: []const u8, comptime color_field: []const u8, is_color_overridden: bool) !void {
    const row = try widgets.openBinding(context, .str("knots.border.row:" ++ label), label);
    const settings = try widgets.openInlineGroup(context, .str("knots.border.settings:" ++ label), thumbnail.get(show_field));
    try bind.unitNumberBox(context, thumbnail, width_field, "px", .{});
    try bind.choiceBox(context, thumbnail, style_field);
    // Unique colours replace it per character.
    const color = try widgets.openInlineGroup(context, .str("knots.border.color:" ++ label), !is_color_overridden);
    try bind.colorBox(context, thumbnail, color_field);
    try color.close(context);
    try settings.close(context);
    try bind.toggle(context, thumbnail, show_field, "");
    try row.close(context);
}

fn visibility(context: *ui.Frame, thumbnail: ThumbnailRef) !void {
    const section = try widgets.openSection(context, "Visibility", "When thumbnails are hidden automatically.", &style.section);
    try bind.toggle(context, thumbnail, "activeThumbnailHidden", "Hide Active Thumbnail");
    try bind.toggle(context, thumbnail, "hideWhenNoEveFocus", "Hide When No EVE Focus");
    try widgets.hintText(context, .src(@src()), "Hides all thumbnails while no EVE client window has focus.");
    const delay = try widgets.openGroup(context, .src(@src()), thumbnail.get("hideWhenNoEveFocus"));
    try bind.number(context, thumbnail, "hideDebounceMs", "Hide Delay", .{ .ms_as_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "Delay before hiding, so switching briefly doesn't flicker.");
    try delay.close(context);
    try section.close(context);
}

/// Picks which of the tab's other sections are drawn, and whether the Placement tab is offered.
fn displayMode(context: *ui.Frame, display: DisplayRef) !void {
    const section = try widgets.openSection(context, "Display Mode", "Thumbnails shows a live preview of each client. Client List is a compact text panel that uses fewer resources, ideal with many clients. None shows nothing; hotkeys and notifications keep working.", &style.section);
    try bind.segmented(context, display, "viewMode", "Show Clients As", &.{ "Thumbnails", "Client List", "None" });
    try section.close(context);
}
