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
    "Cascadia Code", "Cascadia Mono", "Consolas", "Courier New", "Lucida Console", "Monaco",          "Menlo",  "Arial",         "Verdana",
    "Tahoma",        "Trebuchet MS",  "Segoe UI", "Calibri",     "Georgia",        "Times New Roman", "Impact", "Comic Sans MS",
};

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
    /// A 0-100 value with a % after it.
    percent,
    /// A 0-255 alpha shown as 0-100%.
    percent_of_255,
};

/// What an optional number box was left holding when it lost focus.
pub const Typed = union(enum) { unchanged, cleared, value: f64 };

var g_allocator: std.mem.Allocator = undefined;
/// Keyed by the box's element id. Owned; freed in reset.
var g_text_states: std.AutoHashMapUnmanaged(u64, TextState) = .empty;

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

/// In aligned rows the unit sits inside the box.
pub fn number(context: *ui.Frame, ref: anytype, comptime field: []const u8, label: []const u8, options: NumberOptions) !void {
    const key = fieldKey(ref, field);
    const row = try widgets.openBinding(context, key, label);
    if (options.unit) |unit| {
        if (widgets.isAligned()) {
            try unitNumberBox(context, ref, field, unit, options);
        } else {
            try numberBox(context, ref, field, options);
            try context.e(Text{ .selectable = false, .key = key.indexed(3), .content = unit, .style = &style.muted_text });
        }
    } else {
        try numberBox(context, ref, field, options);
    }
    try row.close(context);
}

/// Just the box, for a row holding several, e.g. width × height. An optional setting is unset by clearing the box.
pub fn numberBox(context: *ui.Frame, ref: anytype, comptime field: []const u8, options: NumberOptions) !void {
    try styledNumberBox(context, ref, field, options, &style.number_input);
}

/// Just the box, with `unit` inside it, e.g. a border's width in "px".
pub fn unitNumberBox(context: *ui.Frame, ref: anytype, comptime field: []const u8, unit: []const u8, options: NumberOptions) !void {
    const key = fieldKey(ref, field);
    const box = try openUnitField(context, key.indexed(6), key.indexed(2));
    try styledNumberBox(context, ref, field, options, &style.unit_field_input);
    try context.e(Text{ .selectable = false, .key = key.indexed(3), .content = unit, .style = &style.muted_text });
    try box.close(context);
}

fn styledNumberBox(context: *ui.Frame, ref: anytype, comptime field: []const u8, options: NumberOptions, box_style: *const ui.Style) !void {
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
    try context.e(TextInput{ .key = key, .buf = &state.text, .style = box_style, .placeholder = options.placeholder });
}

/// A number input and its unit in one box, outlined while `input_key` has focus; the caller adds both and closes it.
fn openUnitField(context: *ui.Frame, key: ui.Key, input_key: ui.Key) !ui.component.Rect {
    const is_focused = context.ui().focused(input_key.hash());
    const field_rect = ui.component.Rect{ .key = key, .style = if (is_focused) &style.unit_field_focused else &style.unit_field };
    _ = try field_rect.open(context);
    return field_rect;
}

/// A unit box for a value that isn't one setting, e.g. a slider's "85 %"; returns what was typed on blur, using `key` indices 4 to 6.
fn unitValueBox(context: *ui.Frame, key: ui.Key, value: f64, unit: []const u8) !?f64 {
    const box_key = key.indexed(4);
    const field_rect = try openUnitField(context, key.indexed(6), box_key);
    const typed = try valueBox(context, box_key, value, &style.unit_field_input);
    if (unit.len > 0) try context.e(Text{ .selectable = false, .key = key.indexed(5), .content = unit, .style = &style.muted_text });
    try field_rect.close(context);
    return typed;
}

/// An optional text field is unset when left empty.
pub fn text(context: *ui.Frame, ref: anytype, comptime field: []const u8, label: []const u8, placeholder: []const u8) !void {
    const row = try widgets.openBinding(context, fieldKey(ref, field), label);
    try styledTextBox(context, ref, field, placeholder, if (widgets.isAligned()) &style.text_input_aligned else &style.text_input);
    try row.close(context);
}

/// Just the box, for a row with more in it, e.g. a Browse button.
pub fn textBox(context: *ui.Frame, ref: anytype, comptime field: []const u8, placeholder: []const u8) !void {
    try styledTextBox(context, ref, field, placeholder, &style.text_input);
}

