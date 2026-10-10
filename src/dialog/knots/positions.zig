//! Characters' saved EVE client window positions, taken from the live windows: saved at once for the running profile, like a drag, and kept in another profile's draft until Save; main thread only.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const config = @import("../../config.zig");
const patch = @import("../../config/patch.zig");
const main = @import("../../main.zig");
const scout_mod = @import("../../clients/scout.zig");
const session = @import("session.zig");

/// A live game window's top-left corner and size.
const LiveWindow = struct { position: config.Position, size: config.WindowSize };

/// Logged-in clients' character names, for picking a window to copy from. Copied into `arena`.
pub fn openClients(arena: std.mem.Allocator) ![]const []const u8 {
    const scout = scout_mod.g_scout_ptr orelse return &.{};
    var names: std.ArrayList([]const u8) = .empty;
    for (scout.getWindows()) |window| {
        if (!window.is_eve_client or scout_mod.isGenericCharacterName(window.character_name)) continue;
        // A later edit this frame can rescan and free the scout's copy before the list is drawn.
        try names.append(arena, try arena.dupe(u8, window.character_name));
    }
    return names.items;
}

/// `name`'s live game window, which every character then gets.
pub fn setAll(name: []const u8) !void {
    try setWindowPositions(null, try liveWindow(name));
}

pub fn clearAll() !void {
    try setWindowPositions(null, null);
}

pub fn set(name: []const u8) !void {
    try setWindowPositions(name, try liveWindow(name));
}

pub fn clear(name: []const u8) !void {
    try setWindowPositions(name, null);
}

fn liveWindow(character_name: []const u8) !LiveWindow {
    const scout = scout_mod.g_scout_ptr orelse return error.CharacterIsNotOpen;
    const window = scout.getHwndByName(character_name) orelse return error.CharacterIsNotOpen;
    // A minimized window sits at the off-screen parking spot, not a real position.
    if (win32.isWindowIconic(window)) return error.CharacterWindowIsMinimized;
    var rect: win32.RECT = undefined;
    if (!win32.toBool(win32.GetWindowRect(window, &rect))) return error.WindowPositionUnavailable;
    return .{ .position = .{ .x = rect.left, .y = rect.top }, .size = .{ .width = win32.rectWidth(rect), .height = win32.rectHeight(rect) } };
}

fn setWindowPositions(character_name: ?[]const u8, window: ?LiveWindow) !void {
    const position: ?config.Position = if (window) |live| live.position else null;
    const size: ?config.WindowSize = if (window) |live| live.size else null;
    if (!session.editsDraft()) return main.g_store.setWindowPosition(character_name, position, size);
    const draft = session.profile().ptr;
    try config.applyWindowPosition(draft, character_name, position, size);
    patch.assignIds(config.Config, draft);
    session.editedOutside();
}
