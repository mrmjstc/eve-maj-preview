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
const window_mod = @import("window.zig");
const log = @import("../../log.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Canvas = ui.component.Canvas;
const TextInput = ui.component.TextInput;
const Tooltip = ui.component.Tooltip;
const Color = ui.Color;
const Window = window_mod.Window;
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
    rename,
    import,
    reset,
    delete,

    fn glyph(self: MenuItem) glyphs.Glyph {
        return switch (self) {
            .new => .add,
            .duplicate => .copy,
            .rename => .pencil,
            .import => .import,
            .reset => .reset,
            .delete => .delete,
        };
    }
};

const NamePrompt = enum { new, rename, restore };

/// What a new profile starts as; Duplicate is New starting from a copy.
const StartFrom = enum { defaults, copy };

const Confirm = enum { delete, reset };

/// One window's, reset as each opens.
pub const State = struct {
    is_menu_open: bool = false,
    name_prompt: ?NamePrompt = null,
    is_name_open: bool = false,
    /// Set as the name prompt opens, so its first frame focuses the name field.
    should_focus_name: bool = false,
    start_from: StartFrom = .defaults,
    /// The rainbow picker chose the accent, so it's the one ringed even when the colour matches a preset.
    is_custom_accent: bool = false,
    /// The name being typed; owned, freed in deinit.
    name_text: std.ArrayList(u8) = .empty,
    name_color: Color = color_convert.fromArgb(profiles.DEFAULT_ACCENT),
    /// The backup a restore prompt is for; owned, freed when another prompt opens or in deinit.
    restore_backup: ?[]u8 = null,
    /// The restored profile's name in the prompt's heading; owned, freed with restore_backup.
    restore_label: ?[]u8 = null,
    confirm: ?Confirm = null,
    is_confirm_open: bool = false,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.name_text.deinit(allocator);
        self.clearRestore(allocator);
    }

    fn clearRestore(self: *State, allocator: std.mem.Allocator) void {
        if (self.restore_backup) |backup| allocator.free(backup);
        self.restore_backup = null;
        if (self.restore_label) |label| allocator.free(label);
        self.restore_label = null;
    }
};

/// The accent picked in the name prompt, previewed on the window until it closes.
pub fn previewAccent(window: *Window) ?u32 {
    if (!window.header.is_name_open) return null;
    return color_convert.toArgb(window.header.name_color);
}

pub fn show(window: *Window, context: *ui.Frame) !void {
    const bar = Rect{ .key = .src(@src()), .style = &style.header };
    _ = try bar.open(context);
    try brand(window, context);
    try context.e(Rect{ .key = .src(@src()), .style = &style.spacer });
    // The settings search is hidden for now; searchBox draws it here.
    try profileButton(window, context);
    try bar.close(context);

    try profileMenu(window, context);
    try namePrompt(window, context);
    try confirmPrompt(window, context);
}

/// From the Backups tab: names the profile `backup` (a backup file name) is restored as, starting from `display_name`.
pub fn openRestorePrompt(window: *Window, backup: []const u8, display_name: []const u8) void {
    window.header.clearRestore(window.allocator);
    window.header.restore_backup = window.allocator.dupe(u8, backup) catch |err| {
        slog.err("Failed to open the restore prompt: {}", .{err});
        return;
    };
    window.header.restore_label = window.allocator.dupe(u8, display_name) catch |err| {
        slog.err("Failed to open the restore prompt: {}", .{err});
        window.header.clearRestore(window.allocator);
        return;
    };
    const accent = config.readProfileBackupAccent(window.allocator, window.session.appContext().io, backup) catch |err| blk: {
        slog.warn("Failed to read the colour of backup '{s}': {}", .{ backup, err });
        break :blk null;
    };
    openNamePrompt(window, .restore, display_name, accent orelse profiles.DEFAULT_ACCENT);
}

fn brand(window: *Window, context: *ui.Frame) !void {
    const lockup = Rect{ .key = .src(@src()), .style = &style.brand };
    _ = try lockup.open(context);
    if (window.images.image(.app_mark, .src(@src()), &style.app_mark)) |mark| try context.e(mark);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "EVE-Maj Preview", .style = &style.brand_name });
    try lockup.close(context);
}

