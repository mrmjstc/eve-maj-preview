//! The Thumbnails tab's Appearance page: the editable thumbnail and its texts, then size, borders, opacity and auto-hiding; main thread only.
const std = @import("std");
const ui = @import("ui");
const win32 = @import("../../../../platform/win32.zig");
const config = @import("../../../../config.zig");
const scout = @import("../../../../clients/scout.zig");
const session = @import("../../session.zig");
const bind = @import("../../bind.zig");
const status = @import("../../status.zig");
const style = @import("../../style.zig");
const widgets = @import("../../widgets.zig");
const stage = @import("stage.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const SelectInput = ui.component.SelectInput;
const ThumbnailRef = session.Ref(config.ThumbnailConfig);

const MIN_SIZE_SLIDER = 50;
const MAX_SIZE_SLIDER = 1280;

const Ratio = struct { label: []const u8, ratio: ?f32 };

/// The first matches a running client; the last is whatever the size boxes say.
const RATIOS = [_]Ratio{
    .{ .label = "Match EVE Client", .ratio = null },
    .{ .label = "16:9 (1920×1080, 2560×1440)", .ratio = 16.0 / 9.0 },
    .{ .label = "16:10 (1920×1200, 2560×1600)", .ratio = 16.0 / 10.0 },
    .{ .label = "21:9 (3440×1440)", .ratio = 43.0 / 18.0 },
    .{ .label = "4:3 (1600×1200, 1024×768)", .ratio = 4.0 / 3.0 },
    .{ .label = "Custom", .ratio = null },
};
const MATCH_CLIENT_INDEX = 0;
const CUSTOM_INDEX = RATIOS.len - 1;

var g_focus: stage.Focus = .focused;

pub fn show(context: *ui.Frame) !void {
    const thumbnail = session.profile().child("thumbnail");
    try stageCard(context, thumbnail);
    try size(context, thumbnail);
    try borders(context, thumbnail);
    try visibility(context, thumbnail);
    try systemColors(context);
}

fn stageCard(context: *ui.Frame, thumbnail: ThumbnailRef) !void {
    const card = Rect{ .key = .src(@src()), .style = &style.stage_card };
    _ = try card.open(context);
    const toolbar = Rect{ .key = .src(@src()), .style = &style.stage_toolbar };
    _ = try toolbar.open(context);
    g_focus = try widgets.segmented(context, stage.Focus, g_focus, .{ "Focused", "Inactive" });
    try context.e(Rect{ .key = .src(@src()), .style = &.{ .width = .grow() } });
    try bind.toggle(context, thumbnail, "showText", "Show Text Overlays");
    try toolbar.close(context);
    try stage.show(context, g_focus);
    try widgets.hintText(context, .src(@src()), "Drag a text to move it; click it to edit it. Dimmed texts are turned off. Fonts are not to scale.");
    try card.close(context);
}

fn systemColors(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "System Colors", "Colors for specific solar systems, which take priority over Unique Color per System and the System Name color.", .profile, &style.section);
    try widgets.notPorted(context, .src(@src()), "the system color list");
    try section.close(context);
}

fn size(context: *ui.Frame, thumbnail: ThumbnailRef) !void {
    const section = try widgets.openSection(context, "Size", "The pixel size each thumbnail is rendered at.", .profile, &style.section);
    try aspectRatio(context, thumbnail);

    const size_row = try widgets.openBinding(context, .str("knots.thumbnails.size"), "Width × Height");
    try bind.numberBox(context, thumbnail, "width", .{});
    try context.e(Text{ .key = .str("knots.thumbnails.size.x"), .content = "×", .style = &style.muted_text });
    try bind.numberBox(context, thumbnail, "height", .{});
    try context.e(Text{ .key = .str("knots.thumbnails.size.unit"), .content = "px", .style = &style.muted_text });
    try size_row.close(context);

    const scale_row = try widgets.openBinding(context, .str("knots.thumbnails.scale"), "Scale");
    var width: f32 = @floatFromInt(thumbnail.get("width"));
    const ratio = width / @as(f32, @floatFromInt(@max(thumbnail.get("height"), 1)));
    if (try widgets.slider(context, .str("knots.thumbnails.scale.slider"), &width, MIN_SIZE_SLIDER, MAX_SIZE_SLIDER, 1)) {
        thumbnail.set("width", @intFromFloat(@round(width)));
        thumbnail.set("height", @intFromFloat(@round(width / ratio)));
    }
    try scale_row.close(context);
    try widgets.hintText(context, .src(@src()), "Scale keeps the aspect ratio; type a size to change it.");
    try section.close(context);
}

