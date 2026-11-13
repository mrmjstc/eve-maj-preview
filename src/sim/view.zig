//! The simulator window's contents, laid out like the configuration window: header, tab sidebar, client list and activity feed; main thread only.
const std = @import("std");
const ui = @import("ui");
const style = @import("../dialog/knots/style.zig");
const widgets = @import("../dialog/knots/widgets.zig");
const glyphs = @import("../dialog/knots/glyphs.zig");
const images = @import("../dialog/knots/images.zig");
const universe = @import("../map/universe.zig");
const fleet_mod = @import("fleet.zig");
const lines = @import("lines.zig");
const scenarios = @import("scenarios.zig");
const schedule = @import("schedule.zig");
const log = @import("../log.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Canvas = ui.component.Canvas;
const TextInput = ui.component.TextInput;
const SelectInput = ui.component.SelectInput;
const Fleet = fleet_mod.Fleet;
const Burst = fleet_mod.Burst;
const Scenario = scenarios.Scenario;
const Via = schedule.Via;
const slog = log.Scoped("sim");

/// How many "Test Client N" the list's footer button adds.
const QUICK_CLIENT_COUNT = 10;
const JOURNAL_KEY: ui.Key = .str("sim.journal");
const CLIENTS_KEY: ui.Key = .str("sim.clients");
const CONTENT_KEY: ui.Key = .str("sim.content");
/// The status dot before each client's name.
const DOT_SIZE = 8;
/// A list's rows are keyed from here, past the list's own parts.
const ROW_KEY_BASE = 100;
/// A test's Start button is keyed past any of its setup lines.
const START_KEY_INDEX = 99;

/// Beside the sidebar, padded like the tab content so the two cards line up.
const CLIENTS_COLUMN: ui.Style = .{ .width = .fixed(290), .height = .grow(), .direction = .column, .padding = .init(12, 0, 12, 12) };
/// style.roster, filling its card's width.
const CLIENT_LIST: ui.Style = style.roster.with(.{ .width = .grow() });
const CLIENT_TEXT: ui.Style = .{ .width = .grow(), .direction = .column, .gap = 2 };
const CLIENT_DETAIL: ui.Style = .{ .width = .grow(), .wrap = true, .font_size = .xs, .foreground = .{ .color = style.MUTED } };
const DOT_RUNNING: ui.Style = .{ .width = .fixed(DOT_SIZE), .height = .fixed(DOT_SIZE), .radius = .{ .fixed = DOT_SIZE / 2 }, .background = .{ .color = style.SUCCESS } };
const DOT_IDLE: ui.Style = DOT_RUNNING.with(.{ .background = .{ .color = style.MUTED } });
const DOT_DEAD: ui.Style = DOT_RUNNING.with(.{ .background = .{ .color = style.ERROR } });
const ROW: ui.Style = .{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 8 };
const SPACER: ui.Style = .{ .width = .grow() };
const JOURNAL_PANE: ui.Style = .{
    .width = .grow(),
    .height = .fixed(180),
    .direction = .column,
    .gap = 6,
    .padding = .xy(12, 8),
    .background = .{ .color = style.CHROME },
    .border_width = .edges(1, 0, 0, 0),
    .border_color = .{ .color = style.DIVIDER },
};
const JOURNAL_LIST: style.ScrollPane = .{
    .pane = &.{ .width = .grow(), .height = .grow(), .direction = .column, .overflow = .scroll_y },
    .scrolling = &.{ .width = .grow(), .height = .grow(), .direction = .column, .overflow = .scroll_y, .padding = .init(0, style.ROW_SCROLLBAR_GUTTER, 0, 0) },
    .content = &.{ .width = .grow(), .direction = .column, .gap = 1 },
};
const JOURNAL_ROW: ui.Style = .{ .width = .grow(), .direction = .row, .gap = 10 };
/// Fixed, since the font's digits differ in width.
const JOURNAL_CLOCK: ui.Style = .{ .width = .fixed(52), .font_size = .xs, .foreground = .{ .color = style.MUTED } };
const JOURNAL_INFO: ui.Style = .{ .font_size = .xs, .width = .grow(), .wrap = true, .foreground = .{ .color = style.TEXT_SECONDARY } };
const JOURNAL_SUCCESS: ui.Style = JOURNAL_INFO.with(.{ .foreground = .{ .color = style.SUCCESS } });
const JOURNAL_EXPECT: ui.Style = JOURNAL_INFO.with(.{ .foreground = .{ .color = style.SKY } });
const JOURNAL_WARNING: ui.Style = JOURNAL_INFO.with(.{ .foreground = .{ .color = style.CAUTION } });
const JOURNAL_FAILURE: ui.Style = JOURNAL_INFO.with(.{ .foreground = .{ .color = style.ERROR } });
/// After a row's input, one width for every row, so the inputs line up.
const ROW_NOTE: ui.Style = .{ .width = .fixed(130), .foreground = .{ .color = style.MUTED } };
const NUMBER_INPUT: ui.Style = style.text_input.with(.{ .width = .fixed(80) });
/// The first of a test's setup lines says where the rest go.
const SETUP_INTRO: ui.Style = .{ .width = .grow(), .wrap = true, .foreground = .{ .color = style.MUTED }, .padding = .xy(style.ROW_INSET, 0) };
const SETUP_LINE: ui.Style = .{ .width = .grow(), .wrap = true, .foreground = .{ .color = style.TEXT }, .padding = .xy(style.ROW_INSET, 0) };

/// A heading in the sidebar over the tabs that belong to it.
const Category = enum {
    clients,
    events,
    testing,
    app,

    fn label(self: Category) []const u8 {
        return switch (self) {
            .clients => "CLIENTS",
            .events => "EVENTS",
            .testing => "TESTING",
            .app => "APP",
        };
    }
};

/// In sidebar order, each category's tabs together.
const Tab = enum {
    session,
    travel,
    events,
    chat,
    tests,
    setup,

    fn label(self: Tab) []const u8 {
        return switch (self) {
            .session => "Session",
            .travel => "Travel",
            .events => "Game Events",
            .chat => "Chat",
            .tests => "Guided Tests",
            .setup => "Setup",
        };
    }

    fn category(self: Tab) Category {
        return switch (self) {
            .session, .travel => .clients,
            .events, .chat => .events,
            .tests => .testing,
            .setup => .app,
        };
    }

    fn glyph(self: Tab) glyphs.Glyph {
        return switch (self) {
            .session => .pointer,
            .travel => .map,
            .events => .bell,
            .chat => .speech,
            .tests => .check,
            .setup => .gear,
        };
    }
};

/// What the controls hold between frames; the text buffers are owned and grown by knots with the same allocator.
pub const Controls = struct {
    tab: Tab = .session,
    new_name: std.ArrayList(u8) = .empty,
    system: std.ArrayList(u8) = .empty,
    age_seconds: std.ArrayList(u8) = .empty,
    speaker: std.ArrayList(u8) = .empty,
    message: std.ArrayList(u8) = .empty,
    join_channel: std.ArrayList(u8) = .empty,
    /// Into std.enums.values(lines.Alert).
    alert_index: u32 = 0,
    /// Into chatChannels' list.
    channel_index: u32 = 0,
    /// Into the picked clients, for Travel Mode.
    straggler_index: u32 = 0,
    /// The journal revision last drawn, so new entries scroll it to the end.
    seen_revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) !Controls {
        var controls: Controls = .{};
        errdefer controls.deinit(allocator);
        try controls.system.appendSlice(allocator, "Amarr");
        try controls.age_seconds.appendSlice(allocator, "0");
        try controls.speaker.appendSlice(allocator, "Scout One");
        return controls;
    }

    pub fn deinit(self: *Controls, allocator: std.mem.Allocator) void {
        self.new_name.deinit(allocator);
        self.system.deinit(allocator);
        self.age_seconds.deinit(allocator);
        self.speaker.deinit(allocator);
        self.message.deinit(allocator);
        self.join_channel.deinit(allocator);
    }
};

