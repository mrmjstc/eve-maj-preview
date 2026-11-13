//! The configuration window's Client List tab: a preview of the panel whose parts are clicked to edit them in a popover, then the panel's other settings; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../config.zig");
const types = @import("../../../config/types.zig");
const list_look = @import("../../../panels/list_look.zig");
const map_look = @import("../../../panels/map/look.zig");
const map_text = @import("../../../panels/map/text.zig");
const panel_menu_look = @import("../../../panels/panel_menu_look.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const color_convert = @import("../color_convert.zig");
const panel_preview = @import("panel_preview.zig");
const panel_settings = @import("panel_settings.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const ListRef = session.Ref(config.ListViewConfig);
const PART_PADDING = panel_preview.PART_PADDING;

const POPOVER_KEY: ui.Key = .str("knots.client_list.popover");
const PART_KEY: ui.Key = .str("knots.client_list.part");
const ROW_KEY: ui.Key = .str("knots.client_list.row");
const LINE_KEY: ui.Key = .str("knots.client_list.line");
const STAGE_KEY: ui.Key = .str("knots.client_list.stage");
const TOTALS_KEY: ui.Key = .str("knots.client_list.totals");
/// The panel menu's own words, so the two name each order alike.
const ORDER_LABELS = blk: {
    var labels: [panel_menu_look.ORDER_COUNT][]const u8 = undefined;
    for (panel_menu_look.ORDER_OPTIONS, &labels) |order, *label| label.* = panel_menu_look.orderLabel(order);
    break :blk labels;
};
/// One line of sample rows, one per column.
const SAMPLE_LINE: ui.Style = .{ .width = .grow(), .direction = .row };

/// Each rate's sample, in list_look.Stat order: mining in m3 per minute, scaled to its unit, and bounty in ISK per its unit.
const SAMPLE_VALUES = [list_look.STAT_COUNT]f32{ 412, 980, 21.4, 38_200_000 };
/// Drawn in Fleet Invite's own colour, or the list's notification colour when it has none.
const SAMPLE_NOTIFICATION = "Fleet Invite";
/// Two rates to a stats row, so each fits a column.
const SAMPLES = [_]Sample{
    .{ .name = "Pilot Alpha", .state = .active, .system = "Jita", .security_tenths = 9 },
    .{ .name = "Pilot Bravo", .state = .inactive, .system = "Perimeter", .security_tenths = 10, .is_name_part = true, .is_system_part = true },
    .{ .name = "Pilot Delta", .state = .inactive, .right = .notification },
    .{ .name = "Pilot Echo", .state = .inactive, .system = "Amarr", .security_tenths = 10, .stats = &.{ .incoming_dps, .outgoing_dps } },
    .{ .name = "Pilot Foxtrot", .state = .inactive, .system = "Tama", .security_tenths = 3, .stats = &.{ .mining_rate, .bounty_rate } },
    .{ .name = "Pilot Charlie", .state = .excluded },
};

/// What a click on the preview opens: one per text, as on the thumbnail preview.
const Part = enum {
    active,
    names,
    systems,
    notifications,
    incoming_dps,
    outgoing_dps,
    mining_rate,
    bounty_rate,
    totals,

    fn label(self: Part) []const u8 {
        return switch (self) {
            .active => "Active Client",
            .names => "Character Names",
            .systems => "System Names",
            .notifications => "Alerts",
            .incoming_dps => "Incoming DPS",
            .outgoing_dps => "Outgoing DPS",
            .mining_rate => "Mining Rate",
            .bounty_rate => "Bounty Rate",
            .totals => "Totals",
        };
    }

    fn ofStat(stat: list_look.Stat) Part {
        return switch (stat) {
            .incoming_dps => .incoming_dps,
            .outgoing_dps => .outgoing_dps,
            .mining_rate => .mining_rate,
            .bounty_rate => .bounty_rate,
        };
    }
};

const Sample = struct {
    name: []const u8,
    state: enum { active, inactive, excluded },
    /// What its right-hand slot shows; the system's name is `system`.
    right: enum { system, notification } = .system,
    system: []const u8 = "",
    security_tenths: i8 = 0,
    /// Rates on a line under its name.
    stats: []const list_look.Stat = &.{},
    /// Only one row's name opens Character Names, since a part has one key.
    is_name_part: bool = false,
    /// Only one row's system opens System Names, for the same reason.
    is_system_part: bool = false,
};

/// One rate as the panel draws it; faded while the list doesn't show it.
const StatLabel = struct { text: []const u8, color: u32, is_shown: bool };

/// The preview's colours and text sizes, read from the edited settings.
const Look = struct {
    active_color: u32,
    active_name_color: u32,
    name_color: u32,
    system_color: u32,
    notification_color: u32,
    name_size: f32,
    small_size: f32,
    shows_systems: bool,
    shows_security: bool,
    shows_notifications: bool,
    shows_totals: bool,
    indicator: types.ListIndicatorStyle,
    /// Every rate, in list_look.Stat order.
    stat_labels: [list_look.STAT_COUNT]StatLabel,
    sizes: list_look.Metrics,
    column_count: usize,
    /// Shrinks the preview to fit its section; 1 at real size.
    scale: f32,

    /// `pixels` real pixels at the preview's scale.
    fn scaled(self: Look, pixels: i32) f32 {
        return panel_preview.scaled(self.scale, pixels);
    }
};

/// The overlay switch shared with the thumbnails, then the list's own show, prefix and colour fields.
const StatRows = struct {
    overlay_label: []const u8,
    show_field: []const u8,
    show_label: []const u8,
    show_hint: []const u8,
    prefix_field: []const u8,
    prefix_label: []const u8,
    prefix_hint: []const u8,
    color_field: []const u8,
};

var g_selected: Part = .names;
var g_is_popover_open: bool = false;

/// Once the window has closed.
pub fn reset() void {
    g_is_popover_open = false;
}

pub fn show(context: *ui.Frame) !void {
    if (!session.profile().ptr.display.viewMode.showsClientList()) {
        try widgets.noticeWithButton(context, .src(@src()), "The client list is hidden while Show Clients As is Thumbnails or None.", "Go to Appearance", .appearance);
    }
    const list_view = session.profile().child("listView");
    const section = try widgets.openSection(context, "Client List", "A compact panel of client names. Click a part of the preview to change it.", &style.section);
    const stage = try panel_preview.Stage.open(context, STAGE_KEY);
    const look = try lookOf(context.arena(), session.profile().ptr, stage);
    try preview(context, &session.profile().ptr.listView, look);
    try stage.close(context, look.scale, "Shrunk to fit; the list itself is wider.");
    try section.close(context);

    try layout(context, list_view);
    // Beside thumbnails, the list hides with them.
    try panel_settings.visibility(context, list_view, .list, .{ .has_auto_hide = !session.showsThumbnails() });
    try popover(context, list_view);
}

fn layout(context: *ui.Frame, list_view: ListRef) !void {
    const section = try widgets.openSection(context, "Layout", "How the list orders and arranges its clients.", &style.section);
    try bind.segmented(context, list_view, "order", "Order", &ORDER_LABELS);
    try widgets.hintText(context, .src(@src()), "Setup follows the Characters tab; Found is the order clients were found.");
    try bind.toggle(context, list_view, "groupBySystem", "Group by System");
    try widgets.hintText(context, .src(@src()), "Lists clients under a heading for each system.");
    try bind.number(context, list_view, "columns", "Columns", .{ .unit = "columns", .singular_unit = "column" });
    try widgets.hintText(context, .src(@src()), "Splits the list into this many columns.");
    try bind.number(context, list_view, "columnWidth", "Column Width", .{ .unit = "px" });
    try widgets.hintText(context, .src(@src()), "Long names are cut short to fit.");
    try bind.segmented(context, list_view, "indicatorStyle", "Indicator", &.{ "Dot", "Square", "None" });
    try widgets.hintText(context, .src(@src()), "The mark beside each client that shows its state.");
    const font = try widgets.openBinding(context, .src(@src()), "Font");
    try bind.fontBoxes(context, list_view, "fontName", "fontSize", "fontWeight");
    try font.close(context);
    try widgets.hintText(context, .src(@src()), "Used for names; other text is drawn a little smaller.");
    try section.close(context);
}

/// The panel in list_look's look, with sample clients, at `look.scale`.
fn preview(context: *ui.Frame, list_settings: *const config.ListViewConfig, look: Look) !void {
    const arena = context.arena();
    const column_count = look.column_count;
    // No bottom padding, as the totals footer is always drawn and pads the bottom itself.
    const panel_style = try panel_preview.frameStyle(arena, look.scale, list_settings.opacity, .{
        .width = .fixed(look.scaled(look.sizes.column_width * @as(i32, @intCast(column_count)))),
    });
    const panel = Rect{ .key = .src(@src()), .style = panel_style };
    _ = try panel.open(context);
    const count_text = list_look.countText(try arena.create([list_look.COUNT_TEXT_MAX]u8), SAMPLES.len);
    try panel_preview.header(context, .src(@src()), list_look.HEADER_TEXT, count_text, look.scale);

    // Row by row across the columns, as the panel lays its rows out; a short last line keeps its cells' width.
    var first: usize = 0;
    while (first < SAMPLES.len) : (first += column_count) {
        // Room for the rates even while they're off, as their ghosts still show to be clicked.
        const height = look.scaled(look.sizes.stats_row_height);
        const empty_cell = try arena.create(ui.Style);
        empty_cell.* = .{ .width = .grow(), .height = .fixed(height) };
        const line = Rect{ .key = LINE_KEY.indexed(first), .style = &SAMPLE_LINE };
        _ = try line.open(context);
        for (first..first + column_count) |index| {
            if (index < SAMPLES.len) {
                try sampleRow(context, SAMPLES[index], index, height, look);
            } else {
                try context.e(Rect{ .key = ROW_KEY.indexed(index), .style = empty_cell });
            }
        }
        try line.close(context);
    }
    try totalsFooter(context, look);
    try panel.close(context);
}

/// A rule over the sample rates added up, as the part that edits the totals line.
fn totalsFooter(context: *ui.Frame, look: Look) !void {
    const arena = context.arena();
    const footer_style = try arena.create(ui.Style);
    footer_style.* = .{
        .width = .grow(),
        .height = .fixed(look.scaled(look.sizes.footer_height)),
        .direction = .row,
        .@"align" = .center,
        .padding = .init(0, look.scaled(list_look.PADDING_X - PART_PADDING), 0, look.scaled(list_look.PADDING_X - PART_PADDING)),
        .border_width = .edges(1, 0, 0, 0),
        .border_color = color_convert.solid(list_look.DIVIDER),
    };
    const footer = Rect{ .key = TOTALS_KEY, .style = footer_style };
    _ = try footer.open(context);
    const part = try openPart(context, look, .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = look.scaled(list_look.STAT_GAP) }, list_look.PANEL, .totals, look.shows_totals);
    try context.e(Text{ .selectable = false, .key = TOTALS_KEY.indexed(1), .content = list_look.TOTALS_TEXT, .style = try widgets.textStyle(arena, list_look.MUTED, look.small_size, .{ .is_shown = look.shows_totals, .is_bold = true }) });
    for (look.stat_labels, 2..) |label, index| {
        if (!label.is_shown) continue;
        try context.e(Text{ .selectable = false, .key = TOTALS_KEY.indexed(index), .content = label.text, .style = try widgets.textStyle(arena, label.color, look.small_size, .{ .is_shown = look.shows_totals }) });
    }
    try part.close(context);
    try footer.close(context);
}

/// The active row is one part; so are one row's name and system, and each notification and rate.
fn sampleRow(context: *ui.Frame, sample: Sample, index: usize, height: f32, look: Look) !void {
    const arena = context.arena();
    const key = ROW_KEY.indexed(index);
    // A part pads its text for its outline, so the space before a name part and after a right-hand part gives that back.
    const name_inset: f32 = if (sample.is_name_part) look.scaled(PART_PADDING) else 0;
    const has_right_part = sample.state == .inactive and (sample.right == .notification or sample.is_system_part);
    const right_inset: f32 = if (has_right_part) look.scaled(PART_PADDING) else 0;
    const has_indicator = look.indicator != .None;
    const row_style = try arena.create(ui.Style);
    row_style.* = .{
        .width = .grow(),
        .height = .fixed(height),
        .direction = .row,
        .@"align" = .center,
        .gap = look.scaled(list_look.INDICATOR_GAP) - (if (has_indicator) name_inset else 0),
        .padding = .init(0, look.scaled(list_look.PADDING_X) - right_inset, 0, look.scaled(list_look.PADDING_X) - (if (has_indicator) 0 else name_inset)),
    };
    switch (sample.state) {
        .active => {
            const row = try openPart(context, look, row_style.*, list_look.activeTint(look.active_color), .active, true);
            try indicator(context, key.indexed(1), look.active_color, true, look);
            try context.e(Text{ .selectable = false, .key = key.indexed(2), .content = sample.name, .style = try widgets.textStyle(arena, look.active_name_color, look.name_size, .{ .is_grown = true, .is_bold = true }) });
            try systemSlot(context, sample, key.indexed(3), look);
            try row.close(context);
        },
        .inactive => {
            const row = Rect{ .key = key, .style = row_style };
            _ = try row.open(context);
            try indicator(context, key.indexed(1), list_look.BADGE_INACTIVE, false, look);
            const lines = Rect{ .key = key.indexed(4), .style = try linesStyle(arena, look) };
            _ = try lines.open(context);
            const name = Text{ .selectable = false, .key = key.indexed(2), .content = sample.name, .style = try widgets.textStyle(arena, look.name_color, look.name_size, .{ .is_bold = true }) };
            if (sample.is_name_part) {
                const part = try openPart(context, look, .{}, list_look.PANEL, .names, true);
                try context.e(name);
                try part.close(context);
            } else {
                try context.e(name);
            }
            if (sample.stats.len > 0) try statsLine(context, sample.stats, key.indexed(5), look);
            try lines.close(context);
            switch (sample.right) {
                .system => try systemSlot(context, sample, key.indexed(3), look),
                .notification => try pillPart(context, key.indexed(3), look),
            }
            try row.close(context);
        },
        .excluded => {
            const row = Rect{ .key = key, .style = row_style };
            _ = try row.open(context);
            try indicator(context, key.indexed(1), list_look.BADGE_EXCLUDED, false, look);
            try context.e(Text{ .selectable = false, .key = key.indexed(2), .content = sample.name, .style = try widgets.textStyle(arena, list_look.MUTED, look.name_size, .{ .is_grown = true, .is_bold = true }) });
            try context.e(Text{ .selectable = false, .key = key.indexed(3), .content = "Excluded", .style = try widgets.textStyle(arena, list_look.MUTED, look.small_size, .{ .is_bold = true }) });
            try row.close(context);
        },
    }
}

/// A row's name over its stats line, taking the room the right-hand slot leaves.
fn linesStyle(arena: std.mem.Allocator, look: Look) !*const ui.Style {
    const lines_style = try arena.create(ui.Style);
    lines_style.* = .{ .width = .grow(), .direction = .column, .gap = look.scaled(list_look.LINE_GAP) };
    return lines_style;
}

/// Side by side, `gap` apart.
fn groupStyle(arena: std.mem.Allocator, gap: f32) !*const ui.Style {
    const group_style = try arena.create(ui.Style);
    group_style.* = .{ .direction = .row, .@"align" = .center, .gap = gap };
    return group_style;
}

/// The system then its security; the system is the part that edits it on the row marked `is_system_part`.
fn systemSlot(context: *ui.Frame, sample: Sample, key: ui.Key, look: Look) !void {
    const arena = context.arena();
    const group = Rect{ .key = key, .style = try groupStyle(arena, look.scaled(list_look.SECURITY_GAP)) };
    _ = try group.open(context);
    const system_style = try widgets.textStyle(arena, look.system_color, look.small_size, .{ .is_shown = look.shows_systems, .is_bold = true });
    if (sample.is_system_part) {
        try textPart(context, .systems, key.indexed(1), sample.system, system_style, look.shows_systems, look);
    } else {
        try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = sample.system, .style = system_style });
    }
    const security = map_text.securityText(try arena.create([map_text.SECURITY_TEXT_MAX]u8), sample.security_tenths);
    if (look.shows_security) try context.e(Text{ .selectable = false, .key = key.indexed(2), .content = security, .style = try widgets.textStyle(arena, map_look.securityTextColor(sample.security_tenths), look.small_size, .{ .is_shown = look.shows_systems, .is_bold = true }) });
    try group.close(context);
}

