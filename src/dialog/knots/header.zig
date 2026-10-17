//! The configuration window's header: the brand, the running profile's button and its menu, the prompts the menu opens, and the settings search, hidden for now; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../config.zig");
const profile_files = @import("../../config/profiles.zig");
const session = @import("session.zig");
const profiles = @import("profiles.zig");
const status = @import("status.zig");
const style = @import("style.zig");
const widgets = @import("widgets.zig");
const strings = @import("../../util/strings.zig");
const color_convert = @import("color_convert.zig");
const images = @import("images.zig");
const import_dialog = @import("import_dialog.zig");
const glyphs = @import("glyphs.zig");
const search = @import("search.zig");
const lang = @import("../../lang/lang.zig");
const log = @import("../../log.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Canvas = ui.component.Canvas;
const TextInput = ui.component.TextInput;
const Color = ui.Color;
const slog = log.Scoped("dialog_knots");

const COPY_NAME = "{name} - Copy";
/// Room for a translation's longer wording around the name.
const SUGGESTION_LENGTH = profile_files.MAX_NAME_LENGTH + 64;
const PROFILE_BUTTON_KEY: ui.Key = .str("knots.header.profile");
const MENU_KEY: ui.Key = .str("knots.header.menu");
const SEARCH_KEY: ui.Key = .str("knots.search");
const NAME_INPUT_KEY: ui.Key = .str("knots.header.name");

/// The profile menu's entries after the profiles themselves.
const MenuItem = enum {
    new,
    duplicate,
    import,
    reset,
    delete,

    fn glyph(self: MenuItem) glyphs.Glyph {
        return switch (self) {
            .new => .add,
            .duplicate => .copy,
            .import => .import,
            .reset => .reset,
            .delete => .delete,
        };
    }
};

const NamePrompt = enum { new, restore };

/// What a new profile starts as; Duplicate is New starting from a copy.
const StartFrom = enum { defaults, copy };

const Confirm = enum { delete, reset };

var g_allocator: std.mem.Allocator = undefined;
var g_is_menu_open: bool = false;
var g_name_prompt: ?NamePrompt = null;
var g_is_name_open: bool = false;
/// Set as the name prompt opens, so its first frame focuses the name field.
var g_should_focus_name: bool = false;
var g_start_from: StartFrom = .defaults;
/// The rainbow picker chose the accent, so it's the one ringed even when the colour matches a preset.
var g_is_custom_accent: bool = false;
/// The name being typed. Owned; freed in deinit.
var g_name_text: std.ArrayList(u8) = .empty;
var g_name_color: Color = undefined;
/// The backup a restore prompt is for. Owned; freed when another prompt opens or in deinit.
var g_restore_backup: ?[]u8 = null;
/// The restored profile's name in the prompt's heading. Owned; freed with g_restore_backup.
var g_restore_label: ?[]u8 = null;
var g_confirm: ?Confirm = null;
var g_is_confirm_open: bool = false;

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// Once the window has closed.
pub fn deinit() void {
    g_is_menu_open = false;
    g_name_text.deinit(g_allocator);
    g_name_text = .empty;
    clearRestore();
    g_name_prompt = null;
    g_is_name_open = false;
    g_confirm = null;
    g_is_confirm_open = false;
}

/// The accent picked in the name prompt, previewed on the window until it closes.
pub fn previewAccent() ?u32 {
    if (!g_is_name_open) return null;
    return color_convert.toArgb(g_name_color);
}

pub fn show(context: *ui.Frame) !void {
    const bar = Rect{ .key = .src(@src()), .style = &style.header };
    _ = try bar.open(context);
    try brand(context);
    try context.e(Rect{ .key = .src(@src()), .style = &style.spacer });
    // The settings search is hidden for now; searchBox draws it here.
    try profileButton(context);
    try bar.close(context);

    try profileMenu(context);
    try namePrompt(context);
    try confirmPrompt(context);
}

/// From the Backups tab: names the profile `backup` (a backup file name) is restored as, starting from `display_name`.
pub fn openRestorePrompt(backup: []const u8, display_name: []const u8) void {
    clearRestore();
    g_restore_backup = g_allocator.dupe(u8, backup) catch |err| {
        slog.err("Failed to open the restore prompt: {}", .{err});
        return;
    };
    g_restore_label = g_allocator.dupe(u8, display_name) catch |err| {
        slog.err("Failed to open the restore prompt: {}", .{err});
        clearRestore();
        return;
    };
    const accent = config.readProfileBackupAccent(g_allocator, session.runningApp().io, backup) catch |err| blk: {
        slog.warn("Failed to read the colour of backup '{s}': {}", .{ backup, err });
        break :blk null;
    };
    openNamePrompt(.restore, display_name, accent orelse profiles.DEFAULT_ACCENT);
}

fn brand(context: *ui.Frame) !void {
    const lockup = Rect{ .key = .src(@src()), .style = &style.brand };
    _ = try lockup.open(context);
    if (images.g_app_mark.image(.src(@src()), &style.app_mark)) |mark| try context.e(mark);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "EVE-Maj Preview", .style = &style.brand_name });
    try lockup.close(context);
}

