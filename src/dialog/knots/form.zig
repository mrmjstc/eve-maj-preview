//! The configuration window's frame: categorised tab sidebar, the open tab, the Save footer and the unsaved-changes prompts; main thread only.
const std = @import("std");
const knots = @import("knots");
const ui = @import("ui");
const host = @import("host.zig");
const session = @import("session.zig");
const style = @import("style.zig");
const widgets = @import("widgets.zig");
const glyphs = @import("glyphs.zig");
const import_dialog = @import("import_dialog.zig");
const update_notice = @import("update_notice.zig");
const search = @import("search.zig");
const hotkey = @import("hotkey.zig");
const header = @import("header.zig");
const profiles = @import("profiles.zig");
const status = @import("status.zig");
const lang = @import("../../lang/lang.zig");
const about = @import("tabs/about.zig");
const backups = @import("tabs/backups.zig");
const general = @import("tabs/general.zig");
const hotkeys = @import("tabs/hotkeys.zig");
const hotkey_groups = @import("tabs/hotkey_groups.zig");
const display = @import("tabs/display.zig");
const characters = @import("tabs/characters.zig");
const client_windows = @import("tabs/client_windows.zig");
const client_list = @import("tabs/client_list.zig");
const mouse = @import("tabs/mouse.zig");
const notifications = @import("tabs/notifications.zig");
const event_alerts = @import("tabs/event_alerts.zig");
const chat_alerts = @import("tabs/chat_alerts.zig");
const notification_history = @import("tabs/notification_history.zig");
const map_panel = @import("tabs/map_panel.zig");
const mining = @import("tabs/mining.zig");
const placement = @import("tabs/placement.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Canvas = ui.component.Canvas;

/// A heading in the sidebar over the tabs that belong to it.
const Category = enum {
    clients,
    display,
    panels,
    input,
    alerts,
    app,

    fn label(self: Category) []const u8 {
        return switch (self) {
            .app => "APP",
            .clients => "CLIENTS",
            .display => "DISPLAY",
            .panels => "PANELS",
            .input => "INPUT",
            .alerts => "ALERTS",
        };
    }
};

/// In sidebar order, each category's tabs together.
const Tab = enum {
    characters,
    hotkey_groups,
    client_windows,
    appearance,
    placement,
    mining,
    client_list,
    notification_history,
    map_panel,
    hotkeys,
    mouse,
    notifications,
    event_alerts,
    chat_alerts,
    general,
    backups,
    about,

    fn label(self: Tab) []const u8 {
        return switch (self) {
            .characters => "Characters",
            .hotkey_groups => "Hotkey Groups",
            .client_windows => "Client Windows",
            .appearance => "Appearance",
            .placement => "Placement",
            .mining => "Mining",
            .client_list => "Client List",
            .notification_history => "Alert History",
            .map_panel => "Map & Intel",
            .hotkeys => "Hotkeys",
            .mouse => "Mouse",
            .notifications => "Alert Options",
            .event_alerts => "Game Events",
            .chat_alerts => "Chat Events",
            .general => "General",
            .about => "About",
            .backups => "Backups",
        };
    }

    fn category(self: Tab) Category {
        return switch (self) {
            .characters, .hotkey_groups, .client_windows => .clients,
            .appearance, .placement, .mining => .display,
            .client_list, .notification_history, .map_panel => .panels,
            .hotkeys, .mouse => .input,
            .notifications, .event_alerts, .chat_alerts => .alerts,
            .about, .backups, .general => .app,
        };
    }

    fn glyph(self: Tab) glyphs.Glyph {
        return switch (self) {
            .characters => .person,
            .hotkey_groups => .split_square,
            .client_windows => .open_window,
            .appearance => .thumbnail,
            .placement => .tiles,
            .mining => .pickaxe,
            .client_list => .list,
            .notification_history => .clock,
            .map_panel => .map,
            .hotkeys => .keyboard,
            .mouse => .pointer,
            .notifications => .envelope,
            .event_alerts => .bell,
            .chat_alerts => .speech,
            .general => .gear,
            .about => .info,
            .backups => .reset,
        };
    }

    fn isAdvanced(self: Tab) bool {
        return switch (self) {
            .mining => true,
            .characters, .hotkey_groups, .client_windows, .appearance, .placement, .client_list, .notification_history, .map_panel, .hotkeys, .mouse, .notifications, .event_alerts, .chat_alerts, .general, .about, .backups => false,
        };
    }

    /// Fills the content area itself instead of scrolling in it.
    fn fills(self: Tab) bool {
        return switch (self) {
            .characters, .hotkey_groups, .event_alerts, .chat_alerts => true,
            .placement => placement.fillsWindow(),
            .client_windows, .appearance, .mining, .client_list, .notification_history, .map_panel, .hotkeys, .mouse, .notifications, .general, .about, .backups => false,
        };
    }

    // The sidebar heads each category once, so its tabs must be adjacent.
    comptime {
        const tabs = std.enums.values(Tab);
        for (tabs[0 .. tabs.len - 1], tabs[1..]) |previous, tab| {
            std.debug.assert(@backingInt(previous.category()) <= @backingInt(tab.category()));
        }
    }
};

/// Which tabs the sidebar offers this frame.
const Offered = struct {
    is_advanced_mode: bool,

    fn has(self: Offered, tab: Tab) bool {
        return self.is_advanced_mode or !tab.isAdvanced();
    }
};

var g_tab: Tab = .about;
var g_is_close_prompt_open: bool = false;

/// The window's close button was pressed with unsaved changes.
pub fn confirmClose() void {
    g_is_close_prompt_open = true;
}

pub fn frame(_: *knots.View, context: *ui.Frame) !void {
    host.useLanguage(session.global().get("language"));
    session.beginFrame();
    widgets.beginFrame();
    search.beginFrame();
    try hotkey.beginFrame(context);
    applyAccent(context);
    const offered = Offered{ .is_advanced_mode = session.global().get("advancedMode") };
    if (host.takeRequestedPage()) |page| selectTab(context, switch (page) {
        .client_list => .client_list,
        .history_panel => .notification_history,
        .intel_panel => .map_panel,
    });
    // Turning Advanced Mode off can hide the open tab.
    if (!offered.has(g_tab)) selectTab(context, .about);
    const size = context.input().logical_extent;
    // Style pointers must outlive the frame's layout, which the arena does.
    const root_style = try context.arena().create(ui.Style);
    root_style.* = .{
        .width = .fixed(@floatFromInt(size.width)),
        .height = .fixed(@floatFromInt(size.height)),
        .direction = .column,
        .background = .{ .color = style.BG },
    };
    const root = Rect{ .key = .src(@src()), .style = root_style };
    _ = try root.open(context);
    try header.show(context);

    const body = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .height = .grow(), .direction = .row } };
    _ = try body.open(context);
    try sidebar(context, offered);
    const fill = Rect{ .key = widgets.TAB_CONTENT_KEY, .style = &style.content_fill };
    var scroll: ?widgets.ScrollPane = null;
    if (g_tab.fills()) {
        _ = try fill.open(context);
    } else {
        scroll = try widgets.openScrollPane(context, widgets.TAB_CONTENT_KEY, style.content_scroll);
    }
    if (search.needsIndex()) {
        try indexTabs(context, offered);
    } else {
        if (search.isActive() and !search.tabHasMatches(@backingInt(g_tab))) {
            if (search.firstMatchingTab()) |first| selectTab(context, @fromBackingInt(@intCast(first)));
        }
        try showTab(context, g_tab);
    }
    if (scroll) |pane| try pane.close(context) else try fill.close(context);
    try body.close(context);
    if (widgets.takeNoticeTarget()) |target| selectTab(context, switch (target) {
        .notifications => .notifications,
        .log_monitoring => .general,
        .appearance => .appearance,
    });

    try footer(context);
    try import_dialog.show(context);
    try update_notice.show(context);
    try unsavedPrompt(context);
    // Last, so it opens over the Import dialog that queued its switch.
    try switchPrompt(context);
    // An edit made after what shows it was drawn, e.g. + Add Character under its list, appears on the next frame.
    if (session.takeEdited()) context.requestRedraw();

    try root.close(context);
    widgets.endFrame();
}