/// The sample notification in its pill, as the part that edits it.
fn pillPart(context: *ui.Frame, key: ui.Key, look: Look) !void {
    const arena = context.arena();
    const part = try openPart(context, look, .{}, list_look.PANEL, .notifications, look.shows_notifications);
    const pill_style = try arena.create(ui.Style);
    pill_style.* = .{
        .background = color_convert.solid(list_look.pillFill(list_look.BADGE_ALERT)),
        .border_width = .all(1),
        .border_color = color_convert.solid(list_look.pillBorder(list_look.BADGE_ALERT)),
        .radius = .{ .fixed = look.scaled(@intCast(list_look.PILL_RADIUS)) },
        .padding = .xy(look.scaled(list_look.PILL_PADDING_X - 1), 0),
    };
    const pill = Rect{ .key = key, .style = pill_style };
    _ = try pill.open(context);
    try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = SAMPLE_NOTIFICATION, .style = try widgets.textStyle(arena, look.notification_color, look.small_size, .{ .is_shown = look.shows_notifications, .is_bold = true }) });
    try pill.close(context);
    try part.close(context);
}

/// A row's rates under its name, each the part that edits it.
fn statsLine(context: *ui.Frame, stats: []const list_look.Stat, key: ui.Key, look: Look) !void {
    const arena = context.arena();
    const group = Rect{ .key = key, .style = try groupStyle(arena, look.scaled(list_look.STAT_GAP - 2 * PART_PADDING)) };
    _ = try group.open(context);
    for (stats, 1..) |stat, index| {
        const label = look.stat_labels[@backingInt(stat)];
        try textPart(context, .ofStat(stat), key.indexed(index), label.text, try widgets.textStyle(arena, label.color, look.small_size, .{ .is_shown = label.is_shown }), label.is_shown, look);
    }
    try group.close(context);
}

