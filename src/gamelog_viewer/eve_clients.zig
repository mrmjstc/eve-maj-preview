const std = @import("std");
const win32 = @import("../win32.zig");

/// Single discovered EVE client, paired with its process creation time for sorting.
pub const ClientEntry = struct {
    name: []const u8,
    /// FILETIME as u64 (100-ns intervals since 1601-01-01). 0 means unknown.
    creation_time: u64,
};

const ClientScanContext = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(ClientEntry),
};

/// Returns the character name from an EVE client window's title ("EVE - CharacterName"), or null
/// if hwnd isn't a visible window of the "trinityWindow" class or has no " - " separator.
pub fn matchEveClientTitle(hwnd: win32.HWND, title_buf: *[512:0]u8) ?[]const u8 {
    if (win32.IsWindowVisible(hwnd) == 0) return null;

    var class_name: [64:0]u8 = undefined;
    const class_len = win32.GetClassNameA(hwnd, &class_name, class_name.len);
    if (class_len <= 0) return null;
    const class_slice = class_name[0..@intCast(class_len)];
    if (!std.mem.eql(u8, class_slice, "trinityWindow")) return null;

    const title_len = win32.GetWindowTextA(hwnd, title_buf, title_buf.len);
    if (title_len <= 0) return null;
    const title_slice = title_buf[0..@intCast(title_len)];

    const dash_pos = std.mem.indexOf(u8, title_slice, " - ") orelse return null;
    const char_name = title_slice[dash_pos + 3 ..];
    if (char_name.len == 0) return null;
    return char_name;
}

/// EnumWindows callback that collects character names + process creation times.
fn enumClientsCallback(hwnd: win32.HWND, lParam: win32.LPARAM) callconv(.c) win32.BOOL {
    const ctx: *ClientScanContext = win32.lparamToPtr(ClientScanContext, lParam);

    var title_buf: [512:0]u8 = undefined;
    const char_name = matchEveClientTitle(hwnd, &title_buf) orelse return win32.TRUE;

    // Query process creation time so results can be sorted oldest-first.
    var creation_time: u64 = 0;
    var pid: win32.DWORD = 0;
    _ = win32.GetWindowThreadProcessId(hwnd, &pid);
    if (pid != 0) {
        const proc = win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION, win32.FALSE, pid);
        if (proc) |handle| {
            defer _ = win32.CloseHandle(handle);
            var ct: win32.FILETIME = .{ .dwLowDateTime = 0, .dwHighDateTime = 0 };
            var dummy: win32.FILETIME = .{ .dwLowDateTime = 0, .dwHighDateTime = 0 };
            if (win32.GetProcessTimes(handle, &ct, &dummy, &dummy, &dummy) != win32.FALSE) {
                creation_time = ct.toU64();
            }
        }
    }

    const name_copy = ctx.allocator.dupe(u8, char_name) catch return win32.TRUE;
    ctx.entries.append(ctx.allocator, .{ .name = name_copy, .creation_time = creation_time }) catch {
        ctx.allocator.free(name_copy);
    };
    return win32.TRUE;
}

/// Returns every currently-open EVE client, sorted oldest-first by process creation time
/// (clients with unknown creation time sort last). Caller owns the returned list: free each
/// entry's `name` and then `deinit` the list.
pub fn listOpenClients(allocator: std.mem.Allocator) !std.ArrayList(ClientEntry) {
    var ctx = ClientScanContext{
        .allocator = allocator,
        .entries = std.ArrayList(ClientEntry).empty,
    };
    errdefer {
        for (ctx.entries.items) |entry| allocator.free(entry.name);
        ctx.entries.deinit(allocator);
    }

    _ = win32.EnumWindows(enumClientsCallback, win32.ptrToLparam(&ctx));

    std.sort.pdq(ClientEntry, ctx.entries.items, {}, struct {
        fn lessThan(_: void, a: ClientEntry, b: ClientEntry) bool {
            if (a.creation_time == 0 and b.creation_time == 0) return false;
            if (a.creation_time == 0) return false;
            if (b.creation_time == 0) return true;
            return a.creation_time < b.creation_time;
        }
    }.lessThan);

    return ctx.entries;
}
