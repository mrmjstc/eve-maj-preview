const std = @import("std");
const win32 = @import("win32.zig");
const config_mod = @import("config.zig");
const log = @import("log.zig");
const update = @import("update.zig");
const manager_mod = @import("manager.zig");
const slog = log.scoped("tray");

// Global state for pending profile switch (accessed by menu handler)
pub var g_pending_profile_name: ?[]const u8 = null;
var g_profile_list_cache: ?std.ArrayList([]const u8) = null;
var g_allocator_cache: ?std.mem.Allocator = null;

pub const TrayIcon = struct {
    hwnd: win32.HWND,
    nid: win32.NOTIFYICONDATAA,
    allocator: std.mem.Allocator,
    owns_icon: bool,

    pub fn init(allocator: std.mem.Allocator, hwnd: win32.HWND) !TrayIcon {
        var tray = TrayIcon{
            .hwnd = hwnd,
            .nid = std.mem.zeroes(win32.NOTIFYICONDATAA),
            .allocator = allocator,
            .owns_icon = false,
        };

        g_allocator_cache = allocator;

        tray.nid.cbSize = @sizeOf(win32.NOTIFYICONDATAA);
        tray.nid.hWnd = hwnd;
        tray.nid.uID = 1;
        tray.nid.uFlags = win32.NIF_MESSAGE | win32.NIF_ICON | win32.NIF_TIP;
        tray.nid.uCallbackMessage = win32.WM_TRAYICON;

        const icon_path = "icon.ico";
        const custom_icon = win32.LoadImageA(
            null,
            icon_path,
            win32.IMAGE_ICON,
            16,
            16,
            win32.LR_LOADFROMFILE,
        );

        tray.nid.hIcon = if (custom_icon) |icon| blk: {
            tray.owns_icon = true;
            break :blk @ptrCast(icon);
        } else blk: {
            slog.warn("Failed to load custom tray icon, using default", .{});
            break :blk win32.LoadIconA(null, win32.IDI_APPLICATION) orelse {
                slog.err("Failed to load application icon", .{});
                return error.LoadIconFailed;
            };
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

        if (self.owns_icon) {
            _ = win32.DestroyIcon(self.nid.hIcon);
        }

        if (g_profile_list_cache) |*profiles| {
            for (profiles.items) |profile| {
                self.allocator.free(profile);
            }
            profiles.deinit(self.allocator);
            g_profile_list_cache = null;
        }
        g_allocator_cache = null;

        slog.debug("System tray icon removed", .{});
    }

    /// Show a Windows tray balloon notification; `title`/`text` are truncated to fit szInfoTitle/szInfo (63/255 bytes) if longer.
    pub fn showBalloon(self: *TrayIcon, title: []const u8, text: []const u8, info_flags: win32.DWORD) void {
        const title_len = @min(title.len, self.nid.szInfoTitle.len - 1);
        @memcpy(self.nid.szInfoTitle[0..title_len], title[0..title_len]);
        self.nid.szInfoTitle[title_len] = 0;

        const text_len = @min(text.len, self.nid.szInfo.len - 1);
        @memcpy(self.nid.szInfo[0..text_len], text[0..text_len]);
        self.nid.szInfo[text_len] = 0;

        self.nid.dwInfoFlags = info_flags;
        self.nid.uFlags |= win32.NIF_INFO;

        if (win32.Shell_NotifyIconA(win32.NIM_MODIFY, &self.nid) == 0) {
            slog.warn("Failed to show tray balloon notification", .{});
        }
    }

    pub fn handleTrayMessage(self: *TrayIcon, lParam: win32.LPARAM, current_profile: []const u8, config: *const config_mod.Config, hotkey_manager: ?*@import("hotkeys.zig").HotkeyManager, painter: ?*@import("painter.zig").Painter) void {
        if (lParam == win32.WM_RBUTTONUP) {
            self.showContextMenu(current_profile, config, hotkey_manager, painter);
        } else if (lParam == win32.WM_LBUTTONDBLCLK) {
            slog.info("Opening configuration dialog from system tray double-click", .{});
            openConfigDialog();
        }
    }

    pub fn showContextMenu(self: *TrayIcon, current_profile: []const u8, config: *const config_mod.Config, hotkey_manager: ?*@import("hotkeys.zig").HotkeyManager, painter: ?*@import("painter.zig").Painter) void {
        var cursor_pos: win32.POINT = undefined;
        if (win32.GetCursorPos(&cursor_pos) == 0) {
            slog.err("Failed to get cursor position", .{});
            return;
        }

        const menu = win32.CreatePopupMenu() orelse {
            slog.err("Failed to create popup menu", .{});
            return;
        };
        defer _ = win32.DestroyMenu(menu);

        const profile_submenu = win32.CreatePopupMenu() orelse {
            slog.err("Failed to create profile submenu", .{});
            return;
        };
        // Submenu is destroyed automatically when the parent menu is destroyed.

        const profiles = config_mod.GlobalSettings.enumerateProfiles(self.allocator) catch |err| blk: {
            slog.err("Failed to enumerate profiles: {}", .{err});
            break :blk std.ArrayList([]const u8).empty;
        };

        if (g_profile_list_cache) |*old_profiles| {
            for (old_profiles.items) |profile| {
                self.allocator.free(profile);
            }
            old_profiles.deinit(self.allocator);
        }
        g_profile_list_cache = profiles;

        for (profiles.items, 0..) |profile, i| {
            // Safety limit - keeps IDs within the IDM_PROFILE_BASE range.
            if (i < 1000) {
                const menu_id: u16 = win32.IDM_PROFILE_BASE + @as(u16, @intCast(i));
                const profile_z = self.allocator.dupeZ(u8, profile) catch continue;
                defer self.allocator.free(profile_z);

                const flags: u32 = if (std.mem.eql(u8, profile, current_profile))
                    win32.MF_STRING | win32.MF_CHECKED
                else
                    win32.MF_STRING;

                _ = win32.AppendMenuA(profile_submenu, flags, menu_id, profile_z.ptr);
            }
        }

        if (profiles.items.len == 0) {
            _ = win32.AppendMenuA(profile_submenu, win32.MF_STRING, 0, "(No profiles found)");
        }

        _ = win32.AppendMenuA(menu, win32.MF_POPUP, @intFromPtr(profile_submenu), "Load Profile");
        _ = win32.AppendMenuA(menu, win32.MF_STRING, win32.IDM_OPEN_CONFIG, "Open Configuration...");
        _ = win32.AppendMenuA(menu, win32.MF_SEPARATOR, 0, null);

        const dragging_flags: u32 = if (config.interaction.enableDragging)
            win32.MF_STRING | win32.MF_CHECKED
        else
            win32.MF_STRING;
        _ = win32.AppendMenuA(menu, dragging_flags, win32.IDM_TOGGLE_DRAGGING, "Enable Dragging");

        const auto_minimize_flags: u32 = if (config.autoMinimize.enabled)
            win32.MF_STRING | win32.MF_CHECKED
        else
            win32.MF_STRING;
        _ = win32.AppendMenuA(menu, auto_minimize_flags, win32.IDM_TOGGLE_AUTO_MINIMIZE, "Enable Auto-Minimize");

        const visibility_flags: u32 = if (config.display.viewMode == .Nothing)
            win32.MF_STRING | win32.MF_GRAYED
        else if (painter) |p| blk: {
            // Check if thumbnails are currently visible (check first thumbnail)
            const is_visible = if (p.thumbnails.items.len > 0)
                p.thumbnails.items[0].visibility_state == .Visible
            else
                // No thumbnails: default to visible state.
                true;
            break :blk if (is_visible) win32.MF_STRING | win32.MF_CHECKED else win32.MF_STRING;
        } else win32.MF_STRING;
        _ = win32.AppendMenuA(menu, visibility_flags, win32.IDM_TOGGLE_VISIBILITY, "Show Thumbnails");
        _ = win32.AppendMenuA(menu, win32.MF_SEPARATOR, 0, null);

        const history_panel_visible = if (painter) |p| p.isNotifInfoPanelVisible() else config.display.showNotifInfoPanel;
        const history_panel_flags: u32 = if (history_panel_visible)
            win32.MF_STRING | win32.MF_CHECKED
        else
            win32.MF_STRING;
        _ = win32.AppendMenuA(menu, history_panel_flags, win32.IDM_TOGGLE_NOTIF_HISTORY, "Show History Panel");
        _ = win32.AppendMenuA(menu, win32.MF_STRING, win32.IDM_CLEAR_NOTIF_HISTORY, "Clear Notification History");
        _ = win32.AppendMenuA(menu, win32.MF_SEPARATOR, 0, null);

        if (hotkey_manager) |hkm| {
            const suspend_flags: u32 = if (hkm.areHotkeysSuspended())
                win32.MF_STRING | win32.MF_CHECKED
            else
                win32.MF_STRING;
            _ = win32.AppendMenuA(menu, suspend_flags, win32.IDM_SUSPEND_HOTKEYS, "Suspend Hotkeys");
            _ = win32.AppendMenuA(menu, win32.MF_SEPARATOR, 0, null);
        }

        if (update.g_update_status.isAvailable()) {
            slog.debug("Adding update menu item", .{});
            _ = win32.AppendMenuA(menu, win32.MF_STRING, win32.IDM_UPDATE, "Update Available!");
            _ = win32.AppendMenuA(menu, win32.MF_SEPARATOR, 0, null);
        }

        _ = win32.AppendMenuA(menu, win32.MF_STRING, win32.IDM_CLOSE_ALL_CLIENTS, "Close All Clients");
        _ = win32.AppendMenuA(menu, win32.MF_SEPARATOR, 0, null);
        _ = win32.AppendMenuA(menu, win32.MF_STRING, win32.IDM_EXIT, "Exit");

        // Required to make menu disappear when clicking outside
        _ = win32.SetForegroundWindow(self.hwnd);

        _ = win32.TrackPopupMenu(
            menu,
            win32.TPM_RIGHTBUTTON | win32.TPM_BOTTOMALIGN,
            cursor_pos.x,
            cursor_pos.y,
            0,
            self.hwnd,
            null,
        );
    }

    pub fn handleMenuCommand(command_id: u16, config: *config_mod.Config, allocator: std.mem.Allocator, hotkey_manager: ?*@import("hotkeys.zig").HotkeyManager) bool {
        if (command_id == win32.IDM_EXIT) {
            slog.info("Exit requested from system tray", .{});
            win32.PostQuitMessage(0);
            return true;
        }

        if (command_id == win32.IDM_TOGGLE_DRAGGING) {
            config.interaction.enableDragging = !config.interaction.enableDragging;
            const state = if (config.interaction.enableDragging) "enabled" else "disabled";
            slog.info("Thumbnail dragging toggled: {s}", .{state});

            const profile_path = std.fs.path.join(allocator, &[_][]const u8{ config_mod.PROFILES_DIR, config.profile_name }) catch |err| {
                slog.err("Failed to build profile path for save: {}", .{err});
                return true;
            };
            defer allocator.free(profile_path);

            config_mod.Config.saveToJsonFile(config, allocator, profile_path) catch |err| {
                slog.err("Failed to save config after toggling dragging: {}", .{err});
            };

            return true;
        }

        if (command_id == win32.IDM_OPEN_CONFIG) {
            slog.info("Opening configuration dialog from system tray", .{});
            openConfigDialog();
            return true;
        }

        if (command_id == win32.IDM_TOGGLE_AUTO_MINIMIZE) {
            // Toggle the auto-minimize setting temporarily (not saved)
            config.autoMinimize.enabled = !config.autoMinimize.enabled;
            const state = if (config.autoMinimize.enabled) "enabled" else "disabled";
            slog.info("Auto-minimize toggled: {s}", .{state});
            return true;
        }

        if (command_id == win32.IDM_TOGGLE_VISIBILITY) {
            slog.info("Toggle visibility requested from system tray", .{});
            const main_mod = @import("main.zig");
            if (main_mod.g_timer_hwnd) |hwnd| {
                _ = win32.PostMessageA(hwnd, win32.WM_TOGGLE_VISIBILITY, 0, 0);
            } else {
                slog.err("Timer window not available for toggle visibility", .{});
            }
            return true;
        }

        if (command_id == win32.IDM_TOGGLE_NOTIF_HISTORY) {
            slog.info("Toggle history panel requested from system tray", .{});
            const painter_mod = @import("painter.zig");
            if (painter_mod.g_painter_ptr) |painter_ptr| {
                painter_ptr.toggleNotifInfoPanel();

                const profile_path = std.fs.path.join(allocator, &[_][]const u8{ config_mod.PROFILES_DIR, config.profile_name }) catch |err| {
                    slog.err("Failed to build profile path for save: {}", .{err});
                    return true;
                };
                defer allocator.free(profile_path);

                config_mod.Config.saveToJsonFile(config, allocator, profile_path) catch |err| {
                    slog.err("Failed to save config after toggling history panel: {}", .{err});
                };
            } else {
                slog.err("Painter not available for toggle history panel", .{});
            }
            return true;
        }

        if (command_id == win32.IDM_CLEAR_NOTIF_HISTORY) {
            slog.info("Clear notification history requested from system tray", .{});
            const painter_mod = @import("painter.zig");
            if (painter_mod.g_painter_ptr) |painter_ptr| {
                painter_ptr.clearNotificationHistory();
            } else {
                slog.err("Painter not available for clear notification history", .{});
            }
            return true;
        }

        if (command_id == win32.IDM_SUSPEND_HOTKEYS) {
            if (hotkey_manager) |hkm| {
                hkm.handleSuspendHotkeysRequest();
            }
            return true;
        }

        if (command_id == win32.IDM_CLOSE_ALL_CLIENTS) {
            slog.info("Close all clients requested from system tray", .{});
            const main_mod = @import("main.zig");
            if (main_mod.g_scout_ptr) |scout_ptr| {
                manager_mod.closeAllClients(scout_ptr.getWindows(), config);
            } else {
                slog.err("Scout not available for close all clients", .{});
            }
            return true;
        }

        if (command_id == win32.IDM_UPDATE) {
            slog.info("Opening releases page from tray menu", .{});
            update.openReleasesPage();
            return true;
        }

        if (command_id >= win32.IDM_PROFILE_BASE and command_id < win32.IDM_PROFILE_BASE + 1000) {
            const profile_idx = command_id - win32.IDM_PROFILE_BASE;

            if (g_profile_list_cache) |profiles| {
                if (profile_idx < profiles.items.len) {
                    const selected_profile = profiles.items[profile_idx];
                    slog.info("Profile selected from menu: {s}", .{selected_profile});

                    g_pending_profile_name = selected_profile;

                    const main_mod = @import("main.zig");
                    if (main_mod.g_timer_hwnd) |hwnd| {
                        _ = win32.PostMessageA(hwnd, win32.WM_SWITCH_PROFILE, 0, 0);
                    } else {
                        slog.err("Timer window not available for profile switch", .{});
                    }

                    return true;
                }
            }
        }

        return false;
    }

    pub fn takePendingProfileName() ?[]const u8 {
        const result = g_pending_profile_name;
        g_pending_profile_name = null;
        return result;
    }
};

/// Launch config.exe, which is installed alongside the main executable
fn openConfigDialog() void {
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = std.fs.selfExeDirPath(&exe_dir_buf) catch {
        slog.err("Failed to determine executable directory", .{});
        return;
    };

    var dir_z_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const exe_dir_z = std.fmt.bufPrintZ(&dir_z_buf, "{s}", .{exe_dir}) catch {
        slog.err("Executable directory path too long", .{});
        return;
    };

    var path_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const config_exe_path = std.fmt.bufPrintZ(&path_buf, "{s}\\config.exe", .{exe_dir}) catch {
        slog.err("Failed to build config.exe path", .{});
        return;
    };

    slog.info("Launching configuration dialog: {s}", .{config_exe_path});

    const result = win32.ShellExecuteA(
        null,
        "open",
        config_exe_path.ptr,
        null,
        exe_dir_z.ptr,
        win32.SW_SHOW,
    );

    if (@intFromPtr(result) <= 32) {
        slog.err("Failed to launch config.exe, error code: {}", .{@intFromPtr(result)});
    }
}
