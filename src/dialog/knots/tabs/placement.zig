//! The configuration window's Layout tab: the placement mode and a screen preview, then hand-placement settings or a list of thumbnail spaces beside the selected one's details; main thread only.
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
const hotkey_groups = @import("hotkey_groups.zig");
const screen_map = @import("../screen_map.zig");
const screen_math = @import("../screen_math.zig");
const lang = @import("../../../lang/lang.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const ProfileRef = session.Ref(config.Config);
const DisplayRef = session.Ref(config.DisplayConfig);
const SpaceRef = session.Ref(config.ThumbnailSpace);
const ScreenMap = screen_map.ScreenMap;

const SPACE_ROW_KEY: ui.Key = .str("knots.space.row");
/// How faded a switched-off space is, in the list and on the map alike.
const DISABLED_SPACE_ALPHA = 0.35;
/// The selected region is filled stronger than the others, so it stands out on the map.
const SELECTED_FILL_ALPHA: f32 = 0.3;
const UNSELECTED_FILL_ALPHA: f32 = 0.12;
/// Fainter than the selected region's outline, for the same reason.
const UNSELECTED_OUTLINE_ALPHA = 0.6;
const CHIP_COLUMNS: [3]GridTrack = @splat(.{ .fr = 1 });

// knots doesn't export its grid types by name.
const GridTemplate = @typeInfo(@FieldType(ui.Style, "grid")).optional.child;
const GridTrack = @typeInfo(@FieldType(GridTemplate, "rows")).pointer.child;

/// A pill in a space's Holds grid.
const Chip = struct {
    label: []const u8,
    /// The group name it toggles; null for an unnamed group, which is named when clicked.
    name: ?[]const u8,
    /// The unnamed group's index in hotkeyGroups.
    group_index: usize = 0,
};

/// Unassigned characters or login-screen clients: who a built-in space holds, or a space can take.
const Destination = enum {
    unassigned,
    login_screen,

    fn spaceIn(self: Destination, items: []const config.ThumbnailSpace) ?usize {
        return switch (self) {
            .unassigned => spaces.unassignedSpaceIn(items),
            .login_screen => spaces.loginScreenSpaceIn(items),
        };
    }

    fn isHeldBy(self: Destination, space: *const config.ThumbnailSpace) bool {
        return switch (self) {
            .unassigned => space.holdsUnassigned,
            .login_screen => space.holdsLoginScreen,
        };
    }

    fn isTakenBy(self: Destination, space: *const config.ThumbnailSpace) bool {
        return switch (self) {
            .unassigned => space.takesUnassigned,
            .login_screen => space.takesLoginScreen,
        };
    }
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

    const section = try widgets.openSection(context, "Thumbnail Placement", "Drag thumbnails where you want them, or let Thumbnail Spaces arrange them.", &style.section);
    try bind.segmented(context, display, "placementMode", "Placement Mode", &.{ "Manual", "Thumbnail Spaces" });
    try widgets.hintText(context, .src(@src()), "Thumbnail Spaces arranges thumbnails for you in areas you draw.");
    if (shows_manual) try savedPositionMap(context, profile);
    if (shows_spaces) {
        const items = profile.ptr.thumbnailSpaces.items;
        try regionMap(context, items, selectedIndex(items));
        try bind.toggle(context, display, "hideThumbnailsDuringRegionSelect", "Hide Thumbnails While Drawing a Region");
        try widgets.hintText(context, .src(@src()), "Only while you draw, so you can see the whole screen.");
    }
    try section.close(context);

    if (shows_manual) {
        const manual_section = try widgets.openSection(context, "Manual Placement", "Where thumbnails go when you place them by hand.", &style.section);
        try manual(context, display);
        try manual_section.close(context);
    }
    if (shows_spaces) {
        const spaces_section = try widgets.openSection(context, "Thumbnail Spaces", "Screen areas that arrange hotkey groups. Drag to reorder; the higher one wins.", if (fillsWindow()) &style.fill_section else &style.section);
        try spacesMode(context);
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

    const can_drag = !interaction.get("clickThrough") and interaction.get("enableDragging");
    const dragging = try widgets.openFieldGroup(context, .str("knots.manual.dragging"), "Dragging");
    const drag = try widgets.openGroup(context, .src(@src()), !interaction.get("clickThrough"));
    try bind.toggle(context, interaction, "enableDragging", "Enable Dragging");
    try drag.close(context);
    try widgets.hintText(context, .src(@src()), "Stays off while Click Through is on in the Mouse & Windows tab.");
    try bind.toggle(context, display, "honorSavedPositions", "Restore Saved Positions");
    try widgets.hintText(context, .src(@src()), "When off, thumbnails always start at the Start Position.");
    try dragging.close(context);
    try widgets.separator(context, .str("knots.manual.separator.dragging"));

    const snapping = profile.child("snapping");
    const snapping_group = try widgets.openFieldGroup(context, .str("knots.manual.snapping"), "Snapping");
    const drag_options = try widgets.openGroup(context, .src(@src()), can_drag);
    try bind.toggle(context, snapping, "enabled", "Snap While Dragging");
    try widgets.hintText(context, .src(@src()), "Turns all the snapping below on or off.");
    const group = try widgets.openGroup(context, .src(@src()), snapping.get("enabled"));
    try bind.toggle(context, snapping, "screenEdges", "Snap to Screen Edges");
    try widgets.hintText(context, .src(@src()), "Thumbnails stick to the edges of your monitors.");
    try bind.toggle(context, snapping, "thumbnailEdges", "Snap to Thumbnail Edges");
    try widgets.hintText(context, .src(@src()), "Thumbnails stick to each other's edges.");
    try bind.toggle(context, snapping, "ghostPositions", "Snap to Other Characters' Saved Positions");
    try widgets.hintText(context, .src(@src()), "Includes characters that aren't logged in.");
    try bind.number(context, snapping, "threshold", "Snap Distance", .{ .unit = "px" });
    try widgets.hintText(context, .src(@src()), "How close a thumbnail gets before it snaps into place.");
    try group.close(context);
    try bind.toggle(context, snapping, "showGhostPositionBorders", "Outline Saved Positions While Dragging");
    try widgets.hintText(context, .src(@src()), "Shows the spots you can snap to.");
    try drag_options.close(context);
    try snapping_group.close(context);
    try widgets.separator(context, .str("knots.manual.separator.snapping"));

    const unplaced = try widgets.openFieldGroup(context, .str("knots.manual.new"), "Unplaced");
    const start = try widgets.openBinding(context, .src(@src()), "Start Position");
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "X", .style = &style.muted_text });
    try bind.unitNumberBox(context, display, "startX", "px", .{});
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "Y", .style = &style.muted_text });
    try bind.unitNumberBox(context, display, "startY", "px", .{});
    try start.close(context);
    try widgets.hintText(context, .src(@src()), "Characters with no saved position line up from here, left to right.");
    try bind.number(context, display, "newThumbnailSpacing", "Spacing", .{ .unit = "px" });
    try widgets.hintText(context, .src(@src()), "The gap between thumbnails lined up from the Start Position.");
    try unplaced.close(context);
}

