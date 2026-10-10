//! The configuration window's Characters tab: a reorderable roster beside the selected character's details; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../config.zig");
const ranges = @import("../../../config/ranges.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const hotkey = @import("../hotkey.zig");
const portraits = @import("../portraits.zig");
const positions = @import("../positions.zig");
const screen_map = @import("../screen_map.zig");
const screen_math = @import("../screen_math.zig");
const suggest = @import("../suggest.zig");
const status = @import("../status.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const log = @import("../../../log.zig");

const ScreenMap = screen_map.ScreenMap;
const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const ProfileRef = session.Ref(config.Config);
const CharacterRef = session.Ref(config.CharacterConfig);
const slog = log.scoped("dialog_knots");

const ROW_KEY: ui.Key = .str("knots.roster.row");
const PORTRAIT_KEY: ui.Key = .str("knots.roster.portrait");
/// How big, in preview pixels, a saved position is marked when it was saved without a size.
const POSITION_MARKER_SIZE = 6;
/// The thumbnail's name colour is saved without alpha, which a swatch reads as transparent.
const OPAQUE = 0xFF000000;

const Flag = struct { field: []const u8, label: []const u8 };

const FLAGS = [_]Flag{
    .{ .field = "excludeFromMinimize", .label = "Exclude from Auto-Minimize" },
    .{ .field = "excludeFromCloseAll", .label = "Exclude from Close All" },
    .{ .field = "excludeFromAutoMove", .label = "Exclude from Auto-Move" },
    .{ .field = "hideThumbnail", .label = "Hide Thumbnail" },
    .{ .field = "notificationsMuted", .label = "Mute Notifications" },
};

var g_selected_index: usize = 0;

pub fn show(context: *ui.Frame) !void {
    const section = try widgets.openSection(
        context,
        "Character List",
        "Customize each character's saved position, size, border color, display name, and jump-to hotkey. Characters are added automatically when detected.",
        &style.fill_section,
    );
    const master_detail = Rect{ .key = .src(@src()), .style = &style.master_detail_fill };
    _ = try master_detail.open(context);
    const profile = session.profile();
    const count = profile.ptr.characters.items.len;
    // The list can shrink while the window is open, e.g. on a profile switch.
    if (g_selected_index >= count) g_selected_index = count -| 1;
    try roster(context, profile);
    try detail(context, profile);
    try master_detail.close(context);
    try section.close(context);
}

/// `lifted_style` while it's being dragged, otherwise the roster's own.
fn characterRow(context: *ui.Frame, character: *const config.CharacterConfig, index: usize, lifted_style: ?*const ui.Style) !void {
    const arena = context.arena();
    const name = try rosterName(arena, character, index);
    const is_selected = index == g_selected_index;
    const row = Button{
        .key = ROW_KEY.indexed(index),
        .style = lifted_style orelse if (is_selected) &style.roster_row_selected else &style.roster_row,
    };
    if ((try widgets.openRosterRow(context, row)).clicked and !is_selected) {
        g_selected_index = index;
        context.requestRedraw();
    }
    if (portraits.image(arena, PORTRAIT_KEY, character.name, &style.roster_portrait)) |portrait| {
        try context.e(portrait);
    } else {
        try context.e(Rect{ .key = ui.Key.str("knots.roster.portrait_blank").indexed(index), .style = &style.roster_portrait_blank });
    }
    try context.e(Text{
        .selectable = false,
        .key = ui.Key.str("knots.roster.name").indexed(index),
        .content = name,
        .style = if (is_selected) &style.roster_name_selected else &style.roster_name,
    });
    if (character.hotkey.len > 0) {
        var text: std.Io.Writer.Allocating = .init(arena);
        try text.writer.writeByte('[');
        try hotkey.writeKeys(&text.writer, character.hotkey);
        try text.writer.writeByte(']');
        try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.roster.hotkey").indexed(index), .content = text.written(), .style = &style.roster_badge });
    }
    try row.close(context);
}

fn rosterName(arena: std.mem.Allocator, character: *const config.CharacterConfig, index: usize) ![]const u8 {
    return if (character.name.len > 0) character.name else try std.fmt.allocPrint(arena, "Character {d}", .{index + 1});
}

fn roster(context: *ui.Frame, profile: ProfileRef) !void {
    const characters = profile.ptr.characters.items;
    const list = try widgets.openRoster(context, .str("knots.characters.roster"), &style.roster, true);
    if (characters.len == 0) {
        try widgets.boxedText(context, .src(@src()), "No characters yet.", &style.roster_empty, &style.roster_empty_text);
    }
    var order = widgets.ReorderList.begin(context, ROW_KEY, characters.len, 0);
    for (characters, 0..) |*character, index| {
        try widgets.reorderRow(context, ROW_KEY, index);
        if (try order.next(context, index)) try characterRow(context, character, index, null);
    }
    if (try order.end(context)) |lifted| {
        const lifted_style = try order.liftedStyle(context, list.rowsKey(), if (lifted == g_selected_index) &style.roster_row_selected else &style.roster_row);
        try characterRow(context, &characters[lifted], lifted, lifted_style);
    }
    const action = try list.close(context, .{ .add_label = "+ Add Character", .has_open_clients = true });

    // The selection follows the character it was on, not the slot.
    if (widgets.reorderFinish(context, ROW_KEY, characters.len)) |moved| {
        const selected_id = characters[g_selected_index].id;
        profile.move("characters", moved.from, moved.before);
        for (profile.ptr.characters.items, 0..) |character, index| {
            if (character.id == selected_id) g_selected_index = index;
        }
    }
    // After the reorder, which reads `characters`, since adding can move the list.
    switch (action) {
        .none => {},
        .add => {
            profile.append("characters", .{});
            g_selected_index = profile.ptr.characters.items.len - 1;
        },
        .add_open_clients => populateFromClients(context, profile),
    }
}

fn detail(context: *ui.Frame, profile: ProfileRef) !void {
    const stack = try widgets.openScrollPane(context, .str("knots.character.detail"), style.detail_scroll);
    if (profile.ptr.characters.items.len == 0) {
        try widgets.paragraph(context, .str("knots.characters.empty"), "Add a character under the list, or add every open client with the refresh button beside it.");
        try stack.close(context);
        return;
    }
    const index = g_selected_index;
    const character = profile.item("characters", index);
    const previous_rows = widgets.useDetailRows();
    defer widgets.restoreRows(previous_rows);

    const header = try widgets.openDetailHeader(context, .src(@src()));
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "Character Name", .style = &style.detail_label });
    try bind.textBox(context, character, "name", "Character Name");
    const removed = try widgets.confirmButton(context, ui.Key.str("knots.character.remove").indexed(index), "Remove", "Confirm", &style.plain_button, &style.confirm_button);
    try header.close(context);
    const name_box = bind.boxKey(character, "name");
    if (try suggest.openClients(context, name_box, bind.typedText(name_box))) |picked| character.set("name", picked);

    try bind.text(context, character, "displayName", "Display Name", "Same as character name");
    try widgets.hintText(context, .str("knots.character.display.hint"), "Cosmetic only - shown on the thumbnail label and spoken by TTS if enabled. The Character Name above is still what's matched against your EVE login.");

    const hotkey_row = try widgets.openBinding(context, .str("knots.character.hotkey"), "Hotkey");
    try hotkey.field(context, character, "hotkey");
    try hotkey_row.close(context);
    try widgets.separator(context, .str("knots.character.separator.identity"));

    try thumbnailSize(context, character);
    try widgets.hintText(context, .str("knots.character.size.hint"), "Leave both blank to use the global thumbnail size from the Appearance tab.");
    try widgets.separator(context, .str("knots.character.separator.size"));

    try opacity(context, character);
    try widgets.hintText(context, .str("knots.character.opacity.hint"), "Stays linked to the Appearance tab's Opacity setting unless you move this slider away from it.");
    try widgets.separator(context, .str("knots.character.separator.thumbnail"));

    try colors(context, character);
    try widgets.separator(context, .str("knots.character.separator.colors"));

    const behavior = try widgets.openFieldGroup(context, .str("knots.character.behavior"), "Behavior");
    inline for (FLAGS) |flag| try bind.toggle(context, character, flag.field, flag.label);
    try behavior.close(context);
    try widgets.separator(context, .str("knots.character.separator.behavior"));

    try windowPosition(context, character);
    try stack.close(context);

    if (removed) {
        profile.remove("characters", index);
        g_selected_index = @min(index, profile.ptr.characters.items.len -| 1);
    }
}

