//! The configuration window's Characters tab: a reorderable list of characters, each opening a page of its own settings; main thread only.
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
const screen_map = @import("../screen_map.zig");
const screen_math = @import("../screen_math.zig");
const suggest = @import("../suggest.zig");
const status = @import("../status.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const hotkey_groups = @import("hotkey_groups.zig");
const lang = @import("../../../lang/lang.zig");
const log = @import("../../../log.zig");

const ScreenMap = screen_map.ScreenMap;
const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const ProfileRef = session.Ref(config.Config);
const CharacterRef = session.Ref(config.CharacterConfig);
const slog = log.Scoped("dialog_knots");

const ROW_KEY: ui.Key = .str("knots.characters.row");
const FILTER_KEY: ui.Key = .str("knots.characters.filter");
const ROWS_KEY: ui.Key = .str("knots.characters.rows");
const PORTRAIT_KEY: ui.Key = .str("knots.characters.portrait");
/// How big, in preview pixels, a saved position is marked when it was saved without a size.
const POSITION_MARKER_SIZE = 6;
/// The thumbnail's name colour is saved without alpha, which a swatch reads as transparent.
const OPAQUE = 0xFF000000;
/// An unnamed character's name; English, for lang.format with `.n` counting from 1.
const UNNAMED_CHARACTER_FORMAT = "Character {n}";
/// The most clients the picker lists; EVE allows far fewer at once.
const MAX_PICKER_CLIENTS = 64;

const FLAGS = [_]Flag{
    .{ .field = "excludeFromMinimize", .label = "Exclude from Auto-Minimize", .hint = "This client is never minimized automatically." },
    .{ .field = "excludeFromCloseAll", .label = "Exclude from Close All", .hint = "The Close All hotkey leaves this client open." },
    .{ .field = "excludeFromAutoMove", .label = "Exclude from Auto-Move", .hint = "Its window is never moved to its saved position." },
    .{ .field = "hideThumbnail", .label = "Hide Thumbnail", .hint = "Also hides its row in the client list." },
    .{ .field = "notificationsMuted", .label = "Mute Notifications", .hint = "No alerts for this character at all." },
};

const Flag = struct { field: []const u8, label: []const u8, hint: []const u8 };

const PortraitSize = enum { list, page };

var g_allocator: std.mem.Allocator = undefined;
/// The character whose page is open, or null for the list.
var g_open_index: ?usize = null;
/// What the list is filtered by; owned, freed in reset.
var g_filter: std.ArrayList(u8) = .empty;
/// Set as a new character's page opens, so its first frame focuses the name box.
var g_should_focus_name: bool = false;
var g_is_picker_open: bool = false;
/// The picker's clients, by their place in its list, that were switched off.
var g_skipped: std.StaticBitSet(MAX_PICKER_CLIENTS) = .empty;

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// Once the window has closed.
pub fn reset() void {
    g_filter.deinit(g_allocator);
    g_filter = .empty;
}

pub fn show(context: *ui.Frame) !void {
    const profile = session.profile();
    // The list can shrink while a page is open, e.g. on a profile switch.
    if (g_open_index) |index| {
        if (index >= profile.ptr.characters.items.len) g_open_index = null;
    }
    if (g_open_index) |index| return showPage(context, profile, index);
    try showList(context, profile);
}

fn showList(context: *ui.Frame, profile: ProfileRef) !void {
    const toolbar = Rect{ .key = .src(@src()), .style = &style.list_toolbar };
    _ = try toolbar.open(context);
    try widgets.searchBox(context, FILTER_KEY, &g_filter, "Filter characters");
    const is_add_clicked = try widgets.glyphButton(context, .str("knots.characters.add"), .add, "Add Character", &style.add_button, false);
    const is_populate_clicked = try widgets.glyphButton(context, .str("knots.characters.populate"), .refresh, "Add Open Clients", &style.add_button, false);
    try toolbar.close(context);
    if (is_add_clicked) addCharacter(profile);
    if (is_populate_clicked) openPicker(context, profile);
    try clientPicker(context, profile);

    const characters = profile.ptr.characters.items;
    if (characters.len == 0) {
        const state = try widgets.openEmptyState(context, .str("knots.characters.empty"), "No characters yet", "They're added on their own as their EVE clients log in.");
        try state.close(context);
        return;
    }
    const section = try widgets.openSection(context, "Character List", "Characters are added on their own when they log in. Drag to reorder.", &style.list_section);
    const ui_state = context.ui();
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, ROWS_KEY.hash());
    const rows = Rect{ .key = ROWS_KEY, .style = &style.list_rows };
    _ = try rows.open(context);
    const logged_in = try positions.openClients(context.arena());
    const query = std.mem.trim(u8, g_filter.items, " ");
    // Filtered rows aren't all there, so they can't be dragged into place.
    if (query.len > 0) {
        var shown_count: usize = 0;
        for (characters, 0..) |*character, index| {
            if (!matches(character, query)) continue;
            try characterRow(context, character, index, logged_in, null);
            shown_count += 1;
        }
        if (shown_count == 0) try widgets.paragraph(context, .src(@src()), "No characters match.");
        try rows.close(context);
        try section.close(context);
        return;
    }
    var order = widgets.ReorderList.begin(context, ROW_KEY, characters.len, 0);
    for (characters, 0..) |*character, index| {
        try widgets.reorderRow(context, ROW_KEY, index);
        if (try order.next(context, index)) try characterRow(context, character, index, logged_in, null);
    }
    if (try order.end(context)) |lifted| {
        try characterRow(context, &characters[lifted], lifted, logged_in, try order.liftedStyle(context, ROWS_KEY, &style.list_item));
    }
    try rows.close(context);
    try section.close(context);
    if (widgets.reorderFinish(context, ROW_KEY, characters.len)) |moved| profile.move("characters", moved.from, moved.before);
}

