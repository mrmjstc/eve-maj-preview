//! The configuration window's Characters tab: a reorderable roster beside the selected character's details; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../config.zig");
const ranges = @import("../../../config/ranges.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const hotkey = @import("../hotkey.zig");
const images = @import("../images.zig");
const portraits = @import("../portraits.zig");
const positions = @import("../positions.zig");
const roster_mod = @import("../roster.zig");
const selection = @import("../selection.zig");
const screen_map = @import("../screen_map.zig");
const screen_math = @import("../screen_math.zig");
const suggest = @import("../suggest.zig");
const status = @import("../status.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const lang = @import("../../../lang/lang.zig");
const window_mod = @import("../window.zig");
const log = @import("../../../log.zig");

const ScreenMap = screen_map.ScreenMap;
const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const ProfileRef = session.Ref(config.Config);
const CharacterRef = session.Ref(config.CharacterConfig);
const Window = window_mod.Window;
const slog = log.Scoped("dialog_knots");

const ROW_KEY: ui.Key = .str("knots.roster.row");
const PORTRAIT_KEY: ui.Key = .str("knots.roster.portrait");
/// How big, in preview pixels, a saved position is marked when it was saved without a size.
const POSITION_MARKER_SIZE = 6;
/// The thumbnail's name colour is saved without alpha, which a swatch reads as transparent.
const OPAQUE = 0xFF000000;

const FLAGS = [_]Flag{
    .{ .field = "excludeFromMinimize", .label = "Exclude from Auto-Minimize", .hint = "This client is never minimized automatically." },
    .{ .field = "excludeFromCloseAll", .label = "Exclude from Close All", .hint = "The Close All hotkey leaves this client open." },
    .{ .field = "excludeFromAutoMove", .label = "Exclude from Auto-Move", .hint = "Its window is never moved to its saved position." },
    .{ .field = "excludeFromChatAlerts", .label = "Exclude from Chat Alerts", .hint = "This client never receives chat alerts." },
    .{ .field = "keepFullSpeed", .label = "Keep at Full Speed", .hint = "Client Speed never slows this client down in the background." },
    .{ .field = "hideThumbnail", .label = "Hide Thumbnail", .hint = "Its row in the client list still shows." },
    .{ .field = "hideFromClientList", .label = "Hide from Client List", .hint = "Its thumbnail still shows." },
    .{ .field = "notificationsMuted", .label = "Mute Alerts", .hint = "No alerts for this character at all." },
};

const Flag = struct { field: []const u8, label: []const u8, hint: []const u8 };

/// Kept from one opening of the window to the next.
pub const Kept = struct {
    selected: selection.Selection = .{},
};

pub fn show(window: *Window, context: *ui.Frame) !void {
    const section = try window.widgets.openSection(
        context,
        "Character List",
        "Settings for each character. Characters are added when they log in.",
        &style.fill_section,
    );
    const profile = window.session.profile();
    const character_count = profile.ptr.characters.items.len;
    if (character_count == 0) {
        try emptyState(window, context, profile);
        try section.close(context);
        return;
    }
    window.kept.characters.selected.clamp(character_count);
    const master_detail = Rect{ .key = .src(@src()), .style = &style.master_detail_fill };
    _ = try master_detail.open(context);
    try roster(window, context, profile);
    try detail(window, context, profile);
    try master_detail.close(context);
    try section.close(context);
}

/// Instead of the list and details, until there's a character.
fn emptyState(window: *Window, context: *ui.Frame, profile: ProfileRef) !void {
    const state = try window.widgets.openEmptyState(context, .str("knots.characters.empty"), "No characters yet", "They're added on their own as their EVE clients log in.");
    if (try widgets.glyphButton(context, .str("knots.characters.empty.open"), .refresh, "Add Open Clients", &style.add_button, false)) try populateFromClients(window, context, profile);
    if (try widgets.glyphButton(context, .str("knots.characters.empty.add"), .add, "Add Manually", &style.add_button, false)) {
        if (profile.append("characters", .{})) |added| window.kept.characters.selected.index = added.index;
    }
    try state.close(context);
}

/// `lifted_style` while it's being dragged, otherwise the roster's own; `logged_in_names` borrows from positions.openClients.
fn characterRow(window: *Window, context: *ui.Frame, character: *const config.CharacterConfig, index: usize, logged_in_names: []const []const u8, lifted_style: ?*const ui.Style) !void {
    const arena = context.arena();
    const row = try roster_mod.Row.open(&window.widgets, context, ROW_KEY.indexed(index), index == window.kept.characters.selected.index, lifted_style);
    if (row.is_picked) window.kept.characters.selected.index = index;
    const portrait_box = Rect{ .key = ui.Key.str("knots.roster.portrait_box").indexed(index), .style = &style.roster_portrait_box };
    _ = try portrait_box.open(context);
    const portrait = window.host.portraits.image(arena, PORTRAIT_KEY, character.name, &style.roster_portrait) orelse
        window.images.image(.default_portrait, ui.Key.str("knots.roster.portrait_default").indexed(index), &style.roster_portrait);
    if (portrait) |image| try context.e(image);
    if (positions.isListed(logged_in_names, character.name)) try context.e(Rect{ .key = ui.Key.str("knots.roster.online").indexed(index), .style = &style.roster_online_ring });
    try portrait_box.close(context);
    var badge: []const u8 = "";
    if (character.hotkey.len > 0) {
        var text: std.Io.Writer.Allocating = .init(arena);
        try text.writer.writeByte('[');
        try hotkey.writeKeys(&text.writer, character.hotkey);
        try text.writer.writeByte(']');
        badge = text.written();
    }
    try row.close(context, try rosterName(window, context, index), style.ROSTER_PORTRAIT_SIZE, .{ .text = badge });
}

fn rosterName(window: *Window, context: *ui.Frame, index: usize) ![]const u8 {
    const name = try window.bind.liveText(context, window.session.profile().item("characters", index), "name");
    return if (name.len > 0) name else try lang.format(context.arena(), "Character {n}", .{ .n = index + 1 });
}

fn roster(window: *Window, context: *ui.Frame, profile: ProfileRef) !void {
    const characters = profile.ptr.characters.items;
    const list = try window.widgets.openRoster(context, .str("knots.characters.roster"), &style.roster, true);
    const logged_in_names = try positions.openClients(window.session, context.arena());
    var order = widgets.ReorderList.begin(&window.widgets, context, ROW_KEY, characters.len, 0);
    for (characters, 0..) |*character, index| {
        try window.widgets.reorderRow(context, ROW_KEY, index);
        if (try order.next(context, index)) try characterRow(window, context, character, index, logged_in_names, null);
    }
    if (try order.end(context)) |lifted| {
        const lifted_style = try order.liftedStyle(context, list.rowsKey(), roster_mod.rowStyle(lifted == window.kept.characters.selected.index));
        try characterRow(window, context, &characters[lifted], lifted, logged_in_names, lifted_style);
    }
    const action = try list.close(context, .{ .add_label = "Add Character", .has_open_clients = true });

    if (window.widgets.reorderFinish(context, ROW_KEY, characters.len)) |moved| {
        profile.move("characters", moved.from, moved.before);
        window.kept.characters.selected.afterMove(moved.from, moved.before);
    }
    // After the reorder, which reads `characters`, since adding can move the list.
    switch (action) {
        .none => {},
        .add => {
            if (profile.append("characters", .{})) |added| window.kept.characters.selected.index = added.index;
        },
        .add_open_clients => try populateFromClients(window, context, profile),
    }
}

/// Borrows each name from `characters`.
fn characterNames(arena: std.mem.Allocator, characters: []const config.CharacterConfig) ![]const []const u8 {
    const names = try arena.alloc([]const u8, characters.len);
    for (characters, names) |character, *name| name.* = character.name;
    return names;
}

fn detail(window: *Window, context: *ui.Frame, profile: ProfileRef) !void {
    const stack = try window.widgets.openScrollPane(context, .str("knots.character.detail"), style.detail_scroll);
    const index = window.kept.characters.selected.index;
    const character = profile.item("characters", index);
    const previous_rows = window.widgets.useDetailRows();
    defer window.widgets.restoreRows(previous_rows);

    const header = try window.widgets.openDetailHeader(context, .src(@src()), "Character Name");
    try window.bind.textBox(context, character, "name", "Character Name");
    const removed = try window.widgets.removeButton(context, ui.Key.str("knots.character.remove").indexed(index));
    try header.close(context);
    const name_box = bind.boxKey(character, "name");
    const taken = try characterNames(context.arena(), profile.ptr.characters.items);
    if (try window.suggest.openClients(window.session, context, name_box, window.bind.typedText(name_box), taken)) |picked| character.set("name", picked);

    try window.bind.text(context, character, "displayName", "Display Name", "Same as character name");
    try window.widgets.hintText(context, .str("knots.character.display.hint"), "Shown on the thumbnail and spoken aloud. Clients are still matched by Character Name.");
    try window.widgets.separator(context, .str("knots.character.separator.display"));

    const hotkey_row = try window.widgets.openBinding(context, .str("knots.character.hotkey"), "Direct Hotkey");
    try window.hotkey.field(context, character, "hotkey");
    try hotkey_row.close(context);
    try window.widgets.hintText(context, .str("knots.character.hotkey.hint"), "Brings this character's client to the front.");
    try window.widgets.separator(context, .str("knots.character.separator.identity"));

    try thumbnailSize(window, context, character);
    try window.widgets.hintText(context, .str("knots.character.size.hint"), "Leave blank to use the Appearance tab's size. Ignored inside a thumbnail space.");
    try window.widgets.separator(context, .str("knots.character.separator.size"));

    try opacity(window, context, character);
    try window.widgets.hintText(context, .str("knots.character.opacity.hint"), "Matches the Appearance tab until you move this slider.");
    try preview(window, context, character);
    try window.widgets.separator(context, .str("knots.character.separator.thumbnail"));

    try colors(window, context, character);
    try window.widgets.separator(context, .str("knots.character.separator.colors"));

    const behavior = try window.widgets.openFieldGroup(context, .str("knots.character.behavior"), "Behavior");
    inline for (FLAGS) |flag| {
        try window.bind.toggle(context, character, flag.field, flag.label);
        try window.widgets.hintText(context, .str("knots.character.flag.hint:" ++ flag.field), flag.hint);
    }
    try behavior.close(context);
    try window.widgets.separator(context, .str("knots.character.separator.behavior"));

    try windowPosition(window, context, character);
    try stack.close(context);

    if (removed) {
        profile.remove("characters", index);
        window.kept.characters.selected.afterRemove(index, profile.ptr.characters.items.len);
    }
}

/// Unset follows the Appearance tab's size, shown greyed in the empty box; either box alone overrides that half.
fn thumbnailSize(window: *Window, context: *ui.Frame, character: CharacterRef) !void {
    const inherited = &window.session.profile().ptr.thumbnail;
    const arena = context.arena();
    const row = try window.widgets.openBinding(context, .str("knots.character.size"), "Thumbnail Size");
    try context.e(Rect{ .key = .src(@src()), .style = &style.spacer });
    const size = character.get("thumbnailSize") orelse config.CharacterThumbnailSizeConfig{};
    var next = size;
    switch (try window.bind.optionalUnitValueBox(context, ui.Key.str("knots.character.width").indexed(character.index), toFloat(size.width), try arena.print("{d}", .{inherited.width}), "px")) {
        .unchanged => {},
        .cleared => next.width = null,
        .value => |width| next.width = @intFromFloat(@round(width)),
    }
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "\u{00D7}", .style = &style.muted_text });
    switch (try window.bind.optionalUnitValueBox(context, ui.Key.str("knots.character.height").indexed(character.index), toFloat(size.height), try arena.print("{d}", .{inherited.height}), "px")) {
        .unchanged => {},
        .cleared => next.height = null,
        .value => |height| next.height = @intFromFloat(@round(height)),
    }
    try row.close(context);
    if (!std.meta.eql(next, size)) character.set("thumbnailSize", if (next.width == null and next.height == null) null else next);
}