/// `content` as the part that edits it.
fn textPart(context: *ui.Frame, part: Part, key: ui.Key, content: []const u8, text_style: *const ui.Style, is_shown: bool, look: Look) !void {
    const open = try openPart(context, look, .{}, list_look.PANEL, part, is_shown);
    try context.e(Text{ .selectable = false, .key = key, .content = content, .style = text_style });
    try open.close(context);
}

/// A unique colour varies per character or system, so a sample stands in for it.
fn lookOf(arena: std.mem.Allocator, profile: *const config.Config, stage: panel_preview.Stage) !Look {
    const list_settings = &profile.listView;
    const sizes = list_look.metrics(list_settings);
    const column_count: usize = @intCast(list_look.effectiveColumns(list_settings.columns, SAMPLES.len));
    const scale = stage.scaleFor(@floatFromInt(sizes.column_width * @as(i32, @intCast(column_count))));
    const shown = profile.shownColors();
    const active_color = if (shown.uses_unique_border_colors) style.UNIQUE_SAMPLE else shown.active_color;
    const uses_unique_names = list_settings.useUniqueCharacterNameColors;
    const stat_settings: list_look.StatSettings = .{ .list_settings = list_settings, .combat = &profile.combat, .mining = &profile.mining, .bounty = &profile.bounty };

    var stat_labels: [list_look.STAT_COUNT]StatLabel = undefined;
    for (std.enums.values(list_look.Stat), SAMPLE_VALUES, &stat_labels) |stat, sample, *label| {
        const unit = list_look.rateUnit(stat_settings, stat);
        const value = if (stat == .mining_rate) sample * profile.mining.m3_rate_unit.seconds() / std.time.s_per_min else sample;
        var writer: std.Io.Writer = .fixed(try arena.alloc(u8, list_look.STAT_TEXT_MAX));
        list_look.writeStat(&writer, .{ .stat = stat, .value = value, .has_prefix = list_look.hasPrefix(list_settings, stat), .unit = unit });
        label.* = .{ .text = writer.buffered(), .color = list_look.statColor(list_settings, stat), .is_shown = list_look.showsStat(stat_settings, stat) };
    }

    return .{
        .active_color = active_color,
        .active_name_color = if (uses_unique_names) style.UNIQUE_SAMPLE else list_look.ACTIVE_NAME,
        .name_color = if (uses_unique_names) style.UNIQUE_SAMPLE else list_look.NAME,
        .notification_color = profile.thumbnail.notifications.getTypeConfig(.FleetInvite).text_color orelse list_settings.notificationColor,
        .system_color = if (shown.uses_unique_system_colors) style.UNIQUE_SAMPLE else shown.system_name_color,
        .name_size = @as(f32, @floatFromInt(list_settings.fontSize)) * scale,
        .small_size = @as(f32, @floatFromInt(list_look.smallFontSize(list_settings.fontSize))) * scale,
        .shows_systems = list_settings.showSystemName,
        .shows_security = list_settings.showSystemSecurity,
        .shows_notifications = list_settings.showNotifications,
        .shows_totals = list_look.showsTotals(stat_settings),
        .indicator = list_settings.indicatorStyle,
        .stat_labels = stat_labels,
        .sizes = sizes,
        .column_count = column_count,
        .scale = scale,
    };
}