/// `lifted_style` while it's being dragged, otherwise the list's own; `logged_in` borrows positions.openClients' names.
fn characterRow(context: *ui.Frame, character: *const config.CharacterConfig, index: usize, logged_in: []const []const u8, lifted_style: ?*const ui.Style) !void {
    const arena = context.arena();
    const row = Button{ .key = ROW_KEY.indexed(index), .style = lifted_style orelse &style.list_item };
    if ((try widgets.openRosterRow(context, row)).clicked and !widgets.isDragMoving(ROW_KEY)) openPage(context, index);
    const is_online = isLoggedIn(logged_in, character.name);
    try portrait(context, character.name, ui.Key.str("knots.characters.portrait_box").indexed(index), is_online, .list);

    const text_column = Rect{ .key = ui.Key.str("knots.characters.text").indexed(index), .style = &style.list_item_text };
    _ = try text_column.open(context);
    const name = if (character.name.len > 0) character.name else try lang.format(arena, UNNAMED_CHARACTER_FORMAT, .{ .n = index + 1 });
    try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.characters.name").indexed(index), .content = name, .style = &style.list_item_name });
    const meta = Rect{ .key = ui.Key.str("knots.characters.meta").indexed(index), .style = &style.list_item_meta };
    _ = try meta.open(context);
    var detail_text: std.Io.Writer.Allocating = .init(arena);
    try detail_text.writer.writeAll(lang.text(if (is_online) "Logged in" else "Logged out"));
    if (character.displayName) |display_name| {
        if (display_name.len > 0) {
            try detail_text.writer.writeAll(" \u{00B7} ");
            try detail_text.writer.writeAll(try lang.format(arena, "Shown as {name}", .{ .name = display_name }));
        }
    }
    try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.characters.detail").indexed(index), .content = detail_text.written(), .style = &style.list_item_detail_fit });
    try chips(context, character, index);
    try meta.close(context);
    try text_column.close(context);

    if (character.hotkey.len > 0) {
        var keys: std.Io.Writer.Allocating = .init(arena);
        try hotkey.writeKeys(&keys.writer, character.hotkey);
        try widgets.boxedText(context, ui.Key.str("knots.characters.hotkey").indexed(index), keys.written(), &style.keycap, &style.keycap_text);
    }
    try widgets.listChevron(context, ui.Key.str("knots.characters.chevron").indexed(index));
    try row.close(context);
}

