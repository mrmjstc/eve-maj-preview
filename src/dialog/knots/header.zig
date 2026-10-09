//! The configuration window's header: the app mark, which profile the window edits, the profile buttons and their prompts; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../config.zig");
const profile_files = @import("../../config/profiles.zig");
const session = @import("session.zig");
const profiles = @import("profiles.zig");
const status = @import("status.zig");
const style = @import("style.zig");
const widgets = @import("widgets.zig");
const images = @import("images.zig");
const import_dialog = @import("import_dialog.zig");
const glyphs = @import("glyphs.zig");
const log = @import("../../log.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Canvas = ui.component.Canvas;
const Dialog = ui.component.Dialog;
const TextInput = ui.component.TextInput;
const ColorPicker = ui.component.ColorPicker;
const SelectInput = ui.component.SelectInput;
const Color = ui.Color;
const slog = log.scoped("dialog_knots");

const COPY_SUFFIX = " - Copy";
/// A new profile's accent colour, Config's own default.
pub const DEFAULT_ACCENT = blk: {
    const index = std.meta.fieldIndex(config.Config, "accentColor").?;
    break :blk @typeInfo(config.Config).@"struct".field_attrs[index].defaultValue(u32).?;
};

const Icon = enum { add, copy, delete, reset, import };

const NamePrompt = enum { create, copy, restore };

const Confirm = enum { delete, reset };

var g_allocator: std.mem.Allocator = undefined;
/// The profile picked in the dropdown, waiting on Make It Live / Just Edit. Owned; freed when the prompt closes.
var g_switch_target: ?[]u8 = null;
var g_switch_open: bool = false;
var g_name_prompt: ?NamePrompt = null;
var g_name_open: bool = false;
/// The name being typed. Owned; freed in deinit.
var g_name_text: std.ArrayList(u8) = .empty;
var g_name_color: Color = undefined;
/// The backup a restore prompt is for, and its name to show. Owned; freed when another prompt opens or in deinit.
var g_restore_backup: ?[]u8 = null;
var g_restore_label: ?[]u8 = null;
var g_confirm: ?Confirm = null;
var g_confirm_open: bool = false;

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// Once the window has closed.
pub fn deinit() void {
    clearSwitchTarget();
    g_name_text.deinit(g_allocator);
    g_name_text = .empty;
    clearRestore();
    g_name_prompt = null;
    g_name_open = false;
    g_confirm = null;
    g_confirm_open = false;
}

/// The accent picked in the name prompt, previewed on the window until it closes.
pub fn previewAccent() ?u32 {
    if (!g_name_open) return null;
    return widgets.argbFromColor(g_name_color);
}

pub fn show(context: *ui.Frame) !void {
    if (profiles.takeCreated()) |created| openSwitchPrompt(created);

    const bar = Rect{ .key = .src(@src()), .style = &style.header };
    _ = try bar.open(context);

    const brand = Rect{ .key = .src(@src()), .style = &.{ .direction = .row, .@"align" = .center, .gap = 8 } };
    _ = try brand.open(context);
    if (images.g_app_mark.image(.src(@src()), &style.app_mark)) |mark| try context.e(mark);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "EVE-Maj Preview", .style = &style.app_name });
    try brand.close(context);

    try context.e(Rect{ .key = .src(@src()), .style = &.{ .width = .grow() } });
    try profileSelect(context);

    const editing = session.profile().ptr.profile_name;
    if (try iconButton(context, .add, false)) openNamePrompt(.create, "");
    if (try iconButton(context, .copy, false)) {
        var buf: [profile_files.MAX_NAME_LEN + COPY_SUFFIX.len]u8 = undefined;
        openNamePrompt(.copy, std.fmt.bufPrint(&buf, "{s}{s}", .{ profiles.displayName(editing), COPY_SUFFIX }) catch profiles.displayName(editing));
    }
    const is_default = std.mem.eql(u8, editing, config.DEFAULT_PROFILE);
    if (try iconButton(context, .delete, is_default)) openConfirm(.delete);
    if (try iconButton(context, .reset, false)) openConfirm(.reset);
    if (try iconButton(context, .import, false)) import_dialog.open();

    try bar.close(context);

    try switchPrompt(context);
    try namePrompt(context);
    try confirmPrompt(context);
}

