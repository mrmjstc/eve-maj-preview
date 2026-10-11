//! The configuration window's Notification History tab: a preview of the panel of recent notifications, then its settings; main thread only.
const ui = @import("ui");
const config = @import("../../../config.zig");
const notification = @import("../../../notifications/notification.zig");
const history_look = @import("../../../notifications/history_look.zig");
const list_look = @import("../../../thumbnail/list_look.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const color_convert = @import("../color_convert.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const DisplayRef = session.Ref(config.DisplayConfig);

const STAGE_KEY: ui.Key = .str("knots.notification_history.stage");
const ROW_KEY: ui.Key = .str("knots.notification_history.row");
const FILTER_KEY: ui.Key = .str("knots.notification_history.filter");

/// Newest first, one per category and a merged one.
const SAMPLES = [_]Sample{
    .{ .name = "Pilot Alpha", .notification_type = .FleetInvite, .text = "Fleet invite", .age_ms = 20_000 },
    .{ .name = "Pilot Echo", .notification_type = .TakingDamage, .text = "Taking damage", .age_ms = 95_000 },
    .{ .name = "Pilot Foxtrot", .notification_type = .CargoFull, .text = "Cargo hold full", .age_ms = 4 * 60_000, .merged_count = 3 },
    .{ .name = "Pilot Bravo", .notification_type = .Docking, .text = "Docked", .age_ms = 12 * 60_000 },
    .{ .name = "Pilot Charlie", .notification_type = .SystemChange, .text = "Jumped to Perimeter", .age_ms = 2 * 3_600_000 },
    .{ .name = "Pilot Delta", .notification_type = .CycleExclusion, .text = "Excluded from cycling", .age_ms = 3 * 3_600_000 },
};

const Sample = struct {
    name: []const u8,
    notification_type: notification.NotificationType,
    text: []const u8,
    age_ms: u64,
    /// Shown as one row with a count while merging is on.
    merged_count: usize = 1,
};

/// The preview's colours and text sizes, read from the edited settings.
const Look = struct {
    name_color: u32,
    name_size: f32,
    small_size: f32,
    sizes: history_look.Metrics,
    /// Shrinks the preview to fit its section; 1 at real size.
    scale: f32,

    /// `pixels` real pixels at the preview's scale.
    fn scaled(self: Look, pixels: i32) f32 {
        return @as(f32, @floatFromInt(pixels)) * self.scale;
    }
};

pub fn show(context: *ui.Frame) !void {
    const are_notifications_enabled = session.profile().ptr.thumbnail.notifications.enabled;
    if (!are_notifications_enabled) try widgets.notice(context, .src(@src()), "Notification History requires Notification System switched on in the Notifications tab.");
    const ref = session.profile().child("display");

    const section = try bind.switchedSection(context, "Notification History", "A draggable, resizable panel showing recent notification history. Click a row to jump to that character.", ref, "showNotifInfoPanel", are_notifications_enabled);
    const notifications = try widgets.openGroup(context, .src(@src()), are_notifications_enabled);
    const shown = try widgets.openGroup(context, .src(@src()), ref.get("showNotifInfoPanel"));
    try preview(context, session.profile().ptr);
    try shown.close(context);
    try notifications.close(context);
    try section.close(context);

    // Laid out like the Client List's own sections, which set up the same kind of panel.
    const is_shown = are_notifications_enabled and ref.get("showNotifInfoPanel");
    try layout(context, ref, is_shown);
    try visibility(context, ref, is_shown);
    try rowSettings(context, ref, is_shown);
}

fn layout(context: *ui.Frame, ref: DisplayRef, is_shown: bool) !void {
    const section = try widgets.openSection(context, "Panel Layout", "The panel's size, how many rows it holds, and its font.", &style.section);
    const options = try widgets.openGroup(context, .src(@src()), is_shown);
    const size = try widgets.openBinding(context, .src(@src()), "Size");
    try bind.unitNumberBox(context, ref, "notifInfoPanelWidth", "px", .{});
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "\u{00D7}", .style = &style.muted_text });
    try bind.unitNumberBox(context, ref, "notifInfoPanelHeight", "px", .{});
    try size.close(context);
    try bind.number(context, ref, "notifInfoPanelMaxRows", "Max Rows", .{});
    const font = try widgets.openBinding(context, .src(@src()), "Font");
    try bind.fontBox(context, ref, "notifInfoPanelFontName");
    try bind.unitNumberBox(context, ref, "notifInfoPanelFontSize", "px", .{});
    try bind.choiceBox(context, ref, "notifInfoPanelFontWeight");
    try font.close(context);
    try options.close(context);
    try section.close(context);
}

