//! The Appearance tab's Client List sections: a preview of the panel whose parts are clicked to edit them in a popover, then the panel's other settings; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../config.zig");
const types = @import("../../../config/types.zig");
const list_look = @import("../../../thumbnail/list_look.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const DisplayRef = session.Ref(config.DisplayConfig);

const POPOVER_KEY: ui.Key = .str("knots.client_list.popover");
const PART_KEY: ui.Key = .str("knots.client_list.part");
const ROW_KEY: ui.Key = .str("knots.client_list.row");
const LINE_KEY: ui.Key = .str("knots.client_list.line");
const STAGE_KEY: ui.Key = .str("knots.client_list.stage");
/// One line of sample rows, one per column.
const SAMPLE_LINE: ui.Style = .{ .width = .grow(), .direction = .row };
/// How much a clickable part's outline pads its text, in real pixels.
const PART_PADDING: i32 = 3;
/// One row's rates side by side, each its own part.
const STATS_GROUP: ui.Style = .{ .direction = .row, .@"align" = .center };

/// Each rate's sample, in list_look.Stat order: mining in m3 per minute, bounty in ISK per period.
const SAMPLE_VALUES = [list_look.STAT_COUNT]f32{ 412, 980, 21.4, 38_200_000 };
/// Drawn in Fleet Invite's own colour, or the list's notification colour when it has none.
const SAMPLE_NOTIFICATION = "Fleet Invite";
/// Two rates to a stats row, so each fits a column.
const SAMPLES = [_]Sample{
    .{ .name = "Pilot Alpha", .state = .active, .system = "Jita" },
    .{ .name = "Pilot Bravo", .state = .inactive, .system = "Perimeter", .is_name_part = true },
    .{ .name = "Pilot Delta", .state = .inactive, .right = .notification },
    .{ .name = "Pilot Echo", .state = .inactive, .right = .{ .stats = &.{ .incoming_dps, .outgoing_dps } } },
    .{ .name = "Pilot Foxtrot", .state = .inactive, .right = .{ .stats = &.{ .mining_rate, .bounty_rate } } },
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

    fn label(self: Part) []const u8 {
        return switch (self) {
            .active => "Active Client",
            .names => "Character Names",
            .systems => "System Names",
            .notifications => "Notifications",
            .incoming_dps => "Incoming DPS",
            .outgoing_dps => "Outgoing DPS",
            .mining_rate => "Mining Rate",
            .bounty_rate => "Bounty Rate",
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
    right: union(enum) { system, notification, stats: []const list_look.Stat } = .system,
    system: []const u8 = "",
    /// Only one row's name opens Character Names, since a part has one key.
    is_name_part: bool = false,
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
    shows_notifications: bool,
    indicator: types.ListIndicatorStyle,
    /// Every rate, in list_look.Stat order.
    stat_labels: [list_look.STAT_COUNT]StatLabel,
    sizes: list_look.Metrics,
    columns: usize,
    /// Shrinks the preview to fit its section; 1 at real size.
    scale: f32,

    /// `pixels` real pixels at the preview's scale.
    fn px(self: Look, pixels: i32) f32 {
        return @as(f32, @floatFromInt(pixels)) * self.scale;
    }
};

var g_selected: Part = .names;
var g_is_popover_open: bool = false;

/// Once the window has closed.
pub fn reset() void {
    g_is_popover_open = false;
}

pub fn show(context: *ui.Frame, display: DisplayRef) !void {
    const section = try widgets.openSection(context, "Client List", "A compact panel listing each client by name; click a name to bring that client to the front. Click a part of the preview to change it.", &style.section);
    const ui_state = context.ui();
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, STAGE_KEY.hash());
    const available_width = widgets.measuredBox(ui_state, STAGE_KEY).w();
    // Not laid out yet, so draw once more knowing the room there is.
    if (available_width == 0) context.requestRedraw();
    const stage = Rect{ .key = STAGE_KEY, .style = &style.stage_row };
    _ = try stage.open(context);
    const look = try lookOf(context.arena(), session.profile().ptr, available_width);
    try preview(context, &session.profile().ptr.display, look);
    try stage.close(context);
    if (look.scale < 1) try widgets.paragraph(context, .src(@src()), "Shrunk to fit; the list itself is wider.");
    try section.close(context);

    try layout(context, display);
    try appearance(context, display);
    try visibility(context, display);
    try popover(context, display);
}

fn layout(context: *ui.Frame, display: DisplayRef) !void {
    const section = try widgets.openSection(context, "Layout", "How the list orders and arranges its clients.", &style.section);
    try bind.choice(context, display, "listViewOrder", "Order");
    try bind.number(context, display, "listViewColumns", "Columns", .{});
    try bind.number(context, display, "listViewColumnWidth", "Column Width", .{ .unit = "px" });
    try bind.segmented(context, display, "listViewIndicatorStyle", "Indicator", &.{ "Dot", "Square", "None" });
    try section.close(context);
}

fn appearance(context: *ui.Frame, display: DisplayRef) !void {
    const section = try widgets.openSection(context, "Appearance", "The list's font, and how see-through it is.", &style.section);
    const font = try widgets.openBinding(context, .src(@src()), "Font");
    try bind.fontBox(context, display, "listViewFontName");
    try bind.unitNumberBox(context, display, "listViewFontSize", "px", .{});
    try bind.choiceBox(context, display, "listViewFontWeight");
    try font.close(context);
    try bind.slider(context, display, "listViewOpacity", "Opacity", .{ .display = .percent_of_255 });
    try section.close(context);
}

fn visibility(context: *ui.Frame, display: DisplayRef) !void {
    const section = try widgets.openSection(context, "Position and Visibility", "Where the list opens, and when it's hidden automatically.", &style.section);
    try bind.toggle(context, display, "rememberListViewPosition", "Remember Position");
    try bind.toggle(context, display, "listViewHideWhenNoEveFocus", "Hide When No EVE Focus");
    try widgets.hintText(context, .src(@src()), "Hides the list while no EVE client window has focus.");
    const delay = try widgets.openGroup(context, .src(@src()), display.get("listViewHideWhenNoEveFocus"));
    try bind.number(context, display, "listViewHideDebounceMs", "Hide Delay", .{ .ms_as_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "Delay before hiding, so switching briefly doesn't flicker.");
    try delay.close(context);
    try section.close(context);
}

/// The panel in list_look's look, with sample clients, at `look.scale`.
fn preview(context: *ui.Frame, display: *const config.DisplayConfig, look: Look) !void {
    const arena = context.arena();
    const columns = look.columns;
    const panel_style = try arena.create(ui.Style);
    panel_style.* = .{
        .width = .fixed(look.px(look.sizes.column_width * @as(i32, @intCast(columns)))),
        .direction = .column,
        .padding = .init(0, 0, look.px(list_look.BOTTOM_PADDING), 0),
        .background = widgets.solidColor(list_look.PANEL),
        .border_width = .all(1),
        .border_color = widgets.solidColor(list_look.BORDER),
        .radius = .{ .fixed = look.px(@intCast(list_look.CORNER_RADIUS)) },
        .opacity = @as(f32, @floatFromInt(display.listViewOpacity)) / 255.0,
        .overflow = .hidden,
    };
    const panel = Rect{ .key = .src(@src()), .style = panel_style };
    _ = try panel.open(context);

    const header_style = try arena.create(ui.Style);
    header_style.* = .{
        .width = .grow(),
        .height = .fixed(look.px(look.sizes.header_height)),
        .direction = .row,
        .@"align" = .center,
        .padding = .xy(look.px(list_look.PADDING_X), 0),
        .border_width = .edges(0, 0, 1, 0),
        .border_color = widgets.solidColor(list_look.DIVIDER),
    };
    const header = Rect{ .key = .src(@src()), .style = header_style };
    _ = try header.open(context);
    const header_text = list_look.headerText(try arena.create([list_look.HEADER_TEXT_MAX]u8), SAMPLES.len);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = header_text, .style = try textStyle(arena, list_look.MUTED, look.small_size, false, true) });
    try header.close(context);

    // Row by row across the columns, as the panel lays its rows out; a short last line keeps its cells' width.
    const empty_cell = try arena.create(ui.Style);
    empty_cell.* = .{ .width = .grow(), .height = .fixed(look.px(look.sizes.row_height)) };
    var first: usize = 0;
    while (first < SAMPLES.len) : (first += columns) {
        const line = Rect{ .key = LINE_KEY.indexed(first), .style = &SAMPLE_LINE };
        _ = try line.open(context);
        for (first..first + columns) |index| {
            if (index < SAMPLES.len) {
                try sampleRow(context, SAMPLES[index], index, look);
            } else {
                try context.e(Rect{ .key = ROW_KEY.indexed(index), .style = empty_cell });
            }
        }
        try line.close(context);
    }
    try panel.close(context);
}

/// The active row is one part; an inactive row's right-hand slot is one, and so is one row's name.
fn sampleRow(context: *ui.Frame, sample: Sample, index: usize, look: Look) !void {
    const arena = context.arena();
    const key = ROW_KEY.indexed(index);
    // A part pads its text for its outline, so the space before a name part and after a right-hand part gives that back.
    const name_inset: f32 = if (sample.is_name_part) look.px(PART_PADDING) else 0;
    const right_inset: f32 = if (sample.state == .inactive) look.px(PART_PADDING) else 0;
    const has_indicator = look.indicator != .None;
    const row_style = try arena.create(ui.Style);
    row_style.* = .{
        .width = .grow(),
        .height = .fixed(look.px(look.sizes.row_height)),
        .direction = .row,
        .@"align" = .center,
        .gap = look.px(list_look.INDICATOR_GAP) - (if (has_indicator) name_inset else 0),
        .padding = .init(0, look.px(list_look.PADDING_X) - right_inset, 0, look.px(list_look.PADDING_X) - (if (has_indicator) 0 else name_inset)),
    };
    switch (sample.state) {
        .active => {
            const button_style = try partStyle(arena, look, row_style.*, list_look.activeTint(look.active_color), .active);
            const row = Button{ .key = partKey(.active), .style = button_style };
            if (try openPart(context, row, .active)) select(context, .active);
            try indicator(context, key.indexed(1), look.active_color, look);
            try context.e(Text{ .selectable = false, .key = key.indexed(2), .content = sample.name, .style = try textStyle(arena, look.active_name_color, look.name_size, true, true) });
            try context.e(Text{ .selectable = false, .key = key.indexed(3), .content = sample.system, .style = try textStyle(arena, look.system_color, look.small_size, false, look.shows_systems) });
            try row.close(context);
        },
        .inactive => {
            const row = Rect{ .key = key, .style = row_style };
            _ = try row.open(context);
            try indicator(context, key.indexed(1), list_look.BADGE_INACTIVE, look);
            const name = Text{ .selectable = false, .key = key.indexed(2), .content = sample.name, .style = try textStyle(arena, look.name_color, look.name_size, !sample.is_name_part, true) };
            if (sample.is_name_part) {
                const part = Button{ .key = partKey(.names), .style = try partStyle(arena, look, .{ .width = .grow() }, list_look.PANEL, .names) };
                if (try openPart(context, part, .names)) select(context, .names);
                try context.e(name);
                try part.close(context);
            } else {
                try context.e(name);
            }
            try rightPart(context, sample, key.indexed(3), look);
            try row.close(context);
        },
        .excluded => {
            const row = Rect{ .key = key, .style = row_style };
            _ = try row.open(context);
            try indicator(context, key.indexed(1), list_look.BADGE_EXCLUDED, look);
            try context.e(Text{ .selectable = false, .key = key.indexed(2), .content = sample.name, .style = try textStyle(arena, list_look.MUTED, look.name_size, true, true) });
            try context.e(Text{ .selectable = false, .key = key.indexed(3), .content = "Excluded", .style = try textStyle(arena, list_look.MUTED, look.small_size, false, true) });
            try row.close(context);
        },
    }
}

/// An inactive row's right-hand slot, as the parts that edit what it shows.
fn rightPart(context: *ui.Frame, sample: Sample, key: ui.Key, look: Look) !void {
    const arena = context.arena();
    switch (sample.right) {
        .system => try textPart(context, .systems, key, sample.system, try textStyle(arena, look.system_color, look.small_size, false, look.shows_systems), look),
        .notification => try textPart(context, .notifications, key, SAMPLE_NOTIFICATION, try textStyle(arena, look.notification_color, look.small_size, false, look.shows_notifications), look),
        .stats => |stats| {
            const group = Rect{ .key = key, .style = &STATS_GROUP };
            _ = try group.open(context);
            for (stats, 1..) |stat, index| {
                const label = look.stat_labels[@backingInt(stat)];
                try textPart(context, .ofStat(stat), key.indexed(index), label.text, try textStyle(arena, label.color, look.small_size, false, label.is_shown), look);
            }
            try group.close(context);
        },
    }
}

/// `content` as the part that edits it.
fn textPart(context: *ui.Frame, part: Part, key: ui.Key, content: []const u8, text_style: *const ui.Style, look: Look) !void {
    const button = Button{ .key = partKey(part), .style = try partStyle(context.arena(), look, .{}, list_look.PANEL, part) };
    if (try openPart(context, button, part)) select(context, part);
    try context.e(Text{ .selectable = false, .key = key, .content = content, .style = text_style });
    try button.close(context);
}

/// A unique colour varies per character or system, so a sample stands in for it.
fn lookOf(arena: std.mem.Allocator, profile: *const config.Config, available_width: f32) !Look {
    const display = &profile.display;
    const sizes = list_look.metrics(display);
    const columns: usize = @intCast(list_look.effectiveColumns(display.listViewColumns, SAMPLES.len));
    const panel_width: f32 = @floatFromInt(sizes.column_width * @as(i32, @intCast(columns)));
    const scale = if (available_width > 0 and panel_width > available_width) available_width / panel_width else 1;
    const active_color = if (display.listViewUseUniqueActiveColors) style.UNIQUE_SAMPLE else display.listViewActiveColor;
    const uses_unique_names = display.listViewUseUniqueCharacterNameColors;
    const stat_settings: list_look.StatSettings = .{ .display = display, .combat = &profile.combat, .mining = &profile.mining, .bounty = &profile.bounty };

    var stat_labels: [list_look.STAT_COUNT]StatLabel = undefined;
    for (std.enums.values(list_look.Stat), SAMPLE_VALUES, &stat_labels) |stat, value, *label| {
        var writer: std.Io.Writer = .fixed(try arena.alloc(u8, list_look.STAT_TEXT_MAX));
        list_look.writeStat(&writer, .{ .stat = stat, .value = value, .has_prefix = list_look.hasPrefix(display, stat) });
        label.* = .{ .text = writer.buffered(), .color = list_look.statColor(display, stat), .is_shown = list_look.showsStat(stat_settings, stat) };
    }

    return .{
        .active_color = active_color,
        .active_name_color = if (uses_unique_names) style.UNIQUE_SAMPLE else list_look.activeNameColor(active_color),
        .name_color = if (uses_unique_names) style.UNIQUE_SAMPLE else list_look.NAME,
        .notification_color = profile.thumbnail.notifications.getTypeConfig(.FleetInvite).text_color orelse display.listViewNotificationColor,
        .system_color = if (display.listViewUseUniqueSystemColors) style.UNIQUE_SAMPLE else display.listViewSystemNameColor,
        .name_size = @as(f32, @floatFromInt(display.listViewFontSize)) * scale,
        .small_size = @as(f32, @floatFromInt(list_look.smallFontSize(display.listViewFontSize))) * scale,
        .shows_systems = display.listViewShowSystemName,
        .shows_notifications = display.listViewShowNotifications,
        .indicator = display.listViewIndicatorStyle,
        .stat_labels = stat_labels,
        .sizes = sizes,
        .columns = columns,
        .scale = scale,
    };
}

/// Outlined while hovered, and while its popover is open.
fn partStyle(arena: std.mem.Allocator, look: Look, base: ui.Style, background: u32, part: Part) !*const ui.Style {
    const is_selected = g_is_popover_open and g_selected == part;
    const part_style = try arena.create(ui.Style);
    part_style.* = base.with(.{
        // A Button centres its content, which pushes a row with a growing name off its right edge.
        .justify = .start,
        .background = widgets.solidColor(background),
        .border_width = .all(1),
        .border_color = if (is_selected) .accent else .transparent,
        .radius = .{ .fixed = 3 },
        .hover = &.{ .border_color = .accent, .state_layer = 0 },
        .active = &.{ .state_layer = 0 },
    });
    // The row's own padding already places the active row's content.
    if (part != .active) part_style.padding = .xy(look.px(PART_PADDING), 0);
    return part_style;
}

fn openPart(context: *ui.Frame, button: Button, part: Part) !bool {
    const ui_state = context.ui();
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, partKey(part).hash());
    const response = try button.openResponse(context);
    if (response.hovered) ui_state.requestCursor(.pointer);
    return response.clicked;
}

