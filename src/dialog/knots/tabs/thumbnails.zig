//! The configuration window's Thumbnails tab, laid out as the WebView2 page's: size, text overlays, the Thumbnail Spaces, borders, visibility, snapping, display mode and system colours; main thread only.
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
const stage = @import("thumbnails/stage.zig");
const chips = @import("thumbnails/chips.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const SelectInput = ui.component.SelectInput;
const ThumbnailRef = session.Ref(config.ThumbnailConfig);
const DisplayRef = session.Ref(config.DisplayConfig);

const MIN_SIZE_SLIDER = 50;
const MAX_SIZE_SLIDER = 1280;

const Ratio = struct { label: []const u8, ratio: ?f32 };

/// The first matches a running client; the last is whatever the size boxes say.
const RATIOS = [_]Ratio{
    .{ .label = "Match EVE Client", .ratio = null },
    .{ .label = "16:9 \u{00B7} 1920\u{00D7}1080, 2560\u{00D7}1440, 3840\u{00D7}2160", .ratio = 16.0 / 9.0 },
    .{ .label = "16:10 \u{00B7} 1920\u{00D7}1200, 2560\u{00D7}1600", .ratio = 16.0 / 10.0 },
    .{ .label = "21:9 \u{00B7} 3440\u{00D7}1440", .ratio = 43.0 / 18.0 },
    .{ .label = "4:3 \u{00B7} 1600\u{00D7}1200, 1024\u{00D7}768", .ratio = 4.0 / 3.0 },
    .{ .label = "Custom", .ratio = null },
};
const MATCH_CLIENT_INDEX = 0;
const CUSTOM_INDEX = RATIOS.len - 1;

/// Which border rows Enable Borders turns back on; the page keeps them as unsaved checkbox states.
var g_remembered_borders: struct { focused: bool = true, inactive: bool = true } = .{};

pub fn show(context: *ui.Frame) !void {
    const thumbnail = session.profile().child("thumbnail");
    const display = session.profile().child("display");
    try dimensions(context, thumbnail);
    try textOverlays(context, thumbnail);
    try thumbnailSpace(context, display);
    try notLoggedInSpace(context, display);
    try borders(context, thumbnail);
    try visibility(context, thumbnail);
    try snapping(context);
    try displayMode(context, display);
    try systemColors(context);
}

fn dimensions(context: *ui.Frame, thumbnail: ThumbnailRef) !void {
    const section = try widgets.openSection(context, "Dimensions", "Set the pixel size each thumbnail is rendered at.", .profile, &style.section);
    try aspectRatio(context, thumbnail);

    const size_row = try widgets.openBinding(context, .str("knots.thumbnails.size"), "Thumbnail Size");
    try bind.numberBox(context, thumbnail, "width", .{});
    try context.e(Text{ .selectable = false, .key = .str("knots.thumbnails.size.x"), .content = "\u{00D7}", .style = &style.muted_text });
    try bind.numberBox(context, thumbnail, "height", .{});
    try size_row.close(context);

    const slider_row = try widgets.openBinding(context, .str("knots.thumbnails.scale"), "Size");
    var width: f32 = @floatFromInt(thumbnail.get("width"));
    const ratio = width / @as(f32, @floatFromInt(@max(thumbnail.get("height"), 1)));
    if (try widgets.slider(context, .str("knots.thumbnails.scale.slider"), &width, MIN_SIZE_SLIDER, MAX_SIZE_SLIDER, 1)) {
        thumbnail.set("width", @intFromFloat(@round(width)));
        thumbnail.set("height", @intFromFloat(@round(width / ratio)));
    }
    try slider_row.close(context);
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

fn textOverlays(context: *ui.Frame, thumbnail: ThumbnailRef) !void {
    const section = try widgets.openSection(context, "Text Overlays", "Overlay a text strip on each thumbnail showing the character's name and/or current solar system. The preview below is not to scale - drag to reposition, click to edit.", .profile, &style.section);
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

fn thumbnailSpace(context: *ui.Frame, display: DisplayRef) !void {
    const section = try widgets.openSection(context, "Thumbnail Space", "Drag a rectangle on screen; thumbnails auto-fit to fill it and reflow as characters log in/out.", .profile, &style.section);
    var is_enabled = display.get("layoutMode") == .RegionFit;
    if (try widgets.checkbox(context, .src(@src()), "Enable Thumbnail Space", &is_enabled)) {
        display.set("layoutMode", if (is_enabled) .RegionFit else .Custom);
    }
    try widgets.hintText(context, .src(@src()), "Switches this profile's layout mode to Region Fit, taking over thumbnail placement instead of using saved positions.");

    const options = try widgets.openGroup(context, .src(@src()), is_enabled);
    try bind.toggle(context, display, "regionFitLimitToThumbnailSize", "Cap Thumbnail Size to Configured Dimensions");
    try widgets.hintText(context, .src(@src()), "Stops thumbnails from growing past the Thumbnail Size setting, leaving unused space in the region instead.");
    try bind.choice(context, display, "regionFitOrder", "Order By");
    try widgets.hintText(context, .src(@src()), "Character Order follows the Characters list; Hotkey Group Order follows the hotkey groups instead.");
    try bind.toggle(context, display, "regionFitReorderLoggedOut", "Move Logged-Out Characters to the End");
    try widgets.hintText(context, .src(@src()), "When off, a logged-out character's spot stays put until the next reflow instead of closing the gap immediately.");
    try bind.choiceStyled(context, display, "regionFitDirection", "Fill Order", &style.select_wide);
    try widgets.hintText(context, .src(@src()), "The order the grid fills as thumbnails are placed into the region.");
    try bind.number(context, display, "spacing", "Spacing (px)", .{});
    try widgets.hintText(context, .src(@src()), "Gap between thumbnails inside the Thumbnail Space.");
    try bind.toggle(context, display, "hideThumbnailsDuringRegionSelect", "Hide Thumbnails During Region Selection");
    try widgets.hintText(context, .src(@src()), "Temporarily hides visible thumbnails so they don't cover the drag-to-select overlay.");
    try regionButtons(context, .thumbnail);
    try options.close(context);
    try section.close(context);
}

fn notLoggedInSpace(context: *ui.Frame, display: DisplayRef) !void {
    const section = try widgets.openLinkedSection(context, "Not-Logged-In Thumbnail Space", "Drag a separate rectangle for not-yet-logged-in placeholders; auto-fits the same way as Thumbnail Space, and works alongside it.", .profile, &style.section);
    try bind.toggle(context, display, "notLoggedInSpaceEnabled", "Enable Not-Logged-In Thumbnail Space");

    const options = try widgets.openGroup(context, .src(@src()), display.get("notLoggedInSpaceEnabled"));
    try bind.toggle(context, display, "notLoggedInSpaceLimitToThumbnailSize", "Cap Thumbnail Size to Configured Dimensions");
    try widgets.hintText(context, .src(@src()), "Stops thumbnails from growing past the Thumbnail Size setting, leaving unused space in the region instead.");
    try bind.number(context, display, "notLoggedInSpaceSpacing", "Spacing (px)", .{});
    try widgets.hintText(context, .src(@src()), "Gap between placeholders inside this space.");
    try bind.toggle(context, display, "notLoggedInSpaceHideThumbnailsDuringRegionSelect", "Hide Thumbnails During Region Selection");
    try widgets.hintText(context, .src(@src()), "Temporarily hides visible thumbnails so they don't cover the drag-to-select overlay.");
    try regionButtons(context, .not_logged_in);
    try options.close(context);
    try section.close(context);
}

/// Draw a new space, adjust the current one, or clear it; the last two need one set.
fn regionButtons(context: *ui.Frame, comptime space: region.Space) !void {
    const name = @tagName(space);
    const row = Rect{ .key = .str("knots.region.buttons:" ++ name), .style = &style.button_row };
    _ = try row.open(context);
    if ((try context.interact(Button{ .key = .str("knots.region.new:" ++ name), .label = "\u{25AD} New Thumbnail Region", .style = &style.plain_button })).clicked) {
        region.start(space, false);
    }
    const has_region = region.rect(space) != null;
    if (try widgets.glyphButton(context, .str("knots.region.edit:" ++ name), .pencil, "Edit Region", &style.plain_button, !has_region)) {
        region.start(space, true);
    }
    if (has_region) {
        if (try widgets.confirmButton(context, .str("knots.region.clear:" ++ name), "\u{00D7}", "\u{2713}", &style.icon_button_danger_text, &style.icon_button_confirm)) {
            region.clear(space);
        }
    } else {
        _ = try context.interact(Button{ .key = .str("knots.region.clear:" ++ name), .label = "\u{00D7}", .disabled = true, .style = &style.icon_button_disabled_text });
    }
    try row.close(context);
}

/// Enable Borders isn't a setting of its own: it's on while either state shows a border, and switches both.
fn borders(context: *ui.Frame, thumbnail: ThumbnailRef) !void {
    const section = try widgets.openSection(context, "Borders", "Draw a styled border around thumbnails based on their focus state.", .profile, &style.section);
    const was_enabled = thumbnail.get("showBorderWhenFocused") or thumbnail.get("showBorderWhenInactive");
    var is_enabled = was_enabled;
    if (try widgets.checkbox(context, .src(@src()), "Enable Borders", &is_enabled)) {
        if (is_enabled) {
            thumbnail.set("showBorderWhenFocused", g_remembered_borders.focused);
            thumbnail.set("showBorderWhenInactive", g_remembered_borders.inactive);
        } else {
            g_remembered_borders = .{ .focused = thumbnail.get("showBorderWhenFocused"), .inactive = thumbnail.get("showBorderWhenInactive") };
            thumbnail.set("showBorderWhenFocused", false);
            thumbnail.set("showBorderWhenInactive", false);
        }
    }

    const options = try widgets.openGroup(context, .src(@src()), was_enabled);
    try bind.toggle(context, thumbnail, "useUniqueCharacterBorderColors", "Unique Character Border Colors");
    try widgets.hintText(context, .src(@src()), "Auto-generates a color per character name, overriding the Focused/Inactive Color settings below.");

    const header = Rect{ .key = .src(@src()), .style = &style.grid_row };
    _ = try header.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "", .style = &style.grid_header_state });
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "Width (px)", .style = &style.grid_header_number });
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "Style", .style = &style.grid_header_select });
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "Color", .style = &style.grid_header });
    try header.close(context);

    const unique = thumbnail.get("useUniqueCharacterBorderColors");
    try borderRow(context, thumbnail, "Focused Border", "showBorderWhenFocused", "borderWidth", "borderStyle", "borderColor", unique);
    try borderRow(context, thumbnail, "Inactive Border", "showBorderWhenInactive", "inactiveBorderWidth", "inactiveBorderStyle", "inactiveBorderColor", unique);
    try options.close(context);
    try section.close(context);
}