fn searchBox(window: *Window, context: *ui.Frame) !void {
    if (window.search.isActive() and !window.search.needsIndex()) {
        const match_count = window.search.matchCount();
        const text = if (match_count == 0) lang.text("No matches") else try lang.format(context.arena(), if (match_count == 1) "{n} section" else "{n} sections", .{ .n = match_count });
        try context.e(Text{ .selectable = false, .key = .src(@src()), .content = text, .style = if (match_count == 0) &style.search_count_none else &style.search_count_some });
    }
    const box = Rect{ .key = .src(@src()), .style = &style.search_container };
    _ = try box.open(context);
    try widgets.searchBox(context, SEARCH_KEY, &window.search.query_text, "Search settings...");
    try box.close(context);
}

fn profileButton(window: *Window, context: *ui.Frame) !void {
    const ui_state = context.ui();
    // Measured, so the menu can drop from it.
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, PROFILE_BUTTON_KEY.hash());
    const button = Button{ .key = PROFILE_BUTTON_KEY, .style = if (window.header.is_menu_open) &style.profile_button_open else &style.profile_button };
    const response = try button.openResponse(context);
    const running = window.session.profile().ptr;
    const running_name = profiles.displayName(running.profile_name);
    try ui_state.setAccessibilityName(response.id, running_name);
    try swatch(context, PROFILE_BUTTON_KEY.indexed(1), running.accentColor);
    try context.e(Text{ .selectable = false, .key = PROFILE_BUTTON_KEY.indexed(2), .content = running_name, .style = &style.profile_name });
    try context.e(Canvas{ .key = PROFILE_BUTTON_KEY.indexed(3), .commands = try selectChevron(context.arena(), window.header.is_menu_open), .style = &style.select_chevron });
    try button.close(context);
    if (response.clicked) {
        window.header.is_menu_open = true;
        context.requestRedraw();
    }
}

fn profileMenu(window: *Window, context: *ui.Frame) !void {
    if (!window.header.is_menu_open) return;
    const dialog = try widgets.openMenu(context, MENU_KEY, &window.header.is_menu_open, widgets.measuredBox(context.ui(), PROFILE_BUTTON_KEY));
    const caption = Rect{ .key = MENU_KEY.indexed(10), .style = &style.menu_caption };
    _ = try caption.open(context);
    try context.e(Text{ .selectable = false, .key = MENU_KEY.indexed(11), .content = lang.text("PROFILES"), .style = &style.tab_category_text });
    try caption.close(context);

    const running = window.session.profile().ptr;
    for (profiles.list(window), profiles.accents(window), 0..) |name, accent, index| {
        const is_running = std.mem.eql(u8, name, running.profile_name);
        // The running profile's own colour may have unsaved edits.
        const shown_accent = if (is_running) running.accentColor else accent;
        if (try profileItem(window, context, index, name, shown_accent, is_running) and !is_running) profiles.request(window, .switch_to, name, null);
    }

    try divider(context, MENU_KEY.indexed(12));
    const arena = context.arena();
    const name = profiles.displayName(running.profile_name);
    if (try menuItem(window, context, .new, lang.text("New Profile"), false)) openNewPrompt(window, .defaults);
    if (try menuItem(window, context, .duplicate, try lang.format(arena, "Duplicate '{name}'", .{ .name = name }), false)) openNewPrompt(window, .copy);
    const is_default = std.mem.eql(u8, running.profile_name, config.DEFAULT_PROFILE);
    const rename_label = try lang.format(arena, "Rename '{name}'", .{ .name = name });
    if (is_default) {
        try unavailableMenuItem(window, context, .rename, rename_label, "The default profile can't be renamed.");
    } else if (try menuItem(window, context, .rename, rename_label, false)) {
        openNamePrompt(window, .rename, name, running.accentColor);
    }
    if (try menuItem(window, context, .import, lang.text("Import Settings"), false)) import_dialog.open(window);
    try divider(context, MENU_KEY.indexed(13));
    if (try menuItem(window, context, .reset, try lang.format(arena, "Reset '{name}' to Defaults", .{ .name = name }), false)) openConfirm(window, .reset);
    const delete_label = try lang.format(arena, "Delete '{name}'", .{ .name = name });
    if (is_default) {
        try unavailableMenuItem(window, context, .delete, delete_label, "The default profile can't be deleted.");
    } else if (try menuItem(window, context, .delete, delete_label, false)) {
        openConfirm(window, .delete);
    }
    try dialog.close(context);
}

