//! Hotkeys that switch to another app or open a URL.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const focus_grant = @import("../platform/focus_grant.zig");
const config = @import("../config.zig");
const global_config = @import("../config/global.zig");
const cycle_order = @import("cycle_order.zig");
const paste_upload = @import("paste_upload.zig");
const log = @import("../log.zig");

const slog = log.Scoped("hotkeys");

const FindByExecutableContext = struct {
    executable_name: []const u8,
    found: ?win32.HWND = null,
};

/// Clears `last_non_eve_foreground` if the window it names has since closed.
pub fn returnToLastApp(last_non_eve_foreground: *?win32.HWND) void {
    const target = last_non_eve_foreground.* orelse {
        slog.debug("Return to last app hotkey pressed - no previous non-EVE window recorded", .{});
        return;
    };

    if (!win32.isWindow(target)) {
        slog.debug("Return to last app hotkey pressed - previous window no longer exists", .{});
        last_non_eve_foreground.* = null;
        return;
    }

    slog.info("Return to last app hotkey pressed", .{});
    focusWindow(target);
}

pub fn activateApp(global_settings: *const config.GlobalConfig, app_index: usize) void {
    if (app_index >= global_settings.appHotkeys.items.len) {
        slog.err("Failed to activate app: hotkey index {} is out of range", .{app_index});
        return;
    }
    const app_hotkey = global_settings.appHotkeys.items[app_index];

    const target = findWindowByExecutable(app_hotkey.executableName) orelse {
        slog.debug("Activate app hotkey pressed - no running window found for {s}", .{app_hotkey.executableName});
        return;
    };

    slog.info("Activate app hotkey pressed: {s}", .{app_hotkey.executableName});
    focusWindow(target);
}

/// Steps through the App Hotkeys list, in its order, to the next app with a running window: on from the app in front, else from the list's start or end.
pub fn cycleApps(global_settings: *const config.GlobalConfig, is_forward: bool) void {
    const apps = global_settings.appHotkeys.items;
    const current = foregroundAppIndex(apps);
    var it = cycle_order.CycleOrder.init(current, apps.len, .{ .is_forward = is_forward });
    while (it.next()) |index| {
        const name = apps[index].executableName;
        if (name.len == 0) continue;
        // The list can name the app in front more than once.
        if (current) |current_index| {
            if (std.ascii.eqlIgnoreCase(apps[current_index].executableName, name)) continue;
        }
        const target = findWindowByExecutable(name) orelse continue;
        slog.info("Cycle apps hotkey pressed ({s}): {s}", .{ cycle_order.directionName(is_forward), name });
        focusWindow(target);
        return;
    }
    slog.debug("Cycle apps hotkey pressed - no other app in the App Hotkeys list is running", .{});
}

pub fn openUrl(allocator: std.mem.Allocator, global_settings: *const config.GlobalConfig, url_index: usize) void {
    if (url_index >= global_settings.urlHotkeys.items.len) {
        slog.err("Failed to open URL: hotkey index {} is out of range", .{url_index});
        return;
    }
    const url_hotkey = global_settings.urlHotkeys.items[url_index];
    if (url_hotkey.url.len == 0) {
        slog.debug("Open URL hotkey pressed - no URL set", .{});
        return;
    }

    if (url_hotkey.uploadClipboard) {
        slog.info("Open URL hotkey pressed (uploading clipboard): {s}", .{url_hotkey.url});
        paste_upload.uploadClipboardAndOpenAsync(allocator, url_hotkey.url);
        return;
    }

    slog.info("Open URL hotkey pressed: {s}", .{url_hotkey.url});
    if (!win32.shellOpenUrl(url_hotkey.url)) {
        slog.err("Failed to open URL '{s}'", .{url_hotkey.url});
    }
}

fn findByExecutableCallback(hwnd: win32.HWND, lParam: win32.LPARAM) callconv(.c) win32.BOOL {
    const context: *FindByExecutableContext = win32.lparamToPtr(FindByExecutableContext, lParam);
    if (!win32.isWindowVisible(hwnd)) return win32.TRUE;

    var executable_path_buf: [win32.MAX_PATH:0]u8 = undefined;
    const executable_name = win32.windowExecutableName(hwnd, &executable_path_buf) orelse return win32.TRUE;
    if (!std.ascii.eqlIgnoreCase(executable_name, context.executable_name)) return win32.TRUE;

    context.found = hwnd;
    return win32.FALSE;
}

/// First visible top-level window (in Z-order, so effectively the frontmost) owned by executable_name.
fn findWindowByExecutable(executable_name: []const u8) ?win32.HWND {
    var context = FindByExecutableContext{ .executable_name = executable_name };
    _ = win32.EnumWindows(findByExecutableCallback, win32.ptrToLparam(&context));
    return context.found;
}

fn focusWindow(target: win32.HWND) void {
    if (win32.isWindowIconic(target)) {
        _ = win32.ShowWindowAsync(target, win32.SW_RESTORE);
    }
    focus_grant.forceSetForegroundWindow(target);
}

/// The first App Hotkeys entry for the foreground window's executable, or null when it's none of them.
fn foregroundAppIndex(apps: []const global_config.AppHotkeyConfig) ?usize {
    const foreground = win32.GetForegroundWindow() orelse return null;
    var executable_path_buf: [win32.MAX_PATH:0]u8 = undefined;
    const executable_name = win32.windowExecutableName(foreground, &executable_path_buf) orelse return null;
    for (apps, 0..) |app, index| {
        if (std.ascii.eqlIgnoreCase(app.executableName, executable_name)) return index;
    }
    return null;
}
