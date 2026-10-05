//! The knots configuration window's layout pieces and low-level controls, styled like the WebView2 page; main thread only.
const std = @import("std");
const ui = @import("ui");
const style = @import("style.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const SliderInput = ui.component.SliderInput;
const Checkbox = ui.component.Checkbox;
const Button = ui.component.Button;
const Color = ui.Color;

/// Which settings file a section's settings are saved to, shown as a chip beside its heading.
pub const Scope = enum { none, profile, global };

/// A panel with its heading, the scope chip and the intro hint; the caller closes it.
pub fn openSection(context: *ui.Frame, comptime title: []const u8, comptime hint: []const u8, scope: Scope, section_style: *const ui.Style) !Rect {
    const section = Rect{ .key = .str("knots.section:" ++ title), .style = section_style };
    _ = try section.open(context);
    try context.e(.{
        Rect{ .key = .str("knots.heading:" ++ title), .style = &.{
            .width = .grow(),
            .direction = .row,
            .justify = .space_between,
            .@"align" = .center,
        } },
        .{
            Text{ .key = .str("knots.title:" ++ title), .content = title, .style = &style.heading },
            Text{ .key = .str("knots.scope:" ++ title), .content = switch (scope) {
                .none => "",
                .profile => "PROFILE",
                .global => "ALL PROFILES",
            }, .style = if (scope == .none) &.{} else &style.scope_chip },
        },
    });
    if (hint.len > 0) try context.e(Text{ .key = .str("knots.hint:" ++ title), .content = hint, .style = &style.hint });
    return section;
}

/// A label-then-controls row; the caller adds the controls and closes it.
pub fn openBinding(context: *ui.Frame, key: ui.Key, label: []const u8) !Rect {
    const row = Rect{ .key = key, .style = &.{
        .width = .grow(),
        .direction = .row,
        .@"align" = .center,
        .gap = 8,
    } };
    _ = try row.open(context);
    try context.e(Text{ .key = key.indexed(1), .content = label, .style = &style.label });
    return row;
}

pub fn hintText(context: *ui.Frame, key: ui.Key, content: []const u8) !void {
    try context.e(Text{ .key = key, .content = content, .style = &style.hint });
}

/// A row of sub-tabs; returns the one now selected.
pub fn subTabs(context: *ui.Frame, comptime Tab: type, selected: Tab, comptime labels: [std.enums.values(Tab).len][]const u8) !Tab {
    var result = selected;
    const bar = Rect{ .key = .str("knots.subtabs:" ++ @typeName(Tab)), .style = &style.sub_tabs };
    _ = try bar.open(context);
    inline for (comptime std.enums.values(Tab), labels) |tab, label| {
        const is_active = tab == selected;
        if ((try context.interact(Button{
            .key = .str("knots.subtab:" ++ @typeName(Tab) ++ "." ++ @tagName(tab)),
            .label = label,
            .style = if (is_active) &style.sub_tab_active else &style.sub_tab,
        })).clicked and !is_active) {
            result = tab;
            context.requestRedraw();
        }
    }
    try bar.close(context);
    return result;
}

/// A small row of buttons where one is on, for switching a view rather than a setting; returns the one now on.
pub fn segmented(context: *ui.Frame, comptime Option: type, selected: Option, comptime labels: [std.enums.values(Option).len][]const u8) !Option {
    var result = selected;
    const bar = Rect{ .key = .str("knots.segmented:" ++ @typeName(Option)), .style = &style.segmented };
    _ = try bar.open(context);
    inline for (comptime std.enums.values(Option), labels) |option, label| {
        const is_on = option == selected;
        if ((try context.interact(Button{
            .key = .str("knots.segment:" ++ @typeName(Option) ++ "." ++ @tagName(option)),
            .label = label,
            .style = if (is_on) &style.segment_on else &style.segment,
        })).clicked and !is_on) {
            result = option;
            context.requestRedraw();
        }
    }
    try bar.close(context);
    return result;
}

/// A warning above a tab's sections, e.g. that it needs another setting turned on.
pub fn notice(context: *ui.Frame, key: ui.Key, content: []const u8) !void {
    try context.e(Text{ .key = key, .content = content, .style = &style.notice });
}

/// Marks a part of the old page this window doesn't have yet.
pub fn notPorted(context: *ui.Frame, key: ui.Key, comptime what: []const u8) !void {
    try context.e(Text{ .key = key, .content = "Not in this window yet: " ++ what ++ ". Use the WebView2 configuration window for now.", .style = &style.not_ported });
}

pub fn subheading(context: *ui.Frame, key: ui.Key, content: []const u8) !void {
    try context.e(Text{ .key = key, .content = content, .style = &style.subheading });
}

/// Returns whether the user moved it this frame.
pub fn slider(context: *ui.Frame, key: ui.Key, value: *f32, min: f32, max: f32, steps: f32) !bool {
    const track = Rect{ .key = key, .style = &.{ .width = .grow(), .padding = .xy(8, 0) } };
    _ = try track.open(context);
    const response = try context.interact(SliderInput{
        .key = key.indexed(1),
        .value = value,
        .min = min,
        .max = max,
        .steps = steps,
        .parts = .{ .track = &style.slider_track, .fill = &style.slider_fill, .thumb = &style.slider_thumb },
    });
    try track.close(context);
    return response.changed;
}

/// A value shown beside a slider.
pub fn valueText(context: *ui.Frame, key: ui.Key, content: []const u8) !void {
    try context.e(Text{ .key = key, .content = content, .style = &style.slider_value });
}

/// Returns whether the user toggled it this frame.
pub fn checkbox(context: *ui.Frame, key: ui.Key, label: []const u8, checked: *bool) !bool {
    return (try context.interact(Checkbox{
        .key = key,
        .checked = checked,
        .label = label,
        .style = &style.checkbox,
        .parts = .{ .box = &style.checkbox_box, .label = &style.checkbox_label },
    })).changed;
}

pub fn colorFromArgb(argb: u32) Color {
    return .rgba(@truncate(argb >> 16), @truncate(argb >> 8), @truncate(argb), @truncate(argb >> 24));
}

pub fn argbFromColor(color: Color) u32 {
    const r: u32 = channelToByte(Color.linearToSrgb(color.value[0]));
    const g: u32 = channelToByte(Color.linearToSrgb(color.value[1]));
    const b: u32 = channelToByte(Color.linearToSrgb(color.value[2]));
    const a: u32 = channelToByte(color.value[3]);
    return (a << 24) | (r << 16) | (g << 8) | b;
}

fn channelToByte(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}