/// Unset follows the Appearance tab's size, shown greyed in the empty box; either box alone overrides that half.
fn thumbnailSize(context: *ui.Frame, character: CharacterRef) !void {
    const inherited = &session.profile().ptr.thumbnail;
    const arena = context.arena();
    const row = try widgets.openBinding(context, .str("knots.character.size"), "Thumbnail Size");
    try context.e(Rect{ .key = .src(@src()), .style = &style.spacer });
    const size = character.get("thumbnailSize") orelse config.CharacterThumbnailSizeConfig{};
    var next = size;
    switch (try bind.optionalValueBox(context, ui.Key.str("knots.character.width").indexed(character.index), toFloat(size.width), try std.fmt.allocPrint(arena, "{d}", .{inherited.width}), &style.number_input)) {
        .unchanged => {},
        .cleared => next.width = null,
        .value => |width| next.width = @intFromFloat(@round(width)),
    }
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "\u{00D7}", .style = &style.muted_text });
    switch (try bind.optionalValueBox(context, ui.Key.str("knots.character.height").indexed(character.index), toFloat(size.height), try std.fmt.allocPrint(arena, "{d}", .{inherited.height}), &style.number_input)) {
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
fn opacity(context: *ui.Frame, character: CharacterRef) !void {
    const inherited = session.profile().ptr.thumbnail.thumbnailOpacity;
    const key = ui.Key.str("knots.character.opacity").indexed(character.index);
    const row = try widgets.openBinding(context, key, "Opacity");
    if (try bind.percentSlider(context, key, character.get("opacity") orelse inherited, ranges.OPACITY[0], ranges.OPACITY[1])) |value| {
        character.set("opacity", value);
    }
    try row.close(context);
}

fn colors(context: *ui.Frame, character: CharacterRef) !void {
    const group = try widgets.openFieldGroup(context, .str("knots.character.colors"), "Colors");
    const inherited = &session.profile().ptr.thumbnail;
    const borders = character.get("borderColors") orelse config.CharacterBorderColorsConfig{};
    var next = borders;
    if (try widgets.optionalColor(context, ui.Key.str("knots.character.active").indexed(character.index), "Active Border Color", borders.activeBorderColor, inherited.borderColor)) |change| {
        next.activeBorderColor = switch (change) {
            .cleared => null,
            .set => |argb| argb,
        };
    }
    if (try widgets.optionalColor(context, ui.Key.str("knots.character.inactive").indexed(character.index), "Inactive Border Color", borders.inactiveBorderColor, inherited.inactiveBorderColor)) |change| {
        next.inactiveBorderColor = switch (change) {
            .cleared => null,
            .set => |argb| argb,
        };
    }
    if (!std.meta.eql(next, borders)) character.set("borderColors", if (next.activeBorderColor == null and next.inactiveBorderColor == null) null else next);
    if (try widgets.optionalColor(context, ui.Key.str("knots.character.name_color").indexed(character.index), "Character Name Color", character.get("nameColor"), inherited.characterNameColor | OPAQUE)) |change| {
        character.set("nameColor", switch (change) {
            .cleared => null,
            .set => |argb| argb,
        });
    }
    try group.close(context);
}

/// Saved at once for the running profile, like a drag; Save Position needs the character's client open.
fn windowPosition(context: *ui.Frame, character: CharacterRef) !void {
    const row = try widgets.openBinding(context, .str("knots.character.window_position"), "Window Position");
    try context.e(Rect{ .key = .src(@src()), .style = &style.spacer });
    const shown = if (character.get("windowPosition")) |position| try std.fmt.allocPrint(context.arena(), "{d}, {d}", .{ position.x, position.y }) else "Not set";
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = shown, .style = &style.muted_text });
    const name = character.get("name");
    if (try widgets.confirmButton(context, ui.Key.str("knots.character.position.clear").indexed(character.index), "\u{00D7}", "OK", &style.icon_button_danger_text, &style.icon_button_confirm)) {
        positions.clear(name) catch |err| {
            slog.err("Failed to clear the window position of '{s}': {}", .{ name, err });
            status.show(.failure, "Failed to save: {}", .{err});
        };
    }
    if ((try context.interact(Button{ .key = ui.Key.str("knots.character.position.set").indexed(character.index), .label = "Save Position", .style = &style.plain_button })).clicked) {
        if (positions.set(name)) {
            status.show(.success, "Window position saved", .{});
        } else |err| {
            slog.err("Failed to save the window position of '{s}': {}", .{ name, err });
            status.show(.failure, "Failed to save: {}", .{err});
        }
    }
    try row.close(context);
    try positionMap(context, character);
    try widgets.hintText(context, .str("knots.character.window_position.hint"), "Save Position requires this character's EVE client to be running right now.");
}

