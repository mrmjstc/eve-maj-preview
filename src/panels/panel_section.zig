//! What the header panels' settings sections share, reached by the section's Config field name: staying on top, locking, opacity, folding and position.
const panel_window = @import("../platform/panel_window.zig");
const config_mod = @import("../config.zig");
const panel_menu_look = @import("panel_menu_look.zig");

const Config = config_mod.Config;
const PanelWindow = panel_window.PanelWindow;
const ProfileStore = config_mod.ProfileStore;

/// The ⋯ menu for the panel whose settings `section` names; a panel with grouping or an order fills those in itself.
pub fn menuContents(config: *const Config, comptime section: []const u8, settings_label: []const u8, can_hide: bool) panel_menu_look.Contents {
    const settings = &@field(config, section);
    return .{
        .is_on_top = settings.alwaysOnTop,
        .is_locked = settings.lockPosition,
        .opacity = settings.opacity,
        .settings_label = settings_label,
        .can_hide = can_hide,
        .accent = config.accentColor,
    };
}

/// Runs keep on top, lock and opacity; false for an action left to the panel.
pub fn runMenuAction(store: *ProfileStore, comptime section: []const u8, action: panel_menu_look.Action) bool {
    switch (action) {
        .toggle => |toggle| switch (toggle) {
            .keep_on_top => toggleOnTop(store, section),
            .lock_position => store.updateSection(section, .{ .lockPosition = !@field(store.live, section).lockPosition }),
            .group_by_system => return false,
        },
        .opacity => |opacity| if (opacity.is_final) store.updateSection(section, .{ .opacity = opacity.value }) else store.previewSection(section, .{ .opacity = opacity.value }),
        .order, .command => return false,
    }
    return true;
}

/// The header's pin and the menu's Keep on Top.
pub fn toggleOnTop(store: *ProfileStore, comptime section: []const u8) void {
    store.updateSection(section, .{ .alwaysOnTop = !@field(store.live, section).alwaysOnTop });
}

pub fn toggleCollapsed(store: *ProfileStore, comptime section: []const u8) void {
    store.updateSection(section, .{ .collapsed = !@field(store.live, section).collapsed });
}

/// For a panel keeping its own x and y, while its section remembers its position.
pub fn savePosition(store: *ProfileStore, comptime section: []const u8, panel: *const PanelWindow) void {
    if (!@field(store.live, section).rememberPosition) return;
    const top_left = panel.topLeft() orelse return;
    store.updateSection(section, .{ .x = top_left.x, .y = top_left.y });
}
