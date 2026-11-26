//! The configuration window's Alert History section: a preview of the panel of recent alerts whose parts are clicked to edit them under it, then where the panel shows; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../config.zig");
const notification = @import("../../../notifications/notification.zig");
const history_look = @import("../../../panels/history_look.zig");
const list_look = @import("../../../panels/list_look.zig");
const palette = @import("../../../palette.zig");
const panel_header = @import("../../../panels/panel_header.zig");
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
const PART_PADDING = panel_preview.PART_PADDING;

const BENCH_KEY: ui.Key = .str("knots.notification_history.bench");
const ROW_KEY: ui.Key = .str("knots.notification_history.row");
const FILTER_KEY: ui.Key = .str("knots.notification_history.filter");
const CHIP_LINE_KEY: ui.Key = .str("knots.notification_history.chip_line");
/// A chip's width before it's been laid out once.
const UNMEASURED_CHIP_WIDTH: i32 = 60;
const PART_COUNT = std.enums.values(Part).len;

/// Newest first, one per category and a merged one; the first two not yet looked at.
const SAMPLES = [_]Sample{
    .{ .name = "Pilot Alpha", .notification_type = .FleetInvite, .text = "Fleet invite", .age_ms = 20_000, .is_new = true },
    .{ .name = "Pilot Echo", .notification_type = .TakingDamage, .text = "Taking damage", .age_ms = 95_000, .is_new = true },
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
    /// Arrived since the cursor last left the panel.
    is_new: bool = false,
};

/// The preview's colours and text sizes, read from the edited settings.
const Look = struct {
    name_color: u32,
    /// A new row's name.
    new_name_color: u32,
    name_size: f32,
    small_size: f32,
    /// The chips' and divider's, the header's small font at the preview's scale.
    chip_size: f32,
    sizes: history_look.Metrics,
    /// Shrinks the preview to fit its section; 1 at real size.
    scale: f32,

    /// `pixels` real pixels at the preview's scale.
    fn scaled(self: Look, pixels: i32) f32 {
        return panel_preview.scaled(self.scale, pixels);
    }
};

/// What a click on the preview selects.
const Part = enum {
    panel,
    filters,
    timestamp,
    merged,

    fn label(self: Part) []const u8 {
        return switch (self) {
            .panel => "Panel",
            .filters => "Category Filters",
            .timestamp => "Timestamps",
            .merged => "Merge Repeats",
        };
    }
};

const INITIAL_PICKER: panel_preview.Picker(Part) = .{ .part_key = .str("knots.notification_history.part"), .selected = .panel };

var g_picker: panel_preview.Picker(Part) = INITIAL_PICKER;

/// Once the window has closed.
pub fn reset() void {
    g_picker = INITIAL_PICKER;
}

pub fn show(context: *ui.Frame) !void {
    const profile = session.profile().ptr;
    const are_alerts_on = profile.notifications.enabled;
    if (!are_alerts_on) try widgets.noticeWithButton(context, .src(@src()), "Alert History requires alerts switched on in the Alert Options tab.", "Go to Alert Options", .notifications);
    const ref = session.profile().child("historyPanel");

    const section = try widgets.openSection(context, "Alert History", "A panel of recent alerts. Click a part to edit it.", &style.bench_section);
    const intro = Rect{ .key = .src(@src()), .style = &style.bench_intro };
    _ = try intro.open(context);
    const alerts = try widgets.openGroup(context, .src(@src()), are_alerts_on);
    try bind.toggle(context, ref, "show", "Enable Alert History");
    try alerts.close(context);
    try intro.close(context);
    const is_shown = are_alerts_on and ref.get("show");
    const shown = try widgets.openGroup(context, .src(@src()), is_shown);
    var bench = try panel_preview.Bench.open(context, BENCH_KEY);
    const look = lookOf(profile, &bench);
    try bench.openStage(context, look.scale, &g_picker.shows_off);
    try panel(context, profile, look);
    try bench.closeStage(context);
    try g_picker.partList(context, &partRows(&profile.historyPanel), partSwitch);
    try bench.openInspector(context);
    // The search's index draws every tab with it, and they bind some of the same fields, so the inspector's rows need keys of their own.
    var inspector_ref = ref;
    inspector_ref.index = 1;
    try settings(context, inspector_ref, g_picker.selected);
    try bench.close(context);
    try shown.close(context);
    try section.close(context);

    try panel_settings.visibility(context, ref, .history, .{ .is_shown = is_shown });
}