fn spacesMode(context: *ui.Frame) !void {
    const profile = session.profile();
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
    const list = try widgets.openRoster(context, .str("knots.space.roster"), if (is_filling) &style.roster else &style.roster_filters, is_filling);
    if (items.len == 0) {
        try widgets.boxedText(context, .src(@src()), "No spaces yet.", &style.roster_empty, &style.roster_empty_text);
    }
    const fixed_count = fixedCount(items);
    // Fixed rows don't join the drag, so nothing can be dropped above them.
    var order = widgets.ReorderList.begin(context, SPACE_ROW_KEY, items.len, fixed_count);
    for (items, 0..) |*space, index| {
        if (index >= fixed_count) try widgets.reorderRow(context, SPACE_ROW_KEY, index);
        if (try order.next(context, index)) try spaceRow(context, space, index, null);
    }
    if (try order.end(context)) |lifted| {
        const lifted_style = try order.liftedStyle(context, list.rowsKey(), if (items[lifted].id == g_selected_id) &style.roster_row_selected else &style.roster_row);
        try spaceRow(context, &items[lifted], lifted, lifted_style);
    }
    const is_full = items.len >= spaces.MAX_SPACES;
    const action = try list.close(context, .{ .add_label = "Add Space", .is_add_disabled = is_full });

    if (widgets.reorderFinish(context, SPACE_ROW_KEY, items.len)) |moved| profile.move("thumbnailSpaces", moved.from, @max(moved.before, fixed_count));
    if (action == .add) {
        if (profile.append("thumbnailSpaces", .{ .name = lang.text("New Space") })) |added| g_selected_id = added.get("id");
    }
}