/// textBox with its own box style, e.g. a fixed width in an aligned row.
pub fn styledTextBox(context: *ui.Frame, ref: anytype, comptime field: []const u8, placeholder: []const u8, box_style: *const ui.Style) !void {
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
    try context.e(TextInput{ .key = box_key, .buf = &state.text, .style = box_style, .placeholder = placeholder });
}

/// A text box for a string that isn't one setting, e.g. an entry of a list of names; returns what was typed once the box loses focus.
pub fn stringBox(context: *ui.Frame, key: ui.Key, current: []const u8, placeholder: []const u8, box_style: *const ui.Style) !?[]const u8 {
    const state = try textState(key);
    var committed: ?[]const u8 = null;
    if (context.ui().focused(key.hash())) {
        state.editing = true;
    } else {
        if (state.editing) {
            state.editing = false;
            if (!std.mem.eql(u8, state.text.items, current)) committed = try context.arena().dupe(u8, state.text.items);
        }
        try syncText(state, committed orelse current);
    }
    try context.e(TextInput{ .key = key, .buf = &state.text, .style = box_style, .placeholder = placeholder });
    return committed;
}

/// A number box for an optional value that isn't one setting, e.g. half of a character's size override; empty is unset.
pub fn optionalValueBox(context: *ui.Frame, key: ui.Key, value: ?f64, placeholder: []const u8, box_style: *const ui.Style) !Typed {
    const state = try textState(key);
    var typed: Typed = .unchanged;
    if (context.ui().focused(key.hash())) {
        state.editing = true;
    } else {
        if (state.editing) {
            state.editing = false;
            const trimmed = std.mem.trim(u8, state.text.items, " ");
            if (trimmed.len == 0) {
                typed = .cleared;
            } else if (std.fmt.parseFloat(f64, trimmed)) |parsed| {
                typed = .{ .value = parsed };
            } else |_| {}
        }
        const shown: ?f64 = switch (typed) {
            .unchanged => value,
            .cleared => null,
            .value => |parsed| parsed,
        };
        if (shown) |figure| {
            var buf: [32]u8 = undefined;
            try syncText(state, std.fmt.bufPrint(&buf, "{d}", .{figure}) catch unreachable);
        } else {
            try syncText(state, "");
        }
    }
    try context.e(TextInput{ .key = key, .buf = &state.text, .style = box_style, .placeholder = placeholder });
    return typed;
}

/// A number box for a value that isn't one setting, e.g. an ore's price override; returns what was typed once the box loses focus.
pub fn valueBox(context: *ui.Frame, key: ui.Key, value: f64, box_style: *const ui.Style) !?f64 {
    const state = try textState(key);
    var committed: ?f64 = null;
    if (context.ui().focused(key.hash())) {
        state.editing = true;
    } else {
        if (state.editing) {
            state.editing = false;
            // Not a number: the sync below puts the value back.
            committed = std.fmt.parseFloat(f64, std.mem.trim(u8, state.text.items, " ")) catch null;
        }
        var buf: [32]u8 = undefined;
        try syncText(state, std.fmt.bufPrint(&buf, "{d}", .{committed orelse value}) catch unreachable);
    }
    try context.e(TextInput{ .key = key, .buf = &state.text, .style = box_style });
    return committed;
}

/// A string list typed as comma-separated text; empty entries are dropped.
pub fn csvBox(context: *ui.Frame, ref: anytype, comptime field: []const u8, placeholder: []const u8) !void {
    const box_key = fieldKey(ref, field).indexed(2);
    const state = try textState(box_key);
    const arena = context.arena();
    if (context.ui().focused(box_key.hash())) {
        state.editing = true;
    } else {
        if (state.editing) {
            state.editing = false;
            var values: std.ArrayList([]const u8) = .empty;
            var parts = std.mem.splitScalar(u8, state.text.items, ',');
            while (parts.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " \t");
                if (trimmed.len > 0) try values.append(arena, trimmed);
            }
            ref.setStrings(field, values.items);
        }
        const items: []const []const u8 = ref.get(field).items;
        try syncText(state, try std.mem.join(arena, ", ", items));
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
    if (try sliderControls(context, key, @floatCast(numberTo(F, ref.get(field))), min, max, options.step, options.display)) |value| {
        ref.set(field, numberFrom(F, value));
    }
    try row.close(context);
}