/// Every part's row in the parts list.
fn partRows(history_settings: *const config.HistoryPanelConfig) [PART_COUNT]panel_preview.Picker(Part).Row {
    var part_rows: [PART_COUNT]panel_preview.Picker(Part).Row = undefined;
    for (std.enums.values(Part), &part_rows) |part, *part_row| {
        const is_shown = switch (part) {
            .panel => true,
            .filters => history_settings.showCategoryFilters,
            .timestamp => history_settings.showTimestamp,
            .merged => history_settings.mergeEnabled,
        };
        part_row.* = .{
            .part = part,
            .label = part.label(),
            .is_shown = is_shown,
            .color = palette.TEXT_SECONDARY,
            .starts_group = part == .filters,
        };
    }
    return part_rows;
}

/// The part's on switch in the parts list, where it has one.
fn partSwitch(context: *ui.Frame, part: Part) !void {
    var ref = session.profile().child("historyPanel");
    // At the inspector's index, as the search draws every tab too.
    ref.index = 1;
    switch (part) {
        .panel => {},
        .filters => try bind.toggle(context, ref, "showCategoryFilters", ""),
        .timestamp => try bind.toggle(context, ref, "showTimestamp", ""),
        .merged => try bind.toggle(context, ref, "mergeEnabled", ""),
    }
}

/// The selected part's name, then its settings.
fn settings(context: *ui.Frame, ref: HistoryRef, part: Part) !void {
    try panel_preview.inspectorTitle(context, .src(@src()), part.label());
    switch (part) {
        .panel => {
            const size = try widgets.openBinding(context, .src(@src()), "Size");
            try bind.sizeBoxes(context, ref, "width", "height");
            try size.close(context);
            try widgets.hintText(context, .src(@src()), "You can also drag the panel's edges to resize it.");
            try bind.number(context, ref, "maxRows", "Max Rows", .{ .unit = "rows", .singular_unit = "row" });
            try widgets.hintText(context, .src(@src()), "Older alerts drop off past this.");
            const font = try widgets.openWrappingBinding(context, .src(@src()), "Font");
            try bind.fontBoxes(context, ref, "fontName", "fontSize", "fontWeight");
            try font.close(context);
            try widgets.hintText(context, .src(@src()), "Used for every row's text.");
        },
        .filters => {
            try bind.toggle(context, ref, "showFleet", "Fleet");
            try bind.toggle(context, ref, "showMining", "Mining");
            try bind.toggle(context, ref, "showCombat", "Combat");
            try bind.toggle(context, ref, "showNavigation", "Navigation");
            try bind.toggle(context, ref, "showChat", "Chat");
            try bind.toggle(context, ref, "showGeneral", "General");
            try widgets.paragraph(context, .src(@src()), "The categories the panel lists; clicking a chip on the panel switches its category too.");
        },
        .timestamp => try widgets.paragraph(context, .src(@src()), "Shows times like \"5m ago\" instead of a fixed clock time."),
        .merged => {
            try bind.number(context, ref, "mergeWindowSec", "Merge Window", .{ .unit = "s" });
            try widgets.hintText(context, .src(@src()), "Repeats this close together share a row with a count; click it to expand.");
        },
    }
}

/// A unique name colour varies per character, so a sample stands in for it.
fn lookOf(profile: *const config.Config, bench: *const panel_preview.Bench) Look {
    const history_settings = &profile.historyPanel;
    const scale = bench.scaleFor(@floatFromInt(history_settings.width));
    const uses_unique_names = profile.shownColors().uses_unique_name_colors;
    return .{
        .name_color = if (uses_unique_names) style.UNIQUE_SAMPLE else list_look.NAME,
        .new_name_color = if (uses_unique_names) style.UNIQUE_SAMPLE else list_look.ACTIVE_NAME,
        .name_size = @as(f32, @floatFromInt(history_settings.fontSize)) * scale,
        .small_size = @as(f32, @floatFromInt(list_look.smallFontSize(history_settings.fontSize))) * scale,
        .chip_size = @as(f32, @floatFromInt(palette.SMALL_FONT_SIZE)) * scale,
        .sizes = history_look.metrics(history_settings),
        .scale = scale,
    };
}

