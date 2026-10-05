//! The configuration window's frame: tab sidebar, the open tab, the Save footer and the unsaved-changes prompt; main thread only.
const std = @import("std");
const knots = @import("knots");
const ui = @import("ui");
const host = @import("host.zig");
const session = @import("session.zig");
const style = @import("style.zig");
const widgets = @import("widgets.zig");
const header = @import("header.zig");
const status = @import("status.zig");
const about = @import("tabs/about.zig");
const thumbnails = @import("tabs/thumbnails.zig");
const characters = @import("tabs/characters.zig");
const behavior = @import("tabs/behavior.zig");
const chatlog = @import("tabs/chatlog.zig");
const notifications = @import("tabs/notifications.zig");
const overlays = @import("tabs/overlays.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Dialog = ui.component.Dialog;

const Tab = enum {
    about,
    general,
    thumbnails,
    characters,
    behavior,
    hotkeys,
    hotkey_groups,
    chatlog,
    notifications,
    combat,
    mining,
    bounty,
    resources,

    fn label(tab: Tab) []const u8 {
        return switch (tab) {
            .about => "About",
            .general => "General",
            .thumbnails => "Thumbnails",
            .characters => "Characters",
            .behavior => "Behavior",
            .hotkeys => "Hotkeys",
            .hotkey_groups => "Hotkey Groups",
            .chatlog => "Chat Logs",
            .notifications => "Notifications",
            .combat => "Combat",
            .mining => "Mining",
            .bounty => "Bounty",
            .resources => "Resources",
        };
    }

    /// Shown only in Advanced Mode.
    fn isAdvanced(tab: Tab) bool {
        return switch (tab) {
            .general, .combat, .mining, .bounty, .resources => true,
            .about, .thumbnails, .characters, .behavior, .hotkeys, .hotkey_groups, .chatlog, .notifications => false,
        };
    }

    /// Fills the content area itself instead of scrolling in it.
    fn fills(tab: Tab) bool {
        return switch (tab) {
            .characters => true,
            .about, .general, .thumbnails, .behavior, .hotkeys, .hotkey_groups, .chatlog, .notifications, .combat, .mining, .bounty, .resources => false,
        };
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
    applyAccent(context);
    const advanced = session.global().get("advancedMode");
    // Turning Advanced Mode off hides the open tab if it's an advanced one.
    if (!advanced and g_tab.isAdvanced()) g_tab = .about;
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
    try sidebar(context, advanced);
    const content = Rect{ .key = .src(@src()), .style = if (g_tab.fills()) &style.content_fill else &style.content_scroll };
    _ = try content.open(context);
    switch (g_tab) {
        .about => try about.show(context),
        .thumbnails => try thumbnails.show(context),
        .characters => try characters.show(context),
        .behavior => try behavior.show(context),
        .chatlog => try chatlog.show(context),
        .notifications => try notifications.show(context),
        .combat => try overlays.showCombat(context),
        .mining => try overlays.showMining(context),
        .bounty => try overlays.showBounty(context),
        .resources => try overlays.showResources(context),
        .general, .hotkeys, .hotkey_groups => try notPorted(context),
    }
    try content.close(context);
    try body.close(context);

    try footer(context);
    try unsavedPrompt(context);

    try root.close(context);
}

fn sidebar(context: *ui.Frame, advanced: bool) !void {
    const bar = Rect{ .key = .src(@src()), .style = &style.sidebar };
    _ = try bar.open(context);
    for (std.enums.values(Tab)) |tab| {
        if (!advanced and tab.isAdvanced()) continue;
        const is_active = g_tab == tab;
        const item = Button{
            .key = ui.Key.str("knots.tab").indexed(@intFromEnum(tab)),
            .label = tab.label(),
            .style = if (is_active) &style.tab_item_active else &style.tab_item,
        };
        if ((try context.interact(item)).clicked and !is_active) {
            g_tab = tab;
            context.requestRedraw();
        }
    }
    try bar.close(context);
}

fn notPorted(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Not ported yet", "", .none, &style.section);
    try widgets.hintText(context, .str("knots.not_ported"), "This tab is still in the WebView2 configuration window.");
    try section.close(context);
}

fn footer(context: *ui.Frame) !void {
    const bar = Rect{ .key = .src(@src()), .style = &style.footer };
    _ = try bar.open(context);
    const is_dirty = session.isDirty();
    try context.e(Text{ .key = .src(@src()), .content = status.text(), .style = switch (status.kind()) {
        .info => &style.status_info,
        .success => &style.status_success,
        .failure => &style.status_failure,
    } });
    try context.e(Rect{ .key = .src(@src()), .style = &.{ .width = .grow() } });
    if (is_dirty) try context.e(Text{ .key = .src(@src()), .content = "Unsaved changes", .style = &style.unsaved_chip });
    if ((try context.interact(Button{ .key = .src(@src()), .label = "Discard", .disabled = !is_dirty, .style = if (is_dirty) &style.plain_button else &style.disabled_button })).clicked) {
        host.postCommand(.discard);
    }
    if ((try context.interact(Button{ .key = .src(@src()), .label = "Save", .disabled = !is_dirty, .style = if (is_dirty) &style.primary_button else &style.disabled_button })).clicked) {
        host.postCommand(.save);
    }
    try bar.close(context);
}

fn unsavedPrompt(context: *ui.Frame) !void {
    if (!g_confirm_close) return;
    const dialog = Dialog{ .is_open = &g_confirm_close, .key = .src(@src()), .style = &style.modal };
    _ = try dialog.open(context);
    try context.e(Text{ .key = .src(@src()), .content = "Unsaved Changes", .style = &style.heading });
    try context.e(Text{ .key = .src(@src()), .content = "Save your changes before closing?", .style = &style.modal_text });
    const actions = Rect{ .key = .src(@src()), .style = &style.modal_actions };
    _ = try actions.open(context);
    if ((try context.interact(Button{ .key = .src(@src()), .label = "Cancel", .style = &style.plain_button })).clicked) {
        g_confirm_close = false;
        context.requestRedraw();
    }
    if ((try context.interact(Button{ .key = .src(@src()), .label = "Discard", .style = &style.plain_button })).clicked) {
        g_confirm_close = false;
        host.postCommand(.discard_and_close);
    }
    if ((try context.interact(Button{ .key = .src(@src()), .label = "Save", .style = &style.primary_button })).clicked) {
        g_confirm_close = false;
        host.postCommand(.save_and_close);
    }
    try actions.close(context);
    try dialog.close(context);
}

/// The edited profile's accentColor tints the window, like the page's applyAccentColorTheme.
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