pub fn frame(context: *ui.Frame, fleet: *Fleet, controls: *Controls) !void {
    widgets.beginFrame();
    const size = context.input().logical_extent;
    const root_style = try context.arena().create(ui.Style);
    root_style.* = .{
        .width = .fixed(@floatFromInt(size.width)),
        .height = .fixed(@floatFromInt(size.height)),
        .direction = .column,
        .background = .{ .color = style.BG },
    };
    const picked = try pickedClients(context.arena(), fleet);

    const root = Rect{ .key = .src(@src()), .style = root_style };
    _ = try root.open(context);
    try header(context, fleet, picked.len);
    const body = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .grow(), .direction = .row } };
    _ = try body.open(context);
    try sidebar(context, controls);
    try clientColumn(context, fleet, controls, picked.len);
    const content = try widgets.openScrollPane(context, CONTENT_KEY, style.content_scroll);
    const was_aligned = widgets.useAlignedRows(true);
    switch (controls.tab) {
        .session => try sessionTab(context, fleet, picked),
        .travel => try travelTab(context, fleet, controls, picked),
        .events => try eventsTab(context, fleet, controls, picked),
        .chat => try chatTab(context, fleet, controls, picked),
        .tests => try testsTab(context, fleet, controls, picked),
        .setup => try setupTab(context, fleet),
    }
    _ = widgets.useAlignedRows(was_aligned);
    try content.close(context);
    try body.close(context);
    try journalPane(context, fleet, controls);
    try root.close(context);
    widgets.endFrame();
}