fn searchBox(context: *ui.Frame) !void {
    if (search.isActive() and !search.needsIndex()) {
        const match_count = search.matchCount();
        const text = if (match_count == 0) lang.text("No matches") else try lang.format(context.arena(), if (match_count == 1) "{n} section" else "{n} sections", .{ .n = match_count });
        try context.e(Text{ .selectable = false, .key = .src(@src()), .content = text, .style = if (match_count == 0) &style.search_count_none else &style.search_count_some });
    }
    const box = Rect{ .key = .src(@src()), .style = &style.search_container };
    _ = try box.open(context);
    try widgets.searchBox(context, SEARCH_KEY, &search.g_query, "Search settings...");
    try box.close(context);
}

fn profileButton(context: *ui.Frame) !void {
    const ui_state = context.ui();
    // Measured, so the menu can drop from it.
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, PROFILE_BUTTON_KEY.hash());
    const button = Button{ .key = PROFILE_BUTTON_KEY, .style = if (g_is_menu_open) &style.profile_button_open else &style.profile_button };
    const response = try button.openResponse(context);
    const running = session.profile().ptr;
    try swatch(context, PROFILE_BUTTON_KEY.indexed(1), running.accentColor);
    try context.e(Text{ .selectable = false, .key = PROFILE_BUTTON_KEY.indexed(2), .content = profiles.displayName(running.profile_name), .style = &style.profile_name });
    try context.e(Canvas{ .key = PROFILE_BUTTON_KEY.indexed(3), .commands = try selectChevron(context.arena(), g_is_menu_open), .style = &style.select_chevron });
    try button.close(context);
    if (response.clicked) {
        g_is_menu_open = true;
        context.requestRedraw();
    }
}

fn profileMenu(context: *ui.Frame) !void {
    if (!g_is_menu_open) return;
    const dialog = try widgets.openMenu(context, MENU_KEY, &g_is_menu_open, widgets.measuredBox(context.ui(), PROFILE_BUTTON_KEY));
    const caption = Rect{ .key = MENU_KEY.indexed(10), .style = &style.menu_caption };
    _ = try caption.open(context);
    try context.e(Text{ .selectable = false, .key = MENU_KEY.indexed(11), .content = lang.text("PROFILES"), .style = &style.tab_category_text });
    try caption.close(context);

    const running = session.profile().ptr;
    for (profiles.list(), profiles.accents(), 0..) |name, accent, index| {
        const is_running = std.mem.eql(u8, name, running.profile_name);
        // The running profile's own colour may have unsaved edits.
        const shown_accent = if (is_running) running.accentColor else accent;
        if (try profileItem(context, index, name, shown_accent, is_running) and !is_running) profiles.request(.switch_to, name, null);
    }

    try divider(context, MENU_KEY.indexed(12));
    const arena = context.arena();
    const name = profiles.displayName(running.profile_name);
    if (try menuItem(context, .new, lang.text("New Profile"), false)) openNewPrompt(.defaults);
    if (try menuItem(context, .duplicate, try lang.format(arena, "Duplicate '{name}'", .{ .name = name }), false)) openNewPrompt(.copy);
    if (try menuItem(context, .import, lang.text("Import Settings"), false)) import_dialog.open();
    try divider(context, MENU_KEY.indexed(13));
    if (try menuItem(context, .reset, try lang.format(arena, "Reset '{name}' to Defaults", .{ .name = name }), false)) openConfirm(.reset);
    const is_default = std.mem.eql(u8, running.profile_name, config.DEFAULT_PROFILE);
    if (try menuItem(context, .delete, try lang.format(arena, "Delete '{name}'", .{ .name = name }), is_default)) openConfirm(.delete);
    try dialog.close(context);
}