/// Returns whether it was clicked, which closes the menu.
fn profileItem(window: *Window, context: *ui.Frame, index: usize, name: []const u8, accent: u32, is_running: bool) !bool {
    const key = ui.Key.str("knots.header.menu.profile").indexed(index);
    const button = Button{ .key = key, .style = if (is_running) &style.menu_item_current else &style.menu_item };
    const response = try button.openResponse(context);
    const shown_name = profiles.displayName(name);
    try context.ui().setAccessibilityName(response.id, shown_name);
    if (is_running) {
        try glyph(context, key.indexed(1), .check, context.ui().theme.primary);
    } else {
        try context.e(Rect{ .key = key.indexed(1), .style = &style.menu_glyph });
    }
    try swatch(context, key.indexed(2), accent);
    try context.e(Text{ .selectable = false, .key = key.indexed(3), .content = shown_name, .style = if (is_running or response.hovered) &style.menu_label_lit else &style.menu_label });
    try button.close(context);
    return closesMenu(window, context, response.clicked);
}

/// Returns whether it was clicked, which closes the menu.
fn menuItem(window: *Window, context: *ui.Frame, item: MenuItem, label: []const u8, is_disabled: bool) !bool {
    const key = ui.Key.str("knots.header.menu.item").indexed(@backingInt(item));
    const button = Button{ .key = key, .disabled = is_disabled, .style = if (is_disabled) &style.menu_item_disabled else &style.menu_item };
    const response = try button.openResponse(context);
    try context.ui().setAccessibilityName(response.id, label);
    const is_danger = item == .delete;
    const tint = if (is_disabled) style.BORDER_STRONG else if (is_danger) style.DESTRUCTIVE else if (response.hovered) style.TEXT else style.MUTED;
    try glyph(context, key.indexed(1), item.glyph(), tint);
    const label_style = if (is_disabled) &style.menu_label_disabled else if (is_danger) &style.menu_label_danger else if (response.hovered) &style.menu_label_lit else &style.menu_label;
    try context.e(Text{ .selectable = false, .key = key.indexed(2), .content = label, .style = label_style });
    try button.close(context);
    return closesMenu(window, context, response.clicked and !is_disabled);
}

/// A disabled menuItem, saying why on hover.
fn unavailableMenuItem(window: *Window, context: *ui.Frame, item: MenuItem, label: []const u8, reason: []const u8) !void {
    const tip = Tooltip{ .key = ui.Key.str("knots.header.menu.reason").indexed(@backingInt(item)), .content = lang.text(reason), .style = &style.menu_item_tip };
    _ = try tip.open(context);
    _ = try menuItem(window, context, item, label, true);
    try tip.close(context);
}

