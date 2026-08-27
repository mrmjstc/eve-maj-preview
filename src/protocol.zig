const std = @import("std");
const win32 = @import("win32.zig");
const log = @import("log.zig");
const slog = log.scoped("protocol");

/// Global hotkey actions, mirroring hotkeys.zig's GlobalActionId.
/// Backing type must match win32.WPARAM (usize): sent as the WM_PROTOCOL_HOTKEY wParam.
pub const HotkeyAction = enum(usize) {
    minimize_all,
    close_all,
    toggle_visibility,
    next_profile,
    previous_profile,
    toggle_exclusion,
    next_excluded,
    previous_excluded,
    suspend_hotkeys,
    toggle_auto_minimize,
    cycle_notified,
    previous_notified,
    next_all_clients,
    previous_all_clients,
    next_not_logged_in,
    previous_not_logged_in,
    move_to_saved_positions,
};

pub const Command = union(enum) {
    Switch: []const u8,
    Profile: []const u8,
    Hotkey: HotkeyAction,
    PreviewThumbnail: []const u8,
    RevertPreview: void,
    DialogSuspendHotkeys: void,
    DialogResumeHotkeys: void,
};

/// Format: evemajpreview://action/params
/// Caller owns returned string memory (for Switch and Profile commands)
pub fn parseUrl(url: []const u8, allocator: std.mem.Allocator) !Command {
    const protocol_prefix = "evemajpreview://";
    if (!std.mem.startsWith(u8, url, protocol_prefix)) {
        slog.err("Invalid protocol URL: {s}", .{url});
        return error.InvalidProtocol;
    }

    const path = url[protocol_prefix.len..];
    var iter = std.mem.splitScalar(u8, path, '/');

    const action = iter.next() orelse {
        slog.err("Missing action in protocol URL: {s}", .{url});
        return error.MissingAction;
    };

    if (std.mem.eql(u8, action, "switch")) {
        const char_name_encoded = iter.next() orelse {
            slog.err("Missing character name in switch command", .{});
            return error.MissingParameter;
        };
        const char_name = try urlDecode(allocator, char_name_encoded);
        return Command{ .Switch = char_name };
    } else if (std.mem.eql(u8, action, "profile")) {
        const profile_name_encoded = iter.next() orelse {
            slog.err("Missing profile name in profile command", .{});
            return error.MissingParameter;
        };
        const profile_name = try urlDecode(allocator, profile_name_encoded);
        return Command{ .Profile = profile_name };
    } else if (std.mem.eql(u8, action, "hotkey")) {
        const hotkey_action = iter.next() orelse {
            slog.err("Missing hotkey action in hotkey command", .{});
            return error.MissingParameter;
        };
        const parsed_action = std.meta.stringToEnum(HotkeyAction, hotkey_action) orelse {
            slog.err("Unknown hotkey action: {s}", .{hotkey_action});
            return error.UnknownHotkeyAction;
        };
        return Command{ .Hotkey = parsed_action };
    } else {
        slog.err("Unknown protocol action: {s}", .{action});
        return error.UnknownAction;
    }
}