fn select(context: *ui.Frame, part: Part) void {
    g_selected = part;
    g_is_popover_open = true;
    context.requestRedraw();
}

fn partKey(part: Part) ui.Key {
    return PART_KEY.indexed(@backingInt(part));
}

fn indicator(context: *ui.Frame, key: ui.Key, color: u32, look: Look) !void {
    const radius = look.px(list_look.BADGE_RADIUS);
    const shape: ui.Style = switch (look.indicator) {
        .Dot => .{ .width = .fixed(radius * 2), .height = .fixed(radius * 2), .radius = .{ .fixed = radius } },
        .Square => .{ .width = .fixed(radius * 2), .height = .fixed(radius * 2) },
        .None => return,
    };
    const indicator_shape = try context.arena().create(ui.Style);
    indicator_shape.* = shape.with(.{ .background = widgets.solidColor(color) });
    try context.e(Rect{ .key = key, .style = indicator_shape });
}

/// Faded while `is_shown` is off, so a part whose text is turned off can still be clicked to turn it back on.
fn textStyle(arena: std.mem.Allocator, color: u32, size: f32, is_grown: bool, is_shown: bool) !*const ui.Style {
    const text_style = try arena.create(ui.Style);
    text_style.* = .{
        .foreground = widgets.solidColor(color),
        .font_size = .{ .px = size },
        .opacity = if (is_shown) 1 else style.OFF_TEXT_OPACITY,
    };
    if (is_grown) text_style.width = .grow();
    return text_style;
}

