//! Each tracked client's record, kept in step with Scout's windows and outliving any thumbnail set; main thread only.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const scout = @import("scout.zig");
const log = @import("../log.zig");

const EveWindow = scout.EveWindow;
const slog = log.Scoped("roster");

pub const Client = struct {
    hwnd: win32.HWND,
    is_eve_client: bool,
    /// Owned; Roster frees it on rename and removal.
    character_name: []const u8,
    /// Mirrors EveWindow.logged_in_at, which Scout alone writes; zero at the login screen.
    logged_in_at: win32.Ticks,
    /// Bumped whenever something a view shows changes, so views redraw by comparing it.
    revision: u32 = 0,
};

pub const Roster = struct {
    allocator: std.mem.Allocator,
    /// Searched linearly: there are only ever a few dozen.
    clients: std.ArrayList(Client),

    pub fn init(allocator: std.mem.Allocator) Roster {
        return .{ .allocator = allocator, .clients = .empty };
    }

    pub fn deinit(self: *Roster) void {
        for (self.clients.items) |client| self.allocator.free(client.character_name);
        self.clients.deinit(self.allocator);
    }

    /// Mirrors `windows`, adding, renaming and dropping clients; the only place clients come or go, so don't hold a *Client across it.
    pub fn sync(self: *Roster, windows: []const EveWindow) void {
        self.dropMissing(windows);
        for (windows) |*window| {
            const client = self.byHwnd(window.hwnd) orelse {
                self.add(window);
                continue;
            };
            if (!std.mem.eql(u8, client.character_name, window.character_name)) self.rename(client, window.character_name);
            if (client.logged_in_at.ms != window.logged_in_at.ms) {
                client.logged_in_at = window.logged_in_at;
                client.revision +%= 1;
            }
        }
    }

    pub fn byHwnd(self: *Roster, hwnd: win32.HWND) ?*Client {
        return &self.clients.items[self.indexOf(hwnd) orelse return null];
    }

    /// The first client with this name, which a window filter's windows and logged-out clients share.
    pub fn byName(self: *Roster, name: []const u8) ?*Client {
        for (self.clients.items) |*client| {
            if (std.mem.eql(u8, client.character_name, name)) return client;
        }
        return null;
    }

    pub fn contains(self: *const Roster, hwnd: win32.HWND) bool {
        return self.indexOf(hwnd) != null;
    }

    /// Whether `hwnd` is a tracked EVE client, not a window filter's window.
    pub fn isEveClient(self: *const Roster, hwnd: win32.HWND) bool {
        const index = self.indexOf(hwnd) orelse return false;
        return self.clients.items[index].is_eve_client;
    }

    fn indexOf(self: *const Roster, hwnd: win32.HWND) ?usize {
        for (self.clients.items, 0..) |client, index| {
            if (client.hwnd == hwnd) return index;
        }
        return null;
    }

    fn dropMissing(self: *Roster, windows: []const EveWindow) void {
        var index = self.clients.items.len;
        while (index > 0) {
            index -= 1;
            const client = self.clients.items[index];
            if (isListed(windows, client.hwnd)) continue;
            slog.debug("Dropped '{s}' from the roster", .{client.character_name});
            self.allocator.free(client.character_name);
            _ = self.clients.orderedRemove(index);
        }
    }

    /// A failure is retried on the next sync, which still finds the window missing.
    fn add(self: *Roster, window: *const EveWindow) void {
        const name = self.allocator.dupe(u8, window.character_name) catch |err| {
            slog.err("Failed to copy the name '{s}' for the roster: {}", .{ window.character_name, err });
            return;
        };
        self.clients.append(self.allocator, .{
            .hwnd = window.hwnd,
            .is_eve_client = window.is_eve_client,
            .character_name = name,
            .logged_in_at = window.logged_in_at,
        }) catch |err| {
            slog.err("Failed to add '{s}' to the roster: {}", .{ window.character_name, err });
            self.allocator.free(name);
            return;
        };
        slog.debug("Added '{s}' to the roster", .{name});
    }

    /// Keeps the old name if copying fails, so the next sync tries again.
    fn rename(self: *Roster, client: *Client, new_name: []const u8) void {
        const name = self.allocator.dupe(u8, new_name) catch |err| {
            slog.err("Failed to copy the new name '{s}' for the roster: {}", .{ new_name, err });
            return;
        };
        slog.debug("Renamed '{s}' to '{s}' in the roster", .{ client.character_name, name });
        self.allocator.free(client.character_name);
        client.character_name = name;
        client.revision +%= 1;
    }
};