/// The hotkey groups listing the character, then what it's left out of.
fn chips(context: *ui.Frame, character: *const config.CharacterConfig, index: usize) !void {
    const arena = context.arena();
    const name = std.mem.trim(u8, character.name, " ");
    var chip_index: usize = 0;
    for (session.profile().ptr.hotkeyGroups.items, 0..) |group, group_index| {
        const is_member = for (group.characters.items) |member| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, member, " "), name)) break true;
        } else false;
        if (!is_member) continue;
        const label = if (group.name.len > 0) group.name else try lang.format(arena, hotkey_groups.UNNAMED_GROUP_FORMAT, .{ .n = group_index + 1 });
        try widgets.boxedText(context, ui.Key.str("knots.characters.chip").indexed(index * 64 + chip_index), label, &style.list_chip, &style.list_chip_text);
        chip_index += 1;
    }
    if (character.notificationsMuted) try widgets.boxedText(context, ui.Key.str("knots.characters.muted").indexed(index), "Muted", &style.list_chip, &style.list_chip_text);
    if (character.hideThumbnail) try widgets.boxedText(context, ui.Key.str("knots.characters.hidden").indexed(index), "Hidden", &style.list_chip, &style.list_chip_text);
}

/// By name or display name, ignoring case.
fn matches(character: *const config.CharacterConfig, query: []const u8) bool {
    if (std.ascii.findIgnoreCase(character.name, query) != null) return true;
    const display_name = character.displayName orelse return false;
    return std.ascii.findIgnoreCase(display_name, query) != null;
}

/// The character's portrait, with a dot on it while it's logged in.
fn portrait(context: *ui.Frame, name: []const u8, key: ui.Key, is_online: bool, size: PortraitSize) !void {
    const box_style, const image_style, const dot_style = switch (size) {
        .list => .{ &style.list_portrait_box, &style.list_portrait, &style.online_dot },
        .page => .{ &style.page_portrait_box, &style.page_portrait, &style.page_online_dot },
    };
    const box = Rect{ .key = key, .style = box_style };
    _ = try box.open(context);
    const image = portraits.image(context.arena(), PORTRAIT_KEY, name, image_style) orelse
        images.g_default_portrait.image(key.indexed(1), image_style);
    if (image) |shown| try context.e(shown);
    if (is_online) try context.e(Rect{ .key = key.indexed(2), .style = dot_style });
    try box.close(context);
}

/// Steps to the previous or next character's page; returns whether it was clicked while enabled.
fn stepButton(context: *ui.Frame, key: ui.Key, label: []const u8, is_enabled: bool) !bool {
    const button = Button{ .key = key, .label = label, .disabled = !is_enabled, .style = if (is_enabled) &style.icon_button_text else &style.icon_button_disabled_text };
    return (try context.interact(button)).clicked and is_enabled;
}

fn openPage(context: *ui.Frame, index: usize) void {
    g_open_index = index;
    widgets.scrollTabToTop(context);
}

fn addCharacter(profile: ProfileRef) void {
    const added = profile.append("characters", .{}) orelse return;
    g_open_index = added.index;
    g_should_focus_name = true;
}

/// Matched like unlistedClients, ignoring case and spaces at either end.
fn isLoggedIn(logged_in: []const []const u8, name: []const u8) bool {
    const trimmed = std.mem.trim(u8, name, " ");
    for (logged_in) |client| {
        if (std.ascii.eqlIgnoreCase(trimmed, std.mem.trim(u8, client, " "))) return true;
    }
    return false;
}