/// The brand, as the configuration window shows it, and how many clients are up.
fn header(context: *ui.Frame, fleet: *const Fleet, picked_count: usize) !void {
    const bar = Rect{ .key = .src(@src()), .style = &style.header };
    _ = try bar.open(context);
    const lockup = Rect{ .key = .src(@src()), .style = &style.brand };
    _ = try lockup.open(context);
    if (images.g_app_mark.image(.src(@src()), &style.app_mark)) |mark| try context.e(mark);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "EVE-Maj Client Simulator", .style = &style.brand_name });
    try lockup.close(context);
    try context.e(Rect{ .key = .src(@src()), .style = &SPACER });
    var running_count: usize = 0;
    for (fleet.clients.items) |client| {
        if (client.process != null) running_count += 1;
    }
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = try context.arena().print("{d} running  ·  {d} picked", .{ running_count, picked_count }), .style = &style.muted_text });
    try bar.close(context);
}

fn sidebar(context: *ui.Frame, controls: *Controls) !void {
    const bar = Rect{ .key = .src(@src()), .style = &style.sidebar };
    _ = try bar.open(context);
    var last_category: ?Category = null;
    for (std.enums.values(Tab)) |tab| {
        if (last_category != tab.category()) {
            last_category = tab.category();
            const index = @backingInt(tab.category());
            try context.e(.{
                Rect{ .key = ui.Key.str("sim.tab.category").indexed(index), .style = &style.tab_category },
                .{Text{ .selectable = false, .key = ui.Key.str("sim.tab.category.label").indexed(index), .content = tab.category().label(), .style = &style.tab_category_text }},
            });
        }
        try tabItem(context, controls, tab);
    }
    try bar.close(context);
}

fn tabItem(context: *ui.Frame, controls: *Controls, tab: Tab) !void {
    const is_active = controls.tab == tab;
    const index = @backingInt(tab);
    const item = Button{ .key = ui.Key.str("sim.tab").indexed(index), .style = if (is_active) &style.tab_item_active else &style.tab_item };
    const response = try item.openResponse(context);
    const tint: ui.Color = if (is_active) context.ui().theme.primary else if (response.hovered) style.TEXT else style.MUTED;
    const glyph_key = ui.Key.str("sim.tab.glyph").indexed(index);
    try context.e(Canvas{
        .key = glyph_key,
        .commands = try glyphs.commands(context.arena(), tab.glyph(), glyphs.TAB_SIZE, try glyphs.snapOffset(context, glyph_key), tint.value),
        .style = &style.tab_glyph,
    });
    try context.e(Text{
        .selectable = false,
        .key = ui.Key.str("sim.tab.label").indexed(index),
        .content = tab.label(),
        .style = if (is_active or response.hovered) &style.tab_label_lit else &style.tab_label,
    });
    try item.close(context);
    if (!response.clicked or is_active) return;
    controls.tab = tab;
    if (context.ui().state.get(.scroll, CONTENT_KEY.hash())) |scroll| scroll.offset = .{ 0, 0 };
    context.requestRedraw();
}