fn visibility(context: *ui.Frame, ref: DisplayRef, is_shown: bool) !void {
    const section = try widgets.openSection(context, "Panel Visibility", "Where the panel opens, how see-through it is, and when it's hidden automatically.", &style.section);
    const options = try widgets.openGroup(context, .src(@src()), is_shown);
    try bind.toggle(context, ref, "rememberNotifInfoPanelPosition", "Remember Position");
    try bind.slider(context, ref, "notifInfoPanelOpacity", "Opacity", .{ .display = .percent_of_255 });
    try bind.toggle(context, ref, "hideNotifInfoPanelWhenNoCharacters", "Hide When No Characters Are Logged In");
    try options.close(context);
    try section.close(context);
}

fn rowSettings(context: *ui.Frame, ref: DisplayRef, is_shown: bool) !void {
    const section = try widgets.openSection(context, "Panel Rows", "How each notification is shown in the panel.", &style.section);
    const options = try widgets.openGroup(context, .src(@src()), is_shown);
    try bind.toggle(context, ref, "notifInfoPanelShowTimestamp", "Relative Timestamps");
    try widgets.hintText(context, .src(@src()), "Shows times like \"5m ago\" instead of a fixed clock time.");
    try bind.toggle(context, ref, "notifInfoPanelShowCategoryFilters", "Category Filters");
    try widgets.hintText(context, .src(@src()), "Adds filter buttons for each notification category to the panel.");
    try bind.toggle(context, ref, "notifInfoPanelMergeEnabled", "Merge Repeats");
    try widgets.hintText(context, .src(@src()), "Combines identical notifications fired back to back into one row with a +N count. Click a merged row to expand it.");
    const merge = try widgets.openGroup(context, .src(@src()), ref.get("notifInfoPanelMergeEnabled"));
    try bind.number(context, ref, "notifInfoPanelMergeWindowSec", "Merge Window", .{ .unit = "s" });
    try merge.close(context);
    try options.close(context);
    try section.close(context);
}

/// The panel in history_look's look, with sample notifications, shrunk to fit the section.
fn preview(context: *ui.Frame, profile: *const config.Config) !void {
    const ui_state = context.ui();
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, STAGE_KEY.hash());
    const available_width = widgets.measuredBox(ui_state, STAGE_KEY).w();
    // Not laid out yet, so draw once more knowing the room there is.
    if (available_width == 0) context.requestRedraw();
    const stage = Rect{ .key = STAGE_KEY, .style = &style.stage_row };
    _ = try stage.open(context);
    const look = lookOf(profile, available_width);
    try panel(context, profile, look);
    try stage.close(context);
    if (look.scale < 1) try widgets.paragraph(context, .src(@src()), "Shrunk to fit; the panel itself is wider.");
}

/// A unique name colour varies per character, so a sample stands in for it.
fn lookOf(profile: *const config.Config, available_width: f32) Look {
    const display = &profile.display;
    const panel_width: f32 = @floatFromInt(display.notifInfoPanelWidth);
    const scale = if (available_width > 0 and panel_width > available_width) available_width / panel_width else 1;
    return .{
        .name_color = if (profile.shownColors().uses_unique_name_colors) style.UNIQUE_SAMPLE else list_look.NAME,
        .name_size = @as(f32, @floatFromInt(display.notifInfoPanelFontSize)) * scale,
        .small_size = @as(f32, @floatFromInt(list_look.smallFontSize(display.notifInfoPanelFontSize))) * scale,
        .sizes = history_look.metrics(display),
        .scale = scale,
    };
}

/// Just tall enough for the samples shown (or the empty text), so the panel's empty space below them isn't drawn.
fn previewHeight(display: *const config.DisplayConfig, sizes: history_look.Metrics) i32 {
    const capacity = history_look.rowCapacity(display, sizes);
    var shown_count: usize = 0;
    for (SAMPLES) |sample| {
        if (history_look.showsCategory(display, notification.notificationCategory(sample.notification_type))) shown_count += 1;
    }
    const row_count: i32 = @intCast(@max(1, @min(shown_count, capacity)));
    const fitted = sizes.header_height + row_count * sizes.row_height + list_look.BOTTOM_PADDING + sizes.footer_height;
    return @min(fitted, display.notifInfoPanelHeight);
}

fn panel(context: *ui.Frame, profile: *const config.Config, look: Look) !void {
    const arena = context.arena();
    const display = &profile.display;
    const panel_style = try arena.create(ui.Style);
    panel_style.* = .{
        .width = .fixed(look.scaled(display.notifInfoPanelWidth)),
        .height = .fixed(look.scaled(previewHeight(display, look.sizes))),
        .direction = .column,
        .background = color_convert.solid(list_look.PANEL),
        .border_width = .all(1),
        .border_color = color_convert.solid(list_look.BORDER),
        .radius = .{ .fixed = look.scaled(@intCast(list_look.CORNER_RADIUS)) },
        .opacity = @as(f32, @floatFromInt(display.notifInfoPanelOpacity)) / 255.0,
        .overflow = .hidden,
    };
    const frame = Rect{ .key = .src(@src()), .style = panel_style };
    _ = try frame.open(context);

    const header_style = try arena.create(ui.Style);
    header_style.* = .{
        .width = .grow(),
        .height = .fixed(look.scaled(look.sizes.header_height)),
        .direction = .row,
        .@"align" = .center,
        .padding = .xy(look.scaled(list_look.PADDING_X), 0),
        .border_width = .edges(0, 0, 1, 0),
        .border_color = color_convert.solid(list_look.DIVIDER),
    };
    const header = Rect{ .key = .src(@src()), .style = header_style };
    _ = try header.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = history_look.HEADER_TEXT, .style = try widgets.textStyle(arena, list_look.MUTED, look.small_size, .{}) });
    try header.close(context);

    try rows(context, profile, look);
    if (look.sizes.footer_height > 0) try footer(context, display, look);
    try frame.close(context);
}

