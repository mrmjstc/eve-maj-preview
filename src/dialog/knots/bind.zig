//! Form controls bound to one setting each: they read it every frame and write it through `Ref.set`; main thread only.
const std = @import("std");
const ui = @import("ui");
const style = @import("style.zig");
const widgets = @import("widgets.zig");
const labels = @import("labels.zig");

const Text = ui.component.Text;
const TextInput = ui.component.TextInput;
const ColorPicker = ui.component.ColorPicker;
const SelectInput = ui.component.SelectInput;

/// A text or number box's own copy of its text, which follows the setting until the user starts typing.
const TextState = struct {
    /// Owned; freed in reset.
    text: std.ArrayList(u8) = .empty,
    /// Set while the box has focus, so leaving it applies what was typed.
    editing: bool = false,
};

/// The font dropdowns offer these; a font set by hand in the profile is offered too.
const FONT_OPTIONS = [_][]const u8{
    "Cascadia Code", "Cascadia Mono", "Consolas", "Courier New", "Lucida Console", "Monaco", "Menlo", "Arial", "Verdana",
    "Tahoma", "Trebuchet MS", "Segoe UI", "Calibri", "Georgia", "Times New Roman", "Impact", "Comic Sans MS",
};

var g_allocator: std.mem.Allocator = undefined;
/// Keyed by the box's element id. Owned; freed in reset.
var g_text_states: std.AutoHashMapUnmanaged(u64, TextState) = .empty;

pub const NumberOptions = struct {
    /// Shown after the box, e.g. "ms".
    unit: ?[]const u8 = null,
    /// The setting is in milliseconds but shown, and typed, in seconds.
    ms_as_seconds: bool = false,
    /// Shown in an empty box: an optional setting that's unset, e.g. "auto".
    placeholder: []const u8 = "",
};

pub const SliderOptions = struct {
    /// Default to the field's `ranges` entry.
    min: ?f32 = null,
    max: ?f32 = null,
    step: f32 = 1,
    display: Display = .value,
};

pub const Display = enum {
    value,
    /// A 0-255 alpha shown as 0-100%.
    percent_of_255,
};

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// Forgets every box's text; called once the window has closed.
pub fn reset() void {
    var it = g_text_states.valueIterator();
    while (it.next()) |state| state.text.deinit(g_allocator);
    g_text_states.deinit(g_allocator);
    g_text_states = .empty;
}

pub fn toggle(context: *ui.Frame, ref: anytype, comptime field: []const u8, label: []const u8) !void {
    var value: bool = ref.get(field);
    if (try widgets.checkbox(context, fieldKey(ref, field), label, &value)) ref.set(field, value);
}

pub fn number(context: *ui.Frame, ref: anytype, comptime field: []const u8, label: []const u8, options: NumberOptions) !void {
    const key = fieldKey(ref, field);
    const row = try widgets.openBinding(context, key, label);
    try numberBox(context, ref, field, options);
    if (options.unit) |unit| try context.e(Text{ .key = key.indexed(3), .content = unit, .style = &.{ .foreground = .{ .color = style.MUTED } } });
    try row.close(context);
}

/// Just the box, for a row holding several, e.g. width × height. An optional setting is unset by clearing the box.
pub fn numberBox(context: *ui.Frame, ref: anytype, comptime field: []const u8, options: NumberOptions) !void {
    const F = FieldOf(@TypeOf(ref), field);
    const is_optional = @typeInfo(F) == .optional;
    const N = if (is_optional) @typeInfo(F).optional.child else F;
    const scale: f64 = if (options.ms_as_seconds) 1000 else 1;
    const key = fieldKey(ref, field).indexed(2);
    const state = try textState(key);
    if (context.ui().focused(key.hash())) {
        state.editing = true;
    } else {
        if (state.editing) {
            state.editing = false;
            const trimmed = std.mem.trim(u8, state.text.items, " ");
            if (comptime is_optional) {
                if (trimmed.len == 0) ref.set(field, null);
            }
            // Not a number: the sync below puts the setting back.
            if (std.fmt.parseFloat(f64, trimmed)) |typed| ref.set(field, numberFrom(N, typed * scale)) else |_| {}
        }
        const current: ?N = ref.get(field);
        if (current) |value| {
            var buf: [32]u8 = undefined;
            try syncText(state, std.fmt.bufPrint(&buf, "{d}", .{numberTo(N, value) / scale}) catch unreachable);
        } else {
            try syncText(state, "");
        }
    }
    try context.e(TextInput{ .key = key, .buf = &state.text, .style = &style.number_input, .placeholder = options.placeholder });
}

/// An optional text field is unset when left empty.
pub fn text(context: *ui.Frame, ref: anytype, comptime field: []const u8, label: []const u8, placeholder: []const u8) !void {
    const row = try widgets.openBinding(context, fieldKey(ref, field), label);
    try textBox(context, ref, field, placeholder);
    try row.close(context);
}