/// A card holding the clients as a master list, which every tab's actions work on.
fn clientColumn(context: *ui.Frame, fleet: *Fleet, controls: *Controls, picked_count: usize) !void {
    const column = Rect{ .key = .src(@src()), .style = &CLIENTS_COLUMN };
    _ = try column.open(context);
    const section = try widgets.openSection(context, "Clients", "Click to pick; each tab acts on the picked ones.", &style.fill_section);

    const add_row = Rect{ .key = .src(@src()), .style = &ROW };
    _ = try add_row.open(context);
    try context.e(TextInput{ .key = .src(@src()), .buf = &controls.new_name, .style = &style.text_input, .placeholder = "Character name" });
    if (try button(context, .src(@src()), "Add", std.mem.trim(u8, controls.new_name.items, " ").len > 0)) {
        fleet.start(controls.new_name.items);
        controls.new_name.clearRetainingCapacity();
    }
    try add_row.close(context);

    const pick_row = Rect{ .key = .src(@src()), .style = &ROW };
    _ = try pick_row.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = try context.arena().print("{d} of {d} picked", .{ picked_count, fleet.clients.items.len }), .style = &style.muted_text });
    try context.e(Rect{ .key = .src(@src()), .style = &SPACER });
    if ((try context.interact(Button{ .key = .src(@src()), .label = "All", .style = &style.link })).clicked) setAllPicked(fleet, true);
    if ((try context.interact(Button{ .key = .src(@src()), .label = "None", .style = &style.link })).clicked) setAllPicked(fleet, false);
    try pick_row.close(context);

    const list = Rect{ .key = CLIENTS_KEY, .style = &CLIENT_LIST };
    _ = try list.open(context);
    const rows = try widgets.openScrollPane(context, CLIENTS_KEY.indexed(1), style.roster_scroll);
    if (fleet.clients.items.len == 0) {
        try widgets.boxedText(context, .src(@src()), "No clients yet. Name one above, or add the test clients below.", &style.roster_empty, &style.roster_empty_text);
    }
    for (fleet.clients.items, 0..) |*client, index| try clientRow(context, fleet, client, index);
    try rows.close(context);
    const footer = Rect{ .key = .src(@src()), .style = &style.roster_footer };
    _ = try footer.open(context);
    if (try widgets.glyphButton(context, .src(@src()), .add, "Add 10 Test Clients", &style.roster_add, false)) addTestClients(fleet);
    try footer.close(context);
    try list.close(context);

    try section.close(context);
    try column.close(context);
}

/// A row of the master list: a click picks or unpicks it.
fn clientRow(context: *ui.Frame, fleet: *const Fleet, client: *fleet_mod.Client, index: usize) !void {
    const key = CLIENTS_KEY.indexed(ROW_KEY_BASE + index);
    const row = Button{ .key = key, .style = if (client.is_picked) &style.roster_row_selected else &style.roster_row };
    const response = try widgets.openRosterRow(context, row);
    try context.e(Rect{ .key = key.indexed(1), .style = switch (client.state) {
        .logged_in => &DOT_RUNNING,
        .logged_out => &DOT_IDLE,
        .exited => &DOT_DEAD,
    } });
    const text = Rect{ .key = key.indexed(2), .style = &CLIENT_TEXT };
    _ = try text.open(context);
    try context.e(Text{ .selectable = false, .key = key.indexed(3), .content = client.name, .style = if (client.is_picked) &style.roster_name_selected else &style.roster_name });
    var detail: std.Io.Writer.Allocating = .init(context.arena());
    try detail.writer.print("{s}  ·  {s}", .{ client.system, client.state.label() });
    for (std.enums.values(schedule.Task)) |task| {
        if (fleet.schedule.isRunning(client.name, task)) try detail.writer.print("  ·  {s}", .{task.label()});
    }
    try context.e(Text{ .selectable = false, .key = key.indexed(4), .content = detail.written(), .style = &CLIENT_DETAIL });
    try text.close(context);
    if (client.is_picked) {
        const glyph_key = key.indexed(5);
        try context.e(Canvas{
            .key = glyph_key,
            .commands = try glyphs.commands(context.arena(), .check, glyphs.TAB_SIZE, try glyphs.snapOffset(context, glyph_key), context.ui().theme.primary.value),
            .style = &style.tab_glyph,
        });
    }
    try row.close(context);
    if (!response.clicked) return;
    client.is_picked = !client.is_picked;
    context.requestRedraw();
}