fn spaceName(context: *ui.Frame, space: *const config.ThumbnailSpace, index: usize) ![]const u8 {
    if (isBuiltIn(space)) return lang.text(space.name);
    const name = try bind.liveText(context, session.profile().item("thumbnailSpaces", index), "name");
    return if (name.len > 0) name else lang.text("Unnamed Space");
}

/// Always listed and never renamed, so their saved English names show translated.
fn isBuiltIn(space: *const config.ThumbnailSpace) bool {
    return space.holdsLoginScreen or space.holdsUnassigned;
}

fn shownName(space: *const config.ThumbnailSpace) []const u8 {
    if (isBuiltIn(space)) return lang.text(space.name);
    return if (space.name.len > 0) space.name else lang.text("Unnamed Space");
}

/// `lifted_style` while it's being dragged, otherwise the roster's own.
fn spaceRow(context: *ui.Frame, space: *const config.ThumbnailSpace, index: usize, lifted_style: ?*const ui.Style) !void {
    const arena = context.arena();
    const is_selected = space.id == g_selected_id;
    const row = Button{ .key = SPACE_ROW_KEY.indexed(index), .style = lifted_style orelse if (is_selected) &style.roster_row_selected else &style.roster_row };
    if ((try widgets.openRosterRow(context, row)).clicked and !is_selected) {
        g_selected_id = space.id;
        context.requestRedraw();
    }
    const dot_style = try arena.create(ui.Style);
    dot_style.* = style.space_dot.with(.{ .background = .{ .color = dotColor(context, space.id) }, .opacity = if (space.enabled) @as(f32, 1) else DISABLED_SPACE_ALPHA });
    try context.e(Rect{ .key = ui.Key.str("knots.space.dot").indexed(index), .style = dot_style });
    const name = try spaceName(context, space, index);
    search.captureText(name);
    try context.e(Text{
        .selectable = false,
        .key = ui.Key.str("knots.space.name").indexed(index),
        .content = name,
        .style = if (is_selected) &style.roster_name_selected else &style.roster_name,
    });
    const has_region = spaces.rect(space) != null;
    var badge: []const u8 = "";
    if (!space.enabled or !has_region) {
        const is_warning = space.enabled;
        badge = lang.text(if (is_warning) "No region" else "Off");
        try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.space.state").indexed(index), .content = badge, .style = if (is_warning) &style.roster_badge_warning else &style.roster_badge });
    }
    try widgets.fitRosterRow(context, name, style.SPACE_DOT_SIZE, badge);
    try row.close(context);
}

/// Login Screen and Unassigned Characters stay at the top, as config load puts them (see config/spaces.zig).
fn fixedCount(items: []const config.ThumbnailSpace) usize {
    var count: usize = 0;
    while (count < items.len and isBuiltIn(&items[count])) count += 1;
    return count;
}