/// Beside the clicked part; a click on another part moves it there.
fn popover(context: *ui.Frame, display: DisplayRef) !void {
    if (!g_is_popover_open) return;
    const ui_state = context.ui();
    const dialog = try widgets.openPopover(context, POPOVER_KEY, &g_is_popover_open, widgets.measuredBox(ui_state, partKey(g_selected)));
    if (try settings(context, display, g_selected)) {
        g_is_popover_open = false;
        context.requestRedraw();
    }
    const reason = try dialog.closeResponse(context);
    if (reason != .backdrop) return;
    const mouse = ui_state.input.mouse_pos;
    const point = [2]f32{ @floatCast(mouse[0]), @floatCast(mouse[1]) };
    for (std.enums.values(Part)) |part| {
        if (part != g_selected and widgets.measuredBox(ui_state, partKey(part)).contains(point)) select(context, part);
    }
}

/// Returns whether close was pressed.
fn settings(context: *ui.Frame, display: DisplayRef, part: Part) !bool {
    const close_clicked = try widgets.popoverTitle(context, .src(@src()), part.label());
    try requirementNotices(context, part);

    const was_aligned = widgets.useAlignedRows(true);
    defer _ = widgets.useAlignedRows(was_aligned);
    switch (part) {
        .active => {
            try bind.toggle(context, display, "listViewUseUniqueActiveColors", "Unique Character Active Colors");
            const group = try widgets.openGroup(context, .src(@src()), !display.get("listViewUseUniqueActiveColors"));
            try bind.rgb(context, display, "listViewActiveColor", "Active Color");
            try group.close(context);
        },
        .names => try bind.toggle(context, display, "listViewUseUniqueCharacterNameColors", "Unique Character Name Colors"),
        .systems => {
            try bind.toggle(context, display, "listViewShowSystemName", "Show System Name");
            const shown = try widgets.openGroup(context, .src(@src()), display.get("listViewShowSystemName"));
            try bind.toggle(context, display, "listViewUseUniqueSystemColors", "Unique System Colors");
            const group = try widgets.openGroup(context, .src(@src()), !display.get("listViewUseUniqueSystemColors"));
            try bind.rgb(context, display, "listViewSystemNameColor", "Text Color");
            try group.close(context);
            try shown.close(context);
        },
        .notifications => {
            try bind.toggle(context, display, "listViewShowNotifications", "Show Notifications");
            const shown = try widgets.openGroup(context, .src(@src()), display.get("listViewShowNotifications"));
            try bind.rgb(context, display, "listViewNotificationColor", "Text Color");
            try shown.close(context);
        },
        .incoming_dps => try statSettings(context, display, "listViewShowIncomingDps", "Show Incoming Damage", "listViewShowIncomingPrefix", "Show IN: Prefix", "listViewIncomingDpsColor"),
        .outgoing_dps => try statSettings(context, display, "listViewShowOutgoingDps", "Show Outgoing Damage", "listViewShowOutgoingPrefix", "Show OUT: Prefix", "listViewOutgoingDpsColor"),
        .mining_rate => try statSettings(context, display, "listViewShowMiningRate", "Show Mining Rate", "listViewShowMiningPrefix", "Show M: Prefix", "listViewMiningRateColor"),
        .bounty_rate => try statSettings(context, display, "listViewShowBountyRate", "Show Bounty Rate", "listViewShowBountyPrefix", "Show ISK: Prefix", "listViewBountyRateColor"),
    }
    return close_clicked;
}