fn closesMenu(window: *Window, context: *ui.Frame, is_clicked: bool) bool {
    if (is_clicked) {
        window.header.is_menu_open = false;
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

fn openNewPrompt(window: *Window, start_from: StartFrom) void {
    window.header.start_from = start_from;
    var buf: [SUGGESTION_LENGTH]u8 = undefined;
    openNamePrompt(window, .new, suggestedName(window, &buf, start_from), switch (start_from) {
        .defaults => profiles.DEFAULT_ACCENT,
        .copy => window.session.profile().ptr.accentColor,
    });
}

/// None from defaults, "Main - Copy" for a copy of Main; borrows from `buf` or the running profile.
fn suggestedName(window: *Window, buf: *[SUGGESTION_LENGTH]u8, start_from: StartFrom) []const u8 {
    const name = profiles.displayName(window.session.profile().ptr.profile_name);
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
fn changeStartFrom(window: *Window, start_from: StartFrom) void {
    var old_buf: [SUGGESTION_LENGTH]u8 = undefined;
    var new_buf: [SUGGESTION_LENGTH]u8 = undefined;
    if (std.mem.eql(u8, window.header.name_text.items, suggestedName(window, &old_buf, window.header.start_from))) _ = setName(window, suggestedName(window, &new_buf, start_from));
    window.header.start_from = start_from;
}

fn openNamePrompt(window: *Window, prompt: NamePrompt, initial: []const u8, accent: u32) void {
    if (!setName(window, initial)) return;
    window.header.name_color = color_convert.fromArgb(accent);
    window.header.is_custom_accent = !widgets.isPresetAccent(accent);
    window.header.name_prompt = prompt;
    window.header.is_name_open = true;
    window.header.should_focus_name = true;
}

/// Returns false once it has logged a failure.
fn setName(window: *Window, name: []const u8) bool {
    window.header.name_text.clearRetainingCapacity();
    window.header.name_text.appendSlice(window.allocator, strings.utf8Prefix(name, profile_files.MAX_NAME_LENGTH)) catch |err| {
        slog.err("Failed to fill in the profile name: {}", .{err});
        return false;
    };
    return true;
}

fn namePrompt(window: *Window, context: *ui.Frame) !void {
    const prompt = window.header.name_prompt orelse return;
    if (!window.header.is_name_open) {
        window.header.name_prompt = null;
        return;
    }
    const arena = context.arena();
    const title = switch (prompt) {
        .new => lang.text("New Profile"),
        .rename => lang.text("Rename Profile"),
        .restore => try lang.format(arena, "Restore Backup: {name}", .{ .name = window.header.restore_label orelse "" }),
    };
    const dialog = try widgets.openModal(context, .src(@src()), &window.header.is_name_open, &style.modal, title);

    const name_row = try window.widgets.openModalRow(context, .src(@src()), "Name");
    if (window.header.should_focus_name) {
        try widgets.focusTextInput(context, NAME_INPUT_KEY, window.header.name_text.items.len);
        window.header.should_focus_name = false;
    }
    try context.e(TextInput{ .key = NAME_INPUT_KEY, .buf = &window.header.name_text, .allocator = window.allocator, .placeholder = lang.text("Profile name"), .style = &style.text_input_aligned });
    try name_row.close(context);
    try window.widgets.hintText(context, .src(@src()), "Use " ++ profiles.NAME_RULES ++ ".");
    const typed = std.mem.trim(u8, window.header.name_text.items, " ");
    // A restore may go over an existing profile, which is backed up first.
    const replaced = if (prompt == .restore) profiles.existingProfile(window, arena, typed) else null;
    const running_name = window.session.profile().ptr.profile_name;
    // A rename may change only the case, which still names the profile being renamed.
    const is_own_name = prompt == .rename and std.ascii.eqlIgnoreCase(profiles.existingProfile(window, arena, typed) orelse "", running_name);
    const problem = if (replaced != null or is_own_name) null else profiles.nameProblem(window, arena, typed);
    if (problem) |message| try widgets.boxedText(context, .src(@src()), message, &style.modal_hint_box, &style.field_error);
    if (replaced) |file_name| {
        const note = try lang.format(arena, "Replaces the current '{name}'; it's backed up first.", .{ .name = profiles.displayName(file_name) });
        try widgets.boxedText(context, .src(@src()), note, &style.modal_hint_box, &style.hint);
    }

    switch (prompt) {
        .new => {
            const start_row = try window.widgets.openModalRow(context, .src(@src()), "Start from");
            const copy_label = try lang.format(arena, "Copy of '{name}'", .{ .name = profiles.displayName(window.session.profile().ptr.profile_name) });
            if (try window.widgets.segmented(context, .src(@src()), &.{ "Defaults", copy_label }, @backingInt(window.header.start_from))) |index| {
                changeStartFrom(window, @fromBackingInt(@intCast(index)));
                context.requestRedraw();
            }
            try start_row.close(context);
            try window.widgets.hintText(context, .src(@src()), "Defaults starts fresh; a copy takes every setting from the current profile.");
        },
        .rename, .restore => {},
    }

    // A rename keeps the profile's colour, which its own settings already hold.
    if (prompt != .rename) {
        const color_row = try window.widgets.openModalRow(context, .src(@src()), "Color");
        try widgets.accentChoices(context, .src(@src()), &window.header.name_color, &window.header.is_custom_accent);
        try color_row.close(context);
        try window.widgets.hintText(context, .src(@src()), "Marks it in the profile menu and tints this window.");
    }

    const actions = Rect{ .key = .src(@src()), .style = &style.modal_actions };
    _ = try actions.open(context);
    if (try modalButton(context, .src(@src()), "Cancel", &style.plain_button)) window.header.is_name_open = false;
    const submit_label = switch (prompt) {
        .new => "Create",
        .rename => "Rename",
        .restore => if (replaced != null) "Replace" else "Restore",
    };
    const is_unchanged = prompt == .rename and std.mem.eql(u8, typed, profiles.displayName(running_name));
    const can_submit = typed.len > 0 and problem == null and !is_unchanged;
    const submit = Button{ .key = .src(@src()), .label = lang.text(submit_label), .disabled = !can_submit, .style = if (can_submit) &style.primary_button else &style.disabled_button };
    if ((try context.interact(submit)).clicked and can_submit) {
        submitName(window, prompt);
        context.requestRedraw();
    }
    try actions.close(context);
    try dialog.close(context);
}

fn submitName(window: *Window, prompt: NamePrompt) void {
    const typed = std.mem.trim(u8, window.header.name_text.items, " ");
    const file_name = config.profileFileName(window.allocator, typed) catch |err| {
        slog.info("Rejected profile name '{s}': {}", .{ typed, err });
        window.status.show(.failure, "'{name}' isn't a valid profile name: use " ++ profiles.NAME_RULES, .{ .name = typed });
        return;
    };
    defer window.allocator.free(file_name);
    const accent = color_convert.toArgb(window.header.name_color);
    switch (prompt) {
        .new => profiles.request(window, switch (window.header.start_from) {
            .defaults => .create,
            .copy => .copy,
        }, file_name, accent),
        .rename => profiles.request(window, .rename, file_name, null),
        .restore => if (window.header.restore_backup) |backup| {
            if (profiles.listedName(window, file_name)) |existing| {
                profiles.requestRestore(window, .replace_with_backup, existing, backup, accent);
            } else {
                profiles.requestRestore(window, .restore, file_name, backup, accent);
            }
        },
    }
    window.header.is_name_open = false;
}

fn openConfirm(window: *Window, confirm: Confirm) void {
    window.header.confirm = confirm;
    window.header.is_confirm_open = true;
}

fn confirmPrompt(window: *Window, context: *ui.Frame) !void {
    const confirm = window.header.confirm orelse return;
    if (!window.header.is_confirm_open) {
        window.header.confirm = null;
        return;
    }
    const name = window.session.profile().ptr.profile_name;
    const dialog = try widgets.openModal(context, .src(@src()), &window.header.is_confirm_open, &style.modal, lang.text(switch (confirm) {
        .delete => "Delete Profile?",
        .reset => "Reset Profile?",
    }));
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
    if (try modalButton(context, .src(@src()), "Cancel", &style.plain_button)) window.header.is_confirm_open = false;
    if (try modalButton(context, .src(@src()), switch (confirm) {
        .delete => "Delete",
        .reset => "Reset",
    }, &style.danger_primary_button)) {
        profiles.request(window, switch (confirm) {
            .delete => .delete,
            .reset => .reset,
        }, name, null);
        window.header.is_confirm_open = false;
    }
    try actions.close(context);
    try dialog.close(context);
}

fn modalButton(context: *ui.Frame, key: ui.Key, label: []const u8, button_style: *const ui.Style) !bool {
    const is_clicked = (try context.interact(Button{ .key = key, .label = lang.text(label), .style = button_style })).clicked;
    if (is_clicked) context.requestRedraw();
    return is_clicked;
}
