//! The configuration window's Placement tab: the placement mode and a screen preview, then hand-placement settings or a list of thumbnail spaces beside the selected one's details; main thread only.
const std = @import("std");
const ui = @import("ui");
const win32 = @import("../../../platform/win32.zig");
const config = @import("../../../config.zig");
const spaces = @import("../../../layout/spaces.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const region = @import("../region.zig");
const search = @import("../search.zig");
const screen_map = @import("../screen_map.zig");
const screen_math = @import("../screen_math.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const ProfileRef = session.Ref(config.Config);
const DisplayRef = session.Ref(config.DisplayConfig);
const SpaceRef = session.Ref(config.ThumbnailSpace);
const ScreenMap = screen_map.ScreenMap;

// knots doesn't export its grid types by name.
const GridTemplate = @typeInfo(@FieldType(ui.Style, "grid")).optional.child;
const GridTrack = @typeInfo(@FieldType(GridTemplate, "rows")).pointer.child;

const SPACE_ROW_KEY: ui.Key = .str("knots.space.row");
const CHIP_COLUMNS: [3]GridTrack = @splat(.{ .fr = 1 });

/// A pill in a space's Holds grid.
const Chip = struct {
    label: []const u8,
    /// The group name it toggles; null for an unnamed group, which is named when clicked.
    name: ?[]const u8,
    /// The unnamed group's index in hotkeyGroups.
    group_index: usize = 0,
};

/// The id of the space whose details are shown; not saved, and follows the space through reorders.
var g_selected_id: u32 = 0;

pub fn show(context: *ui.Frame) !void {
    const profile = session.profile();
    const display = profile.child("display");
    // A search shows both modes' settings, so a match in the other mode is still found.
    const mode = display.get("placementMode");
    const shows_manual = mode == .Manual or search.isActive();
    const shows_spaces = mode == .ThumbnailSpaces or search.isActive();

    const section = try widgets.openSection(context, "Thumbnail Placement", "Manual lets you drag each thumbnail where you want it. Thumbnail Spaces fills screen regions you draw with the thumbnails of the hotkey groups each one holds.", &style.section);
    try bind.segmented(context, display, "placementMode", "Placement Mode", &.{ "Manual", "Thumbnail Spaces" });
    if (shows_manual) try savedPositionMap(context, profile);
    if (shows_spaces) {
        const items = profile.ptr.thumbnailSpaces.items;
        try regionMap(context, items, selectedIndex(items));
    }
    try section.close(context);

    if (shows_manual) {
        const manual_section = try widgets.openSection(context, "Manual Placement", "Where thumbnails go when you place them by hand.", &style.section);
        try manual(context, display);
        try manual_section.close(context);
    }
    if (shows_spaces) {
        const spaces_section = try widgets.openSection(context, "Thumbnail Spaces", "A space can hold several hotkey groups. A character two spaces hold goes to the first one in the list; drag a space to reorder.", if (fillsWindow()) &style.fill_section else &style.section);
        try spacesMode(context, display);
        try spaces_section.close(context);
    }
}

/// Spaces mode fills the window like Characters; Manual's settings, or both modes during a search, scroll instead.
pub fn fillsWindow() bool {
    return session.profile().ptr.display.placementMode == .ThumbnailSpaces and !search.isActive();
}

fn manual(context: *ui.Frame, display: DisplayRef) !void {
    const profile = session.profile();
    const interaction = profile.child("interaction");
    const previous_rows = widgets.useDetailRows();
    defer widgets.restoreRows(previous_rows);

    const dragging = try widgets.openFieldGroup(context, .str("knots.manual.dragging"), "Dragging");
    const drag = try widgets.openGroup(context, .src(@src()), !interaction.get("clickThrough"));
    try bind.toggle(context, interaction, "enableDragging", "Enable Dragging");
    try drag.close(context);
    try widgets.hintText(context, .src(@src()), "Stays off while Click Through Thumbnails is on in the Behavior tab.");
    try bind.toggle(context, display, "honorSavedPositions", "Restore Saved Positions");
    try widgets.hintText(context, .src(@src()), "Puts each character's thumbnail back where it was last dragged.");
    try dragging.close(context);
    try widgets.separator(context, .str("knots.manual.separator.dragging"));

    const snapping = profile.child("snapping");
    const snapping_group = try widgets.openFieldGroup(context, .str("knots.manual.snapping"), "Snapping");
    try bind.toggle(context, snapping, "enabled", "Snap While Dragging");
    if (widgets.showsDependents(snapping.get("enabled"))) {
        const group = try widgets.openGroup(context, .src(@src()), snapping.get("enabled"));
        try bind.toggle(context, snapping, "screenEdges", "Snap to Screen Edges");
        try bind.toggle(context, snapping, "thumbnailEdges", "Snap to Thumbnail Edges");
        try bind.toggle(context, snapping, "ghostPositions", "Snap to Other Characters' Saved Positions");
        try bind.toggle(context, snapping, "showGhostPositionBorders", "Outline Saved Positions While Dragging");
        try widgets.hintText(context, .src(@src()), "Outlines every other character's saved position on screen while you drag.");
        try bind.number(context, snapping, "threshold", "Snap Distance", .{ .unit = "px" });
        try group.close(context);
    }
    try snapping_group.close(context);
    try widgets.separator(context, .str("knots.manual.separator.snapping"));

    const new_thumbnails = try widgets.openFieldGroup(context, .str("knots.manual.new"), "New Thumbnails");
    const start = try widgets.openBinding(context, .src(@src()), "Start Position");
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "X", .style = &style.muted_text });
    try bind.numberBox(context, display, "startX", .{});
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "Y", .style = &style.muted_text });
    try bind.numberBox(context, display, "startY", .{});
    try start.close(context);
    try bind.number(context, display, "newThumbnailSpacing", "Spacing", .{ .unit = "px" });
    try widgets.hintText(context, .src(@src()), "Where a character with no saved position appears: lined up left to right from the start position with this gap.");
    try new_thumbnails.close(context);
}