fn toFloat(value: ?i32) ?f64 {
    return if (value) |number| @floatFromInt(number) else null;
}

/// Unset follows the Appearance tab's opacity; moving the slider gives the character its own.
fn opacity(window: *Window, context: *ui.Frame, character: CharacterRef) !void {
    const inherited = window.session.profile().ptr.thumbnail.thumbnailOpacity;
    const key = ui.Key.str("knots.character.opacity").indexed(character.index);
    const row = try window.widgets.openBinding(context, key, "Opacity");
    if (try window.bind.percentSlider(context, key, character.get("opacity") orelse inherited, ranges.OPACITY[0], ranges.OPACITY[1])) |value| {
        character.set("opacity", value);
    }
    try row.close(context);
}

/// The blank colour's swatch sits after the choice, dimmed unless the character ends up blank.
fn preview(window: *Window, context: *ui.Frame, character: CharacterRef) !void {
    const inherited = &window.session.profile().ptr.thumbnail;
    const choice = character.get("preview");
    const is_blank = !choice.showsLive(inherited.showLivePreview);
    const choices = comptime std.enums.values(@TypeOf(choice));
    // Aligned, so the swatch is the bare one the Colors group uses and the row sits at the right edge.
    const was_aligned = window.widgets.useAlignedRows(true);
    defer _ = window.widgets.useAlignedRows(was_aligned);
    const row = try window.widgets.openBinding(context, ui.Key.str("knots.character.preview").indexed(character.index), "Thumbnail Preview");
    const current = std.mem.findScalar(@TypeOf(choice), choices, choice) orelse 0;
    if (try window.widgets.segmented(context, ui.Key.str("knots.character.preview.options").indexed(character.index), &.{ "Default", "Live", "Blank" }, current)) |picked| {
        character.set("preview", choices[picked]);
    }
    const swatch_group = try widgets.openInlineGroup(context, ui.Key.str("knots.character.blank").indexed(character.index), is_blank);
    if (try window.widgets.optionalColorBox(context, ui.Key.str("knots.character.blank_color").indexed(character.index), character.get("blankThumbnailColor"), blankFallback(window, character) | OPAQUE)) |change| {
        character.set("blankThumbnailColor", switch (change) {
            .cleared => null,
            .set => |argb| argb,
        });
    }
    try swatch_group.close(context);
    try row.close(context);
    try window.widgets.hintText(context, .str("knots.character.preview.hint"), "Default follows the Appearance tab.");
}

