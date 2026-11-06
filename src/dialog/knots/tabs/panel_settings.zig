//! Settings the panels' tabs share, which every panel's section names alike; main thread only.
const ui = @import("ui");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

/// Keeps the panels' rows apart, as the search's index draws every tab in one frame.
pub const Panel = enum { history, map, intel };

/// `ref` is a session.Ref to one panel's settings section, e.g. `profile().child("mapPanel")`.
pub fn visibility(context: *ui.Frame, ref: anytype, panel: Panel, is_shown: bool) !void {
    const index = @backingInt(panel);
    const section = try widgets.openSection(context, "Visibility", "Where the panel opens, how see-through it is, and when it hides.", &style.section);
    const options = try widgets.openGroup(context, ui.Key.str("knots.panel.visibility").indexed(index), is_shown);
    try bind.toggle(context, ref, "rememberPosition", "Remember Position");
    try widgets.hintText(context, ui.Key.str("knots.panel.remember.hint").indexed(index), "Opens the panel where you last left it.");
    try alwaysOnTop(context, ref, panel);
    try bind.slider(context, ref, "opacity", "Opacity", .{ .display = .percent_of_255 });
    try widgets.hintText(context, ui.Key.str("knots.panel.opacity.hint").indexed(index), "Lower lets you see through the panel.");
    try autoHide(context, ref, panel);
    try options.close(context);
    try section.close(context);
}

/// `ref` as for visibility.
pub fn alwaysOnTop(context: *ui.Frame, ref: anytype, panel: Panel) !void {
    try bind.toggle(context, ref, "alwaysOnTop", "Always on Top");
    try widgets.hintText(context, ui.Key.str("knots.panel.on_top.hint").indexed(@backingInt(panel)), "Keeps the panel above other windows, game clients included.");
}

/// When the panel hides by itself; `ref` as for visibility.
pub fn autoHide(context: *ui.Frame, ref: anytype, panel: Panel) !void {
    const index = @backingInt(panel);
    try bind.toggle(context, ref, "hideWhenNoCharacters", "Hide When No Characters Are Logged In");
    try widgets.hintText(context, ui.Key.str("knots.panel.characters.hint").indexed(index), "The panel comes back when a character logs in.");
    try bind.toggle(context, ref, "hideWhenNoEveFocus", "Hide When No EVE Focus");
    try widgets.hintText(context, ui.Key.str("knots.panel.focus.hint").indexed(index), "The panel comes back when you return to EVE.");
    const delay = try widgets.openGroup(context, ui.Key.str("knots.panel.delay").indexed(index), ref.get("hideWhenNoEveFocus"));
    try bind.number(context, ref, "hideDebounceMs", "Hide Delay", .{ .shows_seconds = true, .unit = "s" });
    try widgets.hintText(context, ui.Key.str("knots.panel.delay.hint").indexed(index), "Waits this long, so quick switches don't flicker.");
    try delay.close(context);
}