/// `is_shown` is whether the list shows the part's text; the active row's always is.
fn openPart(context: *ui.Frame, look: Look, base: ui.Style, background: u32, part: Part, is_shown: bool) !panel_preview.Part {
    var part_style = base.with(.{ .background = color_convert.solid(background) });
    var inset = [2]f32{ 0, 0 };
    // The row's own padding already places the active row's content.
    if (part != .active) {
        inset = .{ look.scaled(PART_PADDING), 0 };
        part_style.padding = .xy(inset[0], inset[1]);
    }
    const open = try panel_preview.Part.open(context, partKey(part), part_style, inset, .{ .is_shown = is_shown, .is_selected = g_is_popover_open and g_selected == part });
    if (open.is_clicked) select(context, part);
    return open;
}

fn select(context: *ui.Frame, part: Part) void {
    g_selected = part;
    g_is_popover_open = true;
    context.requestRedraw();
}

fn partKey(part: Part) ui.Key {
    return PART_KEY.indexed(@backingInt(part));
}

/// The active client's is bigger; every one sits in a slot as wide as that, so names line up.
fn indicator(context: *ui.Frame, key: ui.Key, color: u32, is_lit: bool, look: Look) !void {
    const diameter = look.scaled(2 * (if (is_lit) list_look.LIT_BADGE_RADIUS else list_look.BADGE_RADIUS));
    const shape: ui.Style = switch (look.indicator) {
        .Dot => .{ .width = .fixed(diameter), .height = .fixed(diameter), .radius = .{ .fixed = diameter / 2 } },
        .Square => .{ .width = .fixed(diameter), .height = .fixed(diameter) },
        .None => return,
    };
    const arena = context.arena();
    const slot_style = try arena.create(ui.Style);
    slot_style.* = .{ .width = .fixed(look.scaled(2 * list_look.LIT_BADGE_RADIUS)), .direction = .row, .justify = .center, .@"align" = .center };
    const slot = Rect{ .key = key, .style = slot_style };
    _ = try slot.open(context);
    const indicator_shape = try arena.create(ui.Style);
    indicator_shape.* = shape.with(.{ .background = color_convert.solid(color) });
    try context.e(Rect{ .key = key.indexed(1), .style = indicator_shape });
    try slot.close(context);
}

