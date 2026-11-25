//! Marking EVE clients fullscreen for Explorer, so the taskbar goes behind an active one that doesn't cover its monitor.
const win32 = @import("../platform/win32.zig");
const roster = @import("roster.zig");
const log = @import("../log.zig");

const Client = roster.Client;
const slog = log.Scoped("taskbar");

/// Which of the roster's clients markClients reaches.
pub const Scope = enum {
    all,
    /// Only those the last sync added.
    joined,
};

/// Marks or unmarks the EVE clients in `clients` that `scope` covers; reaches the taskbar only if there's one.
pub fn markClients(clients: []const Client, scope: Scope, is_fullscreen: bool) void {
    var list: ?win32.TaskbarList = null;
    defer if (list) |*taskbar_list| taskbar_list.deinit();
    for (clients) |client| {
        if (!client.is_eve_client) continue;
        switch (scope) {
            .all => {},
            .joined => if (client.last_sync != .joined) continue,
        }
        if (list == null) {
            list = win32.TaskbarList.init() catch |err| {
                slog.err("Failed to reach the taskbar to mark clients fullscreen: {}", .{err});
                return;
            };
        }
        list.?.markFullscreen(client.hwnd, is_fullscreen) catch |err| {
            slog.err("Failed to mark '{s}' fullscreen for the taskbar: {}", .{ client.character_name, err });
        };
    }
}
