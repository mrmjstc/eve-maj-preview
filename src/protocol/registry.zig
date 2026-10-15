//! Registering this executable as the evemajpreview:// handler for the current user.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const log = @import("../log.zig");

const slog = log.Scoped("protocol");

/// HKCU rather than HKEY_CLASSES_ROOT: the latter falls back to HKLM for new keys, which requires admin rights.
const CLASS_KEY = "Software\\Classes\\evemajpreview";
const COMMAND_KEY = CLASS_KEY ++ "\\shell\\open\\command";
/// The executable's path plus the quoted arguments around it.
const COMMAND_SIZE = std.Io.Dir.max_path_bytes + 32;

/// Registers the handler unless it already points at this executable, so moving the exe re-registers it; failures are logged, not fatal.
pub fn ensureRegistered() void {
    var command_buf: [COMMAND_SIZE]u8 = undefined;
    const command = openCommand(&command_buf) catch |err| {
        slog.warn("Failed to build the protocol handler command: {}", .{err});
        return;
    };
    if (isRegisteredAs(command)) {
        slog.debug("Protocol handler already registered", .{});
        return;
    }

    slog.info("Protocol handler missing or registered to another path, registering", .{});
    register(command) catch |err| {
        slog.warn("Failed to register protocol handler: {}", .{err});
    };
}

/// `"<this exe>" --protocol "%1"`, borrowed from `buffer`.
fn openCommand(buffer: *[COMMAND_SIZE]u8) ![:0]const u8 {
    var executable_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const executable_path = try win32.selfExecutablePath(&executable_path_buf);
    return std.mem.printSentinel(buffer, "\"{s}\" --protocol \"%1\"", .{executable_path}, 0);
}

fn isRegisteredAs(command: []const u8) bool {
    var registered_buf: [COMMAND_SIZE]u8 = undefined;
    var size: win32.DWORD = registered_buf.len;
    const result = win32.RegGetValueA(win32.HKEY_CURRENT_USER, COMMAND_KEY, null, win32.RRF_RT_REG_SZ, null, &registered_buf, &size);
    if (result != win32.ERROR_SUCCESS) return false;
    // `size` counts the terminator.
    return std.mem.eql(u8, registered_buf[0..size -| 1], command);
}

fn register(command: [:0]const u8) !void {
    try setValue(CLASS_KEY, null, "URL:EVE-Maj Preview Protocol");
    try setValue(CLASS_KEY, "URL Protocol", "");
    try setValue(COMMAND_KEY, null, command);
    slog.info("Protocol handler registered: {s}", .{command});
}

/// Creates `key_path` under HKCU if needed; logs the failing call before returning error.RegistryWriteFailed.
fn setValue(comptime key_path: [:0]const u8, value_name: ?win32.LPCSTR, value: [:0]const u8) !void {
    var key: win32.HKEY = undefined;
    var result = win32.RegCreateKeyExA(win32.HKEY_CURRENT_USER, key_path, 0, null, win32.REG_OPTION_NON_VOLATILE, win32.KEY_WRITE, null, &key, null);
    if (result != win32.ERROR_SUCCESS) {
        slog.err("Failed to create registry key 'HKCU\\{s}': error {}", .{ key_path, result });
        return error.RegistryWriteFailed;
    }
    defer _ = win32.RegCloseKey(key);

    // REG_SZ data includes its terminator.
    result = win32.RegSetValueExA(key, value_name, 0, win32.REG_SZ, value.ptr, @intCast(value.len + 1));
    if (result != win32.ERROR_SUCCESS) {
        slog.err("Failed to set a value under 'HKCU\\{s}': error {}", .{ key_path, result });
        return error.RegistryWriteFailed;
    }
}
