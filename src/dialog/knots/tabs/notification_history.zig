//! The configuration window's Notification History tab: the panel of recent notifications; main thread only.
const ui = @import("ui");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

const Text = ui.component.Text;

pub fn show(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Notification History", "A draggable, resizable panel showing recent notification history. Click a row to jump to that character.", &style.section);
    const ref = session.profile().child("display");
    try bind.toggle(context, ref, "showNotifInfoPanel", "Show Notification History");
    const options = try widgets.openGroup(context, .src(@src()), ref.get("showNotifInfoPanel"));
    const size = try widgets.openBinding(context, .src(@src()), "Panel Size");
    try bind.numberBox(context, ref, "notifInfoPanelWidth", .{});
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "\u{00D7}", .style = &style.muted_text });
    try bind.numberBox(context, ref, "notifInfoPanelHeight", .{});
    try size.close(context);
    try bind.number(context, ref, "notifInfoPanelMaxRows", "Max History Rows", .{});
    try bind.slider(context, ref, "notifInfoPanelOpacity", "Panel Opacity", .{ .display = .percent_of_255 });
    const font = try widgets.openBinding(context, .src(@src()), "Font");
    try bind.fontBox(context, ref, "notifInfoPanelFontName");
    try bind.unitNumberBox(context, ref, "notifInfoPanelFontSize", "px", .{});
    try bind.choiceBox(context, ref, "notifInfoPanelFontWeight", &style.select_font_weight);
    try font.close(context);

    try widgets.subheading(context, .src(@src()), "Behavior");
    try bind.toggle(context, ref, "rememberNotifInfoPanelPosition", "Remember Notification History Position");
    try bind.toggle(context, ref, "hideNotifInfoPanelWhenNoCharacters", "Hide Panel When No Characters Are Logged In");
    try bind.toggle(context, ref, "notifInfoPanelShowTimestamp", "Show Relative Timestamps");
    try widgets.hintText(context, .src(@src()), "Shows times like \"5m ago\" instead of a fixed clock time.");
    try bind.toggle(context, ref, "notifInfoPanelShowCategoryFilters", "Show Category Filters");
    try widgets.hintText(context, .src(@src()), "Adds filter buttons for each notification category to the panel.");
    try bind.toggle(context, ref, "notifInfoPanelMergeEnabled", "Merge Repeated Notifications");
    try widgets.hintText(context, .src(@src()), "Combines identical notifications fired back to back into one row with a +N count. Click a merged row to expand it.");
    const merge = try widgets.openGroup(context, .src(@src()), ref.get("notifInfoPanelMergeEnabled"));
    try bind.number(context, ref, "notifInfoPanelMergeWindowSec", "Merge Window", .{ .unit = "s" });
    try merge.close(context);
    try options.close(context);
    try section.close(context);
}