/// Test Client 1 to QUICK_CLIENT_COUNT, skipping any already running.
fn addTestClients(fleet: *Fleet) void {
    var started_count: usize = 0;
    for (1..QUICK_CLIENT_COUNT + 1) |number| {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "Test Client {d}", .{number}) catch unreachable;
        if (fleet.indexOf(name)) |index| {
            if (fleet.clients.items[index].state != .exited) continue;
        }
        fleet.start(name);
        started_count += 1;
    }
    if (started_count == 0) fleet.note(.info, "Test Client 1 to {d} are already running", .{QUICK_CLIENT_COUNT});
}

fn sessionTab(context: *ui.Frame, fleet: *Fleet, picked: []const usize) !void {
    try pickedNotice(context, picked);
    const section = try widgets.openSection(context, "Session", "Logging in starts fresh session logs, as EVE does; logging out only changes the title.", &style.section);
    if (try buttonRow(context, .src(@src()), &.{ "Log in", "Log out", "Start again" }, picked.len > 0)) |choice| {
        for (picked) |index| {
            switch (choice) {
                0 => fleet.setLoggedIn(index, true),
                1 => fleet.setLoggedIn(index, false),
                else => fleet.start(fleet.clients.items[index].name),
            }
        }
    }
    try section.close(context);

    const ending = try widgets.openSection(context, "Ending", "Close asks the window to close; Kill ends the process at once, as a crash would.", &style.section);
    if (try buttonRow(context, .src(@src()), &.{ "Close", "Kill", "Stop running work", "Remove from list" }, picked.len > 0)) |choice| {
        // Backwards, since Remove shifts the rows after it.
        var position = picked.len;
        while (position > 0) {
            position -= 1;
            const index = picked[position];
            switch (choice) {
                0 => fleet.stop(index),
                1 => fleet.kill(index),
                2 => fleet.stopWork(index),
                else => fleet.remove(index),
            }
        }
    }
    try ending.close(context);
}

fn travelTab(context: *ui.Frame, fleet: *Fleet, controls: *Controls, picked: []const usize) !void {
    try pickedNotice(context, picked);
    const section = try widgets.openSection(context, "Jump", "A gate jump writes the gamelog's jump line and Local's change; the other two write one of them, as a pod or filament move does. Lines stamped in the past read as late, so the character stays put.", &style.section);
    const system = std.mem.trim(u8, controls.system.items, " ");
    const system_row = try widgets.openBinding(context, .src(@src()), "System");
    try context.e(TextInput{ .key = .src(@src()), .buf = &controls.system, .style = &style.text_input_aligned, .placeholder = "e.g. Amarr" });
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = if (system.len == 0) "" else if (universe.findSystem(system) != null) "on the gate map" else "not on the gate map", .style = &ROW_NOTE });
    try system_row.close(context);
    const age_row = try widgets.openBinding(context, .src(@src()), "Stamped");
    try context.e(TextInput{ .key = .src(@src()), .buf = &controls.age_seconds, .style = &NUMBER_INPUT });
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "seconds ago", .style = &ROW_NOTE });
    try age_row.close(context);
    if (try buttonRow(context, .src(@src()), &.{ "Gate jump", "Gamelog only", "Local only" }, picked.len > 0 and system.len > 0)) |choice| {
        const age = stampAge(fleet, controls.age_seconds.items);
        const via: Via = switch (choice) {
            0 => .both,
            1 => .gamelog,
            else => .local,
        };
        for (picked) |index| fleet.move(index, system, via, age);
    }
    try section.close(context);

    const random = try widgets.openSection(context, "Random", "Through real gates from where each client is, using the map's own data.", &style.section);
    if (try buttonRow(context, .src(@src()), &.{ "One random gate", "3-jump route, 10s apart" }, picked.len > 0)) |choice| {
        for (picked) |index| if (choice == 0) fleet.jumpRandomly(index) else fleet.startRandomRoute(index);
    }
    try random.close(context);
}

