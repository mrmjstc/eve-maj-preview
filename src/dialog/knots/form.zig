//! The configuration window's frame: categorised tab sidebar, the open tab, the Save footer and the unsaved-changes prompt; main thread only.
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
const status = @import("status.zig");
const about = @import("tabs/about.zig");
const general = @import("tabs/general.zig");
const hotkeys = @import("tabs/hotkeys.zig");
const hotkey_groups = @import("tabs/hotkey_groups.zig");
const display = @import("tabs/display.zig");
const characters = @import("tabs/characters.zig");
const behavior = @import("tabs/behavior.zig");
const chatlog = @import("tabs/chatlog.zig");
const notifications = @import("tabs/notifications.zig");
const overlays = @import("tabs/overlays.zig");
const placement = @import("tabs/placement.zig");
const text_overlays = @import("tabs/text_overlays.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Dialog = ui.component.Dialog;
const Canvas = ui.component.Canvas;

const CONTENT_KEY: ui.Key = .str("knots.content");
const SEARCH_KEY: ui.Key = .str("knots.search");

/// A heading in the sidebar over the tabs that belong to it.
const Category = enum {
    clients,
    display,
    input,
    alerts,
    overlays,
    app,

    fn label(category: Category) []const u8 {
        return switch (category) {
            .clients => "CLIENTS",
            .display => "DISPLAY",
            .input => "INPUT",
            .alerts => "ALERTS",
            .overlays => "OVERLAYS",
            .app => "APP",
        };
    }
};

/// In sidebar order, each category's tabs together.
const Tab = enum {
    characters,
    hotkey_groups,
    appearance,
    placement,
    text_overlays,
    hotkeys,
    behavior,
    notifications,
    chatlog,
    combat,
    mining,
    bounty,
    resources,
    general,
    about,

    fn label(tab: Tab) []const u8 {
        return switch (tab) {
            .characters => "Characters",
            .hotkey_groups => "Hotkey Groups",
            .appearance => "Appearance",
            .placement => "Placement",
            .text_overlays => "Text Overlays",
            .hotkeys => "Hotkeys",
            .behavior => "Behavior",
            .notifications => "Notifications",
            .chatlog => "Log Monitoring",
            .combat => "Combat",
            .mining => "Mining",
            .bounty => "Bounty",
            .resources => "Resources",
            .general => "General",
            .about => "About",
        };
    }

    fn category(tab: Tab) Category {
        return switch (tab) {
            .characters, .hotkey_groups => .clients,
            .appearance, .placement, .text_overlays => .display,
            .hotkeys, .behavior => .input,
            .notifications, .chatlog => .alerts,
            .combat, .mining, .bounty, .resources => .overlays,
            .general, .about => .app,
        };
    }

    fn glyph(tab: Tab) glyphs.Glyph {
        return switch (tab) {
            .characters => .list,
            .hotkey_groups => .split_square,
            .appearance => .thumbnail,
            .placement => .tiles,
            .text_overlays => .letter_t,
            .hotkeys => .keyboard,
            .behavior => .spokes,
            .notifications => .envelope,
            .chatlog => .magnifier,
            .combat => .swords,
            .mining => .diamond,
            .bounty => .dollar,
            .resources => .striped_square,
            .general => .gear,
            .about => .star,
        };
    }

    /// Shown only in Advanced Mode.
    fn isAdvanced(tab: Tab) bool {
        return switch (tab) {
            .combat, .mining, .bounty, .resources, .general => true,
            .characters, .hotkey_groups, .appearance, .placement, .text_overlays, .hotkeys, .behavior, .notifications, .chatlog, .about => false,
        };
    }

    /// Shown only while clients are shown as thumbnails.
    fn needsThumbnails(tab: Tab) bool {
        return switch (tab) {
            .placement, .text_overlays => true,
            .characters, .hotkey_groups, .appearance, .hotkeys, .behavior, .notifications, .chatlog, .combat, .mining, .bounty, .resources, .general, .about => false,
        };
    }

    /// Fills the content area itself instead of scrolling in it.
    fn fills(tab: Tab) bool {
        return switch (tab) {
            .characters, .hotkey_groups => true,
            .placement => placement.fillsWindow(),
            .appearance, .text_overlays, .hotkeys, .behavior, .notifications, .chatlog, .combat, .mining, .bounty, .resources, .general, .about => false,
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
    advanced: bool,
    thumbnails: bool,

    fn has(offered: Offered, tab: Tab) bool {
        if (!offered.advanced and tab.isAdvanced()) return false;
        if (!offered.thumbnails and tab.needsThumbnails()) return false;
        return true;
    }
};

var g_tab: Tab = .about;
var g_confirm_close: bool = false;

/// The window's close button was pressed with unsaved changes.
pub fn confirmClose() void {
    g_confirm_close = true;
}

pub fn frame(_: *knots.View, context: *ui.Frame) !void {
    session.beginFrame();
    widgets.beginFrame();
    search.beginFrame();
    try hotkey.beginFrame(context.arena());
    applyAccent(context);
    const offered = Offered{
        .advanced = session.global().get("advancedMode"),
        .thumbnails = session.showsThumbnails(),
    };
    // Turning Advanced Mode off or leaving thumbnail mode can hide the open tab.
    if (!offered.has(g_tab)) selectTab(context, if (g_tab.needsThumbnails()) .appearance else .about);
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
    const fill = Rect{ .key = CONTENT_KEY, .style = &style.content_fill };
    var scroll: ?widgets.ScrollPane = null;
    if (g_tab.fills()) {
        _ = try fill.open(context);
    } else {
        scroll = try widgets.openScrollPane(context, CONTENT_KEY, style.content_scroll);
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

    try footer(context);
    try import_dialog.show(context);
    try update_notice.show(context);
    try unsavedPrompt(context);
    // An edit made after what shows it was drawn, e.g. + Add Character under its list, appears on the next frame.
    if (session.takeEdited()) context.requestRedraw();

    try root.close(context);
}

fn showTab(context: *ui.Frame, tab: Tab) !void {
    const was_aligned = widgets.useAlignedRows(true);
    defer _ = widgets.useAlignedRows(was_aligned);
    switch (tab) {
        .about => try about.show(context),
        .appearance => try display.show(context),
        .placement => try placement.show(context),
        .text_overlays => try text_overlays.show(context),
        .characters => try characters.show(context),
        .behavior => try behavior.show(context),
        .chatlog => try chatlog.show(context),
        .notifications => try notifications.show(context),
        .combat => try overlays.showCombat(context),
        .mining => try overlays.showMining(context),
        .bounty => try overlays.showBounty(context),
        .resources => try overlays.showResources(context),
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
    const bar = Rect{ .key = .src(@src()), .style = &style.sidebar };
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
                    .content = tab.category().label(),
                    .style = &style.tab_category_text,
                }},
            });
        }
        try tabItem(context, tab);
    }
    try bar.close(context);
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
        .content = tab.label(),
        .style = if (is_active or response.hovered) &style.tab_label_lit else &style.tab_label,
    });
    try item.close(context);
    if (response.clicked and !is_active) selectTab(context, tab);
}

