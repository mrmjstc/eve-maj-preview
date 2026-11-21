//! Each tracked client's record, kept in step with Scout's windows and outliving any thumbnail set; main thread only.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const auto_colors_mod = @import("auto_colors.zig");
const scout = @import("scout.zig");
const stragglers = @import("../travel/stragglers.zig");
const stack = @import("../notifications/stack.zig");
const stats_mod = @import("../activity/stats.zig");
const log = @import("../log.zig");

const Config = config_mod.Config;
const AutoColorStore = auto_colors_mod.AutoColorStore;
const EveWindow = scout.EveWindow;
const NotificationStack = stack.NotificationStack;
const ActivityStats = stats_mod.ActivityStats;
const slog = log.Scoped("roster");

const NO_ALERTS: NotificationStack = .{};
const NO_STATS: ActivityStats = .{};

/// A client's alerts and activity readings for a view to draw, empty for an untracked window; don't hold it across a sync.
pub const Readings = struct {
    alerts: *const NotificationStack = &NO_ALERTS,
    stats: *const ActivityStats = &NO_STATS,
};

/// What the last sync did to a client.
pub const SyncChange = enum { none, joined, logged_in };

/// Which clients Roster.refreshConfig reads the profile for.
pub const Refresh = enum {
    /// After the profile changes.
    all,
    /// Only those added or renamed since the last refresh.
    stale,
};

pub const Client = struct {
    hwnd: win32.HWND,
    is_eve_client: bool,
    /// Owned; Roster frees it on rename and removal.
    character_name: []const u8,
    /// Mirrors EveWindow.logged_in_at, which Scout alone writes; zero at the login screen.
    logged_in_at: win32.Ticks,
    /// Owned, or empty while unknown; only Roster writes it.
    system_name: []const u8 = "",
    /// YYYYMMDD*1000000+HHMMSS of the event that set system_name; 0 if unreadable, which always applies.
    system_name_event_timestamp: u64 = 0,
    travel: stragglers.LeftBehindState = .{},
    /// The alerts on screen, and each type's throttle; written by notifications/dispatch and Roster.
    notifications: NotificationStack = .{},
    /// When control/activation.zig last brought it forward; "suppress when clicked" counts from it.
    last_click_time: win32.Ticks = .{},
    /// What the activity trackers last pushed; only Roster writes it.
    stats: ActivityStats = .{},
    /// Catches a minimize or restore with no focus change; refreshMinimized keeps it current.
    was_minimized: bool = false,
    /// When auto-minimize's delay counts from: the last tick it was active or minimized; only AutoMinimizer.check writes it after joining.
    inactive_since: win32.Ticks,
    /// Owned; the profile's display name for the character, else a copy of character_name.
    display_name: []const u8 = "",
    /// Null at the login screen or with "Unique Character Name Colors" off; callers fall back to their default.
    character_color: ?u32 = null,
    is_excluded_from_minimize: bool = false,
    /// From joining or a rename until refreshConfig reads the profile for the new name.
    is_config_stale: bool = true,
    /// What the last sync did to it, for App to act on before the next.
    last_sync: SyncChange = .none,
    /// Bumped whenever something a view shows changes, so views redraw by comparing it.
    revision: u32 = 0,
};