fn detail(context: *ui.Frame, profile: ProfileRef, index: usize) !void {
    const space = profile.item("thumbnailSpaces", index);
    const id = space.get("id");
    const is_login_screen = space.get("holdsLoginScreen");
    const is_unassigned = space.get("holdsUnassigned");
    // The Login Screen and Unassigned Characters spaces are always in the list, so they can't be renamed or removed.
    const is_special = isBuiltIn(space.ptr);
    const previous_rows = widgets.useDetailRows();
    defer widgets.restoreRows(previous_rows);
    const header = try widgets.openDetailHeader(context, .src(@src()));
    const name_label = lang.text("Name");
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = name_label, .style = try widgets.detailLabelStyle(context, name_label) });
    var removed = false;
    if (is_special) {
        const name = Rect{ .key = .src(@src()), .style = &style.space_fixed_name };
        _ = try name.open(context);
        try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text(space.get("name")), .style = &style.space_fixed_name_text });
        try name.close(context);
        const tag = Rect{ .key = .src(@src()), .style = &style.space_built_in_tag };
        _ = try tag.open(context);
        try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("Built-in"), .style = &style.hint_plain });
        try tag.close(context);
    } else {
        try bind.textBox(context, space, "name", "e.g., Miners");
        removed = try widgets.confirmButton(context, ui.Key.str("knots.space.remove").indexed(id), "Remove", "Confirm", &style.plain_button, &style.confirm_button);
    }
    try header.close(context);
    if (removed) {
        const items = profile.ptr.thumbnailSpaces.items;
        g_selected_id = if (index + 1 < items.len) items[index + 1].id else if (index > 0) items[index - 1].id else 0;
        profile.remove("thumbnailSpaces", index);
        return;
    }

    var is_enabled: bool = space.get("enabled");
    if (try widgets.switchRow(context, ui.Key.str("knots.space.enabled").indexed(id), "Enabled", &is_enabled)) space.set("enabled", is_enabled);
    try widgets.hintText(context, .src(@src()), "When off, its characters go to the next space that holds them, or are placed by hand.");
    try widgets.separator(context, .str("knots.space.separator.enabled"));

    const settings = try widgets.openGroup(context, .src(@src()), is_enabled);
    const area = try widgets.openFieldGroup(context, .str("knots.space.region"), "Region");
    try regionRow(context, id);
    try widgets.hintText(context, .src(@src()), "Draw marks out an area on screen; Edit moves or resizes it.");
    try area.close(context);
    try widgets.separator(context, .str("knots.space.separator.region"));

    const items = profile.ptr.thumbnailSpaces.items;
    const held = try widgets.openFieldGroup(context, .str("knots.space.holds"), "Holds");
    if (is_special) {
        // A settings row rather than a paragraph, so the text lines up with the Holds label.
        const row = try widgets.openRow(context, .src(@src()));
        try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text(if (is_login_screen) "Clients still at the login screen." else "Characters no other active space holds."), .style = &style.hint });
        try row.close(context);
        const kind: Destination = if (is_login_screen) .login_screen else .unassigned;
        const winner = kind.spaceIn(items);
        if (winner != index) try destination(context, items, winner, kind);
    } else {
        try holds(context, profile, space);
        try overlaps(context, items, index);
    }
    try held.close(context);

    // Login Screen taking unassigned characters would mix them with logins, so it's shown only to switch off.
    const shows_unassigned = !is_unassigned and (!is_login_screen or space.get("takesUnassigned")) and showsTake(items, space.ptr, .unassigned);
    const shows_login_screen = !is_login_screen and showsTake(items, space.ptr, .login_screen);
    if (shows_unassigned or shows_login_screen) {
        try widgets.separator(context, .str("knots.space.separator.holds"));
        const behavior = try widgets.openFieldGroup(context, .str("knots.space.behavior"), "Behavior");
        if (shows_unassigned) {
            try bind.toggle(context, space, "takesUnassigned", "Move Unassigned Characters to the End");
            try widgets.hintText(context, .src(@src()), "Characters not in any space go here, after its own.");
        }
        if (shows_login_screen) {
            try bind.toggle(context, space, "takesLoginScreen", "Move Logged-Out Characters to the End");
            try widgets.hintText(context, .src(@src()), "Characters at the login screen go here, after its own.");
        }
        try behavior.close(context);
    }
    try widgets.separator(context, .str("knots.space.separator.behavior"));

    const layout = try widgets.openFieldGroup(context, .str("knots.space.layout"), "Layout");
    try bind.choice(context, space, "direction", "Fill Order");
    try widgets.hintText(context, .src(@src()), "Which way thumbnails fill the space.");
    if (!is_login_screen) {
        try bind.segmented(context, space, "order", "Order By", &.{ "Characters", "Hotkey Groups" });
        try widgets.hintText(context, .src(@src()), "The Characters list's order, or this space's groups in order.");
    }
    try bind.number(context, space, "spacing", "Spacing", .{ .unit = "px" });
    try widgets.hintText(context, .src(@src()), "The gap between thumbnails in this space.");
    try bind.toggle(context, space, "limitToThumbnailSize", "Cap Size at Thumbnail Size");
    try widgets.hintText(context, .src(@src()), "Thumbnails stay at Size, even if there's room to grow.");
    try layout.close(context);
    try settings.close(context);
}