/// Returns whether it was clicked, which closes the menu.
fn profileItem(context: *ui.Frame, index: usize, name: []const u8, accent: u32, is_running: bool) !bool {
    const key = ui.Key.str("knots.header.menu.profile").indexed(index);
    const button = Button{ .key = key, .style = if (is_running) &style.menu_item_current else &style.menu_item };
    const response = try button.openResponse(context);
    if (is_running) {
        try glyph(context, key.indexed(1), .check, context.ui().theme.primary);
    } else {
        try context.e(Rect{ .key = key.indexed(1), .style = &style.menu_glyph });
    }
    try swatch(context, key.indexed(2), accent);
    try context.e(Text{ .selectable = false, .key = key.indexed(3), .content = profiles.displayName(name), .style = if (is_running or response.hovered) &style.menu_label_lit else &style.menu_label });
    try button.close(context);
    return closesMenu(context, response.clicked);
}

/// Returns whether it was clicked, which closes the menu.
fn menuItem(context: *ui.Frame, item: MenuItem, label: []const u8, is_disabled: bool) !bool {
    const key = ui.Key.str("knots.header.menu.item").indexed(@backingInt(item));
    const button = Button{ .key = key, .disabled = is_disabled, .style = if (is_disabled) &style.menu_item_disabled else &style.menu_item };
    const response = try button.openResponse(context);
    const is_danger = item == .delete;
    const tint = if (is_disabled) style.BORDER_STRONG else if (is_danger) style.DESTRUCTIVE else if (response.hovered) style.TEXT else style.MUTED;
    try glyph(context, key.indexed(1), item.glyph(), tint);
    const label_style = if (is_disabled) &style.menu_label_disabled else if (is_danger) &style.menu_label_danger else if (response.hovered) &style.menu_label_lit else &style.menu_label;
    try context.e(Text{ .selectable = false, .key = key.indexed(2), .content = label, .style = label_style });
    try button.close(context);
    return closesMenu(context, response.clicked and !is_disabled);
}

fn closesMenu(context: *ui.Frame, is_clicked: bool) bool {
    if (is_clicked) {
        g_is_menu_open = false;
        context.requestRedraw();
    }
    return is_clicked;
}

fn divider(context: *ui.Frame, key: ui.Key) !void {
    const box = Rect{ .key = key, .style = &style.menu_divider };
    _ = try box.open(context);
    try context.e(Rect{ .key = key.indexed(1), .style = &style.separator });
    try box.close(context);
}

fn swatch(context: *ui.Frame, key: ui.Key, argb: u32) !void {
    const swatch_style = try context.arena().create(ui.Style);
    swatch_style.* = style.profile_swatch.with(.{ .background = color_convert.solid(argb) });
    try context.e(Rect{ .key = key, .style = swatch_style });
}

/// Drawn as knots' select draws its own, so the profile button reads as one of the dropdowns.
fn selectChevron(arena: std.mem.Allocator, is_open: bool) ![]const Canvas.DrawCmd {
    const size: f32 = style.SELECT_CHEVRON_SIZE;
    const mid = size * 0.5;
    const edge_y = size * @as(f32, if (is_open) 0.62 else 0.38);
    const tip_y = size * @as(f32, if (is_open) 0.34 else 0.66);
    const thickness = 1.75;
    const commands = try arena.alloc(Canvas.DrawCmd, 2);
    commands[0] = .{ .line = .{ .from = .{ size * 0.2, edge_y }, .to = .{ mid, tip_y }, .color = style.TEXT.value, .thickness = thickness } };
    commands[1] = .{ .line = .{ .from = .{ mid, tip_y }, .to = .{ size * 0.8, edge_y }, .color = style.TEXT.value, .thickness = thickness } };
    return commands;
}

fn glyph(context: *ui.Frame, key: ui.Key, which: glyphs.Glyph, tint: Color) !void {
    try context.e(Canvas{
        .key = key,
        .commands = try glyphs.commands(context.arena(), which, glyphs.ICON_SIZE, try glyphs.snapOffset(context, key), tint.value),
        .style = &style.menu_glyph,
    });
}

fn openNewPrompt(start_from: StartFrom) void {
    g_start_from = start_from;
    var buf: [SUGGESTION_LENGTH]u8 = undefined;
    openNamePrompt(.new, suggestedName(&buf, start_from), switch (start_from) {
        .defaults => profiles.DEFAULT_ACCENT,
        .copy => session.profile().ptr.accentColor,
    });
}