pub const Roster = struct {
    allocator: std.mem.Allocator,
    /// Searched linearly: there are only ever a few dozen.
    clients: std.ArrayList(Client),
    /// The foreground window, a client's or not, as App last saw it; only setActive writes it.
    active_hwnd: ?win32.HWND = null,

    pub fn init(allocator: std.mem.Allocator) Roster {
        return .{ .allocator = allocator, .clients = .empty };
    }

    pub fn deinit(self: *Roster) void {
        for (self.clients.items) |client| self.freeClient(client);
        self.clients.deinit(self.allocator);
    }

    /// Mirrors `windows`, adding, renaming and dropping clients; the only place clients come or go, so don't hold a *Client across it.
    pub fn sync(self: *Roster, windows: []const EveWindow) void {
        for (self.clients.items) |*client| client.last_sync = .none;
        self.dropMissing(windows);
        for (windows) |*window| {
            const index = self.indexOf(window.hwnd) orelse {
                self.add(window);
                continue;
            };
            const client = &self.clients.items[index];
            if (!std.mem.eql(u8, client.character_name, window.character_name)) self.rename(client, window.character_name);
            if (client.logged_in_at.ms != window.logged_in_at.ms) {
                client.logged_in_at = window.logged_in_at;
                client.revision +%= 1;
            }
        }
    }

    pub fn byHwnd(self: *const Roster, hwnd: win32.HWND) ?*const Client {
        return &self.clients.items[self.indexOf(hwnd) orelse return null];
    }

    /// For notifications/dispatch, which shows alerts on the client; don't hold it across a sync.
    pub fn mutableByHwnd(self: *Roster, hwnd: win32.HWND) ?*Client {
        return &self.clients.items[self.indexOf(hwnd) orelse return null];
    }

    pub fn readingsOf(self: *const Roster, hwnd: win32.HWND) Readings {
        const client = self.byHwnd(hwnd) orelse return .{};
        return .{ .alerts = &client.notifications, .stats = &client.stats };
    }

    /// The first client with this name, which a window filter's windows and logged-out clients share.
    pub fn byName(self: *const Roster, name: []const u8) ?*const Client {
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

    /// `jumped_at_ms` is null unless the client jumped; an update older than the one shown is skipped.
    pub fn updateSystem(self: *Roster, hwnd: win32.HWND, system_name: []const u8, event_timestamp: u64, jumped_at_ms: ?u64) !void {
        const index = self.indexOf(hwnd) orelse {
            slog.debug("No client for window 0x{x} to put in {s}", .{ @intFromPtr(hwnd), system_name });
            return;
        };
        const client = &self.clients.items[index];
        if (event_timestamp != 0 and event_timestamp < client.system_name_event_timestamp) {
            slog.debug("Ignoring stale system update for {s}: {s} (event_timestamp={} < current={})", .{ client.character_name, system_name, event_timestamp, client.system_name_event_timestamp });
            return;
        }

        const copy = try self.allocator.dupe(u8, system_name);
        self.allocator.free(client.system_name);
        client.system_name = copy;
        client.system_name_event_timestamp = event_timestamp;
        if (jumped_at_ms) |now_ms| client.travel.recordJump(now_ms);
        client.revision +%= 1;
        slog.debug("Updated system for {s}: {s}", .{ client.character_name, system_name });
    }

    /// A client whose display name can't be copied stays stale, for the next refresh to retry.
    pub fn refreshConfig(self: *Roster, config: *const Config, auto_colors: *AutoColorStore, refresh: Refresh) void {
        for (self.clients.items) |*client| {
            if (refresh == .stale and !client.is_config_stale) continue;
            self.refreshClientConfig(client, config, auto_colors);
        }
    }

    /// `setter` is an ActivityStats setter, which says whether anything shown changed.
    pub fn updateStats(self: *Roster, hwnd: win32.HWND, comptime setter: anytype, args: anytype) void {
        const client = self.mutableByHwnd(hwnd) orelse return;
        if (@call(.auto, setter, .{&client.stats} ++ args)) client.revision +%= 1;
    }

    /// Per tick; skips `dragged_hwnd`, whose thumbnail is being dragged, as its window's state is in flux.
    pub fn refreshMinimized(self: *Roster, dragged_hwnd: ?win32.HWND) void {
        for (self.clients.items) |*client| {
            if (client.hwnd == dragged_hwnd) continue;
            const is_minimized = win32.isWindowIconic(client.hwnd);
            if (is_minimized == client.was_minimized) continue;
            client.was_minimized = is_minimized;
            client.revision +%= 1;
        }
    }

    /// On a profile switch, so the new profile's delay starts from now, as AutoMinimizer.reset expects.
    pub fn restartMinimizeDelays(self: *Roster, now: win32.Ticks) void {
        for (self.clients.items) |*client| client.inactive_since = now;
    }

    /// For a change views draw that the roster doesn't hold, such as a cycle exclusion, which goes by name.
    pub fn bumpByName(self: *Roster, character_name: []const u8) void {
        for (self.clients.items) |*client| {
            if (std.mem.eql(u8, client.character_name, character_name)) client.revision +%= 1;
        }
    }

    pub fn setActive(self: *Roster, hwnd: ?win32.HWND) void {
        self.active_hwnd = hwnd;
    }

    /// After control/activation.zig brings `hwnd` forward: dismisses the alerts a click clears.
    pub fn recordClick(self: *Roster, hwnd: win32.HWND, now: win32.Ticks) void {
        const client = self.mutableByHwnd(hwnd) orelse return;
        client.last_click_time = now;
        if (client.notifications.dismissClickSuppressed(self.allocator)) client.revision +%= 1;
    }

    /// Per tick; a flashing alert bumps the revision every tick, so both its phases get drawn.
    pub fn expireAlerts(self: *Roster, now: win32.Ticks) void {
        for (self.clients.items) |*client| {
            const expired = client.notifications.expire(self.allocator, now);
            const is_flashing = if (client.notifications.newest()) |newest| newest.isFlashing(now) else false;
            if (expired or is_flashing) client.revision +%= 1;
        }
    }

    /// On a profile switch, since alerts carry the old profile's colours and durations; their throttle goes too.
    pub fn clearAlerts(self: *Roster) void {
        for (self.clients.items) |*client| {
            client.notifications.deinit(self.allocator);
            // Kept rising, as a thumbnail's render cache compares it.
            client.notifications = .{ .revision = client.notifications.revision +% 1 };
            client.revision +%= 1;
        }
    }

    /// Once log monitoring is off, so a stale system, rate or log alert doesn't stay shown.
    pub fn clearLogReadings(self: *Roster) void {
        for (self.clients.items) |*client| {
            self.clearSystem(client);
            if (client.notifications.dismissLogDriven(self.allocator)) client.revision +%= 1;
            if (client.stats.clearLogReadings()) client.revision +%= 1;
        }
    }

    fn indexOf(self: *const Roster, hwnd: win32.HWND) ?usize {
        for (self.clients.items, 0..) |client, index| {
            if (client.hwnd == hwnd) return index;
        }
        return null;
    }

    fn refreshClientConfig(self: *Roster, client: *Client, config: *const Config, auto_colors: *AutoColorStore) void {
        const display_name = config.getDisplayName(client.character_name);
        const character_color = if (scout.isGenericCharacterName(client.character_name)) null else auto_colors.characterNameColor(config, client.character_name);
        const is_name_changed = !std.mem.eql(u8, display_name, client.display_name);
        const is_shown_changed = is_name_changed or !std.meta.eql(character_color, client.character_color);
        if (is_name_changed) {
            const copy = self.allocator.dupe(u8, display_name) catch |err| {
                slog.err("Failed to copy the display name '{s}' for the roster: {}", .{ display_name, err });
                return;
            };
            self.allocator.free(client.display_name);
            client.display_name = copy;
        }
        client.character_color = character_color;
        client.is_excluded_from_minimize = config.isExcludedFromMinimize(client.character_name);
        client.is_config_stale = false;
        if (is_shown_changed) client.revision +%= 1;
    }

    fn clearSystem(self: *Roster, client: *Client) void {
        if (client.system_name.len == 0) return;
        self.allocator.free(client.system_name);
        client.system_name = "";
        client.system_name_event_timestamp = 0;
        client.revision +%= 1;
    }

    fn freeClient(self: *const Roster, client: Client) void {
        self.allocator.free(client.character_name);
        self.allocator.free(client.system_name);
        self.allocator.free(client.display_name);
        client.notifications.deinit(self.allocator);
    }

    fn dropMissing(self: *Roster, windows: []const EveWindow) void {
        var index = self.clients.items.len;
        while (index > 0) {
            index -= 1;
            const client = self.clients.items[index];
            if (isListed(windows, client.hwnd)) continue;
            slog.debug("Dropped '{s}' from the roster", .{client.character_name});
            self.freeClient(client);
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
            .inactive_since = win32.Ticks.now(),
            .last_sync = .joined,
        }) catch |err| {
            slog.err("Failed to add '{s}' to the roster: {}", .{ window.character_name, err });
            self.allocator.free(name);
            return;
        };
        slog.debug("Added '{s}' to the roster", .{name});
    }

    /// Keeps the old name if copying fails, so the next sync tries again; back at the login screen, the system and alerts go too.
    fn rename(self: *Roster, client: *Client, new_name: []const u8) void {
        const name = self.allocator.dupe(u8, new_name) catch |err| {
            slog.err("Failed to copy the new name '{s}' for the roster: {}", .{ new_name, err });
            return;
        };
        slog.debug("Renamed '{s}' to '{s}' in the roster", .{ client.character_name, name });
        const was_generic = scout.isGenericCharacterName(client.character_name);
        const is_now_generic = scout.isGenericCharacterName(name);
        const is_logout = is_now_generic and !was_generic;
        self.allocator.free(client.character_name);
        client.character_name = name;
        client.is_config_stale = true;
        client.revision +%= 1;
        if (was_generic and !is_now_generic) client.last_sync = .logged_in;
        if (!is_logout) return;
        self.clearSystem(client);
        _ = client.notifications.clear(self.allocator);
    }
};