/// Moot while its built-in space places everyone, so then shown only if on, to switch off.
fn showsTake(items: []const config.ThumbnailSpace, space: *const config.ThumbnailSpace, kind: Destination) bool {
    if (kind.isTakenBy(space)) return true;
    const winner = kind.spaceIn(items) orelse return true;
    return !kind.isHeldBy(&items[winner]);
}

/// Where `kind` goes while its built-in space isn't placing them: to `winner`, or by hand when null.
fn destination(context: *ui.Frame, items: []const config.ThumbnailSpace, winner: ?usize, kind: Destination) !void {
    const arena = context.arena();
    const content = if (winner) |winner_index| switch (kind) {
        .unassigned => try lang.format(arena, "Unassigned characters go to '{space}'.", .{ .space = shownName(&items[winner_index]) }),
        .login_screen => try lang.format(arena, "Logged-out characters go to '{space}'.", .{ .space = shownName(&items[winner_index]) }),
    } else switch (kind) {
        .unassigned => lang.text("Unassigned characters are placed by hand."),
        .login_screen => lang.text("Logged-out characters are placed by hand."),
    };
    try widgets.boxedText(context, .str("knots.space.destination"), content, &style.hint_box, &style.hint);
}

/// A pill per hotkey group, filled while held; a name no group has stays until clicked off.
fn holds(context: *ui.Frame, profile: ProfileRef, space: SpaceRef) !void {
    const groups = profile.ptr.hotkeyGroups.items;
    if (groups.len == 0) {
        try widgets.paragraph(context, .src(@src()), "No hotkey groups yet: add some in the Hotkey Groups tab to put their characters in this space.");
    }
    const arena = context.arena();
    var chips: std.ArrayList(Chip) = .empty;
    for (groups, 0..) |group, group_index| {
        if (group.name.len == 0) {
            try chips.append(arena, .{ .label = try lang.format(arena, hotkey_groups.UNNAMED_GROUP_FORMAT, .{ .n = group_index + 1 }), .name = null, .group_index = group_index });
            continue;
        }
        try chips.append(arena, .{ .label = group.name, .name = group.name });
    }
    for (space.ptr.groups.items) |name| {
        if (profile.ptr.hasHotkeyGroupNamed(name)) continue;
        try chips.append(arena, .{ .label = try lang.format(arena, "{name} (no such group)", .{ .name = name }), .name = name });
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
    try widgets.paragraph(context, .src(@src()), "Click a group to put its characters in this space, and again to take it out.");

    const chip = toggled orelse return;
    const name = chip.name orelse try nameUnnamedGroup(arena, profile, chip.group_index);
    if (space.ptr.groupIndex(name)) |at| {
        space.remove("groups", at);
    } else {
        space.appendString("groups", name);
    }
}

/// Spaces hold groups by name, so an unnamed group takes its chip's name, or the next free number.
fn nameUnnamedGroup(arena: std.mem.Allocator, profile: ProfileRef, group_index: usize) ![]const u8 {
    var number = group_index + 1;
    const name = while (true) : (number += 1) {
        const candidate = try lang.format(arena, hotkey_groups.UNNAMED_GROUP_FORMAT, .{ .n = number });
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
        const content = try lang.format(context.arena(), "Characters in '{group}' go to '{space}' instead.", .{ .group = name, .space = shownName(winner) });
        try widgets.boxedText(context, ui.Key.str("knots.space.overlap").indexed(held_index), content, &style.hint_box, &style.hint_warning);
    }
}

/// Cycled by id rather than position, so a space keeps its colour while the list is reordered.
fn dotColor(context: *ui.Frame, space_id: u32) ui.Color {
    const palette = [_]ui.Color{ context.ui().theme.primary, style.SKY, style.PURPLE, style.SUCCESS };
    return palette[space_id % palette.len];
}

/// The space's rectangle, then Draw while it has none or Edit to move or resize it, and × to clear it.
fn regionRow(context: *ui.Frame, space_id: u32) !void {
    const current = region.rect(space_id);
    const shown = if (current) |rect| try lang.format(context.arena(), "{width} \u{00D7} {height} at {x}, {y}", .{
        .width = rect.right - rect.left,
        .height = rect.bottom - rect.top,
        .x = rect.left,
        .y = rect.top,
    }) else lang.text("Not drawn yet");
    const row = try widgets.openBinding(context, .src(@src()), shown);
    if (current == null) {
        if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Draw"), .style = &style.plain_button })).clicked) region.start(space_id, false);
        _ = try context.interact(Button{ .key = .str("knots.region.clear"), .label = "\u{00D7}", .disabled = true, .style = &style.icon_button_disabled_text });
    } else {
        if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Edit"), .style = &style.plain_button })).clicked) region.start(space_id, true);
        if (try widgets.confirmButton(context, .str("knots.region.clear"), "\u{00D7}", "OK", &style.icon_button_danger_text, &style.icon_button_confirm)) region.clear(space_id);
    }
    try row.close(context);
}

/// The selected region is drawn last, stronger and thicker; clicking a region selects its space.
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
        var fill_color = dotColor(context, items[index].id).value;
        var line_color = fill_color;
        const strength: f32 = if (items[index].enabled) 1 else DISABLED_SPACE_ALPHA;
        fill_color[3] = (if (is_selected) SELECTED_FILL_ALPHA else UNSELECTED_FILL_ALPHA) * strength;
        line_color[3] = (if (is_selected) @as(f32, 1) else UNSELECTED_OUTLINE_ALPHA) * strength;
        try map.addBox(arena, box, fill_color, line_color);
        // A second outline just inside doubles the selected region's border, unless the box is too small to inset.
        if (is_selected and box[2] > 4 and box[3] > 4) try map.addBox(arena, .{ box[0] + 1, box[1] + 1, box[2] - 2, box[3] - 2 }, @splat(0), line_color);
    }
    try map.show(context, true);
}