/// What an unset blank colour follows, from the configured border colour since unique ones aren't known here.
fn blankFallback(window: *Window, character: CharacterRef) u32 {
    const profile = window.session.profile().ptr;
    const own_border = if (character.get("borderColors")) |borders| borders.activeBorderColor else null;
    return profile.thumbnail.blankFill(own_border orelse profile.focusedBorderColor());
}

fn colors(window: *Window, context: *ui.Frame, character: CharacterRef) !void {
    const group = try window.widgets.openFieldGroup(context, .str("knots.character.colors"), "Colors");
    const inherited = &window.session.profile().ptr.thumbnail;
    const borders = character.get("borderColors") orelse config.CharacterBorderColorsConfig{};
    var next = borders;
    if (try window.widgets.optionalColor(context, ui.Key.str("knots.character.active").indexed(character.index), "Active Border Color", borders.activeBorderColor, window.session.profile().ptr.focusedBorderColor())) |change| {
        next.activeBorderColor = switch (change) {
            .cleared => null,
            .set => |argb| argb,
        };
    }
    try window.widgets.hintText(context, .str("knots.character.active.hint"), "Reset uses the Appearance tab's color.");
    if (try window.widgets.optionalColor(context, ui.Key.str("knots.character.inactive").indexed(character.index), "Inactive Border Color", borders.inactiveBorderColor, inherited.inactiveBorderColor)) |change| {
        next.inactiveBorderColor = switch (change) {
            .cleared => null,
            .set => |argb| argb,
        };
    }
    try window.widgets.hintText(context, .str("knots.character.inactive.hint"), "Reset uses the Appearance tab's color.");
    if (!std.meta.eql(next, borders)) character.set("borderColors", if (next.activeBorderColor == null and next.inactiveBorderColor == null) null else next);
    if (try window.widgets.optionalColor(context, ui.Key.str("knots.character.name_color").indexed(character.index), "Character Name Color", character.get("nameColor"), inherited.characterNameColor | OPAQUE)) |change| {
        character.set("nameColor", switch (change) {
            .cleared => null,
            .set => |argb| argb,
        });
    }
    try window.widgets.hintText(context, .str("knots.character.name_color.hint"), "Overrides unique name colors. Reset uses the normal color.");
    try group.close(context);
}