fn isListed(windows: []const EveWindow, hwnd: win32.HWND) bool {
    for (windows) |window| {
        if (window.hwnd == hwnd) return true;
    }
    return false;
}

const testing = std.testing;

fn testAlert(notification_type: @FieldType(stack.ActiveNotification, "notification_type"), duration_ms: u32) !stack.ActiveNotification {
    return .{
        .text = try testing.allocator.dupe(u8, "alert"),
        .notification_type = notification_type,
        .start_time = .{ .ms = 1000 },
        .duration_ms = duration_ms,
        .suppress_when_focused = false,
        .suppress_when_clicked = true,
    };
}

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

test "logging out renames the client to the login screen's name and clears its login time and system" {
    var roster: Roster = .init(testing.allocator);
    defer roster.deinit();
    roster.sync(&.{testWindow(1, "Alpha", 900)});
    try roster.updateSystem(@ptrFromInt(1), "Jita", 0, null);
    roster.sync(&.{testWindow(1, "EVE", 0)});

    const client = roster.byHwnd(@ptrFromInt(1)) orelse return error.TestExpectedClient;
    try testing.expect(scout.isGenericCharacterName(client.character_name));
    try testing.expect(client.logged_in_at.isZero());
    try testing.expectEqualStrings("", client.system_name);
}

