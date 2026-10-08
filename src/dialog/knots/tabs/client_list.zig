//! The Display tab's Client List section: a preview of the panel whose parts are clicked to edit them in a popover, then the panel's other settings; main thread only.
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
/// How faded a part's text is while it's turned off.
const HIDDEN_OPACITY = 0.35;
/// About a space's width as a share of the font size, which the panel puts between rates.
const SPACE_EM = 0.3;

/// The stats row's sample rates: DPS only, since every rate at once runs past a column.
const SAMPLE_STATS = [_]Sample.Reading{ .{ .stat = .incoming_dps, .value = 412 }, .{ .stat = .outgoing_dps, .value = 980 } };
const SAMPLE_NOTIFICATION = "Fleet Invite";
const SAMPLES = [_]Sample{
    .{ .name = "Pilot Alpha", .state = .active, .system = "Jita" },
    .{ .name = "Pilot Bravo", .state = .inactive, .system = "Perimeter", .is_name_part = true },
    .{ .name = "Pilot Delta", .state = .inactive, .right = .notification },
    .{ .name = "Pilot Echo", .state = .inactive, .right = .stats },
    .{ .name = "Pilot Charlie", .state = .excluded },
};

/// What a click on the preview opens.
const Part = enum {
    active,
    names,
    systems,
    notifications,
    stats,

    fn label(self: Part) []const u8 {
        return switch (self) {
            .active => "Active Client",
            .names => "Character Names",
            .systems => "System Names",
            .notifications => "Notifications",
            .stats => "Combat, Mining and Bounty",
        };
    }
};

const Sample = struct {
    /// A rate the stats row shows.
    const Reading = struct { stat: list_look.Stat, value: f32 };

    name: []const u8,
    state: enum { active, inactive, excluded },
    /// What its right-hand slot shows; the system's name is `system`.
    right: enum { system, notification, stats } = .system,
    system: []const u8 = "",
    /// Only one row's name opens Character Names, since a part has one key.
    is_name_part: bool = false,
};

/// One rate on the stats row, as the panel draws it.
const StatLabel = struct { text: []const u8, color: u32 };

