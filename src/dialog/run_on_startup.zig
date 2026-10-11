//! Starting the app with Windows, through the current user's Run registry key.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const log = @import("../log.zig");

const slog = log.Scoped("run_on_startup");

const STARTUP_RUN_KEY = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const STARTUP_RUN_VALUE_NAME = "EVE-Maj Preview";
const EXECUTABLE_NAME = "eve-maj-preview.exe";

/// Adds or removes this exe under the user's Run key; failures are logged.
pub fn apply(is_enabled: bool) void {
    if (!is_enabled) {
        var key: win32.HKEY = undefined;
        const open_result = win32.RegOpenKeyExA(win32.HKEY_CURRENT_USER, STARTUP_RUN_KEY, 0, win32.KEY_WRITE, &key);
        if (open_result == win32.ERROR_FILE_NOT_FOUND) return;
        if (open_result != win32.ERROR_SUCCESS) {
            slog.err("Failed to open the startup registry key: error {}", .{open_result});
            return;
        }
        defer _ = win32.RegCloseKey(key);
        const delete_result = win32.RegDeleteValueA(key, STARTUP_RUN_VALUE_NAME);
        if (delete_result != win32.ERROR_SUCCESS and delete_result != win32.ERROR_FILE_NOT_FOUND) {
            slog.err("Failed to remove the startup registry value: error {}", .{delete_result});
        }
        return;
    }

    var executable_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const executable_dir = win32.selfExecutableDirPath(&executable_path_buf) catch |err| {
        slog.err("Failed to find the executable directory for startup registration: {}", .{err});
        return;
    };
    // Room for the two quotes, the separator and the sentinel.
    var command_buf: [std.Io.Dir.max_path_bytes + EXECUTABLE_NAME.len + 4]u8 = undefined;
    const command = std.mem.printSentinel(&command_buf, "\"{s}\\" ++ EXECUTABLE_NAME ++ "\"", .{executable_dir}, 0) catch unreachable;

    var key: win32.HKEY = undefined;
    var disposition: win32.DWORD = undefined;
    const create_result = win32.RegCreateKeyExA(win32.HKEY_CURRENT_USER, STARTUP_RUN_KEY, 0, null, win32.REG_OPTION_NON_VOLATILE, win32.KEY_WRITE, null, &key, &disposition);
    if (create_result != win32.ERROR_SUCCESS) {
        slog.err("Failed to open the startup registry key: error {}", .{create_result});
        return;
    }
    defer _ = win32.RegCloseKey(key);

    const set_result = win32.RegSetValueExA(key, STARTUP_RUN_VALUE_NAME, 0, win32.REG_SZ, command.ptr, @intCast(command.len + 1));
    if (set_result != win32.ERROR_SUCCESS) {
        slog.err("Failed to set the startup registry value: error {}", .{set_result});
    }
}