fn showPage(context: *ui.Frame, profile: ProfileRef, index: usize) !void {
    const character = profile.item("characters", index);
    if (try widgets.backLink(context, .src(@src()), "Characters")) {
        g_open_index = null;
        return;
    }

    const header = try widgets.openPageHeader(context, .src(@src()));
    const logged_in = try positions.openClients(context.arena());
    try portrait(context, character.get("name"), .src(@src()), isLoggedIn(logged_in, character.get("name")), .page);
    const name = try bind.liveText(context, character, "name");
    try widgets.pageTitle(context, .src(@src()), if (name.len > 0) name else try lang.format(context.arena(), UNNAMED_CHARACTER_FORMAT, .{ .n = index + 1 }));
    const count = profile.ptr.characters.items.len;
    if (try stepButton(context, .src(@src()), "\u{2039}", index > 0)) openPage(context, index - 1);
    if (try stepButton(context, .src(@src()), "\u{203A}", index + 1 < count)) openPage(context, index + 1);
    const removed = try widgets.confirmButton(context, ui.Key.str("knots.character.remove").indexed(index), "Remove", "Confirm", &style.plain_button, &style.confirm_button);
    try header.close(context);
    if (removed) {
        profile.remove("characters", index);
        g_open_index = null;
        return;
    }

    const identity = try widgets.openSection(context, "Identity", "", &style.section);
    const name_box = bind.boxKey(character, "name");
    if (g_should_focus_name) {
        try widgets.focusTextInput(context, name_box, 0);
        g_should_focus_name = false;
    }
    try bind.text(context, character, "name", "Character Name", "");
    if (try suggest.openClients(context, name_box, bind.typedText(name_box))) |picked| character.set("name", picked);
    try bind.text(context, character, "displayName", "Display Name", "Same as character name");
    try widgets.hintText(context, .str("knots.character.display.hint"), "Shown on the thumbnail and spoken aloud. Clients are still matched by Character Name.");
    const hotkey_row = try widgets.openBinding(context, .str("knots.character.hotkey"), "Direct Hotkey");
    try hotkey.field(context, character, "hotkey");
    try hotkey_row.close(context);
    try widgets.hintText(context, .str("knots.character.hotkey.hint"), "Brings this character's client to the front.");
    try identity.close(context);

    const thumbnail = try widgets.openSection(context, "Thumbnail", "", &style.section);
    try thumbnailSize(context, character);
    try widgets.hintText(context, .str("knots.character.size.hint"), "Leave blank to use the Thumbnails tab's size. Ignored inside a thumbnail space.");
    try opacity(context, character);
    try widgets.hintText(context, .str("knots.character.opacity.hint"), "Matches the Thumbnails tab until you move this slider.");
    try thumbnail.close(context);

    const color_section = try widgets.openSection(context, "Colors", "", &style.section);
    try colors(context, character);
    try color_section.close(context);

    const behavior = try widgets.openSection(context, "Exceptions", "", &style.section);
    inline for (FLAGS) |flag| {
        try bind.toggle(context, character, flag.field, flag.label);
        try widgets.hintText(context, .str("knots.character.flag.hint:" ++ flag.field), flag.hint);
    }
    try behavior.close(context);

    const position = try widgets.openSection(context, "Saved Position", "", &style.section);
    try windowPosition(context, character);
    try position.close(context);
}