/// Just the box, for a row with more in it, e.g. a Browse button.
pub fn textBox(context: *ui.Frame, ref: anytype, comptime field: []const u8, placeholder: []const u8) !void {
    const F = FieldOf(@TypeOf(ref), field);
    const box_key = fieldKey(ref, field).indexed(2);
    const state = try textState(box_key);
    if (context.ui().focused(box_key.hash())) {
        state.editing = true;
    } else {
        if (state.editing) {
            state.editing = false;
            if (F == ?[]const u8) {
                ref.set(field, if (state.text.items.len == 0) null else state.text.items);
            } else {
                ref.set(field, state.text.items);
            }
        }
        const current: []const u8 = if (F == ?[]const u8) ref.get(field) orelse "" else ref.get(field);
        try syncText(state, current);
    }
    try context.e(TextInput{ .key = box_key, .buf = &state.text, .style = &style.text_input, .placeholder = placeholder });
}

pub fn slider(context: *ui.Frame, ref: anytype, comptime field: []const u8, label: []const u8, options: SliderOptions) !void {
    const Ref = @TypeOf(ref);
    const F = FieldOf(Ref, field);
    const bounds = comptime rangeOf(@typeInfo(@FieldType(Ref, "ptr")).pointer.child, field);
    const min = options.min orelse if (bounds) |b| b[0] else 0;
    const max = options.max orelse if (bounds) |b| b[1] else 100;
    const key = fieldKey(ref, field);
    const row = try widgets.openBinding(context, key, label);
    var value: f32 = @floatCast(numberTo(F, ref.get(field)));
    if (try widgets.slider(context, key.indexed(2), &value, min, max, options.step)) {
        ref.set(field, numberFrom(F, @round(value)));
    }
    const shown = switch (options.display) {
        .value => try std.fmt.allocPrint(context.arena(), "{d:.0}", .{value}),
        .percent_of_255 => try std.fmt.allocPrint(context.arena(), "{d:.0}%", .{value / 255.0 * 100.0}),
    };
    try widgets.valueText(context, key.indexed(3), shown);
    try row.close(context);
}

/// An ARGB `u32` setting.
pub fn color(context: *ui.Frame, ref: anytype, comptime field: []const u8, label: []const u8) !void {
    const row = try widgets.openBinding(context, fieldKey(ref, field), label);
    try colorBox(context, ref, field);
    try row.close(context);
}

/// Just the picker, for a row or grid of several.
pub fn colorBox(context: *ui.Frame, ref: anytype, comptime field: []const u8) !void {
    var value = widgets.colorFromArgb(ref.get(field));
    if ((try context.interact(ColorPicker{
        .key = fieldKey(ref, field).indexed(2),
        .value = &value,
        .style = &style.color_picker,
        .parts = .{ .swatch = &style.color_swatch, .popup = &style.color_popup },
    })).changed) ref.set(field, widgets.argbFromColor(value));
}

/// An ARGB setting split like the page's: a colour for the RGB, and a percentage slider for the alpha.
pub fn colorAndOpacity(context: *ui.Frame, ref: anytype, comptime field: []const u8, color_label: []const u8, opacity_label: []const u8) !void {
    const argb: u32 = ref.get(field);
    const key = fieldKey(ref, field);
    const color_row = try widgets.openBinding(context, key, color_label);
    var value = widgets.colorFromArgb(argb | 0xFF000000);
    if ((try context.interact(ColorPicker{
        .key = key.indexed(2),
        .value = &value,
        .style = &style.color_picker,
        .parts = .{ .swatch = &style.color_swatch, .popup = &style.color_popup },
    })).changed) ref.set(field, (widgets.argbFromColor(value) & 0x00FFFFFF) | (argb & 0xFF000000));
    try color_row.close(context);

    const opacity_key = key.indexed(10);
    const opacity_row = try widgets.openBinding(context, opacity_key, opacity_label);
    var alpha: f32 = @floatFromInt(argb >> 24);
    if (try widgets.slider(context, opacity_key.indexed(2), &alpha, 0, 255, 1)) {
        ref.set(field, (argb & 0x00FFFFFF) | (@as(u32, @intFromFloat(@round(alpha))) << 24));
    }
    try widgets.valueText(context, opacity_key.indexed(3), try std.fmt.allocPrint(context.arena(), "{d:.0}%", .{alpha / 255.0 * 100.0}));
    try opacity_row.close(context);
}