fn eventsTab(context: *ui.Frame, fleet: *Fleet, controls: *Controls, picked: []const usize) !void {
    try pickedNotice(context, picked);
    const section = try widgets.openSection(context, "Game Events", "One gamelog line that raises the named notification; a conduit jump also moves the client.", &style.section);
    const alerts = comptime std.enums.values(lines.Alert);
    var alert_labels: [alerts.len][]const u8 = undefined;
    for (alerts, &alert_labels) |alert, *alert_label| alert_label.* = try spacedWords(context.arena(), alert.notificationName());
    const row = try widgets.openBinding(context, .src(@src()), "Event");
    try choose(context, .src(@src()), &alert_labels, &controls.alert_index, null);
    if (try button(context, .src(@src()), "Fire", picked.len > 0)) {
        for (picked) |index| fleet.fireAlert(index, alerts[controls.alert_index]);
    }
    try row.close(context);
    try section.close(context);

    const activity = try widgets.openSection(context, "Activity", "Bounties and fights run a minute; mining replays three minutes of a real gamelog.", &style.section);
    const bursts = comptime std.enums.values(Burst);
    var burst_labels: [bursts.len][]const u8 = undefined;
    for (bursts, &burst_labels) |burst, *burst_label| burst_label.* = burst.label();
    if (try buttonRow(context, .src(@src()), &burst_labels, picked.len > 0)) |choice| {
        for (picked) |index| fleet.startBurst(index, bursts[choice]);
    }
    if (try buttonRow(context, .src(@src()), &.{"Stop running work"}, picked.len > 0)) |_| {
        for (picked) |index| fleet.stopWork(index);
    }
    try activity.close(context);
}

fn chatTab(context: *ui.Frame, fleet: *Fleet, controls: *Controls, picked: []const usize) !void {
    const section = try widgets.openSection(context, "Message", "Written to every logged-in client listening on the channel, up to a second apart, as real clients log it.", &style.section);
    const channels = try chatChannels(context.arena(), fleet);
    if (controls.channel_index >= channels.len) controls.channel_index = 0;
    const channel_row = try widgets.openBinding(context, .src(@src()), "Channel");
    try choose(context, .src(@src()), channels, &controls.channel_index, &style.select);
    try channel_row.close(context);
    const speaker_row = try widgets.openBinding(context, .src(@src()), "Speaker");
    try context.e(TextInput{ .key = .src(@src()), .buf = &controls.speaker, .style = &style.text_input_aligned });
    try speaker_row.close(context);
    const message_row = try widgets.openBinding(context, .src(@src()), "Message");
    try context.e(TextInput{ .key = .src(@src()), .buf = &controls.message, .style = &style.text_input, .placeholder = "e.g. Perimeter 3 hostiles on gate" });
    try message_row.close(context);
    const speaker = std.mem.trim(u8, controls.speaker.items, " ");
    const message = std.mem.trim(u8, controls.message.items, " ");
    if (try buttonRow(context, .src(@src()), &.{"Send"}, speaker.len > 0 and message.len > 0)) |_| {
        fleet.sendChat(channels[controls.channel_index], speaker, message);
    }
    try section.close(context);

    const joining = try widgets.openSection(context, "Join a channel", "Opens the channel's log on each picked client mid-session, as joining it in game does.", &style.section);
    const join_row = try widgets.openBinding(context, .src(@src()), "Channel");
    try context.e(TextInput{ .key = .src(@src()), .buf = &controls.join_channel, .style = &style.text_input_aligned, .placeholder = "e.g. Alliance" });
    const join_name = std.mem.trim(u8, controls.join_channel.items, " ");
    if (try button(context, .src(@src()), "Join", picked.len > 0 and join_name.len > 0)) {
        for (picked) |index| fleet.join(index, join_name);
    }
    try join_row.close(context);
    try joining.close(context);
}

