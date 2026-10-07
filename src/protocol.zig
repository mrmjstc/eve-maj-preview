//! The evemajpreview:// URL scheme and command-line commands, forwarded to the running instance over WM_COPYDATA.
const std = @import("std");
const win32 = @import("platform/win32.zig");
const log = @import("log.zig");

const slog = log.scoped("protocol");

/// Window class of the main app's hidden timer window, the target of every WM_COPYDATA command; a second CLI invocation finds the running instance by it.
pub const MAIN_WINDOW_CLASS = "EVE_TIMER_CLASS";

/// Global hotkey actions; hotkeys/bindings.zig's GLOBAL_BINDINGS maps each to its HotkeyAction.
/// Backing type must match win32.WPARAM (usize): sent as the WM_PROTOCOL_HOTKEY wParam.
pub const GlobalAction = enum(usize) {
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
    toggle_alert_mute,
    cycle_notified,
    previous_notified,
    next_all_clients,
    previous_all_clients,
    next_not_logged_in,
    previous_not_logged_in,
    move_to_saved_positions,
    return_to_last_app,
    exit_app,
    close_active,
};

pub const Command = union(enum) {
    switch_character: []const u8,
    profile: []const u8,
    hotkey: GlobalAction,
    /// Sent by a second `--config` launch so the running instance opens its configuration window.
    open_config: void,

    /// Frees what parseUrl allocated; commands built any other way borrow their payloads.
    pub fn deinit(self: Command, allocator: std.mem.Allocator) void {
        switch (self) {
            .switch_character, .profile => |name| allocator.free(name),
            .hotkey, .open_config => {},
        }
    }
};

/// `evemajpreview://action/params`; free the result with Command.deinit.
pub fn parseUrl(url: []const u8, allocator: std.mem.Allocator) !Command {
    const protocol_prefix = "evemajpreview://";
    if (!std.mem.startsWith(u8, url, protocol_prefix)) {
        slog.err("Failed to parse protocol URL '{s}': it doesn't start with '{s}'", .{ url, protocol_prefix });
        return error.InvalidProtocol;
    }

    const path = url[protocol_prefix.len..];
    var iter = std.mem.splitScalar(u8, path, '/');

    const action = iter.next() orelse {
        slog.err("Failed to parse protocol URL '{s}': no action", .{url});
        return error.MissingAction;
    };

    if (std.mem.eql(u8, action, "switch")) {
        const char_name_encoded = iter.next() orelse {
            slog.err("Failed to parse switch command: no character name", .{});
            return error.MissingParameter;
        };
        const char_name = try urlDecode(allocator, char_name_encoded);
        return Command{ .switch_character = char_name };
    } else if (std.mem.eql(u8, action, "profile")) {
        const profile_name_encoded = iter.next() orelse {
            slog.err("Failed to parse profile command: no profile name", .{});
            return error.MissingParameter;
        };
        const profile_name = try urlDecode(allocator, profile_name_encoded);
        return Command{ .profile = profile_name };
    } else if (std.mem.eql(u8, action, "hotkey")) {
        const hotkey_action = iter.next() orelse {
            slog.err("Failed to parse hotkey command: no action", .{});
            return error.MissingParameter;
        };
        const parsed_action = std.meta.stringToEnum(GlobalAction, hotkey_action) orelse {
            slog.err("Failed to parse hotkey command: unknown action '{s}'", .{hotkey_action});
            return error.InvalidGlobalAction;
        };
        return Command{ .hotkey = parsed_action };
    } else {
        slog.err("Failed to parse protocol URL: unknown action '{s}'", .{action});
        return error.InvalidAction;
    }
}

pub fn findExistingInstance() ?win32.HWND {
    return win32.FindWindowA(MAIN_WINDOW_CLASS, null);
}

/// Hands a --protocol URL to the already-running instance; protocol URLs never start one.
pub fn forwardToRunningInstance(url: []const u8, allocator: std.mem.Allocator) !void {
    const existing_hwnd = findExistingInstance() orelse {
        slog.warn("No existing instance found, protocol command ignored", .{});
        return error.MissingInstance;
    };

    const cmd = parseUrl(url, allocator) catch |err| {
        slog.err("Failed to parse protocol URL: {}", .{err});
        return err;
    };
    defer cmd.deinit(allocator);

    sendCommandToInstance(existing_hwnd, cmd);
    slog.info("Protocol command sent successfully", .{});
}