fn borderRow(context: *ui.Frame, thumbnail: ThumbnailRef, comptime label: []const u8, comptime show_field: []const u8, comptime width_field: []const u8, comptime style_field: []const u8, comptime color_field: []const u8, unique: bool) !void {
    const row = Rect{ .key = .str("knots.border.row:" ++ label), .style = &style.grid_row };
    _ = try row.open(context);
    const check = Rect{ .key = .str("knots.border.show:" ++ label), .style = &style.grid_state_cell };
    _ = try check.open(context);
    try bind.toggle(context, thumbnail, show_field, label);
    try check.close(context);

    const settings = try widgets.openGroup(context, .str("knots.border.settings:" ++ label), thumbnail.get(show_field));
    const cells = Rect{ .key = .str("knots.border.cells:" ++ label), .style = &style.grid_cells };
    _ = try cells.open(context);
    try bind.numberBox(context, thumbnail, width_field, .{});
    try bind.choiceBox(context, thumbnail, style_field, &style.select_narrow);
    // Overridden per character while unique colours are on.
    const color = try widgets.openGroup(context, .str("knots.border.color:" ++ label), !unique);
    try bind.colorBox(context, thumbnail, color_field);
    try color.close(context);
    try cells.close(context);
    try settings.close(context);
    try row.close(context);
}