fn spacesMode(context: *ui.Frame, display: DisplayRef) !void {
    const profile = session.profile();
    try bind.toggle(context, display, "hideThumbnailsDuringRegionSelect", "Hide Thumbnails While Drawing a Region");
    try widgets.hintText(context, .src(@src()), "Temporarily hides visible thumbnails so they don't cover the drag-to-select overlay.");
    try widgets.separator(context, .str("knots.space.separator.hide"));

    const is_filling = fillsWindow();
    const master_detail = Rect{ .key = .src(@src()), .style = if (is_filling) &style.master_detail_fill else &style.master_detail };
    _ = try master_detail.open(context);
    try roster(context, profile, is_filling);
    if (is_filling) {
        const pane = try widgets.openScrollPane(context, .str("knots.space.detail"), style.detail_scroll);
        try selectedDetail(context, profile);
        try pane.close(context);
    } else {
        const stack = Rect{ .key = .src(@src()), .style = &style.detail_fit };
        _ = try stack.open(context);
        try selectedDetail(context, profile);
        try stack.close(context);
    }
    try master_detail.close(context);
}

fn selectedDetail(context: *ui.Frame, profile: ProfileRef) !void {
    if (selectedIndex(profile.ptr.thumbnailSpaces.items)) |index| {
        try detail(context, profile, index);
    } else {
        try widgets.paragraph(context, .src(@src()), "Add a space, then draw its region and pick the hotkey groups whose thumbnails fill it.");
    }
}

/// The selected space, else the first, so a removed or never-picked selection still shows one.
fn selectedIndex(items: []const config.ThumbnailSpace) ?usize {
    if (items.len == 0) return null;
    for (items, 0..) |space, index| {
        if (space.id == g_selected_id) return index;
    }
    g_selected_id = items[0].id;
    return 0;
}

