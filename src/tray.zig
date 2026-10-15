//! The notification-area icon and its right-click menu.
const std = @import("std");
const win32 = @import("platform/win32.zig");
const config_mod = @import("config.zig");
const update = @import("update.zig");
const actions = @import("clients/actions.zig");
const app_mod = @import("app.zig");
const knots_host = @import("dialog/knots/host.zig");
const scout = @import("clients/scout.zig");
const alert_effects = @import("notifications/alert_effects.zig");
const log = @import("log.zig");

const App = app_mod.App;
const slog = log.Scoped("tray");

/// Keeps profile item IDs inside their range above IDM_PROFILE_BASE.
const MAX_PROFILE_ITEMS = 1000;

/// Keeps each group submenu's item IDs inside their range above its base.
const MAX_GROUP_ITEMS = 1000;

/// An item in one of the group submenus.
const GroupCommand = struct {
    group_index: usize,
    action: actions.GroupAction,
};

pub const TrayIcon = struct {
    hwnd: win32.HWND,
    nid: win32.NOTIFYICONDATAA,
    allocator: std.mem.Allocator,
    owns_icon: bool,
    /// The profiles the menu last listed, which a profile item's ID indexes into; owned, freed by freeProfiles.
    profiles: std.ArrayList([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, hwnd: win32.HWND) !TrayIcon {
        var tray: TrayIcon = .{
            .hwnd = hwnd,
            .nid = std.mem.zeroes(win32.NOTIFYICONDATAA),
            .allocator = allocator,
            .owns_icon = false,
        };

        tray.nid.cbSize = @sizeOf(win32.NOTIFYICONDATAA);
        tray.nid.hWnd = hwnd;
        tray.nid.uID = 1;
        tray.nid.uFlags = win32.NIF_MESSAGE | win32.NIF_ICON | win32.NIF_TIP;
        tray.nid.uCallbackMessage = win32.WM_TRAYICON;

        const app_icon = win32.LoadImageA(win32.GetModuleHandleA(null), @ptrFromInt(win32.APP_ICON_ID), win32.IMAGE_ICON, 16, 16, 0);
        tray.nid.hIcon = if (app_icon) |icon| blk: {
            tray.owns_icon = true;
            break :blk @ptrCast(icon);
        } else blk: {
            slog.warn("Failed to load the app icon for the tray, using the default", .{});
            break :blk win32.LoadIconA(null, win32.IDI_APPLICATION) orelse {
                slog.err("Failed to load application icon", .{});
                return error.LoadIconFailed;
            };
        };
        errdefer if (tray.owns_icon) {
            _ = win32.DestroyIcon(tray.nid.hIcon);
        };

        const tip = "EVE-Maj Preview";
        @memcpy(tray.nid.szTip[0..tip.len], tip);
        tray.nid.szTip[tip.len] = 0;

        if (win32.Shell_NotifyIconA(win32.NIM_ADD, &tray.nid) == 0) {
            slog.err("Failed to add system tray icon", .{});
            return error.AddTrayIconFailed;
        }

        slog.debug("System tray icon created", .{});
        return tray;
    }

    pub fn deinit(self: *TrayIcon) void {
        _ = win32.Shell_NotifyIconA(win32.NIM_DELETE, &self.nid);
        if (self.owns_icon) _ = win32.DestroyIcon(self.nid.hIcon);
        self.freeProfiles();
        slog.debug("System tray icon removed", .{});
    }

    fn freeProfiles(self: *TrayIcon) void {
        for (self.profiles.items) |profile| self.allocator.free(profile);
        self.profiles.deinit(self.allocator);
        self.profiles = .empty;
    }

    pub fn handleTrayMessage(self: *TrayIcon, lParam: win32.LPARAM, app: *App) void {
        if (lParam == win32.WM_RBUTTONUP) {
            self.showContextMenu(app);
        } else if (lParam == win32.WM_LBUTTONDBLCLK) {
            slog.info("Opening configuration dialog from system tray double-click", .{});
            knots_host.open();
        }
    }

    fn showContextMenu(self: *TrayIcon, app: *App) void {
        const config = &app.store.live;
        var cursor_position: win32.POINT = undefined;
        if (!win32.toBool(win32.GetCursorPos(&cursor_position))) {
            slog.err("Failed to get cursor position", .{});
            return;
        }

        const menu = win32.CreatePopupMenu() orelse {
            slog.err("Failed to create popup menu", .{});
            return;
        };
        defer _ = win32.DestroyMenu(menu);

        // Destroyed along with `menu`.
        const profile_menu = win32.CreatePopupMenu() orelse {
            slog.err("Failed to create profile submenu", .{});
            return;
        };
        self.appendProfiles(app.io, profile_menu, config.profile_name);

        _ = win32.AppendMenuA(menu, win32.MF_POPUP, @intFromPtr(profile_menu), "Load Profile");
        _ = win32.AppendMenuA(menu, win32.MF_STRING, win32.IDM_OPEN_CONFIG, "Open Configuration...");
        _ = win32.AppendMenuA(menu, win32.MF_SEPARATOR, 0, null);

        const thumbnail_set = app.thumbnail_set;
        appendChecked(menu, config.interaction.enableDragging, win32.IDM_TOGGLE_DRAGGING, "Enable Dragging");
        appendChecked(menu, app.auto_minimizer.isEnabled(config), win32.IDM_TOGGLE_AUTO_MINIMIZE, "Enable Auto-Minimize");
        appendChecked(menu, config.travel.enabled, win32.IDM_TOGGLE_TRAVEL_MODE, "Enable Travel Mode");
        if (config.display.viewMode == .Nothing) {
            _ = win32.AppendMenuA(menu, win32.MF_STRING | win32.MF_GRAYED, win32.IDM_TOGGLE_VISIBILITY, "Show Thumbnails");
        } else {
            appendChecked(menu, if (thumbnail_set) |p| p.thumbnailsShown() else false, win32.IDM_TOGGLE_VISIBILITY, "Show Thumbnails");
        }
        _ = win32.AppendMenuA(menu, win32.MF_STRING, win32.IDM_RESTORE_SAVED_POSITIONS, "Restore Saved Positions");
        _ = win32.AppendMenuA(menu, win32.MF_SEPARATOR, 0, null);

        appendChecked(menu, app.notifications.panel.isVisible(config, scout.anyCharacterLoggedIn(app.scout.getWindows())), win32.IDM_TOGGLE_NOTIF_HISTORY, "Show Notification History");
        _ = win32.AppendMenuA(menu, win32.MF_STRING, win32.IDM_CLEAR_NOTIF_HISTORY, "Clear Notification History");
        appendChecked(menu, alert_effects.isMuted(), win32.IDM_TOGGLE_ALERT_MUTE, "Mute Audio Alerts");
        _ = win32.AppendMenuA(menu, win32.MF_SEPARATOR, 0, null);

        if (app.hotkey_manager) |manager| {
            appendChecked(menu, manager.areHotkeysSuspended(), win32.IDM_SUSPEND_HOTKEYS, "Suspend Hotkeys");
            _ = win32.AppendMenuA(menu, win32.MF_SEPARATOR, 0, null);
        }

        if (update.g_update_status.isAvailable(app.io)) {
            _ = win32.AppendMenuA(menu, win32.MF_STRING, win32.IDM_UPDATE, "Update Available!");
            _ = win32.AppendMenuA(menu, win32.MF_SEPARATOR, 0, null);
        }

        _ = win32.AppendMenuA(menu, win32.MF_STRING, win32.IDM_CLOSE_ALL_CLIENTS, "Close All Clients");
        self.appendGroupMenu(menu, config.hotkeyGroups.items, win32.IDM_MINIMIZE_GROUP_BASE, "Minimize Group");
        self.appendGroupMenu(menu, config.hotkeyGroups.items, win32.IDM_CLOSE_GROUP_BASE, "Close Group");
        _ = win32.AppendMenuA(menu, win32.MF_SEPARATOR, 0, null);
        _ = win32.AppendMenuA(menu, win32.MF_STRING, win32.IDM_EXIT, "Exit");

        // Without this the menu stays open when clicking elsewhere.
        _ = win32.SetForegroundWindow(self.hwnd);
        _ = win32.TrackPopupMenu(menu, win32.TPM_RIGHTBUTTON | win32.TPM_BOTTOMALIGN, cursor_position.x, cursor_position.y, 0, self.hwnd, null);
    }

    /// Re-reads the profiles, so the list matches the folder each time the menu opens.
    fn appendProfiles(self: *TrayIcon, io: std.Io, profile_menu: win32.HMENU, current_profile: []const u8) void {
        self.freeProfiles();
        self.profiles = config_mod.listProfiles(self.allocator, io) catch |err| blk: {
            slog.err("Failed to enumerate profiles: {}", .{err});
            break :blk .empty;
        };

        if (self.profiles.items.len == 0) {
            _ = win32.AppendMenuA(profile_menu, win32.MF_STRING, 0, "(No profiles found)");
            return;
        }
        const shown = self.profiles.items[0..@min(self.profiles.items.len, MAX_PROFILE_ITEMS)];
        for (shown, 0..) |profile, i| {
            const profile_z = self.allocator.dupeSentinel(u8, profile, 0) catch |err| {
                slog.warn("Failed to copy profile name '{s}' for tray menu: {}", .{ profile, err });
                continue;
            };
            defer self.allocator.free(profile_z);
            appendChecked(profile_menu, std.mem.eql(u8, profile, current_profile), win32.IDM_PROFILE_BASE + i, profile_z);
        }
    }

    /// A submenu of the groups, each item's ID `id_base` plus its index; greyed out when the profile has no groups.
    fn appendGroupMenu(self: *const TrayIcon, menu: win32.HMENU, groups: []const config_mod.HotkeyGroupConfig, id_base: usize, label: [*:0]const u8) void {
        if (groups.len == 0) {
            _ = win32.AppendMenuA(menu, win32.MF_STRING | win32.MF_GRAYED, 0, label);
            return;
        }
        // Destroyed along with `menu`.
        const group_menu = win32.CreatePopupMenu() orelse {
            slog.err("Failed to create the '{s}' submenu", .{std.mem.span(label)});
            return;
        };
        for (groups[0..@min(groups.len, MAX_GROUP_ITEMS)], 0..) |*group, i| {
            var name_buf: [config_mod.HotkeyGroupConfig.DISPLAY_NAME_SIZE]u8 = undefined;
            const name_z = self.allocator.dupeSentinel(u8, group.displayName(&name_buf, i), 0) catch |err| {
                slog.warn("Failed to copy group name '{s}' for tray menu: {}", .{ group.name, err });
                continue;
            };
            defer self.allocator.free(name_z);
            _ = win32.AppendMenuA(group_menu, win32.MF_STRING, id_base + i, name_z);
        }
        _ = win32.AppendMenuA(menu, win32.MF_POPUP, @intFromPtr(group_menu), label);
    }

    pub fn handleMenuCommand(self: *const TrayIcon, command_id: u16, app: *App) void {
        if (command_id >= win32.IDM_PROFILE_BASE and command_id < win32.IDM_PROFILE_BASE + MAX_PROFILE_ITEMS) {
            const index = command_id - win32.IDM_PROFILE_BASE;
            if (index >= self.profiles.items.len) return;
            slog.info("Profile selected from menu: {s}", .{self.profiles.items[index]});
            app.requestProfileSwitch(self.profiles.items[index]);
            return;
        }
        if (groupCommand(command_id)) |command| {
            slog.info("Group {s} requested from system tray", .{@tagName(command.action)});
            actions.applyToGroup(app.scout.getWindows(), &app.store.live, app.store.live.hotkeyGroups.items, command.group_index, command.action);
            return;
        }

        const store = &app.store;
        const config = &store.live;
        switch (command_id) {
            win32.IDM_EXIT => {
                slog.info("Exit requested from system tray", .{});
                app_mod.requestExit();
            },
            win32.IDM_OPEN_CONFIG => {
                slog.info("Opening configuration dialog from system tray", .{});
                knots_host.open();
            },
            win32.IDM_TOGGLE_DRAGGING => {
                const is_enabled = !config.interaction.enableDragging;
                store.update(.{ .interaction = .{ .enableDragging = is_enabled } });
                slog.info("Thumbnail dragging toggled: {s}", .{if (is_enabled) "enabled" else "disabled"});
            },
            win32.IDM_TOGGLE_AUTO_MINIMIZE => app.toggleAutoMinimize(),
            win32.IDM_TOGGLE_TRAVEL_MODE => {
                const is_enabled = !config.travel.enabled;
                store.update(.{ .travel = .{ .enabled = is_enabled } });
                slog.info("Travel Mode toggled: {s}", .{if (is_enabled) "enabled" else "disabled"});
            },
            win32.IDM_TOGGLE_VISIBILITY => {
                slog.info("Toggle visibility requested from system tray", .{});
                const thumbnail_set = app.thumbnail_set orelse {
                    slog.err("Failed to toggle visibility: the thumbnail set isn't ready", .{});
                    return;
                };
                thumbnail_set.toggleAllThumbnailsVisibility();
            },
            win32.IDM_TOGGLE_NOTIF_HISTORY => {
                slog.info("Toggle history panel requested from system tray", .{});
                app.notifications.panel.toggle(app.allocator, store, app.instance, scout.anyCharacterLoggedIn(app.scout.getWindows()));
            },
            win32.IDM_CLEAR_NOTIF_HISTORY => {
                slog.info("Clear notification history requested from system tray", .{});
                app.notifications.history.clear();
            },
            win32.IDM_TOGGLE_ALERT_MUTE => alert_effects.toggleMuted(),
            win32.IDM_SUSPEND_HOTKEYS => {
                if (app.hotkey_manager) |manager| manager.runGlobalAction(.suspend_hotkeys);
            },
            win32.IDM_RESTORE_SAVED_POSITIONS => {
                slog.info("Restore saved positions requested from system tray", .{});
                const manager = app.hotkey_manager orelse {
                    slog.err("Failed to restore saved positions: the hotkey manager isn't ready", .{});
                    return;
                };
                manager.runGlobalAction(.move_to_saved_positions);
            },
            win32.IDM_CLOSE_ALL_CLIENTS => {
                slog.info("Close all clients requested from system tray", .{});
                actions.closeAllClients(app.scout.getWindows(), config, &app.exclusions);
            },
            win32.IDM_UPDATE => {
                slog.info("Opening releases page from tray menu", .{});
                update.openReleasesPage(app.io);
            },
            else => {},
        }
    }
};

/// Null when `command_id` is outside both group submenus' ranges.
fn groupCommand(command_id: u16) ?GroupCommand {
    if (command_id >= win32.IDM_MINIMIZE_GROUP_BASE and command_id < win32.IDM_MINIMIZE_GROUP_BASE + MAX_GROUP_ITEMS) {
        return .{ .group_index = command_id - win32.IDM_MINIMIZE_GROUP_BASE, .action = .minimize };
    }
    if (command_id >= win32.IDM_CLOSE_GROUP_BASE and command_id < win32.IDM_CLOSE_GROUP_BASE + MAX_GROUP_ITEMS) {
        return .{ .group_index = command_id - win32.IDM_CLOSE_GROUP_BASE, .action = .close };
    }
    return null;
}

fn appendChecked(menu: win32.HMENU, is_checked: bool, id: usize, label: [*:0]const u8) void {
    var flags: u32 = win32.MF_STRING;
    if (is_checked) flags |= win32.MF_CHECKED;
    _ = win32.AppendMenuA(menu, flags, id, label);
}