/// A slider and its value in `display`'s units, a box to type into when aligned, in a row the caller opened with `key`; returns the new value if either changed it.
fn sliderControls(context: *ui.Frame, key: ui.Key, value: f32, min: f32, max: f32, step: f32, display: Display) !?f64 {
    var slider_value = value;
    var changed: ?f64 = null;
    if (try widgets.slider(context, key.indexed(2), &slider_value, min, max, step)) changed = @round(slider_value);
    const shown: f64 = switch (display) {
        .value, .percent => @round(slider_value),
        .percent_of_255 => @round(slider_value / 255.0 * 100.0),
    };
    const unit = switch (display) {
        .value => "",
        .percent, .percent_of_255 => "%",
    };
    if (!widgets.isAligned()) {
        try widgets.valueText(context, key.indexed(3), try std.fmt.allocPrint(context.arena(), "{d:.0}{s}", .{ shown, unit }));
        return changed;
    }
    const value_typed = try unitValueBox(context, key, shown, unit) orelse return changed;
    const raw: f64 = switch (display) {
        .value, .percent => value_typed,
        .percent_of_255 => value_typed / 100.0 * 255.0,
    };
    return std.math.clamp(raw, min, max);
}

/// An ARGB `u32` setting.
pub fn color(context: *ui.Frame, ref: anytype, comptime field: []const u8, label: []const u8) !void {
    const row = try widgets.openBinding(context, fieldKey(ref, field), label);
    try colorBox(context, ref, field);
    try row.close(context);
}

/// Just the picker, whose Reset restores the field's default; aligned, it's a bare swatch that saves RGB only, so a colour with alpha comes out opaque.
pub fn colorBox(context: *ui.Frame, ref: anytype, comptime field: []const u8) !void {
    const is_aligned = widgets.isAligned();
    const opaque_mask: u32 = if (is_aligned) 0xFF000000 else 0;
    var value = widgets.colorFromArgb(ref.get(field) | opaque_mask);
    var is_reset = false;
    if ((try context.interact(ColorPicker{
        .key = fieldKey(ref, field).indexed(2),
        .value = &value,
        .style = if (is_aligned) &style.color_picker_swatch else &style.color_picker,
        .parts = widgets.colorParts(is_aligned),
        .show_hex = !is_aligned,
        .show_alpha = !is_aligned,
        .reset = if (defaultOf(@TypeOf(ref), field) != null) &is_reset else null,
    })).changed) ref.set(field, widgets.argbFromColor(value) | opaque_mask);
    if (is_reset) if (defaultOf(@TypeOf(ref), field)) |default| ref.set(field, default);
}

/// An optional colour setting, shown as `fallback` while unset; resetting it clears it.
pub fn optionalColor(context: *ui.Frame, ref: anytype, comptime field: []const u8, label: []const u8, fallback: u32) !void {
    const change = try widgets.optionalColor(context, fieldKey(ref, field), label, ref.get(field), fallback) orelse return;
    ref.set(field, switch (change) {
        .cleared => null,
        .set => |argb| argb,
    });
}

/// The RGB of an ARGB setting, keeping its alpha, which alphaSlider sets; its Reset restores the default's RGB.
pub fn rgb(context: *ui.Frame, ref: anytype, comptime field: []const u8, label: []const u8) !void {
    const row = try widgets.openBinding(context, fieldKey(ref, field), label);
    const argb: u32 = ref.get(field);
    const is_aligned = widgets.isAligned();
    var value = widgets.colorFromArgb(argb | 0xFF000000);
    var is_reset = false;
    if ((try context.interact(ColorPicker{
        .key = fieldKey(ref, field).indexed(2),
        .value = &value,
        .style = if (is_aligned) &style.color_picker_swatch else &style.color_picker,
        .parts = widgets.colorParts(is_aligned),
        .show_hex = !is_aligned,
        .show_alpha = false,
        .reset = if (defaultOf(@TypeOf(ref), field) != null) &is_reset else null,
    })).changed) ref.set(field, (widgets.argbFromColor(value) & 0x00FFFFFF) | (argb & 0xFF000000));
    if (is_reset) if (defaultOf(@TypeOf(ref), field)) |default| ref.set(field, (default & 0x00FFFFFF) | (argb & 0xFF000000));
    try row.close(context);
}

