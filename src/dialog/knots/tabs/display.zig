//! The configuration window's Display tab: how clients are shown, then the thumbnail or client list settings for that mode; main thread only.
const std = @import("std");
const ui = @import("ui");
const win32 = @import("../../../platform/win32.zig");
const config = @import("../../../config.zig");
const scout = @import("../../../clients/scout.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const status = @import("../status.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const region = @import("../region.zig");
const search = @import("../search.zig");
const glyphs = @import("../glyphs.zig");
const stage = @import("thumbnails/stage.zig");
const chips = @import("thumbnails/chips.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Canvas = ui.component.Canvas;
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

const RegionStatus = struct { text: []const u8, is_missing: bool };

/// A foldable card, open between openCard and close; its header is still open for the caller's switch until openBody.
const Card = struct {
    id: []const u8,
    rect: Rect,
    header: Rect,
    is_open: bool,

    /// Closes the header; returns the body to fill when the card is unfolded and `is_enabled`, or a search wants its rows.
    fn openBody(self: *const Card, context: *ui.Frame, is_enabled: bool) !?widgets.Group {
        try self.header.close(context);
        if (!self.is_open or !widgets.showsDependents(is_enabled)) return null;
        const body = Rect{ .key = ui.Key.str("knots.card.body").indexed(std.hash.Wyhash.hash(0, self.id)), .style = &style.space_card_body };
        _ = try body.open(context);
        g_open_body = body;
        return try widgets.openGroup(context, ui.Key.str("knots.card.group").indexed(std.hash.Wyhash.hash(0, self.id)), is_enabled);
    }

    fn close(self: *const Card, context: *ui.Frame) !void {
        if (g_open_body) |body| {
            try body.close(context);
            g_open_body = null;
        }
        try self.rect.close(context);
    }
};

/// Which placement cards are unfolded; not saved.
var g_open_cards: struct { snapping: bool = true, everyone: bool = true, login_screen: bool = false } = .{};
/// The body of the card being drawn, closed by Card.close.
var g_open_body: ?Rect = null;

pub fn show(context: *ui.Frame) !void {
    const was_aligned = widgets.useAlignedRows(true);
    defer _ = widgets.useAlignedRows(was_aligned);
    const thumbnail = session.profile().child("thumbnail");
    const display = session.profile().child("display");
    try displayMode(context, display);
    switch (display.get("viewMode")) {
        .Thumbnails => {
            try sizeAndOpacity(context, thumbnail);
            try borders(context, thumbnail);
            try visibility(context, thumbnail);
            try textOverlays(context, thumbnail);
            try placement(context, display);
            try systemColors(context);
        },
        .ClientList => try clientList(context, display),
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
    const unique = thumbnail.get("useUniqueCharacterBorderColors");
    try borderRow(context, thumbnail, "Focused Border", "showBorderWhenFocused", "borderWidth", "borderStyle", "borderColor", unique);
    try borderRow(context, thumbnail, "Inactive Border", "showBorderWhenInactive", "inactiveBorderWidth", "inactiveBorderStyle", "inactiveBorderColor", unique);
    try bind.toggle(context, thumbnail, "useUniqueCharacterBorderColors", "Unique Character Border Colors");
    try widgets.hintText(context, .src(@src()), "Auto-generates a color per character name, overriding the Focused/Inactive colors above.");
    try section.close(context);
}

/// The state's width, style and colour, then its checkbox last so it lines up with the other rows' checkboxes.
fn borderRow(context: *ui.Frame, thumbnail: ThumbnailRef, comptime label: []const u8, comptime show_field: []const u8, comptime width_field: []const u8, comptime style_field: []const u8, comptime color_field: []const u8, unique: bool) !void {
    const row = try widgets.openBinding(context, .str("knots.border.row:" ++ label), label);
    const settings = try widgets.openInlineGroup(context, .str("knots.border.settings:" ++ label), thumbnail.get(show_field));
    try bind.unitNumberBox(context, thumbnail, width_field, "px", .{});
    try bind.choiceBox(context, thumbnail, style_field, &style.select_narrow);
    // Overridden per character while unique colours are on.
    const color = try widgets.openInlineGroup(context, .str("knots.border.color:" ++ label), !unique);
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
    try bind.number(context, thumbnail, "hideDebounceMs", "Hide Delay", .{ .ms_as_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "Delay before hiding, so switching briefly doesn't flicker.");
    try section.close(context);
}

fn textOverlays(context: *ui.Frame, thumbnail: ThumbnailRef) !void {
    const section = try widgets.openSection(context, "Text Overlays", "Texts shown on each thumbnail. Drag one on the preview to move it, or click it to turn it on or off and change its font and colours. Faded ones are off. The preview is not to scale.", &style.section);
    try bind.toggle(context, thumbnail, "showText", "Show Text Overlays");
    if (try widgets.checkbox(context, .src(@src()), "Sync Fonts and Backgrounds", &chips.g_sync_styling)) {
        if (chips.g_sync_styling) chips.syncFromCharacterName();
    }
    try widgets.hintText(context, .src(@src()), "Editing one overlay's font or background applies it to all the others.");
    const row = Rect{ .key = .src(@src()), .style = &style.stage_row };
    _ = try row.open(context);
    try stage.show(context);
    try row.close(context);
    try section.close(context);
}

/// Manual placement with snapping, or the Everyone space; then the Login Screen space, which works in either mode.
fn placement(context: *ui.Frame, display: DisplayRef) !void {
    const section = try widgets.openSection(context, "Thumbnail Placement", "Drag thumbnails where you want them, or fit them into spaces you draw. Clients at the login screen can have a space of their own in either mode.", &style.section);
    try bind.segmented(context, display, "layoutMode", "Mode", &.{ "Manual", "Fit to Spaces" });
    const is_fit = display.get("layoutMode") == .RegionFit;

    if (widgets.showsDependents(!is_fit)) {
        const manual = try widgets.openGroup(context, .src(@src()), !is_fit);
        try snappingCard(context);
        try manual.close(context);
    }
    if (widgets.showsDependents(is_fit)) {
        const fit = try widgets.openGroup(context, .src(@src()), is_fit);
        try everyoneCard(context, display);
        try fit.close(context);
    }
    try loginScreenCard(context, display);
    try hideWhileDrawing(context, display);
    try section.close(context);
}

fn snappingCard(context: *ui.Frame) !void {
    const ref = session.profile().child("snapping");
    var is_enabled: bool = ref.get("enabled");
    const card = try openCard(context, "snapping", null, "Snap While Dragging", "", "", false, &g_open_cards.snapping);
    if (try widgets.toggleSwitch(context, .str("knots.card.switch:snapping"), &is_enabled)) ref.set("enabled", is_enabled);
    if (try card.openBody(context, is_enabled)) |body| {
        try bind.toggle(context, ref, "screenEdges", "Snap to Screen Edges");
        try bind.toggle(context, ref, "thumbnailEdges", "Snap to Thumbnail Edges");
        try bind.toggle(context, ref, "ghostPositions", "Snap to Other Characters' Saved Positions");
        try bind.toggle(context, ref, "showGhostPositionBorders", "Outline Saved Positions While Dragging");
        try widgets.hintText(context, .src(@src()), "Outlines every other character's saved position on screen while you drag.");
        try bind.number(context, ref, "threshold", "Snap Distance", .{ .unit = "px" });
        try body.close(context);
    }
    try card.close(context);
}

fn everyoneCard(context: *ui.Frame, display: DisplayRef) !void {
    const region_state = try regionStatus(context, .thumbnail);
    const card = try openCard(context, "everyone", context.ui().theme.primary, "Everyone", "All characters", region_state.text, region_state.is_missing, &g_open_cards.everyone);
    if (try card.openBody(context, true)) |body| {
        try regionRow(context, .thumbnail);
        try bind.choiceStyled(context, display, "regionFitDirection", "Fill Order", &style.select_narrow);
        try widgets.hintText(context, .src(@src()), "The order the grid fills: Rows \u{2192} \u{2193} fills each row left to right, then moves down a row; Columns fill down (or up) each column first.");
        try bind.segmented(context, display, "regionFitOrder", "Order By", &.{ "Characters", "Hotkey Groups" });
        try widgets.hintText(context, .src(@src()), "Characters follows the Characters list; Hotkey Groups follows the hotkey groups instead.");
        try bind.number(context, display, "spacing", "Spacing", .{ .unit = "px" });
        try bind.toggle(context, display, "regionFitLimitToThumbnailSize", "Cap Size at Thumbnail Size");
        try widgets.hintText(context, .src(@src()), "Stops thumbnails from growing past the Size setting, leaving unused space in the region instead.");
        try bind.toggle(context, display, "regionFitReorderLoggedOut", "Move Logged-Out Characters to the End");
        try widgets.hintText(context, .src(@src()), "When off, a logged-out character's spot stays put until the next reflow instead of closing the gap immediately.");
        try body.close(context);
    }
    try card.close(context);
}

fn loginScreenCard(context: *ui.Frame, display: DisplayRef) !void {
    var is_enabled: bool = display.get("notLoggedInSpaceEnabled");
    const region_state = try regionStatus(context, .not_logged_in);
    const card = try openCard(context, "login_screen", style.PURPLE, "Login Screen", "Clients at the login screen", region_state.text, region_state.is_missing and is_enabled, &g_open_cards.login_screen);
    if (try widgets.toggleSwitch(context, .str("knots.card.switch:login_screen"), &is_enabled)) display.set("notLoggedInSpaceEnabled", is_enabled);
    if (try card.openBody(context, is_enabled)) |body| {
        try regionRow(context, .not_logged_in);
        try bind.number(context, display, "notLoggedInSpaceSpacing", "Spacing", .{ .unit = "px" });
        try bind.toggle(context, display, "notLoggedInSpaceLimitToThumbnailSize", "Cap Size at Thumbnail Size");
        try body.close(context);
    }
    try card.close(context);
}

/// One switch for both spaces' saved settings, since drawing either region is the same overlay.
fn hideWhileDrawing(context: *ui.Frame, display: DisplayRef) !void {
    var is_hidden: bool = display.get("hideThumbnailsDuringRegionSelect");
    if (try widgets.checkbox(context, .src(@src()), "Hide Thumbnails While Drawing a Region", &is_hidden)) {
        display.set("hideThumbnailsDuringRegionSelect", is_hidden);
        display.set("notLoggedInSpaceHideThumbnailsDuringRegionSelect", is_hidden);
    }
    try widgets.hintText(context, .src(@src()), "Temporarily hides visible thumbnails so they don't cover the drag-to-select overlay.");
}

/// The space's region as "width × height", or that it hasn't been drawn.
fn regionStatus(context: *ui.Frame, space: region.Space) !RegionStatus {
    const rect = region.rect(space) orelse return .{ .text = "No region yet", .is_missing = true };
    return .{ .text = try std.fmt.allocPrint(context.arena(), "{d} \u{00D7} {d}", .{ rect.right - rect.left, rect.bottom - rect.top }), .is_missing = false };
}

/// A card with its fold arrow, colour dot, name, who it holds and its region's state; the caller adds a switch, then calls openBody.
fn openCard(context: *ui.Frame, comptime id: []const u8, dot: ?ui.Color, name: []const u8, who: []const u8, state_text: []const u8, is_warning: bool, is_open: *bool) !Card {
    const shows_open = is_open.* or search.isActive();
    const rect = Rect{ .key = .str("knots.card:" ++ id), .style = if (shows_open) &style.space_card_open else &style.space_card };
    _ = try rect.open(context);
    const header = Rect{ .key = .str("knots.card.header:" ++ id), .style = &style.space_card_header };
    _ = try header.open(context);

    const toggle = Button{ .key = .str("knots.card.toggle:" ++ id), .style = &style.space_card_toggle };
    const response = try toggle.openResponse(context);
    const chevron_key: ui.Key = .str("knots.card.chevron:" ++ id);
    try context.e(Canvas{
        .key = chevron_key,
        .commands = try glyphs.commands(context.arena(), if (shows_open) .chevron_down else .chevron_right, 10, try glyphs.snapOffset(context, chevron_key), style.MUTED.value),
        .style = &style.space_card_chevron,
    });
    if (dot) |color| {
        const dot_style = try context.arena().create(ui.Style);
        dot_style.* = style.space_card_dot.with(.{ .background = .{ .color = color } });
        try context.e(Rect{ .key = .str("knots.card.dot:" ++ id), .style = dot_style });
    }
    search.captureText(name);
    try context.e(Text{ .selectable = false, .key = .str("knots.card.name:" ++ id), .content = name, .style = &style.space_card_name });
    if (who.len > 0) try context.e(Text{ .selectable = false, .key = .str("knots.card.who:" ++ id), .content = who, .style = &style.muted_text });
    try context.e(Rect{ .key = .str("knots.card.fill:" ++ id), .style = &style.fill });
    if (state_text.len > 0) try context.e(Text{ .selectable = false, .key = .str("knots.card.status:" ++ id), .content = state_text, .style = if (is_warning) &style.space_card_status_warning else &style.muted_text });
    try toggle.close(context);
    if (response.clicked) {
        is_open.* = !is_open.*;
        context.requestRedraw();
    }
    return .{ .id = id, .rect = rect, .header = header, .is_open = shows_open };
}

/// Buttons to draw a new rectangle for the space, adjust it, or clear it; the last two need one set.
fn regionRow(context: *ui.Frame, comptime space: region.Space) !void {
    const name = @tagName(space);
    const row = try widgets.openBinding(context, .str("knots.region.row:" ++ name), "Region");
    const current = region.rect(space);
    if ((try context.interact(Button{ .key = .str("knots.region.new:" ++ name), .label = "New", .style = &style.plain_button })).clicked) {
        region.start(space, false);
    }
    if (try widgets.glyphButton(context, .str("knots.region.edit:" ++ name), .pencil, "Edit", &style.plain_button, current == null)) {
        region.start(space, true);
    }
    if (current != null) {
        if (try widgets.confirmButton(context, .str("knots.region.clear:" ++ name), "\u{00D7}", "OK", &style.icon_button_danger_text, &style.icon_button_confirm)) {
            region.clear(space);
        }
    } else {
        _ = try context.interact(Button{ .key = .str("knots.region.clear:" ++ name), .label = "\u{00D7}", .disabled = true, .style = &style.icon_button_disabled_text });
    }
    try row.close(context);
}

/// Picks which of the tab's other sections are drawn.
fn displayMode(context: *ui.Frame, display: DisplayRef) !void {
    const section = try widgets.openSection(context, "Display Mode", "Thumbnails shows a live preview of each client. Client List is a compact text panel that uses fewer resources, ideal with many clients. None shows nothing; hotkeys and notifications keep working.", &style.section);
    try bind.segmented(context, display, "viewMode", "Show Clients As", &.{ "Thumbnails", "Client List", "None" });
    try section.close(context);
}

fn clientList(context: *ui.Frame, display: DisplayRef) !void {
    const section = try widgets.openSection(context, "Client List", "A compact panel listing each client by name; click a name to bring that client to the front.", &style.section);
    try bind.choiceStyled(context, display, "listViewOrder", "Order", &style.select_wide);
    try bind.number(context, display, "listViewColumns", "Columns", .{});
    try bind.slider(context, display, "listViewOpacity", "Opacity", .{ .display = .percent_of_255 });
    const font = try widgets.openBinding(context, .src(@src()), "Font");
    try bind.fontBox(context, display, "listViewFontName");
    try bind.numberBox(context, display, "listViewFontSize", .{});
    try bind.choiceBox(context, display, "listViewFontWeight", &style.select_narrow);
    try font.close(context);
    try bind.toggle(context, display, "rememberListViewPosition", "Remember Position");
    try section.close(context);
}

fn systemColors(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "System Colors", "Define custom colors for specific solar systems. These take priority over Unique System Colors and the default color. Separate names with commas; * matches any text, ? any character, # any digit (e.g. J######).", &style.section);
    const profile = session.profile();
    const list = Rect{ .key = .src(@src()), .style = &style.list };
    _ = try list.open(context);
    var index: usize = 0;
    while (index < profile.ptr.systemColors.items.len) : (index += 1) {
        const entry = profile.item("systemColors", index);
        const row = Rect{ .key = ui.Key.str("knots.system_color.row").indexed(index), .style = &style.list_row };
        _ = try row.open(context);
        try bind.textBox(context, entry, "systemName", "System name");
        try bind.colorBox(context, entry, "color");
        const removed = try widgets.confirmButton(context, ui.Key.str("knots.system_color.remove").indexed(index), "Remove", "Confirm", &style.remove_button, &style.confirm_remove_button);
        try row.close(context);
        if (removed) {
            profile.remove("systemColors", index);
            break;
        }
    }
    try list.close(context);
    if ((try context.interact(Button{ .key = .src(@src()), .label = "+ Add System Color", .style = &style.full_width_button })).clicked) {
        profile.append("systemColors", .{ .systemName = "", .color = 0xFFFFFFFF });
    }
    try section.close(context);
}