fn roster(context: *ui.Frame, profile: ProfileRef, is_filling: bool) !void {
    const items = profile.ptr.thumbnailSpaces.items;
    const list = try widgets.openRoster(context, .str("knots.space.roster"), if (is_filling) &style.roster_wide else &style.roster_filters, is_filling);
    if (items.len == 0) {
        try widgets.boxedText(context, .src(@src()), "No spaces yet.", &style.roster_empty, &style.roster_empty_text);
    }
    const arena = context.arena();
    const fixed_count = fixedCount(items);
    for (items, 0..) |*space, index| {
        const is_selected = space.id == g_selected_id;
        // Fixed rows don't join the drag, so nothing can be dropped above them.
        const mark: widgets.DropMark = if (index < fixed_count) .none else try widgets.reorderRow(context, SPACE_ROW_KEY, index, items.len);
        const row = Button{ .key = SPACE_ROW_KEY.indexed(index), .style = switch (mark) {
            .above => &style.roster_row_drop_above,
            .below => &style.roster_row_drop_below,
            .none => if (is_selected) &style.roster_row_selected else &style.roster_row,
        } };
        if ((try widgets.openRosterRow(context, row)).clicked and !is_selected) {
            g_selected_id = space.id;
            context.requestRedraw();
        }
        const dot_style = try arena.create(ui.Style);
        dot_style.* = style.space_dot.with(.{ .background = .{ .color = dotColor(context, index) }, .opacity = if (space.enabled) @as(f32, 1) else 0.35 });
        try context.e(Rect{ .key = ui.Key.str("knots.space.dot").indexed(index), .style = dot_style });
        search.captureText(space.name);
        try context.e(Text{
            .selectable = false,
            .key = ui.Key.str("knots.space.name").indexed(index),
            .content = if (space.name.len > 0) space.name else "Unnamed Space",
            .style = if (is_selected) &style.roster_name_selected else &style.roster_name,
        });
        const has_region = spaces.rect(space) != null;
        if (!space.enabled or !has_region) {
            const is_warning = space.enabled;
            try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.space.state").indexed(index), .content = if (is_warning) "No region" else "Off", .style = if (is_warning) &style.roster_badge_warning else &style.roster_badge });
        }
        try row.close(context);
    }
    const is_full = items.len >= spaces.MAX_SPACES;
    const action = try list.close(context, .{ .add_label = "+ Add Space", .is_add_disabled = is_full });

    if (widgets.reorderFinish(context, SPACE_ROW_KEY, items.len)) |moved| profile.move("thumbnailSpaces", moved.from, @max(moved.before, fixed_count));
    if (action == .add) {
        const count = profile.ptr.thumbnailSpaces.items.len;
        profile.append("thumbnailSpaces", .{ .name = "New Space" });
        const added = profile.ptr.thumbnailSpaces.items;
        if (added.len > count) g_selected_id = added[added.len - 1].id;
    }
}

/// Login Screen and Unassigned Characters stay at the top, as config load puts them (see config/spaces.zig).
fn fixedCount(items: []const config.ThumbnailSpace) usize {
    var count: usize = 0;
    while (count < items.len and (items[count].holdsLoginScreen or items[count].holdsUnassigned)) count += 1;
    return count;
}