test "a sync marks who joined and who logged in, and the next sync clears both" {
    var roster: Roster = .init(testing.allocator);
    defer roster.deinit();
    roster.sync(&.{testWindow(1, "EVE", 0)});
    try testing.expectEqual(SyncChange.joined, roster.clients.items[0].last_sync);

    roster.sync(&.{ testWindow(1, "Alpha", 900), testWindow(2, "Beta", 700) });
    try testing.expectEqual(SyncChange.logged_in, roster.clients.items[0].last_sync);
    try testing.expectEqual(SyncChange.joined, roster.clients.items[1].last_sync);

    roster.sync(&.{ testWindow(1, "Alpha", 900), testWindow(2, "Beta", 700) });
    try testing.expectEqual(SyncChange.none, roster.clients.items[0].last_sync);
    try testing.expectEqual(SyncChange.none, roster.clients.items[1].last_sync);
}

test "a renamed client waits for its profile settings, and an unchanged one doesn't" {
    var roster: Roster = .init(testing.allocator);
    defer roster.deinit();
    roster.sync(&.{ testWindow(1, "EVE", 0), testWindow(2, "Beta", 700) });
    for (roster.clients.items) |*client| client.is_config_stale = false;
    roster.sync(&.{ testWindow(1, "Alpha", 900), testWindow(2, "Beta", 700) });

    try testing.expect(roster.clients.items[0].is_config_stale);
    try testing.expect(!roster.clients.items[1].is_config_stale);
}

test "logging out drops the client's alerts" {
    var roster: Roster = .init(testing.allocator);
    defer roster.deinit();
    roster.sync(&.{testWindow(1, "Alpha", 900)});
    const client = roster.mutableByHwnd(@ptrFromInt(1)) orelse return error.TestExpectedClient;
    client.notifications.push(testing.allocator, try testAlert(.TakingDamage, 0));
    roster.sync(&.{testWindow(1, "EVE", 0)});

    try testing.expect(roster.readingsOf(@ptrFromInt(1)).alerts.isEmpty());
}

test "a click dismisses click-suppressed alerts and bumps the revision" {
    var roster: Roster = .init(testing.allocator);
    defer roster.deinit();
    roster.sync(&.{testWindow(1, "Alpha", 900)});
    const client = roster.mutableByHwnd(@ptrFromInt(1)) orelse return error.TestExpectedClient;
    client.notifications.push(testing.allocator, try testAlert(.TakingDamage, 0));
    roster.recordClick(@ptrFromInt(1), .{ .ms = 2000 });

    try testing.expect(roster.readingsOf(@ptrFromInt(1)).alerts.isEmpty());
    try testing.expectEqual(@as(u64, 2000), client.last_click_time.ms);
    try testing.expectEqual(@as(u32, 1), client.revision);
}