fn showTab(context: *ui.Frame, tab: Tab) !void {
    const was_aligned = widgets.useAlignedRows(true);
    defer _ = widgets.useAlignedRows(was_aligned);
    switch (tab) {
        .about => try about.show(context),
        .backups => try backups.show(context),
        .appearance => try display.show(context),
        .placement => try placement.show(context),
        .map_panel => try map_panel.show(context),
        .characters => try characters.show(context),
        .client_windows => try client_windows.show(context),
        .client_list => try client_list.show(context),
        .mouse => try mouse.show(context),
        .notifications => try notifications.show(context),
        .event_alerts => try event_alerts.show(context),
        .chat_alerts => try chat_alerts.show(context),
        .notification_history => try notification_history.show(context),
        .mining => try mining.show(context),
        .general => try general.show(context),
        .hotkeys => try hotkeys.show(context),
        .hotkey_groups => try hotkey_groups.show(context),
    }
}

/// Draws every tab the sidebar offers out of sight, once, so the search can see sections on tabs that aren't open.
fn indexTabs(context: *ui.Frame, offered: Offered) !void {
    const hidden = Rect{ .key = .src(@src()), .style = &style.section_hidden };
    _ = try hidden.open(context);
    for (std.enums.values(Tab)) |tab| {
        if (!offered.has(tab)) continue;
        search.beginCapture(@backingInt(tab));
        try showTab(context, tab);
    }
    search.endIndex();
    try hidden.close(context);
    context.requestRedraw();
}