fn detail(context: *ui.Frame, profile: ProfileRef, index: usize) !void {
    const space = profile.item("thumbnailSpaces", index);
    const id = space.get("id");
    const is_login_screen = space.get("holdsLoginScreen");
    const is_unassigned = space.get("holdsUnassigned");
    // The Login Screen and Unassigned Characters spaces are always in the list, so they can't be renamed or removed.
    const is_special = is_login_screen or is_unassigned;
    const previous_rows = widgets.useDetailRows();
    defer widgets.restoreRows(previous_rows);
    const header = try widgets.openDetailHeader(context, .src(@src()));
    if (is_special) {
        try context.e(Text{ .selectable = false, .key = .src(@src()), .content = space.get("name"), .style = &style.roster_name_selected });
    } else {
        try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "Name", .style = &style.detail_label });
        try bind.textBox(context, space, "name", "e.g., Miners");
    }
    var is_enabled: bool = space.get("enabled");
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "Enabled", .style = &style.muted_text });
    if (try widgets.toggleSwitch(context, ui.Key.str("knots.space.enabled").indexed(id), &is_enabled)) space.set("enabled", is_enabled);
    const removed = !is_special and try widgets.confirmButton(context, ui.Key.str("knots.space.remove").indexed(id), "Remove", "Confirm", &style.plain_button, &style.confirm_button);
    try header.close(context);
    if (removed) {
        const items = profile.ptr.thumbnailSpaces.items;
        g_selected_id = if (index + 1 < items.len) items[index + 1].id else if (index > 0) items[index - 1].id else 0;
        profile.remove("thumbnailSpaces", index);
        return;
    }

    const items = profile.ptr.thumbnailSpaces.items;
    if (is_login_screen) {
        try widgets.paragraph(context, .src(@src()), "Holds clients still at the login screen.");
    } else if (is_unassigned) {
        try widgets.paragraph(context, .src(@src()), "Holds characters no other active space holds.");
    } else {
        const held = try widgets.openFieldGroup(context, .str("knots.space.holds"), "Holds");
        try holds(context, profile, space);
        try overlaps(context, items, index);
        try held.close(context);
    }
    try widgets.separator(context, .str("knots.space.separator.holds"));

    const behavior = try widgets.openFieldGroup(context, .str("knots.space.behavior"), "Behavior");
    if (!is_unassigned) {
        try bind.toggle(context, space, "takesUnassigned", "Move Unassigned Characters to the End");
        try widgets.hintText(context, .src(@src()), "Characters no space holds fill in after this space's own. Only the first space with this on takes them, and none does while the Unassigned Characters space is on with a region.");
        if (space.get("takesUnassigned")) try takenElsewhere(context, items, index, spaces.unassignedSpaceIn(items), "Unassigned characters");
    }
    if (!is_login_screen) {
        try bind.toggle(context, space, "takesLoginScreen", "Move Logged-Out Characters to the End");
        try widgets.hintText(context, .src(@src()), "Clients at the login screen fill in last. Only the first space with this on takes them, and none does while the Login Screen space is on with a region.");
    }
    try behavior.close(context);
    try widgets.separator(context, .str("knots.space.separator.behavior"));

    const layout = try widgets.openFieldGroup(context, .str("knots.space.layout"), "Layout");
    try regionRow(context, id);
    try bind.choiceStyled(context, space, "direction", "Fill Order", &style.select_narrow);
    try widgets.hintText(context, .src(@src()), "The order the grid fills: Rows \u{2192} \u{2193} fills each row left to right, then moves down a row; Columns fill down (or up) each column first.");
    if (!is_login_screen) {
        try bind.segmented(context, space, "order", "Order By", &.{ "Characters", "Hotkey Groups" });
        try widgets.hintText(context, .src(@src()), "Characters follows the Characters list; Hotkey Groups follows this space's groups in the Hotkey Groups list.");
    }
    try bind.number(context, space, "spacing", "Spacing", .{ .unit = "px" });
    try bind.toggle(context, space, "limitToThumbnailSize", "Cap Size at Thumbnail Size");
    try widgets.hintText(context, .src(@src()), "Stops thumbnails from growing past the Size setting, leaving unused space in the region instead.");
    try layout.close(context);
}