pub fn sendCommandToInstance(hwnd: win32.HWND, cmd: Command) void {
    switch (cmd) {
        .switch_character => |char_name| {
            sendCopyData(hwnd, win32.PROTOCOL_SWITCH_CHARACTER, char_name);
            slog.info("Sent switch to '{s}'", .{char_name});
        },
        .profile => |profile_name| {
            sendCopyData(hwnd, win32.PROTOCOL_SWITCH_PROFILE, profile_name);
            slog.info("Sent load profile '{s}'", .{profile_name});
        },
        .hotkey => |hotkey_action| {
            _ = win32.SendMessageA(hwnd, win32.WM_PROTOCOL_HOTKEY, @backingInt(hotkey_action), 0);
            slog.info("Sent hotkey action '{s}'", .{@tagName(hotkey_action)});
        },
        .open_config => {
            sendCopyData(hwnd, win32.PROTOCOL_OPEN_CONFIG, "");
            slog.info("Sent open configuration", .{});
        },
    }
}

/// Receiving side of sendCopyData; null for a message sent without a payload.
pub fn copyDataBytes(cds: *const win32.COPYDATASTRUCT) ?[]const u8 {
    const data_ptr = cds.lpData orelse return null;
    return @as([*]const u8, @ptrCast(data_ptr))[0..cds.cbData];
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

/// Registers the evemajpreview:// handler unless it already is; failures are logged, not fatal.
pub fn ensureRegistered(allocator: std.mem.Allocator) void {
    if (isRegistered()) {
        slog.debug("Protocol handler already registered", .{});
        return;
    }

    slog.info("Protocol handler not registered, attempting auto-registration", .{});
    const success = register(allocator) catch |err| blk: {
        slog.warn("Failed to auto-register protocol handler: {}", .{err});
        slog.warn("You may need to run as administrator or manually register using register-protocol.reg", .{});
        break :blk false;
    };
    if (success) {
        slog.info("Protocol handler successfully registered", .{});
    } else {
        slog.warn("Failed to register protocol handler", .{});
    }
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
    var exe_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
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
    const command = try allocator.print("\"{s}\" --protocol \"%1\"\x00", .{exe_path});
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

/// Synchronous, so `payload` only has to outlive the call; an empty payload is sent as a null lpData.
fn sendCopyData(hwnd: win32.HWND, kind: usize, payload: []const u8) void {
    const cds = win32.COPYDATASTRUCT{
        .dwData = kind,
        .cbData = @intCast(payload.len),
        .lpData = if (payload.len > 0) payload.ptr else null,
    };
    _ = win32.SendMessageA(hwnd, win32.WM_COPYDATA, 0, @intCast(@intFromPtr(&cds)));
}

const testing = std.testing;

test "parseUrl reads switch and profile commands and decodes their names" {
    const switch_cmd = try parseUrl("evemajpreview://switch/Some%20Pilot", testing.allocator);
    defer switch_cmd.deinit(testing.allocator);
    try testing.expectEqualStrings("Some Pilot", switch_cmd.switch_character);

    const profile_cmd = try parseUrl("evemajpreview://profile/My+Alts/", testing.allocator);
    defer profile_cmd.deinit(testing.allocator);
    try testing.expectEqualStrings("My Alts", profile_cmd.profile);
}

test "parseUrl reads every hotkey action by name" {
    var buf: [128]u8 = undefined;
    for (std.enums.values(GlobalAction)) |action| {
        const url = try std.mem.print(&buf, "evemajpreview://hotkey/{s}", .{@tagName(action)});
        try testing.expectEqual(action, (try parseUrl(url, testing.allocator)).hotkey);
    }
}

test "parseUrl rejects other schemes, unknown actions and missing parameters" {
    try testing.expectError(error.InvalidProtocol, parseUrl("https://example.com/switch/Pilot", testing.allocator));
    try testing.expectError(error.InvalidAction, parseUrl("evemajpreview://launch/Pilot", testing.allocator));
    try testing.expectError(error.InvalidAction, parseUrl("evemajpreview://", testing.allocator));
    try testing.expectError(error.MissingParameter, parseUrl("evemajpreview://switch", testing.allocator));
    try testing.expectError(error.MissingParameter, parseUrl("evemajpreview://hotkey", testing.allocator));
    try testing.expectError(error.InvalidGlobalAction, parseUrl("evemajpreview://hotkey/self_destruct", testing.allocator));
}

test "urlDecode decodes percent escapes and plus signs" {
    const decoded = try urlDecode(testing.allocator, "Jita%204%20-%20Moon+4%2fX");
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings("Jita 4 - Moon 4/X", decoded);
}

test "urlDecode keeps a malformed or truncated escape as written" {
    const malformed = try urlDecode(testing.allocator, "100%zz");
    defer testing.allocator.free(malformed);
    try testing.expectEqualStrings("100%zz", malformed);

    const truncated = try urlDecode(testing.allocator, "abc%4");
    defer testing.allocator.free(truncated);
    try testing.expectEqualStrings("abc%4", truncated);
}