/// The samples the panel would list: filtered by category, as many as maxRows allows.
fn shownSamples(history_settings: *const config.HistoryPanelConfig, out: *[SAMPLES.len]usize) []const usize {
    var shown_count: usize = 0;
    for (SAMPLES, 0..) |sample, index| {
        if (shown_count >= history_settings.maxRows) break;
        if (!history_look.showsCategory(history_settings, notification.notificationCategory(sample.notification_type))) continue;
        out[shown_count] = index;
        shown_count += 1;
    }
    return out[0..shown_count];
}

fn newCount(shown: []const usize) usize {
    var count: usize = 0;
    for (shown) |index| {
        if (SAMPLES[index].is_new) count += 1;
    }
    return count;
}

/// Each chip's width from last frame, in real pixels; a chip not yet laid out guesses, and asks for another frame.
fn chipWidths(context: *ui.Frame, look: Look) ![history_look.CATEGORY_COUNT]i32 {
    const ui_state = context.ui();
    var widths: [history_look.CATEGORY_COUNT]i32 = undefined;
    for (&widths, 0..) |*width, index| {
        const key = FILTER_KEY.indexed(index);
        _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, key.hash());
        const measured = widgets.measuredBox(ui_state, key).w();
        if (measured == 0) context.requestRedraw();
        width.* = if (measured == 0) UNMEASURED_CHIP_WIDTH else @intFromFloat(@ceil(measured / look.scale));
    }
    return widths;
}

/// Just tall enough for the chips and samples or the empty text, leaving no blank space.
fn previewHeight(history_settings: *const config.HistoryPanelConfig, sizes: history_look.Metrics, rows_top: i32, shown: []const usize) i32 {
    const row_count: i32 = @intCast(@max(1, shown.len));
    const new_count = newCount(shown);
    const has_earlier = new_count > 0 and new_count < shown.len;
    const fitted = rows_top + history_look.ROWS_PADDING_TOP + row_count * sizes.row_height + (if (has_earlier) history_look.EARLIER_HEIGHT else 0) + list_look.BOTTOM_PADDING;
    return @min(fitted, history_settings.height);
}

fn panel(context: *ui.Frame, profile: *const config.Config, look: Look) !void {
    const arena = context.arena();
    const history_settings = &profile.historyPanel;
    var shown_buffer: [SAMPLES.len]usize = undefined;
    const shown = shownSamples(history_settings, &shown_buffer);
    // Laid out while off too, for the ghost that's clicked to turn them on.
    const chip_layout = history_look.layOutChips(try chipWidths(context, look), history_settings.width, panel_header.HEIGHT);
    const rows_top = chip_layout.bottom;

    const panel_style = try panel_preview.frameStyle(arena, look.scale, history_settings.opacity, .{
        .width = .fixed(look.scaled(history_settings.width)),
        .height = .fixed(look.scaled(previewHeight(history_settings, look.sizes, rows_top, shown))),
    });
    const frame = Rect{ .key = .src(@src()), .style = panel_style };
    _ = try frame.open(context);
    try g_picker.header(context, .panel, .src(@src()), history_look.HEADER_TEXT, "", look.scale);
    try chips(context, history_settings, &chip_layout, look);
    try rows(context, profile, shown, look);
    try frame.close(context);
}