/// Unset follows the Thumbnails tab's size, shown greyed in the empty box; either box alone overrides that half.
fn thumbnailSize(context: *ui.Frame, character: CharacterRef) !void {
    const inherited = &session.profile().ptr.thumbnail;
    const arena = context.arena();
    const row = try widgets.openBinding(context, .str("knots.character.size"), "Thumbnail Size");
    try context.e(Rect{ .key = .src(@src()), .style = &style.spacer });
    const size = character.get("thumbnailSize") orelse config.CharacterThumbnailSizeConfig{};
    var next = size;
    switch (try bind.optionalUnitValueBox(context, ui.Key.str("knots.character.width").indexed(character.index), toFloat(size.width), try std.fmt.allocPrint(arena, "{d}", .{inherited.width}), "px")) {
        .unchanged => {},
        .cleared => next.width = null,
        .value => |width| next.width = @intFromFloat(@round(width)),
    }
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "\u{00D7}", .style = &style.muted_text });
    switch (try bind.optionalUnitValueBox(context, ui.Key.str("knots.character.height").indexed(character.index), toFloat(size.height), try std.fmt.allocPrint(arena, "{d}", .{inherited.height}), "px")) {
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

/// Unset follows the Thumbnails tab's opacity; moving the slider gives the character its own.
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
    const inherited = &session.profile().ptr.thumbnail;
    const borders = character.get("borderColors") orelse config.CharacterBorderColorsConfig{};
    var next = borders;
    if (try widgets.optionalColor(context, ui.Key.str("knots.character.active").indexed(character.index), "Active Border Color", borders.activeBorderColor, inherited.borderColor)) |change| {
        next.activeBorderColor = switch (change) {
            .cleared => null,
            .set => |argb| argb,
        };
    }
    try widgets.hintText(context, .str("knots.character.active.hint"), "Reset uses the Thumbnails tab's color.");
    if (try widgets.optionalColor(context, ui.Key.str("knots.character.inactive").indexed(character.index), "Inactive Border Color", borders.inactiveBorderColor, inherited.inactiveBorderColor)) |change| {
        next.inactiveBorderColor = switch (change) {
            .cleared => null,
            .set => |argb| argb,
        };
    }
    try widgets.hintText(context, .str("knots.character.inactive.hint"), "Reset uses the Thumbnails tab's color.");
    if (!std.meta.eql(next, borders)) character.set("borderColors", if (next.activeBorderColor == null and next.inactiveBorderColor == null) null else next);
    if (try widgets.optionalColor(context, ui.Key.str("knots.character.name_color").indexed(character.index), "Character Name Color", character.get("nameColor"), inherited.characterNameColor | OPAQUE)) |change| {
        character.set("nameColor", switch (change) {
            .cleared => null,
            .set => |argb| argb,
        });
    }
    try widgets.hintText(context, .str("knots.character.name_color.hint"), "Overrides unique name colors. Reset uses the normal color.");
}

/// Saved at once for the running profile, like a drag; Save Position needs the character's client open.
fn windowPosition(context: *ui.Frame, character: CharacterRef) !void {
    const row = try widgets.openBinding(context, .str("knots.character.window_position"), "Window Position");
    try context.e(Rect{ .key = .src(@src()), .style = &style.spacer });
    const saved = character.get("windowPosition");
    const shown = if (saved) |position| try std.fmt.allocPrint(context.arena(), "{d}, {d}", .{ position.x, position.y }) else lang.text("Not set");
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = shown, .style = &style.muted_text });
    const name = character.get("name");
    const clear_key = ui.Key.str("knots.character.position.clear").indexed(character.index);
    if (saved == null) {
        _ = try context.interact(Button{ .key = clear_key, .label = "\u{00D7}", .disabled = true, .style = &style.icon_button_disabled_text });
    } else if (try widgets.confirmButton(context, clear_key, "\u{00D7}", "OK", &style.icon_button_danger_text, &style.icon_button_confirm)) {
        positions.clear(name) catch |err| {
            slog.err("Failed to clear the window position of '{s}': {}", .{ name, err });
            status.show(.failure, "Failed to save: {err}", .{ .err = err });
        };
    }
    if ((try context.interact(Button{ .key = ui.Key.str("knots.character.position.set").indexed(character.index), .label = lang.text("Save Position"), .style = &style.plain_button })).clicked) {
        if (positions.set(name)) {
            status.show(.success, "Window position saved", .{});
        } else |err| {
            slog.err("Failed to save the window position of '{s}': {}", .{ name, err });
            status.show(.failure, "Failed to save: {err}", .{ .err = err });
        }
    }
    try row.close(context);
    try positionMap(context, character);
    try widgets.hintText(context, .str("knots.character.window_position.hint"), "This character's client must be open to save its position.");
}

