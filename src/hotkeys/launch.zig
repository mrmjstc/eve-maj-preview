//! Hotkeys that switch to another app or open a URL.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const focus_grant = @import("../platform/focus_grant.zig");
const config = @import("../config.zig");
const paste_upload = @import("paste_upload.zig");
const log = @import("../log.zig");

const slog = log.scoped("hotkeys");

const FindByExecutableContext = struct {
    executable_name: []const u8,
    found: ?win32.HWND = null,
};

fn findByExecutableCallback(hwnd: win32.HWND, lparam: win32.LPARAM) callconv(.c) win32.BOOL {
    const ctx: *FindByExecutableContext = win32.lparamToPtr(FindByExecutableContext, lparam);
    if (!win32.isWindowVisible(hwnd)) return win32.TRUE;

    var exe_path: [260:0]u8 = undefined;
    const exe_name = win32.windowExeName(hwnd, &exe_path) orelse return win32.TRUE;
    if (!std.ascii.eqlIgnoreCase(exe_name, ctx.executable_name)) return win32.TRUE;

    ctx.found = hwnd;
    return win32.FALSE;
}

/// First visible top-level window (in Z-order, so effectively the frontmost) owned by executable_name.
fn findWindowByExecutable(executable_name: []const u8) ?win32.HWND {
    var ctx = FindByExecutableContext{ .executable_name = executable_name };
    _ = win32.EnumWindows(findByExecutableCallback, win32.ptrToLparam(&ctx));
    return ctx.found;
}

fn focusWindow(target: win32.HWND) void {
    if (win32.isWindowIconic(target)) {
        _ = win32.ShowWindowAsync(target, win32.SW_RESTORE);
    }
    focus_grant.forceSetForegroundWindow(target);
}

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
        slog.err("Invalid app hotkey index {}", .{app_index});
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

pub fn openUrl(allocator: std.mem.Allocator, global_settings: *const config.GlobalConfig, url_index: usize) void {
    if (url_index >= global_settings.urlHotkeys.items.len) {
        slog.err("Invalid url hotkey index {}", .{url_index});
        return;
    }
    const url_hotkey = global_settings.urlHotkeys.items[url_index];
    if (url_hotkey.url.len == 0) return;

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
