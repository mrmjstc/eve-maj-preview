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
const DrawCmd = Canvas.DrawCmd;
const slog = log.scoped("dialog_knots");

const ICON_SIZE = 16;
const COPY_SUFFIX = " - Copy";
const DEFAULT_ACCENT = blk: {
    const index = std.meta.fieldIndex(config.Config, "accentColor").?;
    break :blk @typeInfo(config.Config).@"struct".field_attrs[index].defaultValue(u32).?;
};

const Icon = enum { add, copy, delete, reset, import };

const NamePrompt = enum { create, copy };

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
    try context.e(Text{ .key = .src(@src()), .content = "EVE-Maj Preview", .style = &style.app_name });
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
    if (try iconButton(context, .import, false)) status.show(.info, "Importing isn't in this window yet; use the WebView2 configuration window", .{});

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
        .style = &style.profile_select,
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
    try context.e(Text{ .key = .src(@src()), .content = "Switch Profile?", .style = &style.heading });
    try context.e(Text{
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
        .create => DEFAULT_ACCENT,
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
        .key = .src(@src()),
        .content = switch (prompt) {
            .create => "Create New Profile",
            .copy => try std.fmt.allocPrint(context.arena(), "Copy '{s}'", .{profiles.displayName(session.profile().ptr.profile_name)}),
        },
        .style = &style.heading,
    });
    const row = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 8 } };
    _ = try row.open(context);
    try context.e(TextInput{ .key = .src(@src()), .buf = &g_name_text, .placeholder = "Profile name", .style = &style.text_input });
    _ = try context.interact(ColorPicker{ .key = .src(@src()), .value = &g_name_color, .style = &style.color_picker, .parts = .{ .swatch = &style.color_swatch, .popup = &style.color_popup } });
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
    profiles.request(switch (prompt) {
        .create => .create,
        .copy => .copy,
    }, file_name, widgets.argbFromColor(g_name_color));
    g_name_open = false;
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
    try context.e(Text{ .key = .src(@src()), .content = switch (confirm) {
        .delete => "Delete Profile?",
        .reset => "Reset Profile?",
    }, .style = &style.heading });
    try context.e(Text{
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
    }, &style.danger_button)) {
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
        .key = ui.Key.str("knots.header.icon").indexed(@intFromEnum(icon)),
        .disabled = disabled,
        .style = if (disabled) &style.icon_button_disabled else &style.icon_button,
    };
    const response = try button.openResponse(context);
    const tint: Color = if (disabled)
        style.BORDER_STRONG
    else if (response.hovered)
        (if (icon == .delete) style.DESTRUCTIVE else style.TEXT)
    else
        style.MUTED;
    try context.e(Canvas{
        .key = ui.Key.str("knots.header.icon.glyph").indexed(@intFromEnum(icon)),
        .commands = try iconCommands(context.arena(), icon, tint.value),
        .style = &.{ .width = .fixed(ICON_SIZE), .height = .fixed(ICON_SIZE) },
    });
    try button.close(context);
    return response.clicked and !disabled;
}

/// Cascadia Code has none of the page's ⧉ ↺ ⇩ glyphs, and knots can't fall back to another font, so the icons are drawn.
fn iconCommands(arena: std.mem.Allocator, icon: Icon, color: [4]f32) ![]const DrawCmd {
    const thickness = 1.6;
    return switch (icon) {
        .add => try arena.dupe(DrawCmd, &.{
            .{ .line = .{ .from = .{ 8, 3 }, .to = .{ 8, 13 }, .color = color, .thickness = thickness } },
            .{ .line = .{ .from = .{ 3, 8 }, .to = .{ 13, 8 }, .color = color, .thickness = thickness } },
        }),
        .copy => try arena.dupe(DrawCmd, &.{
            .{ .stroke_rect = .{ .x = 6, .y = 2, .w = 8, .h = 8, .color = color, .thickness = 1.4 } },
            .{ .fill_rect = .{ .x = 2, .y = 6, .w = 8, .h = 8, .color = style.SURFACE.value } },
            .{ .stroke_rect = .{ .x = 2, .y = 6, .w = 8, .h = 8, .color = color, .thickness = 1.4 } },
        }),
        .delete => try arena.dupe(DrawCmd, &.{
            .{ .line = .{ .from = .{ 4, 4 }, .to = .{ 12, 12 }, .color = color, .thickness = thickness } },
            .{ .line = .{ .from = .{ 12, 4 }, .to = .{ 4, 12 }, .color = color, .thickness = thickness } },
        }),
        .reset => try resetArrow(arena, color),
        .import => try arena.dupe(DrawCmd, &.{
            .{ .line = .{ .from = .{ 8, 2 }, .to = .{ 8, 9 }, .color = color, .thickness = thickness } },
            .{ .fill_triangle = .{ .points = .{ .{ 4.5, 8 }, .{ 11.5, 8 }, .{ 8, 12 } }, .color = color } },
            .{ .line = .{ .from = .{ 3, 14 }, .to = .{ 13, 14 }, .color = color, .thickness = thickness } },
        }),
    };
}

/// An open circle with an arrowhead at its start, like ↺.
fn resetArrow(arena: std.mem.Allocator, color: [4]f32) ![]const DrawCmd {
    const segments = 14;
    const center = [2]f32{ 8, 8.5 };
    const radius = 5.0;
    // From the top, round anticlockwise to just short of the top again, leaving a gap for the arrowhead.
    const start_angle = -std.math.pi / 2.0 + 0.7;
    const sweep = 2.0 * std.math.pi - 1.1;
    var commands: std.ArrayList(DrawCmd) = .empty;
    var previous = pointOn(center, radius, start_angle);
    for (1..segments + 1) |step| {
        const angle = start_angle + sweep * @as(f32, @floatFromInt(step)) / segments;
        const point = pointOn(center, radius, angle);
        try commands.append(arena, .{ .line = .{ .from = previous, .to = point, .color = color, .thickness = 1.5 } });
        previous = point;
    }
    const tip = pointOn(center, radius, start_angle);
    try commands.append(arena, .{ .fill_triangle = .{ .points = .{ .{ tip[0] - 4, tip[1] - 2.5 }, .{ tip[0] + 0.5, tip[1] - 3.5 }, .{ tip[0] - 1, tip[1] + 1.5 } }, .color = color } });
    return commands.items;
}

fn pointOn(center: [2]f32, radius: f32, angle: f32) [2]f32 {
    return .{ center[0] + radius * @cos(angle), center[1] + radius * @sin(angle) };
}