fn urlDecode(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            const hex = encoded[i + 1 .. i + 3];
            const value = std.fmt.parseInt(u8, hex, 16) catch {
                try result.append(allocator, encoded[i]);
                i += 1;
                continue;
            };
            try result.append(allocator, value);
            i += 3;
        } else if (encoded[i] == '+') {
            try result.append(allocator, ' ');
            i += 1;
        } else {
            try result.append(allocator, encoded[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

pub fn findExistingInstance(class_name: [*:0]const u8) ?win32.HWND {
    return win32.FindWindowA(class_name, null);
}

pub fn sendCommandToInstance(hwnd: win32.HWND, cmd: Command) void {
    switch (cmd) {
        .Switch => |char_name| {
            const cds = win32.COPYDATASTRUCT{
                .dwData = win32.PROTOCOL_SWITCH_CHARACTER,
                .cbData = @intCast(char_name.len),
                .lpData = char_name.ptr,
            };
            _ = win32.SendMessageA(hwnd, win32.WM_COPYDATA, 0, @intCast(@intFromPtr(&cds)));
            slog.info("Sent switch to '{s}'", .{char_name});
        },
        .Profile => |profile_name| {
            const cds = win32.COPYDATASTRUCT{
                .dwData = win32.PROTOCOL_SWITCH_PROFILE,
                .cbData = @intCast(profile_name.len),
                .lpData = profile_name.ptr,
            };
            _ = win32.SendMessageA(hwnd, win32.WM_COPYDATA, 0, @intCast(@intFromPtr(&cds)));
            slog.info("Sent load profile '{s}'", .{profile_name});
        },
        .Hotkey => |hotkey_action| {
            _ = win32.SendMessageA(hwnd, win32.WM_PROTOCOL_HOTKEY, @intFromEnum(hotkey_action), 0);
            slog.info("Sent hotkey action '{s}'", .{@tagName(hotkey_action)});
        },
        .PreviewThumbnail => |json| {
            const cds = win32.COPYDATASTRUCT{
                .dwData = win32.PROTOCOL_PREVIEW_THUMBNAIL,
                .cbData = @intCast(json.len),
                .lpData = json.ptr,
            };
            _ = win32.SendMessageA(hwnd, win32.WM_COPYDATA, 0, @intCast(@intFromPtr(&cds)));
            slog.debug("Sent thumbnail preview patch ({} bytes)", .{json.len});
        },
        .RevertPreview => {
            const cds = win32.COPYDATASTRUCT{
                .dwData = win32.PROTOCOL_REVERT_PREVIEW,
                .cbData = 0,
                .lpData = null,
            };
            _ = win32.SendMessageA(hwnd, win32.WM_COPYDATA, 0, @intCast(@intFromPtr(&cds)));
            slog.info("Sent revert preview", .{});
        },
        .DialogSuspendHotkeys => {
            const cds = win32.COPYDATASTRUCT{
                .dwData = win32.PROTOCOL_DIALOG_SUSPEND_HOTKEYS,
                .cbData = 0,
                .lpData = null,
            };
            _ = win32.SendMessageA(hwnd, win32.WM_COPYDATA, 0, @intCast(@intFromPtr(&cds)));
            slog.debug("Sent dialog suspend hotkeys", .{});
        },
        .DialogResumeHotkeys => {
            const cds = win32.COPYDATASTRUCT{
                .dwData = win32.PROTOCOL_DIALOG_RESUME_HOTKEYS,
                .cbData = 0,
                .lpData = null,
            };
            _ = win32.SendMessageA(hwnd, win32.WM_COPYDATA, 0, @intCast(@intFromPtr(&cds)));
            slog.debug("Sent dialog resume hotkeys", .{});
        },
    }
}

/// Returns the protocol URL if --protocol was passed (caller must free), otherwise null.
pub fn checkCommandLine(process_args: std.process.Args, allocator: std.mem.Allocator) !?[]const u8 {
    // toSlice's result references several internal allocations, so it requires an arena rather than a plain allocator.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const args = try process_args.toSlice(arena_state.allocator());

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--protocol")) {
            if (i + 1 < args.len) {
                // Must duplicate before the arena is freed.
                return try allocator.dupe(u8, args[i + 1]);
            }
        }
    }

    return null;
}

pub fn isRegistered() bool {
    var hKey: win32.HKEY = undefined;
    const result = win32.RegOpenKeyExA(
        win32.HKEY_CURRENT_USER,
        "Software\\Classes\\evemajpreview",
        0,
        win32.KEY_READ,
        &hKey,
    );

    if (result == win32.ERROR_SUCCESS) {
        _ = win32.RegCloseKey(hKey);
        return true;
    }

    return false;
}

pub fn register(allocator: std.mem.Allocator) !bool {
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = try win32.selfExePath(&exe_path_buf);

    var hKey: win32.HKEY = undefined;
    var disposition: win32.DWORD = undefined;

    // HKCU rather than HKEY_CLASSES_ROOT: the latter falls back to HKLM for new keys, which requires admin rights.
    var result = win32.RegCreateKeyExA(
        win32.HKEY_CURRENT_USER,
        "Software\\Classes\\evemajpreview",
        0,
        null,
        win32.REG_OPTION_NON_VOLATILE,
        win32.KEY_WRITE,
        null,
        &hKey,
        &disposition,
    );

    if (result != win32.ERROR_SUCCESS) {
        slog.err("Failed to create registry key HKCU\\Software\\Classes\\evemajpreview: error {}", .{result});
        return false;
    }
    defer _ = win32.RegCloseKey(hKey);

    const description = "URL:EVE-Maj Preview Protocol";
    result = win32.RegSetValueExA(
        hKey,
        null,
        0,
        win32.REG_SZ,
        description.ptr,
        @intCast(description.len + 1),
    );

    if (result != win32.ERROR_SUCCESS) {
        slog.err("Failed to set default value: error {}", .{result});
        return false;
    }

    const url_protocol = "";
    result = win32.RegSetValueExA(
        hKey,
        "URL Protocol",
        0,
        win32.REG_SZ,
        url_protocol.ptr,
        @intCast(url_protocol.len + 1),
    );

    if (result != win32.ERROR_SUCCESS) {
        slog.err("Failed to set URL Protocol value: error {}", .{result});
        return false;
    }

    var hCommandKey: win32.HKEY = undefined;
    result = win32.RegCreateKeyExA(
        win32.HKEY_CURRENT_USER,
        "Software\\Classes\\evemajpreview\\shell\\open\\command",
        0,
        null,
        win32.REG_OPTION_NON_VOLATILE,
        win32.KEY_WRITE,
        null,
        &hCommandKey,
        &disposition,
    );

    if (result != win32.ERROR_SUCCESS) {
        slog.err("Failed to create command key: error {}", .{result});
        return false;
    }
    defer _ = win32.RegCloseKey(hCommandKey);

    // \x00 is embedded in the format string itself, so command.len already covers the terminator (unlike description/url_protocol above, which need +1).
    const command = try std.fmt.allocPrint(allocator, "\"{s}\" --protocol \"%1\"\x00", .{exe_path});
    defer allocator.free(command);

    result = win32.RegSetValueExA(
        hCommandKey,
        null,
        0,
        win32.REG_SZ,
        command.ptr,
        @intCast(command.len),
    );

    if (result != win32.ERROR_SUCCESS) {
        slog.err("Failed to set command value: error {}", .{result});
        return false;
    }

    slog.info("Protocol handler registered successfully: {s}", .{exe_path});
    return true;
}

pub fn unregister() bool {
    const result = win32.RegDeleteTreeA(win32.HKEY_CURRENT_USER, "Software\\Classes\\evemajpreview");

    if (result == win32.ERROR_SUCCESS) {
        slog.info("Protocol handler unregistered successfully", .{});
        return true;
    } else if (result == 2) {
        // 2 is ERROR_FILE_NOT_FOUND.
        slog.debug("Protocol handler was not registered", .{});
        return true;
    } else {
        slog.err("Failed to unregister protocol handler: error {}", .{result});
        return false;
    }
}