fn profileSelect(context: *ui.Frame) !void {
    const names = profiles.list();
    const arena = context.arena();
    const labels = try arena.alloc([]const u8, names.len);
    const values = try arena.alloc(u32, names.len);
    const editing = session.profile().ptr.profile_name;
    var current: u32 = 0;
    for (names, labels, values, 0..) |name, *label, *value, index| {
        label.* = profiles.displayName(name);
        value.* = @intCast(index);
        if (std.mem.eql(u8, name, editing)) current = @intCast(index);
    }
    const key: ui.Key = .str("knots.header.profile");
    // Follows the edited profile while closed, since a prompt or a profile switch can change it.
    if (context.ui().state.get(.select_input, key.hash())) |state| {
        if (!state.open) state.selected = current;
    }
    const response = try context.interact(SelectInput(u32){
        .key = key,
        .labels = labels,
        .values = values,
        .initial_selected = current,
        .style = try widgets.fittedSelect(context, labels),
        .parts = .{ .popup = &style.select_popup },
    });
    const selected = response.selected orelse return;
    if (selected.value != current) openSwitchPrompt(g_allocator.dupe(u8, names[selected.value]) catch |err| {
        slog.err("Failed to switch profile: {}", .{err});
        return;
    });
}

/// Takes ownership of `name`.
fn openSwitchPrompt(name: []u8) void {
    clearSwitchTarget();
    g_switch_target = name;
    g_switch_open = true;
}

fn switchPrompt(context: *ui.Frame) !void {
    const target = g_switch_target orelse return;
    if (!g_switch_open) {
        clearSwitchTarget();
        return;
    }
    const dialog = Dialog{ .is_open = &g_switch_open, .key = .src(@src()), .style = &style.modal };
    _ = try dialog.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "Switch Profile?", .style = &style.heading });
    try context.e(Text{
        .selectable = false,
        .key = .src(@src()),
        .content = try std.fmt.allocPrint(context.arena(), "Make '{s}' the running profile, or just edit it?", .{profiles.displayName(target)}),
        .style = &style.modal_text,
    });
    const hint = if (session.isDirty())
        "Making it live reloads thumbnails, hotkeys, and chatlog monitoring now. Either way, your unsaved changes are dropped."
    else
        "Making it live reloads thumbnails, hotkeys, and chatlog monitoring now. Editing alone leaves the running overlay untouched until you save or choose Make It Live.";
    try widgets.hintText(context, .src(@src()), hint);
    const actions = Rect{ .key = .src(@src()), .style = &style.modal_actions };
    _ = try actions.open(context);
    if (try modalButton(context, .src(@src()), "Cancel", &style.plain_button)) g_switch_open = false;
    if (try modalButton(context, .src(@src()), "Just Edit", &style.plain_button)) {
        profiles.request(.edit, target, null);
        g_switch_open = false;
    }
    if (try modalButton(context, .src(@src()), "Make It Live", &style.primary_button)) {
        profiles.request(.make_live, target, null);
        g_switch_open = false;
    }
    try actions.close(context);
    try dialog.close(context);
}

fn openNamePrompt(prompt: NamePrompt, initial: []const u8) void {
    g_name_text.clearRetainingCapacity();
    g_name_text.appendSlice(g_allocator, initial[0..@min(initial.len, profile_files.MAX_NAME_LEN)]) catch |err| {
        slog.err("Failed to open the profile name prompt: {}", .{err});
        return;
    };
    g_name_color = widgets.colorFromArgb(switch (prompt) {
        .create, .restore => DEFAULT_ACCENT,
        .copy => session.profile().ptr.accentColor,
    });
    g_name_prompt = prompt;
    g_name_open = true;
}

fn namePrompt(context: *ui.Frame) !void {
    const prompt = g_name_prompt orelse return;
    if (!g_name_open) {
        g_name_prompt = null;
        return;
    }
    const dialog = Dialog{ .is_open = &g_name_open, .key = .src(@src()), .style = &style.modal };
    _ = try dialog.open(context);
    try context.e(Text{
        .selectable = false,
        .key = .src(@src()),
        .content = switch (prompt) {
            .create => "Create New Profile",
            .copy => try std.fmt.allocPrint(context.arena(), "Copy '{s}'", .{profiles.displayName(session.profile().ptr.profile_name)}),
            .restore => try std.fmt.allocPrint(context.arena(), "Restore Backup: {s}", .{g_restore_label orelse ""}),
        },
        .style = &style.heading,
    });
    const row = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 8 } };
    _ = try row.open(context);
    try context.e(TextInput{ .key = .src(@src()), .buf = &g_name_text, .placeholder = "Profile name", .style = &style.text_input });
    _ = try context.interact(ColorPicker{ .key = .src(@src()), .value = &g_name_color, .style = &style.color_picker_swatch, .parts = .{ .swatch = &style.color_swatch_fill, .popup = &style.color_popup }, .show_hex = false, .show_alpha = false });
    try row.close(context);
    try widgets.hintText(context, .src(@src()), "Letters, digits, spaces, '-' and '_', up to 16 characters. The colour tints this window while the profile is edited.");
    const actions = Rect{ .key = .src(@src()), .style = &style.modal_actions };
    _ = try actions.open(context);
    if (try modalButton(context, .src(@src()), "Cancel", &style.plain_button)) g_name_open = false;
    if (try modalButton(context, .src(@src()), "OK", &style.primary_button)) submitName(prompt);
    try actions.close(context);
    try dialog.close(context);
}