fn isListed(windows: []const EveWindow, hwnd: win32.HWND) bool {
    for (windows) |window| {
        if (window.hwnd == hwnd) return true;
    }
    return false;
}

const testing = std.testing;

fn testWindow(hwnd_value: usize, character_name: []const u8, logged_in_ms: u64) EveWindow {
    // Never passed to Win32; only compared.
    return .{ .hwnd = @ptrFromInt(hwnd_value), .character_name = character_name, .process_id = 0, .is_eve_client = true, .logged_in_at = .{ .ms = logged_in_ms } };
}

test "a new window joins the roster with its name and login time" {
    var roster: Roster = .init(testing.allocator);
    defer roster.deinit();
    roster.sync(&.{testWindow(1, "Alpha", 500)});

    const client = roster.byHwnd(@ptrFromInt(1)) orelse return error.TestExpectedClient;
    try testing.expectEqualStrings("Alpha", client.character_name);
    try testing.expectEqual(@as(u64, 500), client.logged_in_at.ms);
    try testing.expect(roster.isEveClient(@ptrFromInt(1)));
}

test "a window logging in keeps its place, takes the new name and bumps its revision" {
    var roster: Roster = .init(testing.allocator);
    defer roster.deinit();
    roster.sync(&.{ testWindow(1, "EVE", 0), testWindow(2, "Beta", 700) });
    roster.sync(&.{ testWindow(1, "Alpha", 900), testWindow(2, "Beta", 700) });

    try testing.expectEqualStrings("Alpha", roster.clients.items[0].character_name);
    try testing.expectEqual(@as(u64, 900), roster.clients.items[0].logged_in_at.ms);
    try testing.expectEqual(@as(u32, 2), roster.clients.items[0].revision);
    try testing.expectEqual(@as(u32, 0), roster.clients.items[1].revision);
}

test "logging out renames the client to the login screen's name and clears its login time" {
    var roster: Roster = .init(testing.allocator);
    defer roster.deinit();
    roster.sync(&.{testWindow(1, "Alpha", 900)});
    roster.sync(&.{testWindow(1, "EVE", 0)});

    const client = roster.byHwnd(@ptrFromInt(1)) orelse return error.TestExpectedClient;
    try testing.expect(scout.isGenericCharacterName(client.character_name));
    try testing.expect(client.logged_in_at.isZero());
}

test "a window gone from Scout's list leaves the roster" {
    var roster: Roster = .init(testing.allocator);
    defer roster.deinit();
    roster.sync(&.{ testWindow(1, "Alpha", 500), testWindow(2, "Beta", 600) });
    roster.sync(&.{testWindow(2, "Beta", 600)});

    try testing.expect(!roster.contains(@ptrFromInt(1)));
    try testing.expect(roster.contains(@ptrFromInt(2)));
    try testing.expectEqual(@as(usize, 1), roster.clients.items.len);
}

test "two windows both named EVE stay two clients, and a name finds the first" {
    var roster: Roster = .init(testing.allocator);
    defer roster.deinit();
    roster.sync(&.{ testWindow(1, "EVE", 0), testWindow(2, "EVE", 0) });

    try testing.expectEqual(@as(usize, 2), roster.clients.items.len);
    const first = roster.byName("EVE") orelse return error.TestExpectedClient;
    try testing.expectEqual(@as(win32.HWND, @ptrFromInt(1)), first.hwnd);
}

test "a sync with nothing changed leaves every revision alone" {
    var roster: Roster = .init(testing.allocator);
    defer roster.deinit();
    const windows = [_]EveWindow{testWindow(1, "Alpha", 500)};
    roster.sync(&windows);
    roster.sync(&windows);

    try testing.expectEqual(@as(u32, 0), roster.clients.items[0].revision);
}
