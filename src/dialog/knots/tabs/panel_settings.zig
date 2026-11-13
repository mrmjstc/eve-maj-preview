//! Settings the panels' tabs share, which every panel's section names alike and lists in one order; main thread only.
const ui = @import("ui");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

/// Keeps the panels' rows apart, as the search's index draws every tab in one frame.
pub const Panel = enum { list, history, map, intel };

pub const VisibilityOptions = struct {
    /// False dims the rows, while the panel itself is off.
    is_shown: bool = true,
    /// False leaves out the hiding rows, e.g. for the list beside thumbnails, which hides with them.
    has_auto_hide: bool = true,
};

/// `ref` is a session.Ref to one panel's settings section, e.g. `profile().child("mapPanel")`.
pub fn visibility(context: *ui.Frame, ref: anytype, comptime panel: Panel, options: VisibilityOptions) !void {
    // Named by panel, as the Appearance tab shows the list's beside the thumbnails' own Visibility.
    const section = try widgets.openNamedSection(context, "Visibility:" ++ @tagName(panel), "Visibility", "Where the panel opens, how see-through it is, and when it hides.", &style.section);
    const group = try widgets.openGroup(context, ui.Key.str("knots.panel.visibility").indexed(@backingInt(panel)), options.is_shown);
    try visibilityRows(context, ref, panel, options.has_auto_hide);
    try group.close(context);
    try section.close(context);
}

/// Every panel's in the same order, leaving out those whose setting `ref`'s section doesn't have; for a panel whose rows share a section with others.
pub fn visibilityRows(context: *ui.Frame, ref: anytype, comptime panel: Panel, has_auto_hide: bool) !void {
    const index = @backingInt(panel);
    try bind.toggle(context, ref, "rememberPosition", "Remember Position");
    try widgets.hintText(context, ui.Key.str("knots.panel.remember.hint").indexed(index), "Opens the panel where you last left it.");
    if (comptime @hasField(SettingsOf(@TypeOf(ref)), "lockPosition")) {
        try bind.toggle(context, ref, "lockPosition", "Lock Position");
        try widgets.hintText(context, ui.Key.str("knots.panel.lock.hint").indexed(index), "Its header no longer drags the panel.");
    }
    try bind.toggle(context, ref, "alwaysOnTop", "Always on Top");
    try widgets.hintText(context, ui.Key.str("knots.panel.on_top.hint").indexed(index), "Keeps the panel above other windows, game clients included.");
    try bind.slider(context, ref, "opacity", "Opacity", .{ .display = .percent_of_255 });
    try widgets.hintText(context, ui.Key.str("knots.panel.opacity.hint").indexed(index), "Lower lets you see through the panel.");
    if (has_auto_hide) try autoHide(context, ref, panel);
}

/// When the panel hides by itself; `ref` as for visibility.
fn autoHide(context: *ui.Frame, ref: anytype, comptime panel: Panel) !void {
    const index = @backingInt(panel);
    if (comptime @hasField(SettingsOf(@TypeOf(ref)), "hideWhenNoCharacters")) {
        try bind.toggle(context, ref, "hideWhenNoCharacters", "Hide When No Characters Are Logged In");
        try widgets.hintText(context, ui.Key.str("knots.panel.characters.hint").indexed(index), "The panel comes back when a character logs in.");
    }
    try bind.toggle(context, ref, "hideWhenNoEveFocus", "Hide When No EVE Focus");
    try widgets.hintText(context, ui.Key.str("knots.panel.focus.hint").indexed(index), "The panel comes back when you return to EVE.");
    const delay = try widgets.openGroup(context, ui.Key.str("knots.panel.delay").indexed(index), ref.get("hideWhenNoEveFocus"));
    try bind.number(context, ref, "hideDebounceMs", "Hide Delay", .{ .shows_seconds = true, .unit = "s" });
    try widgets.hintText(context, ui.Key.str("knots.panel.delay.hint").indexed(index), "Waits this long, so quick switches don't flicker.");
    try delay.close(context);
}

/// The settings struct a session.Ref points into.
fn SettingsOf(comptime Ref: type) type {
    return @typeInfo(@FieldType(Ref, "ptr")).pointer.child;
}