/// None from defaults, "Main - Copy" for a copy of Main; borrows from `buf` or the running profile.
fn suggestedName(buf: *[SUGGESTION_LENGTH]u8, start_from: StartFrom) []const u8 {
    const name = profiles.displayName(session.profile().ptr.profile_name);
    return switch (start_from) {
        .defaults => "",
        .copy => blk: {
            var writer: std.Io.Writer = .fixed(buf);
            lang.write(&writer, COPY_NAME, .{ .name = name }) catch |err| {
                slog.warn("Failed to suggest a name for the copy of '{s}': {}", .{ name, err });
                break :blk name;
            };
            break :blk writer.buffered();
        },
    };
}

/// Keeps a typed name, but swaps the suggestion for the new source's.
fn changeStartFrom(start_from: StartFrom) void {
    var old_buf: [SUGGESTION_LENGTH]u8 = undefined;
    var new_buf: [SUGGESTION_LENGTH]u8 = undefined;
    if (std.mem.eql(u8, g_name_text.items, suggestedName(&old_buf, g_start_from))) _ = setName(suggestedName(&new_buf, start_from));
    g_start_from = start_from;
}

fn openNamePrompt(prompt: NamePrompt, initial: []const u8, accent: u32) void {
    if (!setName(initial)) return;
    g_name_color = color_convert.fromArgb(accent);
    g_is_custom_accent = !widgets.isPresetAccent(accent);
    g_name_prompt = prompt;
    g_is_name_open = true;
    g_should_focus_name = true;
}

/// Returns false once it has logged a failure.
fn setName(name: []const u8) bool {
    g_name_text.clearRetainingCapacity();
    g_name_text.appendSlice(g_allocator, strings.utf8Prefix(name, profile_files.MAX_NAME_LENGTH)) catch |err| {
        slog.err("Failed to fill in the profile name: {}", .{err});
        return false;
    };
    return true;
}

fn namePrompt(context: *ui.Frame) !void {
    const prompt = g_name_prompt orelse return;
    if (!g_is_name_open) {
        g_name_prompt = null;
        return;
    }
    const arena = context.arena();
    const dialog = widgets.modal(.src(@src()), &g_is_name_open, &style.modal);
    _ = try dialog.open(context);
    try context.e(Text{
        .selectable = false,
        .key = .src(@src()),
        .content = switch (prompt) {
            .new => lang.text("New Profile"),
            .restore => try lang.format(arena, "Restore Backup: {name}", .{ .name = g_restore_label orelse "" }),
        },
        .style = &style.heading,
    });

    const name_row = try widgets.openModalRow(context, .src(@src()), "Name");
    if (g_should_focus_name) {
        try widgets.focusTextInput(context, NAME_INPUT_KEY, g_name_text.items.len);
        g_should_focus_name = false;
    }
    try context.e(TextInput{ .key = NAME_INPUT_KEY, .buf = &g_name_text, .placeholder = lang.text("Profile name"), .style = &style.text_input_aligned });
    try name_row.close(context);
    try widgets.hintText(context, .src(@src()), "Use " ++ profiles.NAME_RULES ++ ".");
    const typed = std.mem.trim(u8, g_name_text.items, " ");
    // A restore may go over an existing profile, which is backed up first.
    const replaced = if (prompt == .restore) profiles.existingProfile(arena, typed) else null;
    const problem = if (replaced != null) null else profiles.nameProblem(arena, typed);
    if (problem) |message| try widgets.boxedText(context, .src(@src()), message, &style.modal_hint_box, &style.field_error);
    if (replaced) |file_name| {
        const note = try lang.format(arena, "Replaces the current '{name}'; it's backed up first.", .{ .name = profiles.displayName(file_name) });
        try widgets.boxedText(context, .src(@src()), note, &style.modal_hint_box, &style.hint);
    }

    switch (prompt) {
        .new => {
            const start_row = try widgets.openModalRow(context, .src(@src()), "Start from");
            const copy_label = try lang.format(arena, "Copy of '{name}'", .{ .name = profiles.displayName(session.profile().ptr.profile_name) });
            if (try widgets.segmented(context, .src(@src()), &.{ "Defaults", copy_label }, @backingInt(g_start_from))) |index| {
                changeStartFrom(@fromBackingInt(@intCast(index)));
                context.requestRedraw();
            }
            try start_row.close(context);
            try widgets.hintText(context, .src(@src()), "Defaults starts fresh; a copy takes every setting from the current profile.");
        },
        .restore => {},
    }

    const color_row = try widgets.openModalRow(context, .src(@src()), "Color");
    try widgets.accentChoices(context, .src(@src()), &g_name_color, &g_is_custom_accent);
    try color_row.close(context);
    try widgets.hintText(context, .src(@src()), "Marks it in the profile menu and tints this window.");

    const actions = Rect{ .key = .src(@src()), .style = &style.modal_actions };
    _ = try actions.open(context);
    if (try modalButton(context, .src(@src()), "Cancel", &style.plain_button)) g_is_name_open = false;
    const submit_label = switch (prompt) {
        .new => "Create",
        .restore => if (replaced != null) "Replace" else "Restore",
    };
    const can_submit = typed.len > 0 and problem == null;
    const submit = Button{ .key = .src(@src()), .label = lang.text(submit_label), .disabled = !can_submit, .style = if (can_submit) &style.primary_button else &style.disabled_primary_button };
    if ((try context.interact(submit)).clicked and can_submit) {
        submitName(prompt);
        context.requestRedraw();
    }
    try actions.close(context);
    try dialog.close(context);
}

