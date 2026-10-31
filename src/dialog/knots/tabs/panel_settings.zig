//! Settings the panels' tabs share; main thread only.
const ui = @import("ui");
const config = @import("../../../config.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

const DisplayRef = session.Ref(config.DisplayConfig);

/// Keeps the panels' rows apart, as the search's index draws every tab in one frame.
pub const Panel = enum { history, map, intel };

/// The panel's DisplayConfig fields.
pub const VisibilityFields = struct {
    remember: []const u8,
    opacity: []const u8,
    without_characters: []const u8,
    without_focus: []const u8,
    delay_ms: []const u8,
};

pub fn visibility(context: *ui.Frame, ref: DisplayRef, panel: Panel, is_shown: bool, comptime fields: VisibilityFields) !void {
    const index = @backingInt(panel);
    const section = try widgets.openSection(context, "Visibility", "Where the panel opens, how see-through it is, and when it hides.", &style.section);
    const options = try widgets.openGroup(context, ui.Key.str("knots.panel.visibility").indexed(index), is_shown);
    try bind.toggle(context, ref, fields.remember, "Remember Position");
    try widgets.hintText(context, ui.Key.str("knots.panel.remember.hint").indexed(index), "Opens the panel where you last left it.");
    try bind.slider(context, ref, fields.opacity, "Opacity", .{ .display = .percent_of_255 });
    try widgets.hintText(context, ui.Key.str("knots.panel.opacity.hint").indexed(index), "Lower lets you see through the panel.");
    try autoHide(context, ref, panel, fields.without_characters, fields.without_focus, fields.delay_ms);
    try options.close(context);
    try section.close(context);
}

/// When the panel hides by itself; each comptime name is the panel's DisplayConfig field.
pub fn autoHide(context: *ui.Frame, ref: DisplayRef, panel: Panel, comptime without_characters: []const u8, comptime without_focus: []const u8, comptime delay_ms: []const u8) !void {
    const index = @backingInt(panel);
    try bind.toggle(context, ref, without_characters, "Hide When No Characters Are Logged In");
    try widgets.hintText(context, ui.Key.str("knots.panel.characters.hint").indexed(index), "The panel comes back when a character logs in.");
    try bind.toggle(context, ref, without_focus, "Hide When No EVE Focus");
    try widgets.hintText(context, ui.Key.str("knots.panel.focus.hint").indexed(index), "The panel comes back when you return to EVE.");
    const delay = try widgets.openGroup(context, ui.Key.str("knots.panel.delay").indexed(index), ref.get(without_focus));
    try bind.number(context, ref, delay_ms, "Hide Delay", .{ .shows_seconds = true, .unit = "s" });
    try widgets.hintText(context, ui.Key.str("knots.panel.delay.hint").indexed(index), "Waits this long, so quick switches don't flicker.");
    try delay.close(context);
}