fn visibility(context: *ui.Frame, thumbnail: ThumbnailRef) !void {
    const section = try widgets.openSection(context, "Visibility", "Control thumbnail transparency and when thumbnails are automatically hidden.", .profile, &style.section);
    try bind.slider(context, thumbnail, "thumbnailOpacity", "Opacity", .{ .display = .percent_of_255 });
    try bind.toggle(context, thumbnail, "applyOpacityToOverlayTexts", "Apply Opacity to Overlay Texts");
    try widgets.hintText(context, .src(@src()), "Also fades the name/badge/combat/mining/bounty/resource overlay text and backgrounds with the Opacity slider above; otherwise they stay fully opaque.");
    try bind.toggle(context, thumbnail, "activeThumbnailHidden", "Hide Active Thumbnail");
    try bind.toggle(context, thumbnail, "hideWhenNoEveFocus", "Hide When No EVE Focus");
    try widgets.hintText(context, .src(@src()), "Hides all thumbnails while no EVE client window has focus.");
    try bind.number(context, thumbnail, "hideDebounceMs", "Hide Debounce (s)", .{ .ms_as_seconds = true });
    try widgets.hintText(context, .src(@src()), "Delay before hiding, so switching briefly doesn't flicker.");
    try section.close(context);
}

fn snapping(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Snapping", "Configure the snapping behavior for window edges.", .profile, &style.section);
    const ref = session.profile().child("snapping");
    try bind.toggle(context, ref, "enabled", "Enable Snapping");
    const options = try widgets.openGroup(context, .src(@src()), ref.get("enabled"));
    try bind.toggle(context, ref, "screenEdges", "Snap to Screen Edges");
    try bind.toggle(context, ref, "thumbnailEdges", "Snap to Thumbnail Edges");
    try bind.toggle(context, ref, "ghostPositions", "Snap to Other Characters' Ghost Positions");
    try widgets.hintText(context, .src(@src()), "Also snaps to other characters' saved positions while dragging.");
    try bind.toggle(context, ref, "showGhostPositionBorders", "Show Ghost Position Borders");
    try widgets.hintText(context, .src(@src()), "Outlines every other character's saved position on screen while you drag.");
    try bind.number(context, ref, "threshold", "Snapping Threshold (px)", .{});
    try options.close(context);
    try section.close(context);
}