/// The alpha of an ARGB setting as a slider row with its % box, keeping its RGB.
pub fn alphaSlider(context: *ui.Frame, ref: anytype, comptime field: []const u8, label: []const u8) !void {
    const argb: u32 = ref.get(field);
    const key = fieldKey(ref, field).indexed(11);
    const row = try widgets.openBinding(context, key, label);
    if (try percentSlider(context, key, @intCast(argb >> 24), 0, 255)) |alpha| {
        ref.set(field, (argb & 0x00FFFFFF) | (@as(u32, alpha) << 24));
    }
    try row.close(context);
}

/// A 0-255 value's slider and %, in a row the caller opened with `key`; returns the new value if either changed it.
pub fn percentSlider(context: *ui.Frame, key: ui.Key, value: u8, min: f32, max: f32) !?u8 {
    const changed = try sliderControls(context, key, @floatFromInt(value), min, max, 1, .percent_of_255) orelse return null;
    return @intFromFloat(@round(changed));
}

/// A font name from FONT_OPTIONS, plus the current one if it was set by hand; the row holds the font's size and weight beside it.
pub fn fontBox(context: *ui.Frame, ref: anytype, comptime field: []const u8) !void {
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
    const box_key = fieldKey(ref, field).indexed(2);
    if (context.ui().state.get(.select_input, box_key.hash())) |state| {
        if (!state.open) state.selected = selected_index;
    }
    const response = try context.interact(SelectInput(u32){
        .key = box_key,
        .labels = names,
        .values = values,
        .initial_selected = selected_index,
        .style = try widgets.fittedSelect(context, names),
        .parts = .{ .popup = &style.select_popup },
    });
    if (response.selected) |selected| {
        if (selected.value != selected_index) ref.set(field, names[selected.value]);
    }
}

/// An enum setting, offered by its tags spelled as words ("TopLeft" reads "Top Left").
pub fn choice(context: *ui.Frame, ref: anytype, comptime field: []const u8, label: []const u8) !void {
    const row = try widgets.openBinding(context, fieldKey(ref, field), label);
    try dropdown(context, ref, field, true);
    try row.close(context);
}

/// An enum setting with few options, as a row of buttons; `option_labels` names each tag in declaration order.
pub fn segmented(context: *ui.Frame, ref: anytype, comptime field: []const u8, label: []const u8, comptime option_labels: []const []const u8) !void {
    const F = FieldOf(@TypeOf(ref), field);
    const values = comptime std.enums.values(F);
    comptime std.debug.assert(option_labels.len == values.len);
    const key = fieldKey(ref, field);
    const row = try widgets.openBinding(context, key, label);
    const current = std.mem.indexOfScalar(F, values, ref.get(field)) orelse 0;
    if (try widgets.segmented(context, key.indexed(2), option_labels, current)) |picked| ref.set(field, values[picked]);
    try row.close(context);
}

/// Just the dropdown, for a row or grid of several.
pub fn choiceBox(context: *ui.Frame, ref: anytype, comptime field: []const u8) !void {
    try dropdown(context, ref, field, false);
}

/// `is_row_only` widens it to widgets.rowSelect's floor.
fn dropdown(context: *ui.Frame, ref: anytype, comptime field: []const u8, is_row_only: bool) !void {
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
        .style = if (is_row_only) try widgets.rowSelect(context, &option_labels) else try widgets.fittedSelect(context, &option_labels),
        .parts = .{ .popup = &style.select_popup },
    });
    if (response.selected) |selected| ref.set(field, selected.value);
}

fn FieldOf(comptime Ref: type, comptime field: []const u8) type {
    return @FieldType(@typeInfo(@FieldType(Ref, "ptr")).pointer.child, field);
}

/// What a text box keyed `key` holds right now, typed but not yet applied included.
pub fn typedText(key: ui.Key) []const u8 {
    const state = g_text_states.getPtr(key.hash()) orelse return "";
    return state.text.items;
}

/// The key a field's text or number box is drawn with, e.g. to read its caret.
pub fn boxKey(ref: anytype, comptime field: []const u8) ui.Key {
    return fieldKey(ref, field).indexed(2);
}

/// Unique per setting, and per item when the setting is in a list.
/// `field`'s default in the settings struct `Ref` edits; null when it has none, so its swatch offers no Reset.
fn defaultOf(comptime Ref: type, comptime field: []const u8) ?@FieldType(@typeInfo(@FieldType(Ref, "ptr")).pointer.child, field) {
    const T = @typeInfo(@FieldType(Ref, "ptr")).pointer.child;
    return comptime std.meta.fieldInfo(T, @field(std.meta.FieldEnum(T), field)).attrs.defaultValue(@FieldType(T, field));
}

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
