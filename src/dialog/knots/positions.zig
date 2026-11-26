//! The live EVE clients as the dialog sees them: their characters' names, and their window positions saved at once, like a drag; main thread only.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const config = @import("../../config.zig");
const scout_mod = @import("../../clients/scout.zig");
const session_mod = @import("session.zig");
const status_mod = @import("status.zig");
const log = @import("../../log.zig");

const Session = session_mod.Session;
const Status = status_mod.Status;
const slog = log.Scoped("dialog_knots");

const LiveWindow = struct { position: config.Position, size: config.WindowSize };

/// Logged-in clients' character names, copied into `arena`.
pub fn openClients(session: *Session, arena: std.mem.Allocator) ![][]const u8 {
    const scout = session.appContext().scout;
    var names: std.ArrayList([]const u8) = .empty;
    for (scout.getWindows()) |client| {
        if (!client.is_eve_client or scout_mod.isGenericCharacterName(client.character_name)) continue;
        // A later edit this frame can rescan and free the scout's copy before the list is drawn.
        try names.append(arena, try arena.dupe(u8, client.character_name));
    }
    return names.items;
}

/// Open clients' names that `taken` doesn't list, each once, for an Add Open Clients button; null, with the reason shown, when there's no client to add.
pub fn clientsNotIn(session: *Session, status: *Status, arena: std.mem.Allocator, taken: []const []const u8) ?[]const []const u8 {
    const names = openClients(session, arena) catch |err| {
        slog.err("Failed to scan open clients: {}", .{err});
        status.show(.failure, "Failed to scan clients: {err}", .{ .err = err });
        return null;
    };
    if (names.len == 0) {
        status.show(.failure, "No open EVE clients found", .{});
        return null;
    }
    var kept_count: usize = 0;
    for (names) |name| {
        if (isListed(taken, name) or isListed(names[0..kept_count], name)) continue;
        names[kept_count] = name;
        kept_count += 1;
    }
    return names[0..kept_count];
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
pub fn setAll(session: *Session, name: []const u8) !void {
    try setWindowPositions(session, null, try liveWindow(session, name));
}

pub fn clearAll(session: *Session) !void {
    try setWindowPositions(session, null, null);
}

pub fn set(session: *Session, name: []const u8) !void {
    try setWindowPositions(session, name, try liveWindow(session, name));
}

pub fn clear(session: *Session, name: []const u8) !void {
    try setWindowPositions(session, name, null);
}

fn liveWindow(session: *Session, character_name: []const u8) !LiveWindow {
    const scout = session.appContext().scout;
    const hwnd = scout.getHwndByName(character_name) orelse return error.MissingCharacterWindow;
    // A minimized window sits at the off-screen parking spot, not a real position.
    if (win32.isWindowIconic(hwnd)) return error.CharacterWindowIsMinimized;
    var rect: win32.RECT = undefined;
    if (!win32.toBool(win32.GetWindowRect(hwnd, &rect))) return error.GetWindowRectFailed;
    return .{ .position = .{ .x = rect.left, .y = rect.top }, .size = .{ .width = win32.rectWidth(rect), .height = win32.rectHeight(rect) } };
}

fn setWindowPositions(session: *Session, character_name: ?[]const u8, live_window: ?LiveWindow) !void {
    const position: ?config.Position = if (live_window) |live| live.position else null;
    const size: ?config.WindowSize = if (live_window) |live| live.size else null;
    try session.appContext().store.setWindowPosition(character_name, position, size);
}
