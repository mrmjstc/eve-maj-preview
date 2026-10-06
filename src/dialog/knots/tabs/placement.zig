//! The Display tab's Thumbnail Placement section: snapping for hand-placed thumbnails and a card per thumbnail space; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../config.zig");
const spaces = @import("../../../layout/spaces.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const region = @import("../region.zig");
const search = @import("../search.zig");
const glyphs = @import("../glyphs.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Canvas = ui.component.Canvas;
const ProfileRef = session.Ref(config.Config);
const DisplayRef = session.Ref(config.DisplayConfig);
const SpaceRef = session.Ref(config.ThumbnailSpace);

const GRIP_KEY: ui.Key = .str("knots.space.grip");
/// Keys the snapping card apart from the space cards, which use their list index.
const SNAPPING_CARD_INDEX = std.math.maxInt(u32);

const RegionStatus = struct { text: []const u8, is_missing: bool };

/// A foldable card, open between openCard and close; its header is still open for the caller's switch until openBody.
const Card = struct {
    index: u64,
    rect: Rect,
    header: Rect,
    is_open: bool,
    /// The header was clicked this frame, to fold or unfold the card.
    toggled: bool,

    /// Closes the header; returns the body to fill when the card is unfolded and `is_enabled`, or a search wants its rows.
    fn openBody(self: *const Card, context: *ui.Frame, is_enabled: bool) !?widgets.Group {
        try self.header.close(context);
        if (!self.is_open or !widgets.showsDependents(is_enabled)) return null;
        const body = Rect{ .key = ui.Key.str("knots.card.body").indexed(self.index), .style = &style.space_card_body };
        _ = try body.open(context);
        g_open_body = body;
        return try widgets.openGroup(context, ui.Key.str("knots.card.group").indexed(self.index), is_enabled);
    }

    fn close(self: *const Card, context: *ui.Frame) !void {
        if (g_open_body) |body| {
            try body.close(context);
            g_open_body = null;
        }
        try self.rect.close(context);
    }
};

const CardLook = struct {
    dot: ?ui.Color = null,
    name: []const u8,
    who: []const u8 = "",
    state_text: []const u8 = "",
    is_warning: bool = false,
    /// Draws a drag handle keyed GRIP_KEY.indexed(index) ahead of the fold button.
    has_grip: bool = false,
    drop: widgets.DropMark = .none,
};

/// Whether the snapping card is unfolded; not saved.
var g_snapping_open = true;
/// The ids of the unfolded space cards; not saved.
var g_open_space_ids: [spaces.MAX_SPACES]u32 = undefined;
var g_open_space_count: usize = 0;
/// The body of the card being drawn, closed by Card.close.
var g_open_body: ?Rect = null;

pub fn show(context: *ui.Frame, display: DisplayRef) !void {
    const section = try widgets.openSection(context, "Thumbnail Placement", "Drag thumbnails where you want them, or draw spaces that chosen hotkey groups' thumbnails fill automatically. A character two spaces hold goes to the first one; drag a space's handle to reorder.", &style.section);
    try snappingCard(context);

    const profile = session.profile();
    const count = profile.ptr.thumbnailSpaces.items.len;
    var removed: ?usize = null;
    for (0..count) |index| {
        if (try spaceCard(context, profile, index)) removed = index;
    }
    if (widgets.reorderFinish(context, GRIP_KEY, count)) |moved| profile.move("thumbnailSpaces", moved.from, moved.before);
    if (removed) |index| {
        setOpen(profile.ptr.thumbnailSpaces.items[index].id, false);
        profile.remove("thumbnailSpaces", index);
    }

    const is_full = profile.ptr.thumbnailSpaces.items.len >= spaces.MAX_SPACES;
    if ((try context.interact(Button{ .key = .src(@src()), .label = "+ Add Space", .disabled = is_full, .style = &style.full_width_button })).clicked) {
        profile.append("thumbnailSpaces", .{ .name = "New Space" });
        const items = profile.ptr.thumbnailSpaces.items;
        if (items.len > count) setOpen(items[items.len - 1].id, true);
    }

    try bind.toggle(context, display, "regionFitReorderLoggedOut", "Move Logged-Out Characters to the End");
    try widgets.hintText(context, .src(@src()), "When off, a logged-out character's spot in its space stays put until the next reflow instead of closing the gap immediately.");
    try bind.toggle(context, display, "hideThumbnailsDuringRegionSelect", "Hide Thumbnails While Drawing a Region");
    try widgets.hintText(context, .src(@src()), "Temporarily hides visible thumbnails so they don't cover the drag-to-select overlay.");
    try section.close(context);
}

fn snappingCard(context: *ui.Frame) !void {
    const ref = session.profile().child("snapping");
    var is_enabled: bool = ref.get("enabled");
    const card = try openCard(context, SNAPPING_CARD_INDEX, .{ .name = "Snap While Dragging", .who = "Characters no space holds" }, g_snapping_open);
    if (card.toggled) g_snapping_open = !g_snapping_open;
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

/// Returns whether its Remove was confirmed, so the caller removes it once the list is drawn.
fn spaceCard(context: *ui.Frame, profile: ProfileRef, index: usize) !bool {
    const space = profile.item("thumbnailSpaces", index);
    const id = space.get("id");
    var is_enabled: bool = space.get("enabled");
    const region_state = try regionStatus(context, id);
    const drop = try widgets.reorderRow(context, GRIP_KEY, index, profile.ptr.thumbnailSpaces.items.len);
    const card = try openCard(context, index, .{
        .dot = dotColor(context, index),
        .name = if (space.get("name").len > 0) space.get("name") else "Unnamed Space",
        .who = try holdsSummary(context, space.ptr),
        .state_text = region_state.text,
        .is_warning = region_state.is_missing and is_enabled,
        .has_grip = true,
        .drop = drop,
    }, isOpen(id));
    if (card.toggled) setOpen(id, !isOpen(id));
    if (try widgets.toggleSwitch(context, ui.Key.str("knots.space.enabled").indexed(index), &is_enabled)) space.set("enabled", is_enabled);

    var removed = false;
    if (try card.openBody(context, is_enabled)) |body| {
        try bind.text(context, space, "name", "Name", "e.g., Miners");
        try holds(context, profile, space);
        try bind.toggle(context, space, "takesUnassigned", "Unassigned Characters Go to the End");
        try widgets.hintText(context, ui.Key.str("knots.space.unassigned.hint").indexed(index), "Characters no space holds fill in after this space's own. Only the first space with this on takes them; with none, they're placed by hand.");
        try regionRow(context, index, id);
        try bind.choiceStyled(context, space, "direction", "Fill Order", &style.select_narrow);
        try widgets.hintText(context, ui.Key.str("knots.space.direction.hint").indexed(index), "The order the grid fills: Rows \u{2192} \u{2193} fills each row left to right, then moves down a row; Columns fill down (or up) each column first.");
        try bind.segmented(context, space, "order", "Order By", &.{ "Characters", "Hotkey Groups" });
        try widgets.hintText(context, ui.Key.str("knots.space.order.hint").indexed(index), "Characters follows the Characters list; Hotkey Groups follows this space's groups in the Hotkey Groups list.");
        try bind.number(context, space, "spacing", "Spacing", .{ .unit = "px" });
        try bind.toggle(context, space, "limitToThumbnailSize", "Cap Size at Thumbnail Size");
        try widgets.hintText(context, ui.Key.str("knots.space.cap.hint").indexed(index), "Stops thumbnails from growing past the Size setting, leaving unused space in the region instead.");
        const remove_row = try widgets.openBinding(context, ui.Key.str("knots.space.remove.row").indexed(index), "");
        removed = try widgets.confirmButton(context, ui.Key.str("knots.space.remove").indexed(index), "Remove Space", "Confirm", &style.plain_button, &style.confirm_button);
        try remove_row.close(context);
        try body.close(context);
    }
    try card.close(context);
    return removed;
}

/// A switch per hotkey group, then Login Screen; a name no group has any more stays listed until it's switched off.
fn holds(context: *ui.Frame, profile: ProfileRef, space: SpaceRef) !void {
    const base = ui.Key.str("knots.space.holds");
    const space_key = space.index << 16;
    for (profile.ptr.hotkeyGroups.items, 0..) |group, group_index| {
        const key = base.indexed(space_key | group_index);
        if (group.name.len == 0) {
            const unnamed = try widgets.openGroup(context, key.indexed(5), false);
            var is_held = false;
            _ = try widgets.checkbox(context, key, try std.fmt.allocPrint(context.arena(), "Hotkey Group {d} (name it to add it)", .{group_index + 1}), &is_held);
            try unnamed.close(context);
            continue;
        }
        try groupSwitch(context, space, key, group.name, group.name);
    }
    for (space.ptr.groups.items, 0..) |name, held_index| {
        if (profile.ptr.hasHotkeyGroupNamed(name)) continue;
        const key = ui.Key.str("knots.space.holds_missing").indexed(space_key | held_index);
        try groupSwitch(context, space, key, name, try std.fmt.allocPrint(context.arena(), "{s} (no such group)", .{name}));
    }
    try bind.toggle(context, space, "holdsLoginScreen", "Clients at the Login Screen");
}

fn groupSwitch(context: *ui.Frame, space: SpaceRef, key: ui.Key, name: []const u8, label: []const u8) !void {
    const held_at = space.ptr.groupIndex(name);
    var is_held = held_at != null;
    if (!try widgets.checkbox(context, key, label, &is_held)) return;
    if (held_at) |at| {
        space.remove("groups", at);
    } else {
        space.appendString("groups", name);
    }
}

/// e.g. "Miners, Login Screen + unassigned", for the folded card.
fn holdsSummary(context: *ui.Frame, space: *const config.ThumbnailSpace) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    const arena = context.arena();
    for (space.groups.items) |name| {
        if (text.items.len > 0) try text.appendSlice(arena, ", ");
        try text.appendSlice(arena, name);
    }
    if (space.holdsLoginScreen) {
        if (text.items.len > 0) try text.appendSlice(arena, ", ");
        try text.appendSlice(arena, "Login Screen");
    }
    if (space.takesUnassigned) try text.appendSlice(arena, if (text.items.len > 0) " + unassigned" else "Unassigned characters");
    if (text.items.len == 0) return "Holds no one yet";
    return text.items;
}

/// Cycled by position, so neighbouring spaces stay told apart.
fn dotColor(context: *ui.Frame, index: usize) ui.Color {
    const palette = [_]ui.Color{ context.ui().theme.primary, style.SKY, style.PURPLE, style.SUCCESS };
    return palette[index % palette.len];
}

fn isOpen(id: u32) bool {
    return std.mem.indexOfScalar(u32, g_open_space_ids[0..g_open_space_count], id) != null;
}

fn setOpen(id: u32, is_open: bool) void {
    const at = std.mem.indexOfScalar(u32, g_open_space_ids[0..g_open_space_count], id);
    if (is_open) {
        if (at != null or g_open_space_count == g_open_space_ids.len) return;
        g_open_space_ids[g_open_space_count] = id;
        g_open_space_count += 1;
    } else if (at) |index| {
        g_open_space_count -= 1;
        g_open_space_ids[index] = g_open_space_ids[g_open_space_count];
    }
}

/// The space's region as "width × height", or that it hasn't been drawn.
fn regionStatus(context: *ui.Frame, space_id: u32) !RegionStatus {
    const rect = region.rect(space_id) orelse return .{ .text = "No region yet", .is_missing = true };
    return .{ .text = try std.fmt.allocPrint(context.arena(), "{d} \u{00D7} {d}", .{ rect.right - rect.left, rect.bottom - rect.top }), .is_missing = false };
}

/// A card with its fold arrow, colour dot, name, who it holds and its region's state; the caller adds a switch, then calls openBody.
fn openCard(context: *ui.Frame, index: u64, look: CardLook, is_open: bool) !Card {
    const shows_open = is_open or search.isActive();
    const rect = Rect{ .key = ui.Key.str("knots.card").indexed(index), .style = switch (look.drop) {
        .above => &style.space_card_drop_above,
        .below => &style.space_card_drop_below,
        .none => if (shows_open) &style.space_card_open else &style.space_card,
    } };
    _ = try rect.open(context);
    const header = Rect{ .key = ui.Key.str("knots.card.header").indexed(index), .style = &style.space_card_header };
    _ = try header.open(context);

    if (look.has_grip) {
        const grip = Button{ .key = GRIP_KEY.indexed(index), .style = &style.space_card_grip };
        _ = try grip.openResponse(context);
        const grip_glyph_key = ui.Key.str("knots.card.grip_glyph").indexed(index);
        try context.e(Canvas{
            .key = grip_glyph_key,
            .commands = try glyphs.commands(context.arena(), .grip, 10, try glyphs.snapOffset(context, grip_glyph_key), style.MUTED.value),
            .style = &style.space_card_chevron,
        });
        try grip.close(context);
    }

    const toggle = Button{ .key = ui.Key.str("knots.card.toggle").indexed(index), .style = &style.space_card_toggle };
    const response = try toggle.openResponse(context);
    const chevron_key = ui.Key.str("knots.card.chevron").indexed(index);
    try context.e(Canvas{
        .key = chevron_key,
        .commands = try glyphs.commands(context.arena(), if (shows_open) .chevron_down else .chevron_right, 10, try glyphs.snapOffset(context, chevron_key), style.MUTED.value),
        .style = &style.space_card_chevron,
    });
    if (look.dot) |color| {
        const dot_style = try context.arena().create(ui.Style);
        dot_style.* = style.space_card_dot.with(.{ .background = .{ .color = color } });
        try context.e(Rect{ .key = ui.Key.str("knots.card.dot").indexed(index), .style = dot_style });
    }
    search.captureText(look.name);
    try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.card.name").indexed(index), .content = look.name, .style = &style.space_card_name });
    if (look.who.len > 0) try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.card.who").indexed(index), .content = look.who, .style = &style.muted_text });
    try context.e(Rect{ .key = ui.Key.str("knots.card.fill").indexed(index), .style = &style.fill });
    if (look.state_text.len > 0) try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.card.status").indexed(index), .content = look.state_text, .style = if (look.is_warning) &style.space_card_status_warning else &style.muted_text });
    try toggle.close(context);
    if (response.clicked) context.requestRedraw();
    return .{ .index = index, .rect = rect, .header = header, .is_open = shows_open, .toggled = response.clicked };
}

/// Buttons to draw a new rectangle for the space, adjust it, or clear it; the last two need one set.
fn regionRow(context: *ui.Frame, index: usize, space_id: u32) !void {
    const row = try widgets.openBinding(context, ui.Key.str("knots.region.row").indexed(index), "Region");
    const current = region.rect(space_id);
    if ((try context.interact(Button{ .key = ui.Key.str("knots.region.new").indexed(index), .label = "New", .style = &style.plain_button })).clicked) {
        region.start(space_id, false);
    }
    if (try widgets.glyphButton(context, ui.Key.str("knots.region.edit").indexed(index), .pencil, "Edit", &style.plain_button, current == null)) {
        region.start(space_id, true);
    }
    if (current != null) {
        if (try widgets.confirmButton(context, ui.Key.str("knots.region.clear").indexed(index), "\u{00D7}", "OK", &style.icon_button_danger_text, &style.icon_button_confirm)) {
            region.clear(space_id);
        }
    } else {
        _ = try context.interact(Button{ .key = ui.Key.str("knots.region.clear").indexed(index), .label = "\u{00D7}", .disabled = true, .style = &style.icon_button_disabled_text });
    }
    try row.close(context);
}