/// A pill per hotkey group, filled while this space holds it; a name no group has any more stays until it's clicked off.
fn holds(context: *ui.Frame, profile: ProfileRef, space: SpaceRef) !void {
    const groups = profile.ptr.hotkeyGroups.items;
    if (groups.len == 0) {
        try widgets.paragraph(context, .src(@src()), "No hotkey groups yet: add some in the Hotkey Groups tab to put their characters in this space.");
    }
    const arena = context.arena();
    var chips: std.ArrayList(Chip) = .empty;
    for (groups, 0..) |group, group_index| {
        if (group.name.len == 0) {
            try chips.append(arena, .{ .label = try std.fmt.allocPrint(arena, "Hotkey Group {d}", .{group_index + 1}), .name = null, .group_index = group_index });
            continue;
        }
        try chips.append(arena, .{ .label = group.name, .name = group.name });
    }
    for (space.ptr.groups.items) |name| {
        if (profile.ptr.hasHotkeyGroupNamed(name)) continue;
        try chips.append(arena, .{ .label = try std.fmt.allocPrint(arena, "{s} (no such group)", .{name}), .name = name });
    }
    if (chips.items.len == 0) return;

    const row_count = (chips.items.len + CHIP_COLUMNS.len - 1) / CHIP_COLUMNS.len;
    const rows = try arena.alloc(GridTrack, row_count);
    @memset(rows, .{ .fixed = style.GROUP_CHIP_HEIGHT });
    const grid_style = try arena.create(ui.Style);
    grid_style.* = style.group_chip_grid.with(.{ .grid = .{ .cols = &CHIP_COLUMNS, .rows = rows } });
    const grid = Rect{ .key = .src(@src()), .style = grid_style };
    _ = try grid.open(context);
    const base = ui.Key.str("knots.space.chip");
    var toggled: ?Chip = null;
    for (chips.items, 0..) |chip, chip_index| {
        search.captureText(chip.label);
        const is_held = if (chip.name) |held| space.ptr.groupIndex(held) != null else false;
        const chip_style = try arena.create(ui.Style);
        const look = if (is_held) &style.group_chip_held else &style.group_chip;
        chip_style.* = look.with(.{ .grid_cell = .{ .row = @intCast(chip_index / CHIP_COLUMNS.len), .col = @intCast(chip_index % CHIP_COLUMNS.len) } });
        if ((try context.interact(Button{
            .key = base.indexed(chip_index),
            .label = chip.label,
            .style = chip_style,
            .parts = .{ .label = if (is_held) &style.group_chip_label_held else &style.group_chip_label },
        })).clicked) toggled = chip;
    }
    try grid.close(context);
    try widgets.hintText(context, .src(@src()), "Click a group to put its characters in this space, and again to take it out.");

    const chip = toggled orelse return;
    const name = chip.name orelse try nameUnnamedGroup(arena, profile, chip.group_index);
    if (space.ptr.groupIndex(name)) |at| {
        space.remove("groups", at);
    } else {
        space.appendString("groups", name);
    }
}

/// Spaces hold groups by name, so an unnamed group takes the name its chip shows, or the next free number if another group has it.
fn nameUnnamedGroup(arena: std.mem.Allocator, profile: ProfileRef, group_index: usize) ![]const u8 {
    var number = group_index + 1;
    const name = while (true) : (number += 1) {
        const candidate = try std.fmt.allocPrint(arena, "Hotkey Group {d}", .{number});
        if (!profile.ptr.hasHotkeyGroupNamed(candidate)) break candidate;
    };
    profile.item("hotkeyGroups", group_index).set("name", name);
    return name;
}

/// Warns about each group of this space whose characters another space gets.
fn overlaps(context: *ui.Frame, items: []const config.ThumbnailSpace, index: usize) !void {
    for (items[index].groups.items, 0..) |name, held_index| {
        const winner_index = spaces.groupSpaceIn(items, name) orelse continue;
        if (winner_index == index) continue;
        const winner = &items[winner_index];
        const content = try std.fmt.allocPrint(context.arena(), "Characters in '{s}' go to '{s}' instead.", .{ name, if (winner.name.len > 0) winner.name else "Unnamed Space" });
        try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.space.overlap").indexed(held_index), .content = content, .style = &style.hint_warning });
    }
}

/// Warns that a switched-on take setting goes unused because `winner`, another space, takes them.
fn takenElsewhere(context: *ui.Frame, items: []const config.ThumbnailSpace, index: usize, winner: ?usize, comptime who: []const u8) !void {
    const winner_index = winner orelse return;
    if (winner_index == index) return;
    const name = if (items[winner_index].name.len > 0) items[winner_index].name else "Unnamed Space";
    const content = try std.fmt.allocPrint(context.arena(), who ++ " go to '{s}' instead.", .{name});
    try context.e(Text{ .selectable = false, .key = .str("knots.space.taken:" ++ who), .content = content, .style = &style.hint_warning });
}

/// Cycled by position, so neighbouring spaces stay told apart.
fn dotColor(context: *ui.Frame, index: usize) ui.Color {
    const palette = [_]ui.Color{ context.ui().theme.primary, style.SKY, style.PURPLE, style.SUCCESS };
    return palette[index % palette.len];
}