/// The category chips, in the lines the panel wraps them onto, as one part; lit while their category shows, and a ghost while they're off.
fn chips(context: *ui.Frame, history_settings: *const config.HistoryPanelConfig, chip_layout: *const history_look.ChipLayout, look: Look) !void {
    const arena = context.arena();
    const padding = look.scaled(PART_PADDING);
    const bar_style = try arena.create(ui.Style);
    // The part's padding and border make up the rest of the panel's.
    const edge = padding + 1;
    bar_style.* = .{
        .width = .grow(),
        .direction = .column,
        .padding = .init(look.scaled(history_look.CHIPS_PADDING_TOP) - edge, look.scaled(history_look.CHIPS_PADDING_X) - edge, look.scaled(history_look.CHIPS_PADDING_BOTTOM) - edge, look.scaled(history_look.CHIPS_PADDING_X) - edge),
        .border_width = .edges(0, 0, 1, 0),
        .border_color = color_convert.solid(list_look.DIVIDER),
    };
    const bar = Rect{ .key = .src(@src()), .style = bar_style };
    _ = try bar.open(context);
    const is_shown = history_settings.showCategoryFilters;
    const part = try g_picker.openPart(context, .{
        .width = .grow(),
        .padding = .all(padding),
        .background = color_convert.solid(list_look.PANEL),
    }, .{ padding, padding }, .filters, is_shown);
    const opacity = g_picker.contentOpacity(.filters, is_shown);
    const lines_style = try arena.create(ui.Style);
    lines_style.* = .{ .width = .grow(), .direction = .column, .gap = look.scaled(history_look.CHIP_GAP) };
    const lines = Rect{ .key = .src(@src()), .style = lines_style };
    _ = try lines.open(context);
    const line_style = try arena.create(ui.Style);
    line_style.* = .{ .direction = .row, .gap = look.scaled(history_look.CHIP_GAP) };
    var first: usize = 0;
    while (first < history_look.CATEGORY_COUNT) {
        var last = first + 1;
        while (last < history_look.CATEGORY_COUNT and chip_layout.boxes[last].top == chip_layout.boxes[first].top) last += 1;
        const line = Rect{ .key = CHIP_LINE_KEY.indexed(first), .style = line_style };
        _ = try line.open(context);
        for (first..last) |index| try chip(context, history_look.CATEGORY_ORDER[index], index, history_look.isCategoryEnabled(history_settings, history_look.CATEGORY_ORDER[index]), opacity, look);
        try line.close(context);
        first = last;
    }
    try lines.close(context);
    try part.close(context);
    try bar.close(context);
}

/// `opacity` is the Category Filters part's, which its chips take since it doesn't reach them.
fn chip(context: *ui.Frame, category: notification.NotificationCategory, index: usize, is_on: bool, opacity: f32, look: Look) !void {
    const arena = context.arena();
    const key = FILTER_KEY.indexed(index);
    const fill = if (is_on) palette.PANEL else list_look.PANEL;
    const label_color = if (is_on) palette.TEXT else palette.MUTED;
    const chip_style = try arena.create(ui.Style);
    chip_style.* = .{
        .height = .fixed(look.scaled(history_look.CHIP_HEIGHT)),
        .direction = .row,
        .@"align" = .center,
        .gap = look.scaled(history_look.CHIP_TEXT_GAP),
        .padding = .xy(look.scaled(history_look.CHIP_PADDING_X), 0),
        .radius = .{ .fixed = look.scaled(@intCast(history_look.CHIP_RADIUS)) },
        .background = color_convert.solid(fill),
        .border_width = .all(1),
        .border_color = color_convert.solid(if (is_on) palette.BORDER else palette.DIVIDER),
        .opacity = opacity,
    };
    const chip_rect = Rect{ .key = key, .style = chip_style };
    _ = try chip_rect.open(context);
    const diameter = look.scaled(2 * history_look.CHIP_DOT_RADIUS);
    const dot_style = try arena.create(ui.Style);
    dot_style.* = .{
        .width = .fixed(diameter),
        .height = .fixed(diameter),
        .radius = .{ .fixed = diameter / 2 },
        .background = color_convert.solid(if (is_on) history_look.categoryColor(category) else palette.BORDER),
        .opacity = opacity,
    };
    try context.e(Rect{ .key = key.indexed(1), .style = dot_style });
    try context.e(Text{ .selectable = false, .key = key.indexed(2), .content = history_look.categoryLabel(category), .style = try widgets.textStyle(arena, label_color, look.chip_size, .{ .opacity = opacity }) });
    const count = try arena.print("{d}", .{sampleCount(category)});
    try context.e(Text{ .selectable = false, .key = key.indexed(3), .content = count, .style = try widgets.textStyle(arena, history_look.chipCountColor(label_color, fill), look.chip_size, .{ .opacity = opacity }) });
    try chip_rect.close(context);
}

fn sampleCount(category: notification.NotificationCategory) usize {
    var count: usize = 0;
    for (SAMPLES) |sample| {
        if (notification.notificationCategory(sample.notification_type) == category) count += sample.merged_count;
    }
    return count;
}