/// What else has to be on for the part's text to show, as the thumbnail preview's popovers say.
fn requirementNotices(context: *ui.Frame, part: Part) !void {
    const profile = session.profile().ptr;
    const needs_chatlog = switch (part) {
        .active, .names => false,
        .systems, .notifications, .incoming_dps, .outgoing_dps, .mining_rate, .bounty_rate => true,
    };
    if (needs_chatlog and !profile.chatlog.enabled) try widgets.notice(context, .src(@src()), "Requires Log Monitoring to be enabled.");
    if (part == .notifications and !profile.thumbnail.notifications.enabled) try widgets.notice(context, .src(@src()), "Requires Enable Notifications on the Notifications tab.");
    const missing_overlay: ?[]const u8 = switch (part) {
        .active, .names, .systems, .notifications => null,
        .incoming_dps, .outgoing_dps => if (profile.combat.enabled) null else "Requires the Combat overlay to be enabled on the Combat tab.",
        .mining_rate => if (profile.mining.enabled) null else "Requires the Mining overlay to be enabled on the Mining tab.",
        .bounty_rate => if (profile.bounty.enabled) null else "Requires the Bounty overlay to be enabled on the Bounty tab.",
    };
    if (missing_overlay) |text| try widgets.notice(context, .src(@src()), text);
}

fn statSettings(context: *ui.Frame, display: DisplayRef, comptime show_field: []const u8, show_label: []const u8, comptime prefix_field: []const u8, prefix_label: []const u8, comptime color_field: []const u8) !void {
    try bind.toggle(context, display, show_field, show_label);
    const shown = try widgets.openGroup(context, .str("knots.client_list.shown:" ++ show_field), display.get(show_field));
    try bind.toggle(context, display, prefix_field, prefix_label);
    try bind.rgb(context, display, color_field, "Text Color");
    try shown.close(context);
}