/// Every monitor with the saved window on it, or a marker at its top-left when it was saved without a size.
fn positionMap(context: *ui.Frame, character: CharacterRef) !void {
    var map = try ScreenMap.init(context, .str("knots.character.position.map"));
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

/// Opens the picker over the logged-in clients that aren't listed yet, or says why there's nothing to pick.
fn openPicker(context: *ui.Frame, profile: ProfileRef) void {
    const names = unlistedClients(context.arena(), profile) orelse return;
    if (names.len == 0) {
        status.show(.info, "All open EVE clients are already in the list", .{});
        return;
    }
    g_skipped = .empty;
    g_is_picker_open = true;
    context.requestRedraw();
}

/// Each unlisted client with a switch, all on to start; Add takes the ones still on.
fn clientPicker(context: *ui.Frame, profile: ProfileRef) !void {
    if (!g_is_picker_open) return;
    const names = unlistedClients(context.arena(), profile) orelse {
        g_is_picker_open = false;
        return;
    };
    const dialog = try widgets.openPrompt(context, .src(@src()), &g_is_picker_open, "Add Open Clients");
    if (names.len == 0) try widgets.paragraph(context, .src(@src()), "Every logged-in client is already in the list.");
    const shown = names[0..@min(names.len, MAX_PICKER_CLIENTS)];
    var chosen_count: usize = 0;
    for (shown, 0..) |name, index| {
        var is_chosen = !g_skipped.isSet(index);
        if (try widgets.switchRow(context, ui.Key.str("knots.characters.pick").indexed(index), name, &is_chosen)) g_skipped.setValue(index, !is_chosen);
        if (is_chosen) chosen_count += 1;
    }
    const actions = try widgets.openPromptActions(context, .src(@src()), &g_is_picker_open);
    const is_add_clicked = try widgets.promptSubmit(context, .src(@src()), try lang.format(context.arena(), "Add {n}", .{ .n = chosen_count }), chosen_count > 0);
    try actions.close(context);
    try dialog.close(context);
    if (!is_add_clicked) return;

    var added_count: usize = 0;
    for (shown, 0..) |name, index| {
        if (g_skipped.isSet(index)) continue;
        const added = profile.append("characters", .{}) orelse break;
        added.set("name", name);
        added_count += 1;
    }
    status.show(.success, "Added {n} character(s) from open EVE clients", .{ .n = added_count });
    g_is_picker_open = false;
}

/// Logged-in clients not in the list, matched ignoring case and spaces at either end; null once it has said why it couldn't tell.
fn unlistedClients(arena: std.mem.Allocator, profile: ProfileRef) ?[]const []const u8 {
    const names = positions.openClients(arena) catch |err| {
        slog.err("Failed to list open clients: {}", .{err});
        status.show(.failure, "Failed to scan clients: {err}", .{ .err = err });
        return null;
    };
    if (names.len == 0) {
        status.show(.failure, "No open EVE clients found", .{});
        return null;
    }
    var unlisted: std.ArrayList([]const u8) = .empty;
    for (names) |name| {
        const exists = for (profile.ptr.characters.items) |character| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, character.name, " "), std.mem.trim(u8, name, " "))) break true;
        } else false;
        if (exists) continue;
        unlisted.append(arena, name) catch |err| {
            slog.err("Failed to list open clients: {}", .{err});
            return null;
        };
    }
    return unlisted.items;
}