fn testsTab(context: *ui.Frame, fleet: *Fleet, controls: *Controls, picked: []const usize) !void {
    const pending = fleet.schedule.pendingCount(.scenario);
    const steps_left = fleet.schedule.expectationCount();
    if (pending > 0) {
        const running = try widgets.openSection(context, "Running", "", &style.section);
        const row = Rect{ .key = .src(@src()), .style = &ROW };
        _ = try row.open(context);
        try context.e(Text{ .selectable = false, .key = .src(@src()), .content = try context.arena().print("A test is running, {d} step(s) left; its expectations show in the activity feed.", .{steps_left}), .style = &style.modal_text });
        if (try button(context, .src(@src()), "Stop test", true)) {
            _ = fleet.schedule.cancel(null, .scenario);
            fleet.note(.info, "Stopped the test", .{});
        }
        try row.close(context);
        try running.close(context);
    }
    inline for (comptime std.enums.values(Scenario)) |scenario| {
        const section = try widgets.openSection(context, comptime scenario.label(), comptime scenario.summary(), &style.section);
        const setup_key: ui.Key = .str("sim.setup." ++ @tagName(scenario));
        for (scenario.setup(), 0..) |setup_line, line_index| {
            try context.e(Text{ .selectable = false, .key = setup_key.indexed(line_index), .content = setup_line, .style = if (line_index == 0) &SETUP_INTRO else &SETUP_LINE });
        }
        if (scenario == .travel_mode and picked.len > 0) {
            if (controls.straggler_index >= picked.len) controls.straggler_index = 0;
            const names = try context.arena().alloc([]const u8, picked.len);
            for (picked, names) |index, *name| name.* = fleet.clients.items[index].name;
            const row = try widgets.openBinding(context, .src(@src()), "Left behind");
            try choose(context, .src(@src()), names, &controls.straggler_index, null);
            try row.close(context);
        }
        const is_ready = picked.len >= scenario.pickedNeeded() and pending == 0;
        if (try buttonRow(context, setup_key.indexed(START_KEY_INDEX), &.{"Start"}, is_ready)) |_| {
            const straggler = if (scenario == .travel_mode and picked.len > 0) picked[controls.straggler_index] else null;
            scenarios.start(fleet, scenario, picked, straggler);
        }
        try section.close(context);
    }
}

fn setupTab(context: *ui.Frame, fleet: *Fleet) !void {
    const folders = try widgets.openSection(context, "Log folders", "The app's defaults, so it watches these with no settings change. Changes apply to sessions started afterwards.", &style.section);
    const chatlog_row = try widgets.openBinding(context, .src(@src()), "Chatlogs");
    try context.e(TextInput{ .key = .src(@src()), .buf = &fleet.chatlog_dir, .style = &style.path_input });
    try chatlog_row.close(context);
    const gamelog_row = try widgets.openBinding(context, .src(@src()), "Gamelogs");
    try context.e(TextInput{ .key = .src(@src()), .buf = &fleet.gamelog_dir, .style = &style.path_input });
    try gamelog_row.close(context);
    const channel_row = try widgets.openBinding(context, .src(@src()), "Channels joined");
    try context.e(TextInput{ .key = .src(@src()), .buf = &fleet.channel_list, .style = &style.path_input });
    try channel_row.close(context);
    try widgets.paragraph(context, .src(@src()), "Fixture files are named after their character's ID, e.g. Local_*_1480182092.txt, so they never overwrite real EVE logs and can be deleted any time.");
    try folders.close(context);

    const files = try widgets.openSection(context, "Simulator files", "", &style.section);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = try context.arena().print("Work folder: {s}", .{fleet.work_dir}), .style = &SETUP_LINE });
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = try context.arena().print("Clients run as: {s}", .{fleet.client_executable}), .style = &SETUP_LINE });
    try files.close(context);
}

fn journalPane(context: *ui.Frame, fleet: *Fleet, controls: *Controls) !void {
    const pane = Rect{ .key = .src(@src()), .style = &JOURNAL_PANE };
    _ = try pane.open(context);
    const title_row = Rect{ .key = .src(@src()), .style = &ROW };
    _ = try title_row.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "Activity", .style = &style.heading });
    try context.e(Rect{ .key = .src(@src()), .style = &SPACER });
    if (try button(context, .src(@src()), "Clear", fleet.journal.entries.items.len > 0)) fleet.journal.clear();
    try title_row.close(context);

    if (fleet.journal.revision != controls.seen_revision) {
        controls.seen_revision = fleet.journal.revision;
        widgets.scrollToEnd(context, JOURNAL_KEY);
    }
    const list = try widgets.openScrollPane(context, JOURNAL_KEY, JOURNAL_LIST);
    for (fleet.journal.entries.items, 0..) |*entry, index| {
        const key = JOURNAL_KEY.indexed(ROW_KEY_BASE + index);
        const row = Rect{ .key = key, .style = &JOURNAL_ROW };
        _ = try row.open(context);
        try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = &entry.clock, .style = &JOURNAL_CLOCK });
        try context.e(Text{ .key = key.indexed(2), .content = entry.text, .style = switch (entry.kind) {
            .info => &JOURNAL_INFO,
            .success => &JOURNAL_SUCCESS,
            .expect => &JOURNAL_EXPECT,
            .warning => &JOURNAL_WARNING,
            .failure => &JOURNAL_FAILURE,
        } });
        try row.close(context);
    }
    try list.close(context);
    try pane.close(context);
}

