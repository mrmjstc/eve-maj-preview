//! Hands evemajpreview:// URLs from a second process to the running instance over WM_COPYDATA.
const win32 = @import("../platform/win32.zig");
const log = @import("../log.zig");

const slog = log.Scoped("protocol");

/// Window class of the main app's hidden timer window, the target of every WM_COPYDATA command; a second CLI invocation finds the running instance by it.
pub const MAIN_WINDOW_CLASS = "EVE_TIMER_CLASS";
/// The dwData of a URL; 1-9 were older formats, skipped so a stale sender's message is ignored rather than misread.
const URL_MESSAGE_KIND: usize = 10;

pub fn findExistingInstance() ?win32.HWND {
    return win32.FindWindowA(MAIN_WINDOW_CLASS, null);
}

/// Hands a --protocol URL to the already-running instance, which parses it; protocol URLs never start one.
pub fn forwardToRunningInstance(text: []const u8) !void {
    const existing_hwnd = findExistingInstance() orelse {
        slog.warn("Failed to forward the protocol command: no running instance", .{});
        return error.MissingInstance;
    };
    send(existing_hwnd, text);
    slog.info("Protocol command forwarded", .{});
}

/// Synchronous, so `text` only has to outlive the call.
pub fn send(hwnd: win32.HWND, text: []const u8) void {
    const copy_data: win32.COPYDATASTRUCT = .{
        .dwData = URL_MESSAGE_KIND,
        .cbData = @intCast(text.len),
        .lpData = if (text.len > 0) text.ptr else null,
    };
    _ = win32.SendMessageA(hwnd, win32.WM_COPYDATA, 0, @intCast(@intFromPtr(&copy_data)));
}

/// The URL `send` passed, borrowed from `copy_data`; null for any other WM_COPYDATA.
pub fn receivedUrl(copy_data: *const win32.COPYDATASTRUCT) ?[]const u8 {
    if (copy_data.dwData != URL_MESSAGE_KIND) return null;
    const data = copy_data.lpData orelse return "";
    return @as([*]const u8, @ptrCast(data))[0..copy_data.cbData];
}