/// The preview's colours and text sizes, read from the edited settings.
const Look = struct {
    active_color: u32,
    active_name_color: u32,
    name_color: u32,
    system_color: u32,
    name_size: f32,
    small_size: f32,
    shows_systems: bool,
    shows_notifications: bool,
    indicator: types.ListIndicatorStyle,
    /// The stats row's rates, each in its own colour; faded while the list shows none.
    stats: []const StatLabel,
    shows_stats: bool,
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

    try bind.choiceStyled(context, display, "listViewOrder", "Order", &style.select_wide);
    try bind.number(context, display, "listViewColumns", "Columns", .{});
    try bind.number(context, display, "listViewColumnWidth", "Column Width", .{ .unit = "px" });
    try bind.slider(context, display, "listViewOpacity", "Opacity", .{ .display = .percent_of_255 });
    const font = try widgets.openBinding(context, .src(@src()), "Font");
    try bind.fontBox(context, display, "listViewFontName");
    try bind.unitNumberBox(context, display, "listViewFontSize", "px", .{});
    try bind.choiceBox(context, display, "listViewFontWeight", &style.select_narrow);
    try font.close(context);
    try bind.segmented(context, display, "listViewIndicatorStyle", "Indicator", &.{ "Dot", "Square", "Bar", "None" });
    try bind.toggle(context, display, "rememberListViewPosition", "Remember Position");
    try bind.toggle(context, display, "listViewHideWhenNoEveFocus", "Hide When No EVE Focus");
    try widgets.hintText(context, .src(@src()), "Hides the list while no EVE client window has focus.");
    try bind.number(context, display, "listViewHideDebounceMs", "Hide Delay", .{ .ms_as_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "Delay before hiding, so switching briefly doesn't flicker.");
    try section.close(context);
    try popover(context, display);
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
        .background = argb(list_look.PANEL),
        .border_width = .all(1),
        .border_color = argb(list_look.BORDER),
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
        .border_color = argb(list_look.DIVIDER),
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
    const row_style = try arena.create(ui.Style);
    row_style.* = .{
        .width = .grow(),
        .height = .fixed(look.px(look.sizes.row_height)),
        .direction = .row,
        .@"align" = .center,
        .gap = look.px(list_look.INDICATOR_GAP),
        // A bar runs down the row's very edge.
        .padding = .init(0, look.px(list_look.PADDING_X), 0, if (look.indicator == .Bar) 0 else look.px(list_look.PADDING_X)),
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

/// An inactive row's right-hand slot, as the part that edits what it shows.
fn rightPart(context: *ui.Frame, sample: Sample, key: ui.Key, look: Look) !void {
    const arena = context.arena();
    const part: Part = switch (sample.right) {
        .system => .systems,
        .notification => .notifications,
        .stats => .stats,
    };
    const button = Button{ .key = partKey(part), .style = try partStyle(arena, look, .{ .gap = look.small_size * SPACE_EM }, list_look.PANEL, part) };
    if (try openPart(context, button, part)) select(context, part);
    switch (sample.right) {
        .system => try context.e(Text{ .selectable = false, .key = key, .content = sample.system, .style = try textStyle(arena, look.system_color, look.small_size, false, look.shows_systems) }),
        .notification => try context.e(Text{ .selectable = false, .key = key, .content = SAMPLE_NOTIFICATION, .style = try textStyle(arena, list_look.NOTIFICATION_TEXT, look.small_size, false, look.shows_notifications) }),
        .stats => for (look.stats, 0..) |label, index| {
            try context.e(Text{ .selectable = false, .key = key.indexed(index), .content = label.text, .style = try textStyle(arena, label.color, look.small_size, false, look.shows_stats) });
        },
    }
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

    var readings: [SAMPLE_STATS.len]list_look.StatReading = undefined;
    var count: usize = 0;
    for (SAMPLE_STATS) |sample| {
        if (!list_look.showsStat(stat_settings, sample.stat)) continue;
        readings[count] = .{ .stat = sample.stat, .value = sample.value, .has_prefix = list_look.hasPrefix(display, sample.stat) };
        count += 1;
    }
    const shows_stats = count > 0;
    // With none shown, every sample stands in, faded, so the part can still be clicked.
    if (!shows_stats) {
        for (SAMPLE_STATS, &readings) |sample, *reading| {
            reading.* = .{ .stat = sample.stat, .value = sample.value, .has_prefix = list_look.hasPrefix(display, sample.stat) };
        }
        count = SAMPLE_STATS.len;
    }
    const stats = try arena.alloc(StatLabel, count);
    for (readings[0..count], stats) |reading, *label| {
        var writer: std.Io.Writer = .fixed(try arena.alloc(u8, list_look.STAT_TEXT_MAX));
        list_look.writeStat(&writer, reading);
        label.* = .{ .text = writer.buffered(), .color = list_look.statColor(display, reading.stat) };
    }

    return .{
        .active_color = active_color,
        .active_name_color = if (uses_unique_names) style.UNIQUE_SAMPLE else list_look.activeNameColor(active_color),
        .name_color = if (uses_unique_names) style.UNIQUE_SAMPLE else list_look.NAME,
        .system_color = if (display.listViewUseUniqueSystemColors) style.UNIQUE_SAMPLE else display.listViewSystemNameColor,
        .name_size = @as(f32, @floatFromInt(display.listViewFontSize)) * scale,
        .small_size = @as(f32, @floatFromInt(list_look.smallFontSize(display.listViewFontSize))) * scale,
        .shows_systems = display.listViewShowSystemName,
        .shows_notifications = display.listViewShowNotifications,
        .indicator = display.listViewIndicatorStyle,
        .stats = stats,
        .shows_stats = shows_stats,
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
        .background = argb(background),
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
    return PART_KEY.indexed(@intFromEnum(part));
}

fn indicator(context: *ui.Frame, key: ui.Key, color: u32, look: Look) !void {
    const radius = look.px(list_look.BADGE_RADIUS);
    const shape: ui.Style = switch (look.indicator) {
        .Dot => .{ .width = .fixed(radius * 2), .height = .fixed(radius * 2), .radius = .{ .fixed = radius } },
        .Square => .{ .width = .fixed(radius * 2), .height = .fixed(radius * 2) },
        .Bar => .{ .width = .fixed(look.px(list_look.BAR_WIDTH)), .height = .grow() },
        .None => return,
    };
    const indicator_shape = try context.arena().create(ui.Style);
    indicator_shape.* = shape.with(.{ .background = argb(color) });
    try context.e(Rect{ .key = key, .style = indicator_shape });
}

/// Faded while `is_shown` is off, so a part whose text is turned off can still be clicked to turn it back on.
fn textStyle(arena: std.mem.Allocator, color: u32, size: f32, is_grown: bool, is_shown: bool) !*const ui.Style {
    const text_style = try arena.create(ui.Style);
    text_style.* = .{
        .foreground = argb(color),
        .font_size = .{ .px = size },
        .opacity = if (is_shown) 1 else HIDDEN_OPACITY,
    };
    if (is_grown) text_style.width = .grow();
    return text_style;
}

fn argb(color: u32) ui.Color.Input {
    return .{ .color = widgets.colorFromArgb(color | 0xFF000000) };
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

    const was_aligned = widgets.useAlignedRows(true);
    defer _ = widgets.useAlignedRows(was_aligned);
    switch (part) {
        .active => {
            try bind.toggle(context, display, "listViewUseUniqueActiveColors", "Unique Character Active Colors");
            const group = try widgets.openGroup(context, .src(@src()), !display.get("listViewUseUniqueActiveColors"));
            try bind.rgb(context, display, "listViewActiveColor", "Active Color");
            try group.close(context);
            try widgets.paragraph(context, .src(@src()), "Colours the active client's dot, row and name. A character's own active border colour on the Characters tab comes first.");
        },
        .names => {
            try bind.toggle(context, display, "listViewUseUniqueCharacterNameColors", "Unique Character Name Colors");
            try widgets.paragraph(context, .src(@src()), "A character's own name colour on the Characters tab comes first.");
        },
        .systems => {
            try bind.toggle(context, display, "listViewShowSystemName", "Show System Name");
            try bind.toggle(context, display, "listViewUseUniqueSystemColors", "Unique System Colors");
            const group = try widgets.openGroup(context, .src(@src()), !display.get("listViewUseUniqueSystemColors"));
            try bind.rgb(context, display, "listViewSystemNameColor", "System Name Color");
            try group.close(context);
            try widgets.paragraph(context, .src(@src()), "A system's own custom colour comes first.");
        },
        .notifications => {
            try bind.toggle(context, display, "listViewShowNotifications", "Show Notifications");
            try widgets.paragraph(context, .src(@src()), "The newest notification takes a row's right-hand slot until it expires. Each type's colour is set on the Notifications tab.");
        },
        .stats => try statSettings(context, display),
    }
    return close_clicked;
}

fn statSettings(context: *ui.Frame, display: DisplayRef) !void {
    try widgets.subheading(context, .src(@src()), "Incoming DPS");
    try bind.toggle(context, display, "listViewShowIncomingDps", "Show Incoming DPS");
    const incoming = try widgets.openGroup(context, .src(@src()), display.get("listViewShowIncomingDps"));
    try bind.toggle(context, display, "listViewShowIncomingPrefix", "Show IN: Prefix");
    try bind.rgb(context, display, "listViewIncomingDpsColor", "Text Color");
    try incoming.close(context);

    try widgets.subheading(context, .src(@src()), "Outgoing DPS");
    try bind.toggle(context, display, "listViewShowOutgoingDps", "Show Outgoing DPS");
    const outgoing = try widgets.openGroup(context, .src(@src()), display.get("listViewShowOutgoingDps"));
    try bind.toggle(context, display, "listViewShowOutgoingPrefix", "Show OUT: Prefix");
    try bind.rgb(context, display, "listViewOutgoingDpsColor", "Text Color");
    try outgoing.close(context);

    try widgets.subheading(context, .src(@src()), "Mining Rate");
    try bind.toggle(context, display, "listViewShowMiningRate", "Show Mining Rate");
    const mining = try widgets.openGroup(context, .src(@src()), display.get("listViewShowMiningRate"));
    try bind.toggle(context, display, "listViewShowMiningPrefix", "Show M: Prefix");
    try bind.rgb(context, display, "listViewMiningRateColor", "Text Color");
    try mining.close(context);

    try widgets.subheading(context, .src(@src()), "Bounty Rate");
    try bind.toggle(context, display, "listViewShowBountyRate", "Show Bounty Rate");
    const bounty = try widgets.openGroup(context, .src(@src()), display.get("listViewShowBountyRate"));
    try bind.toggle(context, display, "listViewShowBountyPrefix", "Show ISK: Prefix");
    try bind.rgb(context, display, "listViewBountyRateColor", "Text Color");
    try bounty.close(context);

    try widgets.paragraph(context, .src(@src()), "A row shows these together, each in its own colour. Each also needs its overlay enabled on the Combat, Mining or Bounty tab.");
}