/// The shown samples, with "Earlier" after the new ones.
fn rows(context: *ui.Frame, profile: *const config.Config, shown: []const usize, look: Look) !void {
    const arena = context.arena();
    const body_style = try arena.create(ui.Style);
    body_style.* = .{
        .width = .grow(),
        .height = .grow(),
        .direction = .column,
        .padding = .init(look.scaled(history_look.ROWS_PADDING_TOP), 0, 0, 0),
    };
    const body = Rect{ .key = .src(@src()), .style = body_style };
    _ = try body.open(context);

    const row_style = try arena.create(ui.Style);
    row_style.* = .{
        .width = .grow(),
        .height = .fixed(look.scaled(look.sizes.row_height)),
        .direction = .row,
        .@"align" = .center,
        .gap = look.scaled(history_look.TEXT_GAP),
        .padding = .xy(look.scaled(history_look.PADDING_X), 0),
        .overflow = .hidden,
    };
    if (shown.len == 0) {
        const row = Rect{ .key = .src(@src()), .style = row_style };
        _ = try row.open(context);
        try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "All alerts filtered", .style = try widgets.textStyle(arena, list_look.MUTED, look.name_size, .{}) });
        try row.close(context);
    }
    var follows_new = false;
    for (shown, 0..) |index, position| {
        const sample = SAMPLES[index];
        if (follows_new and !sample.is_new) try earlier(context, look);
        follows_new = sample.is_new;
        try sampleRow(context, profile, sample, index, position == 0, row_style, look);
    }
    try body.close(context);
}

/// The first row's timestamp is the part that edits it, since a part has one key; so is a merged row's count.
fn sampleRow(context: *ui.Frame, profile: *const config.Config, sample: Sample, index: usize, is_first: bool, row_style: *const ui.Style, look: Look) !void {
    const arena = context.arena();
    const history_settings = &profile.historyPanel;
    const category = notification.notificationCategory(sample.notification_type);
    const key = ROW_KEY.indexed(index);
    const padding = look.scaled(PART_PADDING);
    var part_row_style = row_style;
    if (is_first) {
        // The timestamp part pads its text, so the row's right padding gives that back.
        const edge_style = try arena.create(ui.Style);
        edge_style.* = row_style.with(.{
            .padding = .init(0, look.scaled(history_look.PADDING_X) - padding, 0, look.scaled(history_look.PADDING_X)),
        });
        part_row_style = edge_style;
    }
    const row = Rect{ .key = key, .style = part_row_style };
    _ = try row.open(context);

    // The row's gap is the one between its texts, so the slot makes up the wider one after the tile.
    const slot_style = try arena.create(ui.Style);
    slot_style.* = .{ .width = .fixed(history_look.TILE_SIZE + look.scaled(history_look.TILE_GAP - history_look.TEXT_GAP)), .direction = .row };
    const slot = Rect{ .key = key.indexed(9), .style = slot_style };
    _ = try slot.open(context);
    const tile_style = try arena.create(ui.Style);
    tile_style.* = .{
        .width = .fixed(history_look.TILE_SIZE),
        .height = .fixed(history_look.TILE_SIZE),
        .justify = .center,
        .@"align" = .center,
        .radius = .{ .fixed = @floatFromInt(history_look.TILE_RADIUS) },
        .background = color_convert.solid(history_look.tileColor(category)),
    };
    const tile = Rect{ .key = key.indexed(1), .style = tile_style };
    _ = try tile.open(context);
    try panel_preview.panelGlyph(context, key.indexed(2), history_look.categoryGlyph(category), history_look.TILE_GLYPH_SIZE, history_look.categoryColor(category));
    try tile.close(context);
    try slot.close(context);

    try context.e(Text{ .selectable = false, .key = key.indexed(3), .content = sample.name, .style = try widgets.textStyle(arena, if (sample.is_new) look.new_name_color else look.name_color, look.name_size, .{ .is_bold = true }) });
    const message_color = history_look.messageColor(&profile.notifications, sample.notification_type);
    // Takes the room left and clips a long message, so the timestamp keeps its place.
    const middle_style = try arena.create(ui.Style);
    middle_style.* = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = look.scaled(history_look.TEXT_GAP), .overflow = .hidden };
    const middle = Rect{ .key = key.indexed(7), .style = middle_style };
    _ = try middle.open(context);
    const message_style = try widgets.textStyle(arena, message_color, look.name_size, .{});
    try context.e(Text{ .selectable = false, .key = key.indexed(4), .content = try widgets.fittedText(context, sample.text, message_style, try messageRoom(context, key, sample, look)), .style = message_style });
    if (sample.merged_count > 1) {
        const merges = history_settings.mergeEnabled;
        const part = try g_picker.openPart(context, .{
            .@"align" = .center,
            .padding = .xy(padding, 0),
            .background = color_convert.solid(list_look.PANEL),
        }, .{ padding, 0 }, .merged, merges);
        const pill_style = try arena.create(ui.Style);
        pill_style.* = .{
            .background = color_convert.solid(palette.SURFACE),
            .radius = .{ .fixed = look.scaled(@intCast(history_look.MERGED_RADIUS)) },
            .padding = .xy(look.scaled(history_look.MERGED_PADDING_X), 0),
            .opacity = g_picker.contentOpacity(.merged, merges),
        };
        const pill = Rect{ .key = key.indexed(5), .style = pill_style };
        _ = try pill.open(context);
        const merged = history_look.mergedText(try arena.create([history_look.COUNT_TEXT_MAX]u8), sample.merged_count);
        try context.e(Text{ .selectable = false, .key = key.indexed(6), .content = merged, .style = try widgets.textStyle(arena, palette.TEXT_SECONDARY, look.small_size, .{ .opacity = g_picker.contentOpacity(.merged, merges) }) });
        try pill.close(context);
        try part.close(context);
    }
    try middle.close(context);
    const shows_timestamp = history_settings.showTimestamp;
    if (shows_timestamp or is_first) {
        const time_text = panel_look.relativeTime(try arena.create([panel_look.TIME_TEXT_MAX]u8), sample.age_ms);
        const opacity: f32 = if (is_first) g_picker.contentOpacity(.timestamp, shows_timestamp) else 1;
        const time = Text{ .selectable = false, .key = key.indexed(8), .content = time_text, .style = try widgets.textStyle(arena, list_look.MUTED, look.small_size, .{ .opacity = opacity }) };
        if (is_first) {
            const part = try g_picker.openPart(context, .{
                .padding = .xy(padding, 0),
                .background = color_convert.solid(list_look.PANEL),
            }, .{ padding, 0 }, .timestamp, shows_timestamp);
            try context.e(time);
            try part.close(context);
        } else {
            try context.e(time);
        }
    }
    try row.close(context);
}

