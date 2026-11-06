//! The live EVE clients as the dialog sees them: their characters' names, and their window positions saved at once, like a drag; main thread only.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const config = @import("../../config.zig");
const scout_mod = @import("../../clients/scout.zig");
const session = @import("session.zig");
const status = @import("status.zig");
const log = @import("../../log.zig");

const slog = log.Scoped("dialog_knots");

const LiveWindow = struct { position: config.Position, size: config.WindowSize };

/// Logged-in clients' character names, copied into `arena`.
pub fn openClients(arena: std.mem.Allocator) ![][]const u8 {
    const scout = &session.runningApp().scout;
    var names: std.ArrayList([]const u8) = .empty;
    for (scout.getWindows()) |window| {
        if (!window.is_eve_client or scout_mod.isGenericCharacterName(window.character_name)) continue;
        // A later edit this frame can rescan and free the scout's copy before the list is drawn.
        try names.append(arena, try arena.dupe(u8, window.character_name));
    }
    return names.items;
}

/// Open clients' names that `taken` doesn't list, each once, for an Add Open Clients button; null, with the reason shown, when there's no client to add.
pub fn clientsNotIn(arena: std.mem.Allocator, taken: []const []const u8) ?[]const []const u8 {
    const names = openClients(arena) catch |err| {
        slog.err("Failed to scan open clients: {}", .{err});
        status.show(.failure, "Failed to scan clients: {err}", .{ .err = err });
        return null;
    };
    if (names.len == 0) {
        status.show(.failure, "No open EVE clients found", .{});
        return null;
    }
    var count: usize = 0;
    for (names) |name| {
        if (isListed(taken, name) or isListed(names[0..count], name)) continue;
        names[count] = name;
        count += 1;
    }
    return names[0..count];
}

/// Matched ignoring case and spaces at either end, as a client's name is.
pub fn isListed(names: []const []const u8, name: []const u8) bool {
    const trimmed = std.mem.trim(u8, name, " ");
    for (names) |other| {
        if (std.ascii.eqlIgnoreCase(trimmed, std.mem.trim(u8, other, " "))) return true;
    }
    return false;
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
    const scout = &session.runningApp().scout;
    const hwnd = scout.getHwndByName(character_name) orelse return error.MissingCharacterWindow;
    // A minimized window sits at the off-screen parking spot, not a real position.
    if (win32.isWindowIconic(hwnd)) return error.CharacterWindowIsMinimized;
    var rect: win32.RECT = undefined;
    if (!win32.toBool(win32.GetWindowRect(hwnd, &rect))) return error.GetWindowRectFailed;
    return .{ .position = .{ .x = rect.left, .y = rect.top }, .size = .{ .width = win32.rectWidth(rect), .height = win32.rectHeight(rect) } };
}

fn setWindowPositions(character_name: ?[]const u8, window: ?LiveWindow) !void {
    const position: ?config.Position = if (window) |live| live.position else null;
    const size: ?config.WindowSize = if (window) |live| live.size else null;
    try session.runningApp().store.setWindowPosition(character_name, position, size);
}
