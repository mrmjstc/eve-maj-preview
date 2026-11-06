//! The configuration window's History Panel tab: a preview of the panel of recent notifications, then its settings; main thread only.
const ui = @import("ui");
const config = @import("../../../config.zig");
const notification = @import("../../../notifications/notification.zig");
const history_look = @import("../../../panels/history_look.zig");
const list_look = @import("../../../panels/list_look.zig");
const panel_look = @import("../../../panels/panel_look.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const color_convert = @import("../color_convert.zig");
const panel_preview = @import("panel_preview.zig");
const panel_settings = @import("panel_settings.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const HistoryRef = session.Ref(config.HistoryPanelConfig);

const STAGE_KEY: ui.Key = .str("knots.notification_history.stage");
const ROW_KEY: ui.Key = .str("knots.notification_history.row");
const FILTER_KEY: ui.Key = .str("knots.notification_history.filter");

/// Newest first, one per category and a merged one.
const SAMPLES = [_]Sample{
    .{ .name = "Pilot Alpha", .notification_type = .FleetInvite, .text = "Fleet invite", .age_ms = 20_000 },
    .{ .name = "Pilot Echo", .notification_type = .TakingDamage, .text = "Taking damage", .age_ms = 95_000 },
    .{ .name = "Pilot Foxtrot", .notification_type = .CargoFull, .text = "Cargo hold full", .age_ms = 4 * 60_000, .merged_count = 3 },
    .{ .name = "Pilot Bravo", .notification_type = .Docking, .text = "Docked", .age_ms = 12 * 60_000 },
    .{ .name = "Pilot Golf", .notification_type = .ChatIntel, .text = "Perimeter (2 jumps): spike 10", .age_ms = 40 * 60_000 },
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
        return panel_preview.scaled(self.scale, pixels);
    }
};

pub fn show(context: *ui.Frame) !void {
    const are_notifications_enabled = session.profile().ptr.thumbnail.notifications.enabled;
    if (!are_notifications_enabled) try widgets.noticeWithButton(context, .src(@src()), "History Panel requires Notification System switched on in the Notifications tab.", "Go to Notifications", .notifications);
    const ref = session.profile().child("historyPanel");

    const section = try widgets.openSection(context, "History Panel", "A panel of recent alerts. Click a row to jump to that character.", &style.section);
    const notifications = try widgets.openGroup(context, .src(@src()), are_notifications_enabled);
    try bind.toggle(context, ref, "show", "Enable History Panel");
    const shown = try widgets.openGroup(context, .src(@src()), ref.get("show"));
    try preview(context, session.profile().ptr);
    try shown.close(context);
    try notifications.close(context);
    try section.close(context);

    // Laid out like the Client List's own sections, which set up the same kind of panel.
    const is_shown = are_notifications_enabled and ref.get("show");
    try layout(context, ref, is_shown);
    try panel_settings.visibility(context, ref, .history, is_shown);
    try rowSettings(context, ref, is_shown);
}

fn layout(context: *ui.Frame, ref: HistoryRef, is_shown: bool) !void {
    const section = try widgets.openSection(context, "Layout", "The panel's size, how many rows it holds, its font, and its filter buttons.", &style.section);
    const options = try widgets.openGroup(context, .src(@src()), is_shown);
    const size = try widgets.openBinding(context, .src(@src()), "Size");
    try bind.sizeBoxes(context, ref, "width", "height");
    try size.close(context);
    try widgets.hintText(context, .src(@src()), "You can also drag the panel's edges to resize it.");
    try bind.number(context, ref, "maxRows", "Max Rows", .{ .unit = "rows", .singular_unit = "row" });
    try widgets.hintText(context, .src(@src()), "Older notifications drop off past this.");
    const font = try widgets.openBinding(context, .src(@src()), "Font");
    try bind.fontBoxes(context, ref, "fontName", "fontSize", "fontWeight");
    try font.close(context);
    try widgets.hintText(context, .src(@src()), "Used for every row's text.");
    try bind.toggle(context, ref, "showCategoryFilters", "Category Filters");
    try widgets.hintText(context, .src(@src()), "Adds buttons to filter the panel by type.");
    try options.close(context);
    try section.close(context);
}

fn rowSettings(context: *ui.Frame, ref: HistoryRef, is_shown: bool) !void {
    const section = try widgets.openSection(context, "Rows", "How each notification is shown in the panel.", &style.section);
    const options = try widgets.openGroup(context, .src(@src()), is_shown);
    try bind.toggle(context, ref, "showTimestamp", "Relative Timestamps");
    try widgets.hintText(context, .src(@src()), "Shows times like \"5m ago\" instead of a fixed clock time.");
    try bind.toggle(context, ref, "mergeEnabled", "Merge Repeats");
    try widgets.hintText(context, .src(@src()), "Repeats share one row with a count; click it to expand.");
    const merge = try widgets.openGroup(context, .src(@src()), ref.get("mergeEnabled"));
    try bind.number(context, ref, "mergeWindowSec", "Merge Window", .{ .unit = "s" });
    try widgets.hintText(context, .src(@src()), "Repeats this close together share a row.");
    try merge.close(context);
    try options.close(context);
    try section.close(context);
}

/// The panel in history_look's look, with sample notifications, shrunk to fit the section.
fn preview(context: *ui.Frame, profile: *const config.Config) !void {
    const stage = try panel_preview.Stage.open(context, STAGE_KEY);
    const look = lookOf(profile, stage);
    try panel(context, profile, look);
    try stage.close(context, look.scale, "Shrunk to fit; the panel itself is wider.");
}

/// A unique name colour varies per character, so a sample stands in for it.
fn lookOf(profile: *const config.Config, stage: panel_preview.Stage) Look {
    const history_settings = &profile.historyPanel;
    const scale = stage.scaleFor(@floatFromInt(history_settings.width));
    return .{
        .name_color = if (profile.shownColors().uses_unique_name_colors) style.UNIQUE_SAMPLE else list_look.NAME,
        .name_size = @as(f32, @floatFromInt(history_settings.fontSize)) * scale,
        .small_size = @as(f32, @floatFromInt(list_look.smallFontSize(history_settings.fontSize))) * scale,
        .sizes = history_look.metrics(history_settings),
        .scale = scale,
    };
}

/// Just tall enough for the samples or the empty text, leaving no blank space.
fn previewHeight(history_settings: *const config.HistoryPanelConfig, sizes: history_look.Metrics) i32 {
    const capacity = history_look.rowCapacity(history_settings, sizes);
    var shown_count: usize = 0;
    for (SAMPLES) |sample| {
        if (history_look.showsCategory(history_settings, notification.notificationCategory(sample.notification_type))) shown_count += 1;
    }
    const row_count: i32 = @intCast(@max(1, @min(shown_count, capacity)));
    const fitted = sizes.header_height + row_count * sizes.row_height + list_look.BOTTOM_PADDING + sizes.footer_height;
    return @min(fitted, history_settings.height);
}

fn panel(context: *ui.Frame, profile: *const config.Config, look: Look) !void {
    const arena = context.arena();
    const history_settings = &profile.historyPanel;
    const panel_style = try panel_preview.frameStyle(arena, look.scale, history_settings.opacity, .{
        .width = .fixed(look.scaled(history_settings.width)),
        .height = .fixed(look.scaled(previewHeight(history_settings, look.sizes))),
    });
    const frame = Rect{ .key = .src(@src()), .style = panel_style };
    _ = try frame.open(context);
    try panel_preview.header(context, .src(@src()), history_look.HEADER_TEXT, look.sizes.header_height, look.scale, look.small_size);

    try rows(context, profile, look);
    if (look.sizes.footer_height > 0) try footer(context, history_settings, look);
    try frame.close(context);
}

/// The samples the panel would show: filtered by category, merged while merging is on, and as many as fit.
fn rows(context: *ui.Frame, profile: *const config.Config, look: Look) !void {
    const arena = context.arena();
    const history_settings = &profile.historyPanel;
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
    const capacity = history_look.rowCapacity(history_settings, look.sizes);
    var shown_count: usize = 0;
    for (SAMPLES, 0..) |sample, index| {
        if (shown_count >= capacity) break;
        if (!history_look.showsCategory(history_settings, notification.notificationCategory(sample.notification_type))) continue;
        shown_count += 1;

        const key = ROW_KEY.indexed(index);
        const row = Rect{ .key = key, .style = row_style };
        _ = try row.open(context);
        const is_merged = history_settings.mergeEnabled and sample.merged_count > 1;
        const name = if (is_merged) history_look.countText(try arena.create([history_look.COUNT_TEXT_MAX]u8), sample.merged_count) else sample.name;
        try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = name, .style = try widgets.textStyle(arena, if (is_merged) list_look.MUTED else look.name_color, look.name_size, .{}) });
        const message_color = history_look.messageColor(&profile.thumbnail.notifications, sample.notification_type);
        try context.e(Text{ .selectable = false, .key = key.indexed(2), .content = sample.text, .style = try widgets.textStyle(arena, message_color, look.name_size, .{ .is_grown = true }) });
        if (history_settings.showTimestamp) {
            const time_text = panel_look.relativeTime(try arena.create([panel_look.TIME_TEXT_MAX]u8), sample.age_ms);
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
fn footer(context: *ui.Frame, history_settings: *const config.HistoryPanelConfig, look: Look) !void {
    const arena = context.arena();
    const gap = look.scaled(panel_look.BUTTON_GAP);
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
        const is_enabled = history_look.isCategoryEnabled(history_settings, category);
        const button_style = try arena.create(ui.Style);
        button_style.* = .{
            .width = .grow(),
            .height = .grow(),
            .justify = .center,
            .@"align" = .center,
            .radius = .{ .fixed = look.scaled(@intCast(panel_look.BUTTON_RADIUS)) },
            .background = if (is_enabled) color_convert.solid(panel_look.BUTTON_ON) else .transparent,
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