test "an alert past its duration expires; a profile switch clears the rest, throttle included" {
    var roster: Roster = .init(testing.allocator);
    defer roster.deinit();
    roster.sync(&.{testWindow(1, "Alpha", 900)});
    const client = roster.mutableByHwnd(@ptrFromInt(1)) orelse return error.TestExpectedClient;
    client.notifications.push(testing.allocator, try testAlert(.TakingDamage, 500));
    client.notifications.push(testing.allocator, try testAlert(.MiningIdle, 0));
    client.notifications.markShown(.MiningIdle, .{ .ms = 1000 });
    roster.expireAlerts(.{ .ms = 1600 });
    try testing.expectEqual(@as(usize, 1), client.notifications.items().len);

    roster.clearAlerts();
    try testing.expect(client.notifications.isEmpty());
    try testing.expect(!client.notifications.isThrottled(.MiningIdle, 60_000, .{ .ms = 1700 }));
}

test "a window gone from Scout's list leaves the roster" {
    var roster: Roster = .init(testing.allocator);
    defer roster.deinit();
    roster.sync(&.{ testWindow(1, "Alpha", 500), testWindow(2, "Beta", 600) });
    try roster.updateSystem(@ptrFromInt(1), "Jita", 0, null);
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

test "a system update sets the system and bumps the revision; a jump records its time" {
    var roster: Roster = .init(testing.allocator);
    defer roster.deinit();
    roster.sync(&.{testWindow(1, "Alpha", 500)});
    try roster.updateSystem(@ptrFromInt(1), "Jita", 20260101120000, null);
    try roster.updateSystem(@ptrFromInt(1), "Perimeter", 20260101120100, 4_000);

    const client = roster.byHwnd(@ptrFromInt(1)) orelse return error.TestExpectedClient;
    try testing.expectEqualStrings("Perimeter", client.system_name);
    try testing.expectEqual(@as(u32, 2), client.revision);
    try testing.expectEqual(@as(u64, 4_000), client.travel.last_jump_ms);
}

test "a system update older than the one shown is skipped, and an undated one always applies" {
    var roster: Roster = .init(testing.allocator);
    defer roster.deinit();
    roster.sync(&.{testWindow(1, "Alpha", 500)});
    try roster.updateSystem(@ptrFromInt(1), "Perimeter", 20260101120100, null);
    try roster.updateSystem(@ptrFromInt(1), "Jita", 20260101120000, null);
    const client = roster.byHwnd(@ptrFromInt(1)) orelse return error.TestExpectedClient;
    try testing.expectEqualStrings("Perimeter", client.system_name);

    try roster.updateSystem(@ptrFromInt(1), "Amarr", 0, null);
    try testing.expectEqualStrings("Amarr", client.system_name);
}

test "a stats push that changes a reading bumps the revision, and clearing log readings drops the rate" {
    var roster: Roster = .init(testing.allocator);
    defer roster.deinit();
    roster.sync(&.{testWindow(1, "Alpha", 500)});
    roster.updateStats(@ptrFromInt(1), ActivityStats.setDps, .{ 120.0, 80.0 });
    const client = roster.byHwnd(@ptrFromInt(1)) orelse return error.TestExpectedClient;
    try testing.expectEqual(@as(u32, 1), client.revision);
    try testing.expectEqual(@as(?f32, 120.0), roster.readingsOf(@ptrFromInt(1)).stats.incoming_dps);

    roster.clearLogReadings();
    try testing.expect(!client.stats.has_dps);
    try testing.expectEqual(@as(u32, 2), client.revision);
}

test "a window the roster doesn't track reads as no alerts and no readings" {
    var roster: Roster = .init(testing.allocator);
    defer roster.deinit();
    const readings = roster.readingsOf(@ptrFromInt(7));
    try testing.expect(readings.alerts.isEmpty());
    try testing.expect(!readings.stats.has_dps);
}

test "clearing log readings empties every system and keeps travel" {
    var roster: Roster = .init(testing.allocator);
    defer roster.deinit();
    roster.sync(&.{ testWindow(1, "Alpha", 500), testWindow(2, "Beta", 600) });
    try roster.updateSystem(@ptrFromInt(1), "Jita", 0, 4_000);
    roster.clearLogReadings();

    try testing.expectEqualStrings("", roster.clients.items[0].system_name);
    try testing.expectEqual(@as(u64, 4_000), roster.clients.items[0].travel.last_jump_ms);
    try testing.expectEqual(@as(u32, 0), roster.clients.items[1].revision);
}