fn submitName(prompt: NamePrompt) void {
    const typed = std.mem.trim(u8, g_name_text.items, " ");
    const file_name = config.profileFileName(g_allocator, typed) catch |err| {
        slog.info("Rejected profile name '{s}': {}", .{ typed, err });
        status.show(.failure, "'{name}' isn't a valid profile name: use " ++ profiles.NAME_RULES, .{ .name = typed });
        return;
    };
    defer g_allocator.free(file_name);
    const accent = color_convert.toArgb(g_name_color);
    switch (prompt) {
        .new => profiles.request(switch (g_start_from) {
            .defaults => .create,
            .copy => .copy,
        }, file_name, accent),
        .restore => if (g_restore_backup) |backup| {
            if (profiles.listedName(file_name)) |existing| {
                profiles.requestRestore(.replace_with_backup, existing, backup, accent);
            } else {
                profiles.requestRestore(.restore, file_name, backup, accent);
            }
        },
    }
    g_is_name_open = false;
}

fn clearRestore() void {
    if (g_restore_backup) |backup| g_allocator.free(backup);
    g_restore_backup = null;
    if (g_restore_label) |label| g_allocator.free(label);
    g_restore_label = null;
}

fn openConfirm(confirm: Confirm) void {
    g_confirm = confirm;
    g_is_confirm_open = true;
}

fn confirmPrompt(context: *ui.Frame) !void {
    const confirm = g_confirm orelse return;
    if (!g_is_confirm_open) {
        g_confirm = null;
        return;
    }
    const name = session.profile().ptr.profile_name;
    const dialog = widgets.modal(.src(@src()), &g_is_confirm_open, &style.modal);
    _ = try dialog.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text(switch (confirm) {
        .delete => "Delete Profile?",
        .reset => "Reset Profile?",
    }), .style = &style.heading });
    try context.e(Text{
        .selectable = false,
        .key = .src(@src()),
        .content = switch (confirm) {
            .delete => try lang.format(context.arena(), "'{name}' is moved to a backup, which the Backups tab can restore.", .{ .name = profiles.displayName(name) }),
            .reset => try lang.format(context.arena(), "Every setting in '{name}' goes back to its default. A backup is kept, which the Backups tab can restore.", .{ .name = profiles.displayName(name) }),
        },
        .style = &style.modal_text,
    });
    const actions = Rect{ .key = .src(@src()), .style = &style.modal_actions };
    _ = try actions.open(context);
    if (try modalButton(context, .src(@src()), "Cancel", &style.plain_button)) g_is_confirm_open = false;
    if (try modalButton(context, .src(@src()), switch (confirm) {
        .delete => "Delete",
        .reset => "Reset",
    }, &style.danger_primary_button)) {
        profiles.request(switch (confirm) {
            .delete => .delete,
            .reset => .reset,
        }, name, null);
        g_is_confirm_open = false;
    }
    try actions.close(context);
    try dialog.close(context);
}

fn modalButton(context: *ui.Frame, key: ui.Key, label: []const u8, button_style: *const ui.Style) !bool {
    const is_clicked = (try context.interact(Button{ .key = key, .label = lang.text(label), .style = button_style })).clicked;
    if (is_clicked) context.requestRedraw();
    return is_clicked;
}