/// Beside the clicked part; a click on another part moves it there.
fn popover(context: *ui.Frame, list_view: ListRef) !void {
    if (!g_is_popover_open) return;
    const ui_state = context.ui();
    const dialog = try widgets.openPopover(context, POPOVER_KEY, &g_is_popover_open, widgets.measuredBox(ui_state, partKey(g_selected)));
    if (try settings(context, list_view, g_selected)) {
        g_is_popover_open = false;
        context.requestRedraw();
    }
    const reason = try widgets.closePopover(context, dialog);
    if (reason != .backdrop) return;
    const mouse = ui_state.input.mouse_pos;
    const point = [2]f32{ @floatCast(mouse[0]), @floatCast(mouse[1]) };
    for (std.enums.values(Part)) |part| {
        if (part != g_selected and widgets.measuredBox(ui_state, partKey(part)).contains(point)) select(context, part);
    }
}

/// Returns whether close was pressed.
fn settings(context: *ui.Frame, list_view: ListRef, part: Part) !bool {
    const is_close_clicked = try widgets.popoverTitle(context, .src(@src()), part.label());
    try requirementNotices(context, part);
    const profile = session.profile();

    const was_aligned = widgets.useAlignedRows(true);
    defer _ = widgets.useAlignedRows(was_aligned);
    const was_compact = widgets.useCompactRows(true);
    defer _ = widgets.useCompactRows(was_compact);
    const follows_thumbnails = session.showsThumbnails();
    switch (part) {
        .active => {
            if (follows_thumbnails) {
                try widgets.notice(context, .src(@src()), "Follows the thumbnails' active border color.");
                return is_close_clicked;
            }
            try bind.toggle(context, list_view, "useUniqueActiveColors", "Unique Character Active Colors");
            try widgets.hintText(context, .src(@src()), "Each character's mark gets its own color.");
            const group = try widgets.openGroup(context, .src(@src()), !list_view.get("useUniqueActiveColors"));
            try bind.optionalColor(context, list_view, "activeColor", "Active Color", profile.ptr.accentColor);
            try widgets.hintText(context, .src(@src()), "Marks the client you're in.");
            try group.close(context);
        },
        // The list's own in every view mode, unlike its other colors.
        .names => {
            try bind.toggle(context, list_view, "useUniqueCharacterNameColors", "Unique Character Name Colors");
            try widgets.hintText(context, .src(@src()), "Each character's name gets its own color.");
        },
        .systems => {
            try bind.toggle(context, list_view, "showSystemName", "Show System Name");
            try widgets.hintText(context, .src(@src()), "Needs Log Monitoring to know where each character is.");
            const security = try widgets.openGroup(context, .src(@src()), list_view.get("showSystemName"));
            try bind.toggle(context, list_view, "showSystemSecurity", "Show Security Status");
            try widgets.hintText(context, .src(@src()), "Beside the system's name, in the game's colors.");
            try security.close(context);
            if (follows_thumbnails) {
                try widgets.notice(context, .src(@src()), "Colors follow the thumbnails' system name settings.");
                return is_close_clicked;
            }
            const shown = try widgets.openGroup(context, .src(@src()), list_view.get("showSystemName"));
            try bind.toggle(context, list_view, "useUniqueSystemColors", "Unique System Colors");
            try widgets.hintText(context, .src(@src()), "Each system gets its own color; System Colors overrides it.");
            const group = try widgets.openGroup(context, .src(@src()), !list_view.get("useUniqueSystemColors"));
            try bind.rgb(context, list_view, "systemNameColor", "Text Color");
            try widgets.hintText(context, .src(@src()), "Used while unique colors are off.");
            try group.close(context);
            try shown.close(context);
        },
        .notifications => {
            try bind.toggle(context, list_view, "showNotifications", "Show Alerts");
            try widgets.hintText(context, .src(@src()), "Shows alert text, like Fleet Invite, in the list.");
            const shown = try widgets.openGroup(context, .src(@src()), list_view.get("showNotifications"));
            try bind.rgb(context, list_view, "notificationColor", "Text Color");
            try widgets.hintText(context, .src(@src()), "The color of this text.");
            try shown.close(context);
        },
        .incoming_dps => try statSettings(context, list_view, profile.child("combat"), .{
            .overlay_label = "Enable Combat Overlays",
            .show_field = "showIncomingDps",
            .show_label = "Show Incoming Damage",
            .show_hint = "Damage the character is taking per second.",
            .prefix_field = "showIncomingPrefix",
            .prefix_label = "Show IN: Prefix",
            .prefix_hint = "Puts IN: before the number so it's easy to tell apart.",
            .color_field = "incomingDpsColor",
        }),
        .outgoing_dps => try statSettings(context, list_view, profile.child("combat"), .{
            .overlay_label = "Enable Combat Overlays",
            .show_field = "showOutgoingDps",
            .show_label = "Show Outgoing Damage",
            .show_hint = "Damage the character is dealing per second.",
            .prefix_field = "showOutgoingPrefix",
            .prefix_label = "Show OUT: Prefix",
            .prefix_hint = "Puts OUT: before the number so it's easy to tell apart.",
            .color_field = "outgoingDpsColor",
        }),
        .mining_rate => try statSettings(context, list_view, profile.child("mining"), .{
            .overlay_label = "Enable Mining Overlay",
            .show_field = "showMiningRate",
            .show_label = "Show Mining Rate",
            .show_hint = "How much the character mines.",
            .prefix_field = "showMiningPrefix",
            .prefix_label = "Show M: Prefix",
            .prefix_hint = "Puts M: before the rate so it's easy to tell apart.",
            .color_field = "miningRateColor",
        }),
        .bounty_rate => try statSettings(context, list_view, profile.child("bounty"), .{
            .overlay_label = "Enable Bounty Overlay",
            .show_field = "showBountyRate",
            .show_label = "Show Bounty Rate",
            .show_hint = "ISK the character earns from bounties.",
            .prefix_field = "showBountyPrefix",
            .prefix_label = "Show ISK: Prefix",
            .prefix_hint = "Puts ISK: before the rate so it's easy to tell apart.",
            .color_field = "bountyRateColor",
        }),
        .totals => {
            try bind.toggle(context, list_view, "showTotals", "Show Totals");
            try widgets.hintText(context, .src(@src()), "Adds up the rates the rows show; ~ means some clients are still being measured.");
        },
    }
    return is_close_clicked;
}