/// Every monitor in miniature with each hand-placed character's saved thumbnail position.
fn savedPositionMap(context: *ui.Frame, profile: ProfileRef) !void {
    var map = try ScreenMap.init(context, .str("knots.manual.map"));
    for (profile.ptr.characters.items) |character| {
        const position = character.position orelse continue;
        // A space ignores the saved position.
        if (spaces.spaceFor(profile.ptr, character.name) != null) continue;
        const size = profile.ptr.handPlacedSize(character.name);
        // Scaled for the monitor the thumbnail sits on, as thumbnail/arrange.zig does.
        const scale = win32.dpiToScale(win32.dpiForPoint(.{ .x = position.x, .y = position.y }));
        const rect: win32.RECT = .{
            .left = position.x,
            .top = position.y,
            .right = position.x + win32.scalePixels(size.width, scale),
            .bottom = position.y + win32.scalePixels(size.height, scale),
        };
        const box = map.frame.visibleBox(rect) orelse continue;
        try map.addSavedPosition(context, box);
    }
    try map.show(context, false);
}

/// Null for a switched-off built-in space, which the map leaves out rather than fades.
fn regionBox(map: *const ScreenMap, space: *const config.ThumbnailSpace) ?screen_math.Box {
    if (!space.enabled and isBuiltIn(space)) return null;
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