/// The samples the panel would show: filtered by category, merged while merging is on, and as many as fit.
fn rows(context: *ui.Frame, profile: *const config.Config, look: Look) !void {
    const arena = context.arena();
    const display = &profile.display;
    const body_style = try arena.create(ui.Style);
    body_style.* = .{ .width = .grow(), .height = .grow(), .direction = .column };
    const body = Rect{ .key = .src(@src()), .style = body_style };
    _ = try body.open(context);

    const row_style = try arena.create(ui.Style);
    row_style.* = .{
        .width = .grow(),
        .height = .fixed(look.scaled(look.sizes.row_height)),
        .direction = .row,
        .@"align" = .center,
        .gap = look.scaled(history_look.TEXT_GAP),
        .padding = .xy(look.scaled(list_look.PADDING_X), 0),
        .overflow = .hidden,
    };
    const capacity = history_look.rowCapacity(display, look.sizes);
    var shown_count: usize = 0;
    for (SAMPLES, 0..) |sample, index| {
        if (shown_count >= capacity) break;
        if (!history_look.showsCategory(display, notification.notificationCategory(sample.notification_type))) continue;
        shown_count += 1;

        const key = ROW_KEY.indexed(index);
        const row = Rect{ .key = key, .style = row_style };
        _ = try row.open(context);
        const is_merged = display.notifInfoPanelMergeEnabled and sample.merged_count > 1;
        const name = if (is_merged) history_look.countText(try arena.create([history_look.COUNT_TEXT_MAX]u8), sample.merged_count) else sample.name;
        try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = name, .style = try widgets.textStyle(arena, if (is_merged) list_look.MUTED else look.name_color, look.name_size, .{}) });
        const message_color = history_look.messageColor(&profile.thumbnail.notifications, sample.notification_type);
        try context.e(Text{ .selectable = false, .key = key.indexed(2), .content = sample.text, .style = try widgets.textStyle(arena, message_color, look.name_size, .{ .is_grown = true }) });
        if (display.notifInfoPanelShowTimestamp) {
            const time_text = history_look.relativeTime(try arena.create([history_look.TIME_TEXT_MAX]u8), sample.age_ms);
            try context.e(Text{ .selectable = false, .key = key.indexed(3), .content = time_text, .style = try widgets.textStyle(arena, list_look.MUTED, look.small_size, .{}) });
        }
        try row.close(context);
    }
    if (shown_count == 0 and capacity > 0) {
        const row = Rect{ .key = .src(@src()), .style = row_style };
        _ = try row.open(context);
        try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "All notifications filtered", .style = try widgets.textStyle(arena, list_look.MUTED, look.name_size, .{}) });
        try row.close(context);
    }
    try body.close(context);
}

/// The category filter buttons, filled while their category shows.
fn footer(context: *ui.Frame, display: *const config.DisplayConfig, look: Look) !void {
    const arena = context.arena();
    const gap = look.scaled(history_look.FILTER_GAP);
    const footer_style = try arena.create(ui.Style);
    footer_style.* = .{
        .width = .grow(),
        .height = .fixed(look.scaled(look.sizes.footer_height)),
        .direction = .row,
        .gap = gap,
        .padding = .all(gap),
        .border_width = .edges(1, 0, 0, 0),
        .border_color = color_convert.solid(list_look.DIVIDER),
    };
    const bar = Rect{ .key = .src(@src()), .style = footer_style };
    _ = try bar.open(context);
    for (history_look.CATEGORY_ORDER, 0..) |category, index| {
        const is_enabled = history_look.isCategoryEnabled(display, category);
        const button_style = try arena.create(ui.Style);
        button_style.* = .{
            .width = .grow(),
            .height = .grow(),
            .justify = .center,
            .@"align" = .center,
            .radius = .{ .fixed = look.scaled(@intCast(history_look.FILTER_RADIUS)) },
            .background = if (is_enabled) color_convert.solid(history_look.FILTER_ON) else .transparent,
            .overflow = .hidden,
        };
        const key = FILTER_KEY.indexed(index);
        const button = Rect{ .key = key, .style = button_style };
        _ = try button.open(context);
        try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = history_look.categoryLabel(category), .style = try widgets.textStyle(arena, if (is_enabled) list_look.NAME else list_look.MUTED, look.small_size, .{}) });
        try button.close(context);
    }
    try bar.close(context);
}