/// A font name from FONT_OPTIONS, plus the current one if it was set by hand.
pub fn fontName(context: *ui.Frame, ref: anytype, comptime field: []const u8, label: []const u8) !void {
    const current: []const u8 = ref.get(field);
    const arena = context.arena();
    const is_listed = for (FONT_OPTIONS) |name| {
        if (std.mem.eql(u8, name, current)) break true;
    } else false;
    const names: []const []const u8 = if (is_listed) &FONT_OPTIONS else try std.mem.concat(arena, []const u8, &.{ &.{current}, &FONT_OPTIONS });
    const values = try arena.alloc(u32, names.len);
    var selected_index: u32 = 0;
    for (names, values, 0..) |name, *value, index| {
        value.* = @intCast(index);
        if (std.mem.eql(u8, name, current)) selected_index = @intCast(index);
    }
    const key = fieldKey(ref, field);
    const row = try widgets.openBinding(context, key, label);
    const box_key = key.indexed(2);
    if (context.ui().state.get(.select_input, box_key.hash())) |state| {
        if (!state.open) state.selected = selected_index;
    }
    const response = try context.interact(SelectInput(u32){
        .key = box_key,
        .labels = names,
        .values = values,
        .initial_selected = selected_index,
        .style = &style.select,
        .parts = .{ .popup = &style.select_popup },
    });
    if (response.selected) |selected| {
        if (selected.value != selected_index) ref.set(field, names[selected.value]);
    }
    try row.close(context);
}

/// An enum setting, offered by its tags spelled as words ("TopLeft" reads "Top Left").
pub fn choice(context: *ui.Frame, ref: anytype, comptime field: []const u8, label: []const u8) !void {
    try choiceStyled(context, ref, field, label, &style.select);
}

/// For options too long for the standard dropdown.
pub fn choiceStyled(context: *ui.Frame, ref: anytype, comptime field: []const u8, label: []const u8, box_style: *const ui.Style) !void {
    const row = try widgets.openBinding(context, fieldKey(ref, field), label);
    try choiceBox(context, ref, field, box_style);
    try row.close(context);
}

/// Just the dropdown, for a row or grid of several.
pub fn choiceBox(context: *ui.Frame, ref: anytype, comptime field: []const u8, box_style: *const ui.Style) !void {
    const F = FieldOf(@TypeOf(ref), field);
    const values = comptime std.enums.values(F);
    const option_labels = comptime labels.enumLabels(F);
    const box_key = fieldKey(ref, field).indexed(2);
    const current: u32 = @intCast(std.mem.indexOfScalar(F, values, ref.get(field)) orelse 0);
    // The dropdown keeps its own selection; while closed it follows the setting, which may have changed elsewhere.
    if (context.ui().state.get(.select_input, box_key.hash())) |state| {
        if (!state.open) state.selected = current;
    }
    const response = try context.interact(SelectInput(F){
        .key = box_key,
        .labels = &option_labels,
        .values = values,
        .initial_selected = current,
        .style = box_style,
        .parts = .{ .popup = &style.select_popup },
    });
    if (response.selected) |selected| ref.set(field, selected.value);
}

fn FieldOf(comptime Ref: type, comptime field: []const u8) type {
    return @FieldType(@typeInfo(@FieldType(Ref, "ptr")).pointer.child, field);
}

/// Unique per setting, and per item when the setting is in a list.
fn fieldKey(ref: anytype, comptime field: []const u8) ui.Key {
    const T = @typeInfo(@FieldType(@TypeOf(ref), "ptr")).pointer.child;
    return ui.Key.str("knots.bind:" ++ @typeName(T) ++ "." ++ field).indexed(ref.index);
}

fn textState(key: ui.Key) !*TextState {
    const gop = try g_text_states.getOrPut(g_allocator, key.hash());
    if (!gop.found_existing) gop.value_ptr.* = .{};
    return gop.value_ptr;
}

fn syncText(state: *TextState, current: []const u8) !void {
    if (std.mem.eql(u8, state.text.items, current)) return;
    state.text.clearRetainingCapacity();
    try state.text.appendSlice(g_allocator, current);
}

/// A field's `ranges` entry, as floats.
pub fn rangeOf(comptime T: type, comptime field: []const u8) ?[2]f32 {
    if (!@hasDecl(T, "ranges") or !@hasField(@TypeOf(T.ranges), field)) return null;
    const bounds = @field(T.ranges, field);
    return .{ @as(f32, bounds[0]), @as(f32, bounds[1]) };
}

fn numberTo(comptime F: type, value: F) f64 {
    return switch (@typeInfo(F)) {
        .int => @floatFromInt(value),
        .float => @floatCast(value),
        else => @compileError("not a number setting: " ++ @typeName(F)),
    };
}

/// Saturates at F's bounds; the document's validate clamps to the setting's own range.
fn numberFrom(comptime F: type, value: f64) F {
    return switch (@typeInfo(F)) {
        .int => std.math.lossyCast(F, @round(value)),
        .float => @floatCast(value),
        else => @compileError("not a number setting: " ++ @typeName(F)),
    };
}