/// Buttons to draw a new rectangle for the space, adjust it, or clear it; the last two need one set.
fn regionRow(context: *ui.Frame, space_id: u32) !void {
    const row = try widgets.openRow(context, .src(@src()));
    try context.e(Rect{ .key = .src(@src()), .style = &style.spacer });
    const current = region.rect(space_id);
    if ((try context.interact(Button{ .key = .src(@src()), .label = "New Space", .style = &style.plain_button })).clicked) {
        region.start(space_id, false);
    }
    if (try widgets.glyphButton(context, .src(@src()), .pencil, "Edit", &style.plain_button, current == null)) {
        region.start(space_id, true);
    }
    if (current != null) {
        if (try widgets.confirmButton(context, .str("knots.region.clear"), "\u{00D7}", "OK", &style.icon_button_danger_text, &style.icon_button_confirm)) {
            region.clear(space_id);
        }
    } else {
        _ = try context.interact(Button{ .key = .str("knots.region.clear"), .label = "\u{00D7}", .disabled = true, .style = &style.icon_button_disabled_text });
    }
    try row.close(context);
}

/// Every monitor in miniature with every space's region, the selected one drawn last and filled stronger; clicking a region selects its space.
fn regionMap(context: *ui.Frame, items: []const config.ThumbnailSpace, initial_selected: ?usize) !void {
    var map = try ScreenMap.init(context, .str("knots.space.map"));
    const ui_state = context.ui();
    var selected = initial_selected;
    if (regionUnderMouse(&map, ui_state, items, selected)) |index| {
        ui_state.requestCursor(.pointer);
        const is_new = if (selected) |selected_index| index != selected_index else true;
        if (ui_state.leftClicked(map.key.hash(), .within) and is_new) {
            g_selected_id = items[index].id;
            selected = index;
            context.requestRedraw();
        }
    }

    const arena = context.arena();
    for (0..items.len + 1) |pass| {
        // The selected space is drawn on the last pass, over the others.
        const index = if (pass < items.len) pass else selected orelse break;
        const is_selected = if (selected) |selected_index| index == selected_index else false;
        if (pass < items.len and is_selected) continue;
        const box = regionBox(&map, &items[index]) orelse continue;
        var fill_color = dotColor(context, index).value;
        var line_color = fill_color;
        const strength: f32 = if (items[index].enabled) 1 else 0.35;
        fill_color[3] = (if (is_selected) @as(f32, 0.3) else 0.12) * strength;
        line_color[3] = strength;
        try map.addBox(arena, box, fill_color, line_color);
    }
    try map.show(context, true);
}

/// Every monitor in miniature with each hand-placed character's saved thumbnail position.
fn savedPositionMap(context: *ui.Frame, profile: ProfileRef) !void {
    var map = try ScreenMap.init(context, .str("knots.manual.map"));
    const arena = context.arena();
    const line_color = context.ui().theme.primary.value;
    var fill_color = line_color;
    fill_color[3] = 0.25;
    for (profile.ptr.characters.items) |character| {
        const position = character.position orelse continue;
        // A space ignores the saved position.
        if (spaces.spaceFor(profile.ptr, character.name) != null) continue;
        const size = profile.ptr.handPlacedSize(character.name);
        // Scaled for the monitor the thumbnail sits on, as thumbnail/arrange.zig does.
        const scale = win32.dpiToScale(win32.dpiForPoint(.{ .x = position.x, .y = position.y }));
        const rect = win32.RECT{
            .left = position.x,
            .top = position.y,
            .right = position.x + win32.scalePixels(size.width, scale),
            .bottom = position.y + win32.scalePixels(size.height, scale),
        };
        const box = map.frame.visibleBox(rect) orelse continue;
        try map.addBox(arena, box, fill_color, line_color);
    }
    try map.show(context, false);
}

fn regionBox(map: *const ScreenMap, space: *const config.ThumbnailSpace) ?screen_math.Box {
    return map.frame.visibleBox(spaces.rect(space) orelse return null);
}

/// The topmost region under the mouse, checked in reverse of the order regionMap draws them in.
fn regionUnderMouse(map: *const ScreenMap, ui_state: *ui.UI, items: []const config.ThumbnailSpace, selected: ?usize) ?usize {
    const point = map.mousePoint(ui_state) orelse return null;
    if (selected) |index| {
        if (regionBox(map, &items[index])) |box| if (screen_math.contains(box, point)) return index;
    }
    var index = items.len;
    while (index > 0) {
        index -= 1;
        if (selected) |selected_index| if (index == selected_index) continue;
        if (regionBox(map, &items[index])) |box| if (screen_math.contains(box, point)) return index;
    }
    return null;
}