/// The width a row's message had last frame, less its merged count's; 0 until the row is laid out.
fn messageRoom(context: *ui.Frame, key: ui.Key, sample: Sample, look: Look) !f32 {
    const ui_state = context.ui();
    const middle_key = key.indexed(7);
    if (ui_state.state.get(.measured, middle_key.hash()) == null) context.requestRedraw();
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, middle_key.hash());
    var room = widgets.measuredBox(ui_state, middle_key).w();
    if (sample.merged_count > 1) room -= widgets.measuredBox(ui_state, g_picker.keyOf(.merged)).w() + look.scaled(history_look.TEXT_GAP);
    return room;
}

/// The divider between the new rows and the rest.
fn earlier(context: *ui.Frame, look: Look) !void {
    const arena = context.arena();
    const divider_style = try arena.create(ui.Style);
    divider_style.* = .{
        .width = .grow(),
        .height = .fixed(look.scaled(history_look.EARLIER_HEIGHT)),
        .direction = .row,
        .@"align" = .center,
        .gap = look.scaled(history_look.EARLIER_RULE_GAP),
        .padding = .xy(look.scaled(history_look.PADDING_X), 0),
    };
    const divider = Rect{ .key = .src(@src()), .style = divider_style };
    _ = try divider.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = history_look.EARLIER_TEXT, .style = try widgets.textStyle(arena, list_look.MUTED, look.chip_size, .{}) });
    const rule_style = try arena.create(ui.Style);
    rule_style.* = .{ .width = .grow(), .height = .fixed(1), .background = color_convert.solid(list_look.DIVIDER) };
    try context.e(Rect{ .key = .src(@src()), .style = rule_style });
    try divider.close(context);
}