/// What else has to be on for the part's text to show, as the thumbnail preview's popovers say.
fn requirementNotices(context: *ui.Frame, part: Part) !void {
    const profile = session.profile().ptr;
    const is_monitoring = session.global().ptr.chatlog.enabled;
    const needs_chatlog = switch (part) {
        .active, .names, .notifications => false,
        .systems, .incoming_dps, .outgoing_dps, .mining_rate, .bounty_rate, .totals => true,
    };
    if (needs_chatlog and !is_monitoring) try widgets.notice(context, .src(@src()), "Requires Log Monitoring to be enabled.");
    const stat_settings: list_look.StatSettings = .{ .list_settings = &profile.listView, .combat = &profile.combat, .mining = &profile.mining, .bounty = &profile.bounty };
    if (part == .totals and !list_look.showsAnyStat(stat_settings)) try widgets.notice(context, .src(@src()), "Needs at least one rate shown on the rows.");
    if (part == .notifications and !is_monitoring) try widgets.notice(context, .src(@src()), "Without Log Monitoring, only alerts for your own actions, like Profile Switch, are shown.");
    if (part == .notifications and !profile.thumbnail.notifications.enabled) try widgets.notice(context, .src(@src()), "Requires alerts switched on in the Alert Options tab.");
}

/// `overlay` is the rate's overlay session.Ref; its `enabled`, shared with the thumbnails, gates the list's rate.
fn statSettings(context: *ui.Frame, list_view: ListRef, overlay: anytype, comptime rows: StatRows) !void {
    try bind.toggle(context, overlay, "enabled", rows.overlay_label);
    try widgets.hintText(context, .str("knots.client_list.overlay.hint:" ++ rows.show_field), "Also turns it on for thumbnails.");
    const enabled = try widgets.openGroup(context, .str("knots.client_list.overlay:" ++ rows.show_field), overlay.get("enabled"));
    try bind.toggle(context, list_view, rows.show_field, rows.show_label);
    try widgets.hintText(context, .str("knots.client_list.shown.hint:" ++ rows.show_field), rows.show_hint);
    const shown = try widgets.openGroup(context, .str("knots.client_list.shown:" ++ rows.show_field), list_view.get(rows.show_field));
    try bind.toggle(context, list_view, rows.prefix_field, rows.prefix_label);
    try widgets.hintText(context, .str("knots.client_list.prefix.hint:" ++ rows.show_field), rows.prefix_hint);
    try bind.rgb(context, list_view, rows.color_field, "Text Color");
    try widgets.hintText(context, .str("knots.client_list.color.hint:" ++ rows.show_field), "The color of this text.");
    try shown.close(context);
    try enabled.close(context);
}