/// The new tab starts at its top.
fn selectTab(context: *ui.Frame, tab: Tab) void {
    g_tab = tab;
    const ui_state = context.ui();
    if (ui_state.state.get(.scroll, CONTENT_KEY.hash())) |scroll| scroll.offset = .{ 0, 0 };
    context.requestRedraw();
}

fn footer(context: *ui.Frame) !void {
    const bar = Rect{ .key = .src(@src()), .style = &style.footer };
    _ = try bar.open(context);
    try searchBox(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = status.text(), .style = switch (status.kind()) {
        .info => &style.status_info,
        .success => &style.status_success,
        .failure => &style.status_failure,
    } });
    try context.e(Rect{ .key = .src(@src()), .style = &.{ .width = .grow() } });
    if (session.isDirty()) try context.e(.{
        Rect{ .key = .src(@src()), .style = &style.unsaved_chip },
        .{
            Text{ .selectable = false, .key = .src(@src()), .content = "●", .style = &style.unsaved_dot },
            Text{ .selectable = false, .key = .src(@src()), .content = "Unsaved changes", .style = &style.unsaved_text },
        },
    });
    if ((try context.interact(Button{ .key = .src(@src()), .label = "Close", .style = &style.outline_button })).clicked) {
        host.requestClose();
    }
    if ((try context.interact(Button{ .key = .src(@src()), .label = "Save", .style = &style.primary_button })).clicked) {
        host.postCommand(.save);
    }
    try bar.close(context);
}

/// The settings search: the box, its clear button, and how many sections match.
fn searchBox(context: *ui.Frame) !void {
    const box = Rect{ .key = .src(@src()), .style = &style.search_container };
    _ = try box.open(context);
    try context.e(ui.component.TextInput{ .key = SEARCH_KEY, .buf = &search.g_query, .style = &style.search_input, .placeholder = "Search settings..." });
    if (search.g_query.items.len > 0) {
        if ((try context.interact(Button{ .key = .src(@src()), .label = "\u{00D7}", .style = &style.search_clear })).clicked) {
            search.clear();
            context.requestRedraw();
        }
    }
    try box.close(context);
    if (search.isActive() and !search.needsIndex()) {
        const count = search.matchCount();
        const text = if (count == 0) "No matches" else try std.fmt.allocPrint(context.arena(), "{d} {s}", .{ count, if (count == 1) "section" else "sections" });
        try context.e(Text{ .selectable = false, .key = .src(@src()), .content = text, .style = if (count == 0) &style.search_count_none else &style.search_count_some });
    }
}

fn unsavedPrompt(context: *ui.Frame) !void {
    if (!g_confirm_close) return;
    const dialog = Dialog{ .is_open = &g_confirm_close, .key = .src(@src()), .style = &style.modal };
    _ = try dialog.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "Unsaved Changes", .style = &style.heading });
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "You have unsaved changes. Save them before closing, or close without saving?", .style = &style.modal_text });
    const actions = Rect{ .key = .src(@src()), .style = &style.modal_actions };
    _ = try actions.open(context);
    // Furthest from Save, so the destructive choice isn't beside the default one.
    if ((try context.interact(Button{ .key = .src(@src()), .label = "Discard", .style = &style.danger_button })).clicked) {
        g_confirm_close = false;
        host.postCommand(.discard_and_close);
    }
    if ((try context.interact(Button{ .key = .src(@src()), .label = "Cancel", .style = &style.outline_button })).clicked) {
        g_confirm_close = false;
        context.requestRedraw();
    }
    if ((try context.interact(Button{ .key = .src(@src()), .label = "Save", .style = &style.primary_button })).clicked) {
        g_confirm_close = false;
        host.postCommand(.save_and_close);
    }
    try actions.close(context);
    try dialog.close(context);
}

/// The edited profile's accentColor tints the window.
fn applyAccent(context: *ui.Frame) void {
    const argb = header.previewAccent() orelse session.profile().ptr.accentColor;
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