fn sidebar(context: *ui.Frame, offered: Offered) !void {
    const bar = Rect{ .key = .src(@src()), .style = try sidebarStyle(context, offered) };
    _ = try bar.open(context);
    var last_category: ?Category = null;
    for (std.enums.values(Tab)) |tab| {
        if (!offered.has(tab)) continue;
        if (!search.tabHasMatches(@backingInt(tab))) continue;
        if (last_category != tab.category()) {
            last_category = tab.category();
            const index = @backingInt(tab.category());
            try context.e(.{
                Rect{ .key = ui.Key.str("knots.tab.category").indexed(index), .style = &style.tab_category },
                .{Text{
                    .selectable = false,
                    .key = ui.Key.str("knots.tab.category.label").indexed(index),
                    .content = lang.text(tab.category().label()),
                    .style = &style.tab_category_text,
                }},
            });
        }
        try tabItem(context, tab);
    }
    try bar.close(context);
}

/// style.sidebar, widened to its longest tab or category name in the chosen language.
fn sidebarStyle(context: *ui.Frame, offered: Offered) !*const ui.Style {
    const item_padding = comptime style.tab_item.padding.?;
    const category_padding = comptime style.tab_category.padding.?;
    const bar_padding = comptime style.sidebar.padding.?;
    const bar_border = 1;
    var widest: f32 = 0;
    for (std.enums.values(Tab)) |tab| {
        if (!offered.has(tab)) continue;
        const label_width = try widgets.textWidth(context, lang.text(tab.label()), &style.tab_label);
        widest = @max(widest, item_padding.left() + glyphs.TAB_SIZE + style.tab_item.gap.? + label_width + item_padding.right());
        const category_width = try widgets.textWidth(context, lang.text(tab.category().label()), &style.tab_category_text);
        widest = @max(widest, category_padding.left() + category_width + category_padding.right());
    }
    const width = std.math.clamp(@ceil(bar_padding.left() + widest + bar_padding.right() + bar_border), style.SIDEBAR_WIDTH, style.SIDEBAR_MAX_WIDTH);
    const sized = try context.arena().create(ui.Style);
    sized.* = style.sidebar.with(.{ .width = .fixed(width) });
    return sized;
}

fn tabItem(context: *ui.Frame, tab: Tab) !void {
    const is_active = g_tab == tab;
    const index = @backingInt(tab);
    const item = Button{
        .key = ui.Key.str("knots.tab").indexed(index),
        .style = if (is_active) &style.tab_item_active else &style.tab_item,
    };
    const response = try item.openResponse(context);
    const tint: ui.Color = if (is_active) context.ui().theme.primary else if (response.hovered) style.TEXT else style.MUTED;
    const glyph_key = ui.Key.str("knots.tab.glyph").indexed(index);
    try context.e(Canvas{
        .key = glyph_key,
        .commands = try glyphs.commands(context.arena(), tab.glyph(), glyphs.TAB_SIZE, try glyphs.snapOffset(context, glyph_key), tint.value),
        .style = &style.tab_glyph,
    });
    try context.e(Text{
        .selectable = false,
        .key = ui.Key.str("knots.tab.label").indexed(index),
        .content = lang.text(tab.label()),
        .style = if (is_active or response.hovered) &style.tab_label_lit else &style.tab_label,
    });
    try item.close(context);
    if (response.clicked and !is_active) selectTab(context, tab);
}

/// The new tab starts at its top.
fn selectTab(context: *ui.Frame, tab: Tab) void {
    g_tab = tab;
    const ui_state = context.ui();
    if (ui_state.state.get(.scroll, widgets.TAB_CONTENT_KEY.hash())) |scroll| scroll.offset = .{ 0, 0 };
    context.requestRedraw();
}