/// Saved at once for the running profile, like a drag; Save Position needs the character's client open.
fn windowPosition(window: *Window, context: *ui.Frame, character: CharacterRef) !void {
    const row = try window.widgets.openBinding(context, .str("knots.character.window_position"), "Window Position");
    try context.e(Rect{ .key = .src(@src()), .style = &style.spacer });
    const saved = character.get("windowPosition");
    const shown = if (saved) |position| try context.arena().print("{d}, {d}", .{ position.x, position.y }) else lang.text("Not set");
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = shown, .style = &style.muted_text });
    const name = character.get("name");
    const clear_key = ui.Key.str("knots.character.position.clear").indexed(character.index);
    if (saved == null) {
        _ = try context.interact(Button{ .key = clear_key, .label = "\u{00D7}", .disabled = true, .style = &style.icon_button_disabled_text });
    } else if (try window.widgets.confirmButton(context, clear_key, "\u{00D7}", "OK", &style.icon_button_danger_text, &style.icon_button_confirm)) {
        positions.clear(window.session, name) catch |err| {
            slog.err("Failed to clear the window position of '{s}': {}", .{ name, err });
            window.status.show(.failure, "Failed to save: {err}", .{ .err = err });
        };
    }
    if ((try context.interact(Button{ .key = ui.Key.str("knots.character.position.set").indexed(character.index), .label = lang.text("Save Position"), .style = &style.plain_button })).clicked) {
        if (positions.set(window.session, name)) {
            window.status.show(.success, "Window position saved", .{});
        } else |err| {
            slog.err("Failed to save the window position of '{s}': {}", .{ name, err });
            window.status.show(.failure, "Failed to save: {err}", .{ .err = err });
        }
    }
    try row.close(context);
    try positionMap(context, character);
    try window.widgets.hintText(context, .str("knots.character.window_position.hint"), "This character's client must be open to save its position.");
}