/// Picking a ratio keeps the width and fits the height to it.
fn aspectRatio(context: *ui.Frame, thumbnail: ThumbnailRef) !void {
    const row = try widgets.openBinding(context, .str("knots.thumbnails.ratio"), "Aspect Ratio");
    const key: ui.Key = .str("knots.thumbnails.ratio.select");
    const current: u32 = currentRatio(thumbnail.get("width"), thumbnail.get("height"));
    if (context.ui().state.get(.select_input, key.hash())) |state| {
        if (!state.open) state.selected = current;
    }
    const labels = comptime blk: {
        var out: [RATIOS.len][]const u8 = undefined;
        for (RATIOS, &out) |ratio, *label| label.* = ratio.label;
        break :blk out;
    };
    const values: [RATIOS.len]u32 = comptime std.simd.iota(u32, RATIOS.len);
    const response = try context.interact(SelectInput(u32){
        .key = key,
        .labels = &labels,
        .values = &values,
        .initial_selected = current,
        .style = &style.select_wide,
        .parts = .{ .popup = &style.select_popup },
    });
    try row.close(context);

    const selected = response.selected orelse return;
    const width: f32 = @floatFromInt(thumbnail.get("width"));
    const ratio: f32 = if (selected.value == MATCH_CLIENT_INDEX) clientRatio() orelse {
        status.show(.info, "No EVE client is open to match; open one and pick this again", .{});
        return;
    } else RATIOS[selected.value].ratio orelse return;
    thumbnail.set("height", @intFromFloat(@round(width / ratio)));
}

/// The preset the size already has, give or take rounding; Custom when none fits.
fn currentRatio(width: i32, height: i32) u32 {
    for (RATIOS, 0..) |preset, index| {
        const ratio = preset.ratio orelse continue;
        const fitted: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(width)) / ratio));
        if (@abs(fitted - height) <= 1) return @intCast(index);
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

/// A grid: one row per focus state, one column per border setting.
fn borders(context: *ui.Frame, thumbnail: ThumbnailRef) !void {
    const section = try widgets.openSection(context, "Borders", "A border around each thumbnail, styled by whether its client has focus.", .profile, &style.section);
    const unique = thumbnail.get("useUniqueCharacterBorderColors");

    const header = Rect{ .key = .src(@src()), .style = &style.grid_row };
    _ = try header.open(context);
    try context.e(Text{ .key = .src(@src()), .content = "", .style = &style.label });
    try context.e(Text{ .key = .src(@src()), .content = "Show", .style = &style.grid_header_check });
    try context.e(Text{ .key = .src(@src()), .content = "Width (px)", .style = &style.grid_header_number });
    try context.e(Text{ .key = .src(@src()), .content = "Style", .style = &style.grid_header_select });
    try context.e(Text{ .key = .src(@src()), .content = "Color", .style = &style.grid_header });
    try header.close(context);

    try borderRow(context, thumbnail, "Focused", "showBorderWhenFocused", "borderWidth", "borderStyle", "borderColor", unique);
    try borderRow(context, thumbnail, "Inactive", "showBorderWhenInactive", "inactiveBorderWidth", "inactiveBorderStyle", "inactiveBorderColor", unique);

    try bind.toggle(context, thumbnail, "useUniqueCharacterBorderColors", "Unique Color per Character");
    try widgets.hintText(context, .src(@src()), "Each character gets its own generated color, in place of the colors above.");
    try section.close(context);
}

/// A state's settings dim while its border is off, but stay editable.
fn borderRow(context: *ui.Frame, thumbnail: ThumbnailRef, comptime label: []const u8, comptime show_field: []const u8, comptime width_field: []const u8, comptime style_field: []const u8, comptime color_field: []const u8, unique: bool) !void {
    const row = Rect{ .key = .str("knots.border.row:" ++ label), .style = &style.grid_row };
    _ = try row.open(context);
    try context.e(Text{ .key = .str("knots.border.label:" ++ label), .content = label, .style = &style.label });
    const check = Rect{ .key = .str("knots.border.show:" ++ label), .style = &style.grid_check_cell };
    _ = try check.open(context);
    try bind.toggle(context, thumbnail, show_field, "");
    try check.close(context);

    const settings = Rect{ .key = .str("knots.border.settings:" ++ label), .style = if (thumbnail.get(show_field)) &style.grid_cells else &style.grid_cells_dimmed };
    _ = try settings.open(context);
    try bind.numberBox(context, thumbnail, width_field, .{});
    try bind.choiceBox(context, thumbnail, style_field, &style.select_narrow);
    if (unique) {
        try context.e(Text{ .key = .str("knots.border.unique:" ++ label), .content = "Per character", .style = &style.muted_text });
    } else {
        try bind.colorBox(context, thumbnail, color_field);
    }
    try settings.close(context);
    try row.close(context);
}

fn visibility(context: *ui.Frame, thumbnail: ThumbnailRef) !void {
    const section = try widgets.openSection(context, "Opacity & Hiding", "How see-through thumbnails are, and when they get out of the way.", .profile, &style.section);
    try bind.slider(context, thumbnail, "thumbnailOpacity", "Opacity", .{ .display = .percent_of_255 });
    try bind.toggle(context, thumbnail, "applyOpacityToOverlayTexts", "Fade Overlay Text Too");
    try widgets.hintText(context, .src(@src()), "Also fades the name, badge, timer and activity overlays with the opacity above; otherwise they stay fully opaque.");

    try widgets.subheading(context, .src(@src()), "Hide Thumbnails");
    try bind.toggle(context, thumbnail, "activeThumbnailHidden", "Hide the Active Client's Thumbnail");
    try bind.toggle(context, thumbnail, "hideWhenNoEveFocus", "Hide All When No EVE Client Has Focus");
    if (thumbnail.get("hideWhenNoEveFocus")) {
        try bind.number(context, thumbnail, "hideDebounceMs", "Hide Delay (s)", .{ .ms_as_seconds = true });
        try widgets.hintText(context, .src(@src()), "Waits this long before hiding, so switching windows briefly doesn't make them flicker.");
    }
    try section.close(context);
}