/// Above a tab whose actions work on the picked clients.
fn pickedNotice(context: *ui.Frame, picked: []const usize) !void {
    if (picked.len > 0) return;
    try widgets.notice(context, .src(@src()), "Pick one or more clients in the list to act on them.");
}

/// A plain button, drawn disabled when `is_enabled` is false; returns whether it was clicked.
fn button(context: *ui.Frame, key: ui.Key, label: []const u8, is_enabled: bool) !bool {
    const response = try context.interact(Button{
        .key = key,
        .label = label,
        .disabled = !is_enabled,
        .style = if (is_enabled) &style.plain_button else &style.disabled_button,
    });
    return response.clicked and is_enabled;
}

/// Buttons side by side; returns which was clicked.
fn buttonRow(context: *ui.Frame, key: ui.Key, labels: []const []const u8, is_enabled: bool) !?usize {
    const row = Rect{ .key = key, .style = &style.button_row };
    _ = try row.open(context);
    var clicked: ?usize = null;
    for (labels, 0..) |label, index| {
        if (try button(context, key.indexed(index + 1), label, is_enabled)) clicked = index;
    }
    try row.close(context);
    return clicked;
}

/// `selected` follows the pick and the dropdown follows `selected` while closed; a null `select_style` fits the longest label.
fn choose(context: *ui.Frame, key: ui.Key, labels: []const []const u8, selected: *u32, select_style: ?*const ui.Style) !void {
    if (labels.len == 0) return;
    if (context.ui().state.get(.select_input, key.hash())) |state| {
        if (!state.open) state.selected = selected.*;
    }
    const values = try context.arena().alloc(u32, labels.len);
    for (values, 0..) |*value, index| value.* = @intCast(index);
    const response = try context.interact(SelectInput(u32){
        .key = key,
        .labels = labels,
        .values = values,
        .initial_selected = selected.*,
        .style = select_style orelse try widgets.fittedSelect(context, labels),
        .parts = .{ .popup = &style.select_popup },
    });
    if (response.selected) |choice| selected.* = choice.value;
}

/// Read only when a move is sent, so a bad entry is reported once; anything but a whole number stamps the lines now.
fn stampAge(fleet: *Fleet, typed: []const u8) u32 {
    const trimmed = std.mem.trim(u8, typed, " ");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(u32, trimmed, 10) catch |err| blk: {
        slog.warn("Failed to read '{s}' as seconds ago, so the lines are stamped now: {}", .{ trimmed, err });
        fleet.note(.warning, "'{s}' isn't a whole number of seconds, so the lines are stamped now", .{trimmed});
        break :blk 0;
    };
}

/// "FleetInvite" reads "Fleet Invite"; made in `arena`.
fn spacedWords(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    var spaced: std.ArrayList(u8) = .empty;
    for (name, 0..) |byte, index| {
        if (index > 0 and std.ascii.isUpper(byte)) try spaced.append(arena, ' ');
        try spaced.append(arena, byte);
    }
    return spaced.items;
}

/// Local, then the Setup tab's channels; made in `arena`.
fn chatChannels(arena: std.mem.Allocator, fleet: *const Fleet) ![]const []const u8 {
    var channels: std.ArrayList([]const u8) = .empty;
    try channels.append(arena, lines.LOCAL_CHANNEL);
    var names = fleet.channelNames();
    while (names.next()) |raw| {
        const channel = std.mem.trim(u8, raw, " ");
        if (channel.len > 0) try channels.append(arena, try arena.dupe(u8, channel));
    }
    return channels.items;
}

/// In list order; made in `arena`.
fn pickedClients(arena: std.mem.Allocator, fleet: *const Fleet) ![]const usize {
    var picked: std.ArrayList(usize) = .empty;
    for (fleet.clients.items, 0..) |client, index| {
        if (client.is_picked) try picked.append(arena, index);
    }
    return picked.items;
}

fn setAllPicked(fleet: *Fleet, is_picked: bool) void {
    for (fleet.clients.items) |*client| client.is_picked = is_picked;
}