/// Every monitor with the saved window on it, or a marker at its top-left when it was saved without a size.
fn positionMap(context: *ui.Frame, character: CharacterRef) !void {
    var map = try ScreenMap.init(context, .str("knots.character.position.map"));
    if (character.get("windowPosition")) |position| {
        const line_color = context.ui().theme.primary.value;
        var fill_color = line_color;
        fill_color[3] = 0.25;
        const size = character.get("windowSize");
        const width = if (size) |saved| saved.width else 0;
        const height = if (size) |saved| saved.height else 0;
        const window_box = map.frame.box(.{ .left = position.x, .top = position.y, .right = position.x + width, .bottom = position.y + height });
        const box: screen_math.Box = if (window_box[2] >= 1 and window_box[3] >= 1) window_box else .{ window_box[0], window_box[1], POSITION_MARKER_SIZE, POSITION_MARKER_SIZE };
        try map.addBox(context.arena(), box, fill_color, line_color);
    }
    try map.show(context, false);
}

/// Adds every logged-in client that isn't listed yet.
fn populateFromClients(context: *ui.Frame, profile: ProfileRef) void {
    const names = positions.openClients(context.arena()) catch |err| {
        slog.err("Failed to populate characters from open clients: {}", .{err});
        status.show(.failure, "Failed to scan clients: {}", .{err});
        return;
    };
    if (names.len == 0) {
        status.show(.failure, "No open EVE clients found", .{});
        return;
    }
    var added: usize = 0;
    for (names) |name| {
        const exists = for (profile.ptr.characters.items) |character| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, character.name, " "), std.mem.trim(u8, name, " "))) break true;
        } else false;
        if (exists) continue;
        profile.append("characters", .{});
        profile.item("characters", profile.ptr.characters.items.len - 1).set("name", name);
        added += 1;
    }
    if (added > 0) {
        status.show(.success, "Added {d} character(s) from open EVE clients", .{added});
    } else {
        status.show(.info, "All open EVE clients are already in the list", .{});
    }
}