fn footer(context: *ui.Frame) !void {
    const bar = Rect{ .key = .src(@src()), .style = &style.footer };
    _ = try bar.open(context);
    // Copied: a dialog drawn later this frame may rewrite the status buffer.
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = try context.arena().dupe(u8, status.text()), .style = switch (status.kind()) {
        .info => &style.status_info,
        .success => &style.status_success,
        .failure => &style.status_failure,
    } });
    try context.e(Rect{ .key = .src(@src()), .style = &.{ .width = .grow() } });
    if (session.isDirty()) try context.e(.{
        Rect{ .key = .src(@src()), .style = &style.unsaved_chip },
        .{
            Text{ .selectable = false, .key = .src(@src()), .content = "●", .style = &style.unsaved_dot },
            Text{ .selectable = false, .key = .src(@src()), .content = lang.text("Unsaved changes"), .style = &style.unsaved_text },
        },
    });
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Close"), .style = &style.outline_button })).clicked) {
        host.requestClose();
    }
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Save"), .style = &style.primary_button })).clicked) {
        host.postCommand(.save);
    }
    try bar.close(context);
}

fn unsavedPrompt(context: *ui.Frame) !void {
    if (!g_is_close_prompt_open) return;
    const dialog = widgets.modal(.src(@src()), &g_is_close_prompt_open, &style.modal);
    _ = try dialog.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("Unsaved Changes"), .style = &style.heading });
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("You have unsaved changes. Save them before closing, or close without saving?"), .style = &style.modal_text });
    const actions = Rect{ .key = .src(@src()), .style = &style.modal_actions };
    _ = try actions.open(context);
    // Furthest from Save, so the destructive choice isn't beside the default one.
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Discard"), .style = &style.danger_button })).clicked) {
        g_is_close_prompt_open = false;
        host.postCommand(.discard_and_close);
    }
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Cancel"), .style = &style.outline_button })).clicked) {
        g_is_close_prompt_open = false;
        context.requestRedraw();
    }
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Save"), .style = &style.primary_button })).clicked) {
        g_is_close_prompt_open = false;
        host.postCommand(.save_and_close);
    }
    try actions.close(context);
    try dialog.close(context);
}

/// A profile switch waiting on unsaved changes, which it would otherwise drop.
fn switchPrompt(context: *ui.Frame) !void {
    const target = profiles.awaitedName() orelse return;
    const is_open = profiles.awaitingFlag();
    const dialog = widgets.modal(.src(@src()), is_open, &style.modal);
    _ = try dialog.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("Unsaved Changes"), .style = &style.heading });
    try context.e(Text{
        .selectable = false,
        .key = .src(@src()),
        .content = if (profiles.isAwaitingRename())
            lang.text("Renaming reloads the profile, which drops your unsaved changes. Save them first?")
        else
            try lang.format(context.arena(), "Switching to '{name}' drops your unsaved changes. Save them first?", .{ .name = target }),
        .style = &style.modal_text,
    });
    const actions = Rect{ .key = .src(@src()), .style = &style.modal_actions };
    _ = try actions.open(context);
    var choice: ?profiles.Unsaved = null;
    // Furthest from Save, so the destructive choice isn't beside the default one.
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Discard"), .style = &style.danger_button })).clicked) choice = .discard;
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Cancel"), .style = &style.outline_button })).clicked) is_open.* = false;
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text(if (profiles.isAwaitingRename()) "Save and Rename" else "Save and Switch"), .style = &style.primary_button })).clicked) choice = .save;
    try actions.close(context);
    try dialog.close(context);
    if (choice) |unsaved| {
        profiles.resolve(unsaved);
    } else if (!is_open.*) {
        // Cancel, Escape and a click outside all close it without an answer.
        profiles.cancel();
        context.requestRedraw();
    }
}

/// The edited profile's accentColor tints the window, or the one a prompt is picking for a new profile.
fn applyAccent(context: *ui.Frame) void {
    const argb = header.previewAccent() orelse import_dialog.previewAccent() orelse session.profile().ptr.accentColor;
    const r: u8 = @truncate(argb >> 16);
    const g: u8 = @truncate(argb >> 8);
    const b: u8 = @truncate(argb);
    const theme = &context.ui().theme;
    theme.primary = .rgba(r, g, b, 255);
    theme.accented = .rgba(towardWhite(r), towardWhite(g), towardWhite(b), 255);
    const luminance = (0.299 * @as(f32, @floatFromInt(r)) + 0.587 * @as(f32, @floatFromInt(g)) + 0.114 * @as(f32, @floatFromInt(b))) / 255.0;
    theme.on_primary = if (luminance > 0.55) style.INK_DARK else style.INK_LIGHT;
}

/// The hover shade: 15% of the way to white.
fn towardWhite(channel: u8) u8 {
    return channel + @as(u8, @intFromFloat(@round(@as(f32, @floatFromInt(255 - channel)) * 0.15)));
}