/// Every monitor with the saved window on it, or a marker at its top-left when it was saved without a size.
fn positionMap(context: *ui.Frame, character: CharacterRef) !void {
    var map: ScreenMap = try .init(context, .str("knots.character.position.map"));
    if (character.get("windowPosition")) |position| {
        const size = character.get("windowSize");
        const width = if (size) |saved| saved.width else 0;
        const height = if (size) |saved| saved.height else 0;
        const window_box = map.frame.box(.{ .left = position.x, .top = position.y, .right = position.x + width, .bottom = position.y + height });
        const box: screen_math.Box = if (window_box[2] >= 1 and window_box[3] >= 1) window_box else .{ window_box[0], window_box[1], POSITION_MARKER_SIZE, POSITION_MARKER_SIZE };
        try map.addSavedPosition(context, box);
    }
    try map.show(context, false);
}

/// Adds every logged-in client that isn't listed yet.
fn populateFromClients(window: *Window, context: *ui.Frame, profile: ProfileRef) !void {
    const names = positions.clientsNotIn(window.session, &window.status, context.arena(), try characterNames(context.arena(), profile.ptr.characters.items)) orelse return;
    var added_count: usize = 0;
    for (names) |name| {
        const added = profile.append("characters", .{}) orelse break;
        added.set("name", name);
        added_count += 1;
    }
    if (added_count > 0) {
        window.status.show(.success, "Added {n} character(s) from open EVE clients", .{ .n = added_count });
    } else {
        window.status.show(.info, "All open EVE clients are already in the list", .{});
    }
}