fn displayMode(context: *ui.Frame, display: DisplayRef) !void {
    const section = try widgets.openSection(context, "Display Mode", "Thumbnails is best for visually tracking each client at a glance. Client List is more compact and uses fewer resources \u{2014} ideal with many clients. Nothing uses the least resources of all; hotkeys and notifications keep working.", .profile, &style.section);
    try bind.choiceStyled(context, display, "viewMode", "View Mode", &style.select_wide);

    const options = try widgets.openGroup(context, .src(@src()), display.get("viewMode") == .ClientList);
    try widgets.subheading(context, .src(@src()), "Layout");
    try bind.choiceStyled(context, display, "listViewOrder", "Client List Order", &style.select_wide);
    try bind.number(context, display, "listViewColumns", "Columns", .{});
    try bind.slider(context, display, "listViewOpacity", "Client List Opacity", .{ .display = .percent_of_255 });

    try widgets.subheading(context, .src(@src()), "Font");
    const font = Rect{ .key = .src(@src()), .style = &style.stacked_row };
    _ = try font.open(context);
    const name = try stackedField(context, .src(@src()), "Font Name");
    try bind.fontBox(context, display, "listViewFontName");
    try name.close(context);
    const size = try stackedField(context, .src(@src()), "Font Size (px)");
    try bind.numberBox(context, display, "listViewFontSize", .{});
    try size.close(context);
    const weight = try stackedField(context, .src(@src()), "Font Weight");
    try bind.choiceBox(context, display, "listViewFontWeight", &style.select_narrow);
    try weight.close(context);
    try font.close(context);

    try widgets.subheading(context, .src(@src()), "Behavior");
    try bind.toggle(context, display, "rememberListViewPosition", "Remember Client List Position");
    try options.close(context);
    try section.close(context);
}

/// A column with `label` above whatever the caller adds; the caller closes it.
fn stackedField(context: *ui.Frame, key: ui.Key, label: []const u8) !Rect {
    const field = Rect{ .key = key, .style = &style.stacked_field };
    _ = try field.open(context);
    try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = label, .style = &style.stacked_label });
    return field;
}

fn systemColors(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "System Colors", "Define custom colors for specific solar systems. These take priority over Unique System Colors and the default color. Separate names with commas; * matches any text, ? any character, # any digit (e.g. J######).", .profile, &style.section);
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