fn submitName(prompt: NamePrompt) void {
    const typed = std.mem.trim(u8, g_name_text.items, " ");
    const file_name = config.profileFileName(g_allocator, typed) catch {
        status.show(.failure, "'{s}' isn't a valid profile name: use letters, digits, spaces, '-' and '_', up to 16 characters", .{typed});
        return;
    };
    defer g_allocator.free(file_name);
    const accent = widgets.argbFromColor(g_name_color);
    switch (prompt) {
        .create => profiles.request(.create, file_name, accent),
        .copy => profiles.request(.copy, file_name, accent),
        .restore => if (g_restore_backup) |backup| profiles.requestRestore(file_name, backup, accent),
    }
    g_name_open = false;
}

/// From the Import dialog: names the profile `backup` (a backup file name) is restored as, starting from `display_name`.
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
    openNamePrompt(.restore, display_name);
}

fn clearRestore() void {
    if (g_restore_backup) |backup| g_allocator.free(backup);
    g_restore_backup = null;
    if (g_restore_label) |label| g_allocator.free(label);
    g_restore_label = null;
}

fn openConfirm(confirm: Confirm) void {
    g_confirm = confirm;
    g_confirm_open = true;
}

fn confirmPrompt(context: *ui.Frame) !void {
    const confirm = g_confirm orelse return;
    if (!g_confirm_open) {
        g_confirm = null;
        return;
    }
    const name = session.profile().ptr.profile_name;
    const dialog = Dialog{ .is_open = &g_confirm_open, .key = .src(@src()), .style = &style.modal };
    _ = try dialog.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = switch (confirm) {
        .delete => "Delete Profile?",
        .reset => "Reset Profile?",
    }, .style = &style.heading });
    try context.e(Text{
        .selectable = false,
        .key = .src(@src()),
        .content = switch (confirm) {
            .delete => try std.fmt.allocPrint(context.arena(), "'{s}' is moved to a backup, which Import can restore.", .{profiles.displayName(name)}),
            .reset => try std.fmt.allocPrint(context.arena(), "Every setting in '{s}' goes back to its default. This can't be undone.", .{profiles.displayName(name)}),
        },
        .style = &style.modal_text,
    });
    const actions = Rect{ .key = .src(@src()), .style = &style.modal_actions };
    _ = try actions.open(context);
    if (try modalButton(context, .src(@src()), "Cancel", &style.plain_button)) g_confirm_open = false;
    if (try modalButton(context, .src(@src()), switch (confirm) {
        .delete => "Delete",
        .reset => "Reset",
    }, &style.danger_primary_button)) {
        profiles.request(switch (confirm) {
            .delete => .delete,
            .reset => .reset,
        }, name, null);
        g_confirm_open = false;
    }
    try actions.close(context);
    try dialog.close(context);
}

fn modalButton(context: *ui.Frame, key: ui.Key, label: []const u8, button_style: *const ui.Style) !bool {
    const clicked = (try context.interact(Button{ .key = key, .label = label, .style = button_style })).clicked;
    if (clicked) context.requestRedraw();
    return clicked;
}

fn clearSwitchTarget() void {
    if (g_switch_target) |name| g_allocator.free(name);
    g_switch_target = null;
}

/// Returns whether it was clicked.
fn iconButton(context: *ui.Frame, icon: Icon, disabled: bool) !bool {
    const button = Button{
        .key = ui.Key.str("knots.header.icon").indexed(@backingInt(icon)),
        .disabled = disabled,
        .style = if (disabled) &style.icon_button_disabled else switch (icon) {
            .add => &style.icon_button_add,
            .copy => &style.icon_button,
            .delete => &style.icon_button_danger,
            .reset => &style.icon_button_reset,
            .import => &style.icon_button_import,
        },
    };
    const response = try button.openResponse(context);
    const tint: Color = if (disabled)
        style.BORDER_STRONG
    else if (response.hovered) switch (icon) {
        .add => style.SUCCESS,
        .copy => style.TEXT,
        .delete => style.DESTRUCTIVE,
        .reset => style.PURPLE,
        .import => style.SKY,
    } else style.MUTED;
    const glyph_key = ui.Key.str("knots.header.icon.glyph").indexed(@backingInt(icon));
    const glyph: glyphs.Glyph = switch (icon) {
        .add => .add,
        .copy => .copy,
        .delete => .delete,
        .reset => .reset,
        .import => .import,
    };
    try context.e(Canvas{
        .key = glyph_key,
        .commands = try glyphs.commands(context.arena(), glyph, glyphs.ICON_SIZE, try glyphs.snapOffset(context, glyph_key), tint.value),
        .style = &.{ .width = .fixed(glyphs.ICON_SIZE), .height = .fixed(glyphs.ICON_SIZE) },
    });
    try button.close(context);
    return response.clicked and !disabled;
}
